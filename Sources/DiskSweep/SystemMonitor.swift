import AppKit
import Darwin

/// Memory figures matching Activity Monitor's Memory tab.
struct MemoryStats {
    var total = ProcessInfo.processInfo.physicalMemory
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0
    /// 1 = normal, 2 = warning, 4 = critical (kern.memorystatus_vm_pressure_level).
    var pressureLevel: Int32 = 1

    var used: UInt64 { app + wired + compressed }

    var pressureLabel: String {
        switch pressureLevel {
        case 4: "Critical"
        case 2: "High"
        default: "Normal"
        }
    }

    var pressureColor: NSColor {
        switch pressureLevel {
        case 4: .systemRed
        case 2: .systemOrange
        default: .systemGreen
        }
    }
}

/// One app and all its helper processes (e.g. Chrome and every Chrome Helper), with total memory.
struct AppMemory: Identifiable {
    let bundlePath: String
    let name: String
    let bundleID: String?
    let bytes: UInt64
    let processCount: Int
    let isBackground: Bool
    var id: String { bundlePath }

    var runningApp: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == bundlePath }
    }

    /// Apps DiskSweep never offers to quit.
    var isProtected: Bool {
        let protectedIDs: Set<String> = ["com.apple.finder", "com.apple.dock", "com.apple.systemuiserver",
                                         "com.apple.loginwindow", "com.apple.controlcenter"]
        return bundleID.map { protectedIDs.contains($0) || $0 == Bundle.main.bundleIdentifier } ?? false
    }
}

/// Live memory statistics and per-app memory use, refreshed every few seconds.
@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var memory = MemoryStats()
    @Published private(set) var apps: [AppMemory] = []
    @Published private(set) var isFreeingMemory = false
    @Published var memoryMessage: String?
    // Inactive apps
    @Published var inactiveMinutes: Int = UserDefaults.standard.object(forKey: "inactiveMinutes") as? Int ?? 30 {
        didSet { UserDefaults.standard.set(inactiveMinutes, forKey: "inactiveMinutes") }
    }
    @Published var autoQuitInactive: Bool = UserDefaults.standard.bool(forKey: "autoQuitInactive") {
        didSet { UserDefaults.standard.set(autoQuitInactive, forKey: "autoQuitInactive") }
    }
    @Published var keepOpen: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "keepOpenApps") ?? SystemMonitor.defaultKeepOpen) {
        didSet { UserDefaults.standard.set(Array(keepOpen), forKey: "keepOpenApps") }
    }
    @Published private(set) var lastAutoQuit: (names: [String], date: Date)?
    /// When each running app was last in front, keyed by "pid-launchTime" so the record survives
    /// DiskSweep restarting (e.g. for an update) but never applies to a relaunched app.
    private var lastActive: [String: Double] = UserDefaults.standard.dictionary(forKey: "appLastActive") as? [String: Double] ?? [:]
    private var lastAutoQuitCheck = Date.distantPast
    /// DiskSweep can only see app switches while it's running. Apps it hasn't seen in front yet
    /// count as used when it started, so nothing is treated as idle just because it's unknown.
    private let trackingStarted = Date()

    /// Apps that play audio or hold calls; quitting them while idle would cut off music or a call.
    static let defaultKeepOpen = [
        "com.apple.Music", "com.spotify.client", "com.apple.podcasts", "com.tidal.desktop",
        "com.image-line.flstudio", "com.ableton.live", "com.apple.logic10", "com.apple.garageband10",
        "us.zoom.xos", "com.microsoft.teams2", "com.apple.FaceTime", "com.hnc.Discord", "com.apple.QuickTimePlayerX",
    ]

    @Published private(set) var launchItems: [LaunchItem] = []
    @Published private(set) var changingLaunchItem: String?
    @Published var launchMessage: String?

    private var timer: Timer?
    private var isRefreshing = false

    init() {
        refresh()
        refreshLaunchItems()
        // Track which app is in front, to know how long every other app has gone unused.
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self.markActive(app) }
        }
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self.markActive(app) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        autoQuitIfNeeded()
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            let (memory, apps) = await Task.detached(priority: .utility) {
                (Self.readMemory(), Self.readApps())
            }.value
            self.memory = memory
            self.apps = apps
            isRefreshing = false
        }
    }

    var backgroundApps: [AppMemory] { apps.filter { $0.isBackground && !$0.isProtected } }

    /// Every open app (with a window or Dock icon) that can be quit: everything except
    /// DiskSweep itself and core macOS apps like Finder.
    var openApps: [AppMemory] { apps.filter { !$0.isBackground && !$0.isProtected } }

    // MARK: - Inactive apps

    private static func key(for app: NSRunningApplication) -> String {
        "\(app.processIdentifier)-\(Int(app.launchDate?.timeIntervalSince1970 ?? 0))"
    }

    private func markActive(_ app: NSRunningApplication) {
        lastActive[Self.key(for: app)] = Date().timeIntervalSince1970
        // Forget apps that are no longer running.
        let live = Set(NSWorkspace.shared.runningApplications.map(Self.key(for:)))
        lastActive = lastActive.filter { live.contains($0.key) }
        UserDefaults.standard.set(lastActive, forKey: "appLastActive")
    }

    /// When the app was last used: now if it's in front, else when it last left the front.
    /// With no record, the later of when it was opened and when DiskSweep started watching.
    func lastUsed(_ app: AppMemory) -> Date? {
        guard let running = app.runningApp else { return nil }
        if running.isActive { return Date() }
        if let seconds = lastActive[Self.key(for: running)] { return Date(timeIntervalSince1970: seconds) }
        return max(running.launchDate ?? trackingStarted, trackingStarted)
    }

    func idleMinutes(_ app: AppMemory) -> Int? {
        lastUsed(app).map { Int(Date().timeIntervalSince($0) / 60) }
    }

    func isKeptOpen(_ app: AppMemory) -> Bool { app.bundleID.map { keepOpen.contains($0) } ?? false }

    func setKeepOpen(_ app: AppMemory, _ keep: Bool) {
        guard let id = app.bundleID else { return }
        if keep { keepOpen.insert(id) } else { keepOpen.remove(id) }
    }

    /// Open apps not used for at least `inactiveMinutes`, excluding the app in front,
    /// DiskSweep, Finder and anything on the Keep Open list.
    var inactiveApps: [AppMemory] {
        openApps.filter { app in
            guard !isKeptOpen(app), app.runningApp?.isActive == false, let idle = idleMinutes(app) else { return false }
            return idle >= inactiveMinutes
        }
    }

    func quitInactiveApps() {
        for app in inactiveApps { app.runningApp?.terminate() }
        Task {
            try? await Task.sleep(for: .seconds(2))
            refresh()
        }
    }

    /// With Auto-quit on, checks once a minute and quits apps idle past the limit.
    private func autoQuitIfNeeded() {
        guard autoQuitInactive, Date().timeIntervalSince(lastAutoQuitCheck) >= 60 else { return }
        lastAutoQuitCheck = Date()
        let targets = inactiveApps
        guard !targets.isEmpty else { return }
        for app in targets { app.runningApp?.terminate() }
        lastAutoQuit = (targets.map(\.name), Date())
    }

    // MARK: - Background items

    func refreshLaunchItems() {
        Task {
            launchItems = await Task.detached(priority: .utility) { BackgroundItems.load() }.value
        }
    }

    /// Turns a background item off (stops it and keeps it from starting again) or back on.
    func setEnabled(_ item: LaunchItem, _ enabled: Bool) {
        changingLaunchItem = item.id
        Task {
            let ok = await Task.detached { BackgroundItems.setEnabled(item, enabled) }.value
            changingLaunchItem = nil
            if !ok {
                launchMessage = item.scope == .systemDaemon
                    ? "\(item.displayName) wasn't changed. System items need your administrator password."
                    : "macOS didn't allow \(item.displayName) to be changed."
            }
            launchItems = await Task.detached(priority: .utility) { BackgroundItems.load() }.value
            refresh()
        }
    }

    // MARK: - Actions

    func quit(_ app: AppMemory, force: Bool = false) {
        guard !app.isProtected, let running = app.runningApp else { return }
        if force { running.forceTerminate() } else { running.terminate() }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            refresh()
        }
    }

    /// Every app that can be quit, open or running in the background: all except DiskSweep and
    /// core macOS apps like Finder.
    var allQuittableApps: [AppMemory] { apps.filter { !$0.isProtected } }

    /// Quits every other app the same way ⌘Q does, so apps with unsaved work still ask to save.
    func quitAllApps() { quitAndMeasure(allQuittableApps, cacheToo: false) }

    func quitBackgroundApps() { quitAndMeasure(backgroundApps, cacheToo: false) }

    /// What Free Up Memory would quit: apps unused for the inactive limit plus background apps,
    /// leaving out the app in front and anything on the Keep Open list.
    var freeUpTargets: [AppMemory] {
        var seen = Set<String>()
        return (inactiveApps + backgroundApps.filter { !isKeptOpen($0) }).filter { seen.insert($0.id).inserted }
    }

    /// Frees memory the way that actually works on Apple silicon: quitting apps you aren't
    /// using. No password needed. Reports how much memory use dropped.
    func freeUpMemory() { quitAndMeasure(freeUpTargets, cacheToo: false) }

    /// Also drops cached files from memory using macOS's `purge`, which needs administrator
    /// rights, so macOS shows its own password prompt. DiskSweep never sees the password.
    func clearFileCache() { quitAndMeasure([], cacheToo: true) }

    private func quitAndMeasure(_ targets: [AppMemory], cacheToo: Bool) {
        guard !isFreeingMemory else { return }
        isFreeingMemory = true
        let before = Self.readMemory()
        let names = targets.map(\.name)
        for app in targets { app.runningApp?.terminate() }
        Task {
            var purgeStatus: Int32 = 0
            if cacheToo {
                purgeStatus = await Task.detached { () -> Int32 in
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    process.arguments = ["-e", "do shell script \"/usr/sbin/purge\" with administrator privileges"]
                    process.standardError = FileHandle.nullDevice
                    do {
                        try process.run()
                        process.waitUntilExit()
                        return process.terminationStatus
                    } catch {
                        return -1
                    }
                }.value
            }
            // Give apps time to finish quitting and macOS time to reclaim their memory.
            if !targets.isEmpty { try? await Task.sleep(for: .seconds(4)) }
            let after = Self.readMemory()
            isFreeingMemory = false
            refresh()

            if cacheToo && purgeStatus != 0 {
                memoryMessage = "The file cache wasn't cleared. The password prompt was cancelled."
                return
            }
            if !cacheToo && targets.isEmpty {
                let top = apps.first { !$0.isProtected }
                memoryMessage = "Nothing to quit: every open app has been used in the last \(inactiveMinutes) minutes or is on your Keep Open list."
                    + (top.map { " To free more memory, quit an app you don't need. \($0.name) is using \(Fmt.bytes(Int64($0.bytes)))." } ?? "")
                return
            }
            let usedDrop = before.used > after.used ? before.used - after.used : 0
            let freeGain = after.free > before.free ? after.free - before.free : 0
            var message = cacheToo
                ? "Cleared \(Fmt.bytes(Int64(freeGain))) of cached files from memory. macOS refills the cache as you work. That's normal."
                : "Quit \(names.count) app\(names.count == 1 ? "" : "s"): \(names.prefix(6).joined(separator: ", "))\(names.count > 6 ? "…" : "")."
            if !cacheToo {
                message += usedDrop > 0
                    ? "\n\nMemory in use dropped by \(Fmt.bytes(Int64(usedDrop))): \(Fmt.bytes(Int64(before.used))) → \(Fmt.bytes(Int64(after.used)))."
                    : "\n\nmacOS is still reclaiming their memory. The numbers will drop over the next few seconds."
            }
            memoryMessage = message
        }
    }

    // MARK: - Reading system state

    nonisolated static func readMemory() -> MemoryStats {
        var result = MemoryStats()
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if status == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let purgeable = UInt64(stats.purgeable_count)
            let anonymous = UInt64(stats.internal_page_count)
            result.app = (anonymous > purgeable ? anonymous - purgeable : 0) * page
            result.wired = UInt64(stats.wire_count) * page
            result.compressed = UInt64(stats.compressor_page_count) * page
            result.cached = (UInt64(stats.external_page_count) + purgeable) * page
            result.free = UInt64(stats.free_count) * page
        }
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 { result.swapUsed = swap.xsu_used }
        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 { result.pressureLevel = level }
        return result
    }

    /// Groups every process by the app bundle it lives in, so helpers count toward their app.
    nonisolated static func readApps() -> [AppMemory] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        var totals: [String: (bytes: UInt64, processes: Int)] = [:]
        var pathBuffer = [CChar](repeating: 0, count: 4096)

        for pid in pids.prefix(max(count, 0)) where pid > 0 {
            guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { continue }
            let path = String(cString: pathBuffer)
            // The first ".app/" is the outermost app, so helpers nested inside it count toward it.
            guard let range = path.range(of: ".app/") else { continue }
            let bundle = String(path[..<range.lowerBound]) + ".app"
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard ok == 0 else { continue }
            totals[bundle, default: (0, 0)].bytes += info.ri_phys_footprint
            totals[bundle, default: (0, 0)].processes += 1
        }

        let running = NSWorkspace.shared.runningApplications
        return totals.compactMap { bundlePath, total -> AppMemory? in
            guard let app = running.first(where: { $0.bundleURL?.path == bundlePath }) else { return nil }
            let isApple = app.bundleIdentifier?.hasPrefix("com.apple.") ?? false
            let isBackground = app.activationPolicy != .regular
            // Apple's own background helpers are part of macOS; only show Apple apps you opened.
            if isApple && isBackground { return nil }
            return AppMemory(bundlePath: bundlePath, name: app.localizedName ?? (bundlePath as NSString).lastPathComponent,
                             bundleID: app.bundleIdentifier, bytes: total.bytes, processCount: total.processes,
                             isBackground: isBackground)
        }
        .sorted { $0.bytes > $1.bytes }
    }
}
