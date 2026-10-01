import AppKit
import SwiftUI

/// "Speed Settings": a checklist of macOS and Chrome settings that make a real difference on a slow
/// Mac. Every check only *reads* settings. DiskSweep never changes them: each row opens the right
/// Settings page and says what to switch, so the user stays in control of their system.

enum SpeedImpact: Int, Comparable {
    case big, medium, small

    var label: String {
        switch self {
        case .big: "Big difference"
        case .medium: "Some difference"
        case .small: "Small difference"
        }
    }

    static func < (a: SpeedImpact, b: SpeedImpact) -> Bool { a.rawValue < b.rawValue }
}

enum SpeedStatus {
    case good, tip, unknown

    var symbol: String {
        switch self {
        case .good: "checkmark.circle.fill"
        case .tip: "exclamationmark.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .good: .green
        case .tip: .orange
        case .unknown: .secondary
        }
    }
}

enum SpeedAction {
    case settings(String)            // x-apple.systempreferences URL
    case chrome(String)              // chrome:// page
    case page(Category)              // a DiskSweep page
}

struct SpeedCheck: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let impact: SpeedImpact
    let status: SpeedStatus
    /// What DiskSweep found, in plain words.
    let finding: String
    /// What to do, shown only when there's something to improve.
    let howTo: String?
    let actionTitle: String?
    let action: SpeedAction?
}

/// Plain values read off the main thread, turned into checks on the main actor.
private struct SpeedFacts: Sendable {
    var chromeInstalled = false
    var memorySaverOn: Bool?
    var memorySaverLevel: Int?
    var chromeExtensions: [String] = []
    var indexedAudio: [(folder: String, count: Int)] = []
    var indexedAudioTotal = 0
    var appleIntelligenceOn: Bool?
    var uptimeDays = 0
    var lowPowerOnCharger = false
    var lowPowerOnBattery = false
    var hasBattery = false
    var movingWallpaper = false
    var freeBytes: Int64 = 0
    var totalBytes: Int64 = 0
}

@MainActor
final class SpeedSettingsChecker: ObservableObject {
    @Published private(set) var checks: [SpeedCheck] = []
    @Published private(set) var isChecking = false
    @Published var message: String?

    func refresh(enabledBackgroundItems: Int) {
        guard !isChecking else { return }
        isChecking = true
        // These two are public AppKit settings and must be read on the main thread.
        let transparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let motion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        Task {
            let facts = await Task.detached(priority: .userInitiated) { Self.readFacts() }.value
            checks = Self.makeChecks(facts, reduceTransparency: transparency, reduceMotion: motion,
                                     backgroundItems: enabledBackgroundItems)
                .sorted { ($0.status == .good ? 1 : 0, $0.impact) < ($1.status == .good ? 1 : 0, $1.impact) }
            isChecking = false
        }
    }

    // MARK: Actions

    func perform(_ action: SpeedAction, model: AppModel) {
        switch action {
        case .settings(let url):
            if let url = URL(string: url) { NSWorkspace.shared.open(url) }
        case .page(let category):
            model.navigate(to: category)
        case .chrome(let page):
            openInChrome(page)
        }
    }

    /// Chrome won't open its own chrome:// pages from a link, so ask it over AppleScript (macOS asks
    /// once whether DiskSweep may control Chrome). If that's refused, copy the address instead.
    private func openInChrome(_ page: String) {
        let source = """
        tell application "Google Chrome"
            activate
            if (count of windows) is 0 then make new window
            tell front window to make new tab with properties {URL:"\(page)"}
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if error != nil {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(page, forType: .string)
            if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
                NSWorkspace.shared.openApplication(at: chrome, configuration: .init())
            }
            message = "The address \(page) is copied. In Chrome, click the address bar, paste it (⌘V) and press Return."
        }
    }

    // MARK: Reading settings (read-only)

    nonisolated private static func readFacts() -> SpeedFacts {
        var f = SpeedFacts()
        let home = NSHomeDirectory()
        let fm = FileManager.default

        // Chrome: Memory Saver lives in "Local State", extensions in each profile's preferences.
        let chrome = home + "/Library/Application Support/Google/Chrome"
        f.chromeInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") != nil
        if let state = json(chrome + "/Local State") {
            let tuning = state["performance_tuning"] as? [String: Any]
            let mode = (tuning?["high_efficiency_mode"] as? [String: Any])?["state"] as? Int
            // Chrome's states: 0 = off, 2 = on (1 is an old "on a timer" value, also on).
            f.memorySaverOn = mode.map { $0 != 0 } ?? false
            f.memorySaverLevel = (tuning?["memory_saver_mode"] as? [String: Any])?["aggressiveness"] as? Int
            let profiles = ((state["profile"] as? [String: Any])?["info_cache"] as? [String: Any])?.keys.sorted() ?? ["Default"]
            var names = Set<String>()
            for profile in profiles {
                var settings: [String: Any] = [:]
                for file in ["Preferences", "Secure Preferences"] {
                    let s = ((json(chrome + "/" + profile + "/" + file)?["extensions"] as? [String: Any])?["settings"] as? [String: Any]) ?? [:]
                    for (id, value) in s {
                        var merged = settings[id] as? [String: Any] ?? [:]
                        merged.merge(value as? [String: Any] ?? [:]) { _, new in new }
                        settings[id] = merged
                    }
                }
                for value in settings.values.compactMap({ $0 as? [String: Any] }) {
                    // Location 1 = installed from the Web Store, 4 = loaded unpacked. Others are built in.
                    guard let location = value["location"] as? Int, location == 1 || location == 4 else { continue }
                    let reasons = value["disable_reasons"] as? [Any] ?? []
                    let disabled = !reasons.isEmpty || (value["state"] as? Int) == 0
                    guard !disabled, let name = (value["manifest"] as? [String: Any])?["name"] as? String,
                          !name.hasPrefix("__MSG_") else { continue }
                    names.insert(name)
                }
            }
            f.chromeExtensions = names.sorted()
        }

        // Spotlight: audio files it's indexing in your folders (sample libraries, stems, bounces).
        let audio = shell("/usr/bin/mdfind", ["-onlyin", home, "kMDItemContentTypeTree == 'public.audio'"])
            .split(separator: "\n").map(String.init)
        f.indexedAudioTotal = audio.count
        var byFolder: [String: Int] = [:]
        for path in audio where path.hasPrefix(home + "/") {
            let parts = path.dropFirst(home.count + 1).split(separator: "/")
            guard parts.count > 1 else { continue }
            let depth = parts.first == "Library" ? min(3, parts.count - 1) : min(2, parts.count - 1)
            byFolder["~/" + parts.prefix(depth).joined(separator: "/"), default: 0] += 1
        }
        f.indexedAudio = byFolder.sorted { $0.value > $1.value }.prefix(3).map { ($0.key, $0.value) }

        // Apple Intelligence: macOS records the opt-in in this domain. Not documented, so only "looks on".
        let domain = "com.apple.CloudSubscriptionFeatures.optIn" as CFString
        if let keys = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String], !keys.isEmpty {
            f.appleIntelligenceOn = keys.contains {
                (CFPreferencesCopyValue($0 as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool) == true
            }
        }

        // Time since the last restart.
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 {
            f.uptimeDays = Int(Date().timeIntervalSince1970 - Double(boot.tv_sec)) / 86_400
        }

        // Low Power Mode per power source.
        var section = ""
        for line in shell("/usr/bin/pmset", ["-g", "custom"]).split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasSuffix("Power:") { section = text; if text.hasPrefix("Battery") { f.hasBattery = true }; continue }
            let fields = text.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 2, fields[0] == "lowpowermode" else { continue }
            let on = fields[1] != "0"
            if section.hasPrefix("AC") { f.lowPowerOnCharger = on } else if section.hasPrefix("Battery") { f.lowPowerOnBattery = on }
        }

        // Wallpaper: aerials are videos that keep playing; still and dynamic pictures cost next to nothing.
        if let data = fm.contents(atPath: home + "/Library/Application Support/com.apple.wallpaper/Store/Index.plist"),
           let text = String(data: data, encoding: .ascii) ?? String(data: data, encoding: .isoLatin1) {
            f.movingWallpaper = text.contains("com.apple.wallpaper.choice.aerials")
        }

        // Free space on the startup disk.
        if let values = try? URL(fileURLWithPath: home).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            f.freeBytes = values.volumeAvailableCapacityForImportantUsage ?? 0
            f.totalBytes = Int64(values.volumeTotalCapacity ?? 0)
        }
        return f
    }

    nonisolated private static func json(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    nonisolated private static func shell(_ tool: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: Turning facts into advice

    private static func makeChecks(_ f: SpeedFacts, reduceTransparency: Bool, reduceMotion: Bool, backgroundItems: Int) -> [SpeedCheck] {
        var checks: [SpeedCheck] = []

        if f.chromeInstalled {
            let level = ["Moderate", "Balanced", "Maximum"]
            let current = f.memorySaverLevel.flatMap { level.indices.contains($0) ? level[$0] : nil } ?? "Balanced"
            let on = f.memorySaverOn == true
            let maximum = on && f.memorySaverLevel == 2
            checks.append(SpeedCheck(
                id: "memorySaver", title: "Chrome Memory Saver", symbol: "leaf", impact: .big,
                status: maximum ? .good : .tip,
                finding: !on ? "Memory Saver is off, so every Chrome tab keeps its memory even when you're not looking at it."
                    : maximum ? "Memory Saver is on and set to Maximum. Tabs you aren't using give their memory back quickly."
                    : "Memory Saver is on, set to \(current). On a Mac with little memory, Maximum frees tabs sooner.",
                howTo: maximum ? nil : "Turn on Memory Saver and choose Maximum. A sleeping tab reloads when you click it.",
                actionTitle: "Open Chrome Performance", action: .chrome("chrome://settings/performance")))

            let count = f.chromeExtensions.count
            let shown = f.chromeExtensions.prefix(6).joined(separator: ", ") + (count > 6 ? " and \(count - 6) more" : "")
            checks.append(SpeedCheck(
                id: "extensions", title: "Chrome extensions", symbol: "puzzlepiece.extension", impact: count >= 8 ? .big : .medium,
                status: count >= 8 ? .tip : .good,
                finding: count == 0 ? "No extensions are switched on."
                    : "\(count) extension\(count == 1 ? " is" : "s are") switched on: \(shown).",
                howTo: count >= 8 ? "Each extension runs all the time, in every window. Remove the ones you don't use every week (especially VPNs and ad blockers doubling up)." : nil,
                actionTitle: "Open Chrome Extensions", action: .chrome("chrome://extensions")))
        }

        let restartTip = f.uptimeDays >= 7
        checks.append(SpeedCheck(
            id: "restart", title: "Restart now and then", symbol: "arrow.clockwise.circle", impact: .big,
            status: restartTip ? .tip : .good,
            finding: f.uptimeDays == 0 ? "Your Mac was restarted today."
                : "Your Mac was last restarted \(f.uptimeDays) day\(f.uptimeDays == 1 ? "" : "s") ago.",
            howTo: restartTip ? "Save your work, then choose Restart from the Apple menu. It empties swap and resets apps that slowly take more memory. Once a week is plenty." : nil,
            actionTitle: nil, action: nil))

        let freeShare = f.totalBytes > 0 ? Double(f.freeBytes) / Double(f.totalBytes) : 1
        checks.append(SpeedCheck(
            id: "space", title: "Free disk space", symbol: "internaldrive", impact: freeShare < 0.10 ? .big : .medium,
            status: freeShare >= 0.15 ? .good : .tip,
            finding: "\(Fmt.bytes(f.freeBytes)) free (\(Int((freeShare * 100).rounded()))% of the disk).",
            howTo: freeShare >= 0.15 ? nil : "macOS uses free space as extra memory (swap). Below about 15% free it slows down. Smart Care shows what's safe to remove.",
            actionTitle: freeShare >= 0.15 ? nil : "Open Smart Care", action: freeShare >= 0.15 ? nil : .page(.dashboard)))

        let manyAudio = f.indexedAudioTotal >= 3000
        let folders = f.indexedAudio.map { "\($0.folder) (\($0.count))" }.joined(separator: ", ")
        checks.append(SpeedCheck(
            id: "spotlight", title: "Spotlight and sample libraries", symbol: "magnifyingglass", impact: manyAudio ? .medium : .small,
            status: manyAudio ? .tip : .good,
            finding: f.indexedAudioTotal == 0 ? "Spotlight isn't indexing any audio files in your folders."
                : "Spotlight is indexing \(f.indexedAudioTotal.formatted()) audio file\(f.indexedAudioTotal == 1 ? "" : "s")" + (folders.isEmpty ? "." : ", mostly in \(folders)."),
            howTo: manyAudio ? "Add big sample, loop and stems folders to Spotlight's Search Privacy list so it stops reading them in the background. Your DAW's own browser still finds them." : nil,
            actionTitle: "Open Spotlight Settings", action: .settings("x-apple.systempreferences:com.apple.Spotlight-Settings.extension")))

        checks.append(SpeedCheck(
            id: "intelligence", title: "Apple Intelligence", symbol: "brain.head.profile", impact: .medium,
            status: f.appleIntelligenceOn == true ? .tip : (f.appleIntelligenceOn == false ? .good : .unknown),
            finding: f.appleIntelligenceOn == true ? "It looks like Apple Intelligence is on. Its on-device models use memory and several GB of disk."
                : f.appleIntelligenceOn == false ? "Apple Intelligence looks off." : "DiskSweep can't tell whether Apple Intelligence is on.",
            howTo: f.appleIntelligenceOn == false ? nil : "If you don't use Writing Tools, Genmoji or the new Siri, switching it off frees memory, which matters most on 8 GB Macs.",
            actionTitle: "Open Apple Intelligence Settings", action: .settings("x-apple.systempreferences:com.apple.Siri-Settings.extension")))

        checks.append(SpeedCheck(
            id: "background", title: "Background and login items", symbol: "gearshape.2", impact: .medium,
            status: backgroundItems >= 6 ? .tip : .good,
            finding: "\(backgroundItems) background helper\(backgroundItems == 1 ? " is" : "s are") switched on.",
            howTo: backgroundItems >= 6 ? "Switch off helpers for apps you rarely use, and check which apps open at login." : nil,
            actionTitle: "Open Background Items", action: .page(.background)))

        if f.hasBattery || f.lowPowerOnCharger {
            checks.append(SpeedCheck(
                id: "lowPower", title: "Low Power Mode", symbol: "battery.50", impact: .medium,
                status: f.lowPowerOnCharger ? .tip : .good,
                finding: f.lowPowerOnCharger ? "Low Power Mode stays on while plugged in, so your Mac runs slower on purpose."
                    : f.lowPowerOnBattery ? "Low Power Mode is on only on battery. Full speed when plugged in."
                    : "Low Power Mode is off.",
                howTo: f.lowPowerOnCharger ? "Set Low Power Mode to \"Only on Battery\" or \"Never\"." : nil,
                actionTitle: "Open Battery Settings", action: .settings("x-apple.systempreferences:com.apple.Battery-Settings.extension")))
        }

        checks.append(SpeedCheck(
            id: "transparency", title: "Reduce transparency", symbol: "square.on.square.intersection.dashed", impact: .small,
            status: reduceTransparency ? .good : .tip,
            finding: reduceTransparency ? "On. Windows and menus skip the see-through glass effect."
                : "Off. The see-through glass effect in macOS 26 takes extra graphics work.",
            howTo: reduceTransparency ? nil : "Turn on Accessibility → Display → Reduce transparency. Menus and windows look more solid.",
            actionTitle: "Open Display Accessibility", action: .settings("x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Display")))

        checks.append(SpeedCheck(
            id: "motion", title: "Reduce motion", symbol: "wind", impact: .small,
            status: reduceMotion ? .good : .tip,
            finding: reduceMotion ? "On. Animations are short and simple."
                : "Off. Opening apps and switching spaces use full animations.",
            howTo: reduceMotion ? nil : "Turn on Accessibility → Display → Reduce motion. Your Mac isn't faster, but it feels snappier.",
            actionTitle: "Open Display Accessibility", action: .settings("x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Display")))

        checks.append(SpeedCheck(
            id: "wallpaper", title: "Wallpaper and widgets", symbol: "photo.on.rectangle", impact: .small,
            status: f.movingWallpaper ? .tip : .good,
            finding: f.movingWallpaper ? "Your wallpaper is a moving aerial video, which keeps playing in the background."
                : "Your wallpaper is a still or dynamic picture, which costs next to nothing.",
            howTo: f.movingWallpaper ? "Pick a still picture. Remove desktop widgets you don't look at, too: each one keeps running." : nil,
            actionTitle: "Open Wallpaper Settings", action: .settings("x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")))

        return checks
    }
}

// MARK: - Page

struct SpeedSettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var monitor: SystemMonitor
    @StateObject private var checker = SpeedSettingsChecker()

    var body: some View {
        let checks = checker.checks.filter {
            model.search.isEmpty || $0.title.localizedCaseInsensitiveContains(model.search)
        }
        let good = checker.checks.filter { $0.status == .good }.count
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Speed Settings", systemImage: Category.speedSettings.symbol).font(.title2.bold())
                    if !checker.checks.isEmpty {
                        Text("\(good) of \(checker.checks.count) look good")
                            .foregroundStyle(.secondary)
                            .padding(.leading, 6)
                    }
                    Spacer()
                    if checker.isChecking { ProgressView().controlSize(.small) }
                    Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Check again")
                }
                Text(Category.speedSettings.blurb).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 12)
            Divider()

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(checks) { check in
                        SpeedCheckRow(check: check) { checker.perform($0, model: model) }
                    }
                    Text("Tips you may see elsewhere, like turning off swap or System Integrity Protection, \"repairing permissions\" or running maintenance scripts, don't speed up modern Macs or can make them unstable, so they aren't listed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                .padding(16)
            }
        }
        .onAppear { refresh() }
        // Coming back from System Settings or Chrome: check again so the ticks update.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .alert("Speed Settings", isPresented: Binding(get: { checker.message != nil }, set: { if !$0 { checker.message = nil } })) {
            Button("OK") { checker.message = nil }
        } message: {
            Text(checker.message ?? "")
        }
    }

    private func refresh() {
        checker.refresh(enabledBackgroundItems: monitor.launchItems.filter(\.isEnabled).count)
    }
}

struct SpeedCheckRow: View {
    let check: SpeedCheck
    let perform: (SpeedAction) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: check.symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(check.title).font(.headline)
                    Text(check.impact.label)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .foregroundStyle(.secondary)
                        .background(.quaternary, in: Capsule())
                }
                Text(check.finding).fixedSize(horizontal: false, vertical: true)
                if let howTo = check.howTo {
                    Text(howTo)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let title = check.actionTitle, let action = check.action, check.status != .good || check.id == "extensions" {
                    Button(title) { perform(action) }
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: check.status.symbol)
                .font(.title2)
                .foregroundStyle(check.status.color)
                .help(check.status == .good ? "Looks good" : check.status == .tip ? "Worth changing" : "Couldn't check")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}
