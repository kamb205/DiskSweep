import Foundation
import AppKit

// MARK: - Report model

/// What Storage Insights found: where every byte goes, what changed since the last scan, and
/// findings explained in plain words, each with the actions that apply. Saved with the scan.
struct StorageReport: Codable {
    var date = Date()
    var capacity: Int64 = 0
    /// Space that is free right now.
    var freeNow: Int64 = 0
    /// Free space plus "purgeable" space macOS clears on its own when it needs room (what Finder shows).
    var freeUsable: Int64 = 0
    var measured: Int64 = 0
    var wholeDisk = false
    var areas: [StorageArea] = []
    var findings: [Finding] = []
    var growth: [Growth] = []
    var previousScan: Date?
    var summary: [String] = []
    /// How many big folders DiskSweep's own AI model looked at, and how many it recognised confidently.
    var aiChecked = 0
    var aiRecognised = 0

    var used: Int64 { max(capacity - freeNow, 0) }
    var purgeable: Int64 { max(freeUsable - freeNow, 0) }
    var reclaimable: Int64 { findings.reduce(0) { $0 + $1.reclaimable } }
}

struct StorageArea: Codable, Identifiable, Hashable {
    let name: String
    let symbol: String
    let size: Int64
    let detail: String
    var path: String? = nil
    var id: String { name }
}

struct Growth: Codable, Identifiable, Hashable {
    let path: String
    /// Friendly name, e.g. "Photos Library" for a folder inside the library.
    var label: String = ""
    let before: Int64
    let after: Int64
    var reason: String? = nil
    var id: String { path }
    var delta: Int64 { after - before }
}

struct Finding: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case virtualMachine, photos, cloud, purgeable, snapshots, update, swap, apps, archive
        case project, developer, audio, hidden, messages, systemData, ai
    }

    /// What DiskSweep's AI model (`FolderModel`) thinks the item is.
    struct Verdict: Codable, Hashable {
        let kind: String
        let confidence: Double
        let reasons: [String]
    }

    enum Action: Codable, Hashable {
        case reveal(String)
        case trash([String])
        case openURL(String)
        case openApp(String)
        case copy(String)
        case page(String)
    }

    struct ActionButton: Codable, Hashable {
        let label: String
        let action: Action
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    /// Space this finding is about.
    let size: Int64
    /// How much could realistically be freed by following the advice (0 = information only).
    let reclaimable: Int64
    let safety: Safety
    var paths: [String] = []
    var buttons: [ActionButton] = []
    var verdict: Verdict? = nil

    var symbol: String {
        switch kind {
        case .virtualMachine: "server.rack"
        case .photos: "photo.on.rectangle"
        case .cloud: "icloud"
        case .purgeable: "sparkles"
        case .snapshots: "clock.arrow.circlepath"
        case .update: "arrow.down.circle"
        case .swap: "memorychip"
        case .apps: "square.grid.2x2"
        case .archive: "doc.zipper"
        case .project: "chevron.left.forwardslash.chevron.right"
        case .developer: "hammer"
        case .audio: "waveform"
        case .hidden: "eye.slash"
        case .messages: "message"
        case .systemData: "gearshape.2"
        case .ai: verdict.flatMap { FolderKind(rawValue: $0.kind)?.symbol } ?? "brain"
        }
    }
}

// MARK: - Size history (for "what changed")

/// Folder sizes from the previous scan, so the next one can say what grew.
enum SizeHistory {
    struct Snapshot: Codable {
        var date: Date
        var sizes: [String: Int64]
    }

    private static var url: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DiskSweep", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("size-history.plist")
    }

    static func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(Snapshot.self, from: data)
    }

    /// Merges with the previous snapshot, so a Home Folder scan doesn't forget what an Entire Disk scan measured.
    static func save(_ sizes: [String: Int64], replacingUnder root: String) {
        var merged = load()?.sizes ?? [:]
        let prefix = root == "/" ? "/" : root + "/"
        merged = merged.filter { key, _ in key != root && !key.hasPrefix(prefix) }
        merged.merge(sizes) { _, new in new }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(Snapshot(date: Date(), sizes: merged)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Analyst

/// Looks at the whole scan the way a person would: accounts for every part of the disk (including
/// hidden folders, virtual machines and space macOS manages), recognises what big things are, works
/// out what changed since last time, and explains what can be done. Read-only, never deletes.
final class StorageAnalyst {
    private let result: ScanResult
    private let fm = FileManager.default
    private let home = NSHomeDirectory()
    private let sizes: [String: Int64]
    private var report = StorageReport()
    /// Paths a finding already explains, so they aren't reported twice.
    private var explained: [String] = []
    private let runningBundleIDs: Set<String>
    private let saveHistory: Bool

    private var lib: String { home + "/Library" }

    init(result: ScanResult, saveHistory: Bool) {
        self.result = result
        self.sizes = result.folderSizes
        self.saveHistory = saveHistory
        runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
        // Items other pages already list don't need a second explanation here.
        explained = (result.junk + result.developer + result.aiModels + result.leftovers).map(\.path)
    }

    func run() -> StorageReport {
        readVolume()
        report.wholeDisk = result.root == "/"
        report.measured = result.scannedBytes

        let vms = findVirtualMachines()
        let photos = findPhotoLibraries()
        let projects = findProjects()

        checkPurgeable()
        checkSystemData()
        checkSnapshots()
        checkPendingUpdate()
        checkSwap()
        checkUnusedApps()
        checkIntelOnlyApps()
        checkAudioFormats()
        checkArchives()
        checkHomebrew()
        checkCloudAndMessages()
        checkHiddenFolders()
        classifyEverything()

        buildAreas(vms: vms, photos: photos, projects: projects)
        findGrowth()
        report.findings.sort {
            if ($0.reclaimable > 0) != ($1.reclaimable > 0) { return $0.reclaimable > 0 }
            if $0.reclaimable != $1.reclaimable { return $0.reclaimable > $1.reclaimable }
            return $0.size > $1.size
        }
        writeSummary()
        return report
    }

    // MARK: Measuring

    private func size(of path: String) -> Int64? {
        if let s = sizes[path] { return s }
        return measure(path)
    }

    /// Measures a folder outside the scan (e.g. /Library/Updates during a Home Folder scan). Capped so it
    /// can't turn into a second full scan.
    private func measure(_ path: String, fileLimit: Int = 200_000) -> Int64? {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]
        let url = URL(fileURLWithPath: path)
        if !isDir.boolValue {
            let rv = try? url.resourceValues(forKeys: keys)
            return Int64(rv?.totalFileAllocatedSize ?? rv?.fileAllocatedSize ?? 0)
        }
        guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [],
                                         errorHandler: { _, _ in true }) else { return nil }
        var total: Int64 = 0
        var count = 0
        for case let file as URL in walker {
            count += 1
            if count > fileLimit { break }
            guard let rv = try? file.resourceValues(forKeys: keys), rv.isDirectory != true else { continue }
            total += Int64(rv.totalFileAllocatedSize ?? rv.fileAllocatedSize ?? 0)
        }
        return total
    }

    private func children(of path: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: path)) ?? []).filter { $0 != ".DS_Store" }.map { path + "/" + $0 }
    }

    private func exists(_ path: String) -> Bool { fm.fileExists(atPath: path) }

    private func modified(_ path: String) -> Date? {
        (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Newest modification date among a folder's direct contents: when a VM or project was last touched.
    private func lastTouched(_ path: String) -> Date? {
        ([path] + children(of: path)).compactMap(modified).max()
    }

    private func pretty(_ path: String) -> String { Fmt.path(path) }

    private func ago(_ date: Date?) -> String {
        guard let date else { return "a long time ago" }
        let days = Int(Date().timeIntervalSince(date) / 86_400)
        if days < 1 { return "today" }
        if days == 1 { return "yesterday" }
        if days < 60 { return "\(days) days ago" }
        return "in " + date.formatted(.dateTime.month(.wide).year())
    }

    private func isAppRunning(_ ids: [String]) -> Bool { ids.contains { runningBundleIDs.contains($0.lowercased()) } }

    private func appInstalled(_ id: String) -> Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil }

    private func add(_ finding: Finding) {
        report.findings.append(finding)
        explained.append(contentsOf: finding.paths)
    }

    private func isExplained(_ path: String) -> Bool {
        explained.contains { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }
    }

    private func readVolume() {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey]
        guard let rv = try? URL(fileURLWithPath: result.root).resourceValues(forKeys: keys) else { return }
        report.capacity = Int64(rv.volumeTotalCapacity ?? 0)
        report.freeNow = Int64(rv.volumeAvailableCapacity ?? 0)
        report.freeUsable = max(rv.volumeAvailableCapacityForImportantUsage ?? 0, report.freeNow)
    }

    // MARK: Virtual machines

    private struct VMInfo {
        let path: String
        let name: String
        let tool: String
        let size: Int64
        /// Largest size the virtual disk can grow to, when known.
        let maxSize: Int64?
        let running: Bool
        let lastUsed: Date?
        let isLinux: Bool
        let deleteCommand: String?
    }

    private func findVirtualMachines() -> [VMInfo] {
        var vms: [VMInfo] = []

        func disks(in folder: String) -> Int64? {
            let names = ["disk", "diffdisk", "basedisk", "disk.img", "Disk.img", "root.img"]
            let total = names.compactMap { name -> Int64? in
                guard let attrs = try? fm.attributesOfItem(atPath: folder + "/" + name) else { return nil }
                return (attrs[.size] as? NSNumber)?.int64Value
            }.reduce(0, +)
            return total > 0 ? total : nil
        }

        func pidAlive(_ file: String) -> Bool {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8),
                  let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
            return kill(pid, 0) == 0
        }

        // Lima (and Colima, which runs Lima underneath)
        for base in [home + "/.lima", home + "/.colima/_lima"] {
            for dir in children(of: base) where exists(dir + "/lima.yaml") {
                guard let size = size(of: dir), size > 0 else { continue }
                let name = (dir as NSString).lastPathComponent
                // Ask Lima itself; pid files can be left behind after a crash and point at an unrelated process.
                let running = limaStatus(name: name, home: base).map { $0 == "Running" }
                    ?? (pidAlive(dir + "/ha.pid") || pidAlive(dir + "/vz.pid") || pidAlive(dir + "/qemu.pid"))
                let colima = base.contains(".colima")
                vms.append(VMInfo(path: dir, name: name, tool: colima ? "Colima" : "Lima", size: size, maxSize: disks(in: dir),
                                  running: running, lastUsed: lastTouched(dir), isLinux: true,
                                  deleteCommand: colima ? (name == "colima" ? "colima delete" : "colima delete -p \(name.replacingOccurrences(of: "colima-", with: ""))") : "limactl delete \(name)"))
            }
        }

        // App-based VM tools: one entry per VM bundle.
        let bundleTools: [(folder: String, ext: String?, tool: String, ids: [String], linux: Bool)] = [
            (lib + "/Containers/com.utmapp.UTM/Data/Documents", "utm", "UTM", ["com.utmapp.UTM"], false),
            (home + "/Parallels", "pvm", "Parallels", ["com.parallels.desktop.console"], false),
            (home + "/Documents/Parallels", "pvm", "Parallels", ["com.parallels.desktop.console"], false),
            (home + "/Virtual Machines.localized", "vmwarevm", "VMware Fusion", ["com.vmware.fusion"], false),
            (home + "/Documents/Virtual Machines.localized", "vmwarevm", "VMware Fusion", ["com.vmware.fusion"], false),
            (home + "/VirtualBox VMs", nil, "VirtualBox", ["org.virtualbox.app.VirtualBox"], false),
            (home + "/.tart/vms", nil, "Tart", [], false),
            (home + "/.android/avd", "avd", "Android Emulator", [], true),
        ]
        for tool in bundleTools {
            for dir in children(of: tool.folder) {
                if let ext = tool.ext, (dir as NSString).pathExtension.lowercased() != ext { continue }
                guard let size = size(of: dir), size >= 100_000_000 else { continue }
                let name = ((dir as NSString).lastPathComponent as NSString).deletingPathExtension
                vms.append(VMInfo(path: dir, name: name, tool: tool.tool, size: size, maxSize: nil,
                                  running: isAppRunning(tool.ids), lastUsed: lastTouched(dir), isLinux: tool.linux,
                                  deleteCommand: tool.tool == "Tart" ? "tart delete \(name)" : nil))
            }
        }

        // Container tools that keep one big Linux disk.
        let single: [(path: String, tool: String, ids: [String])] = [
            (lib + "/Containers/com.docker.docker/Data/vms", "Docker Desktop", ["com.docker.docker"]),
            (home + "/.orbstack", "OrbStack", ["dev.kdrag0n.MacVirt"]),
            (lib + "/Group Containers/HUAQ24HBR6.dev.orbstack", "OrbStack", ["dev.kdrag0n.MacVirt"]),
            (home + "/.local/share/containers/podman/machine", "Podman", []),
        ]
        for entry in single {
            guard let size = size(of: entry.path), size >= 500_000_000 else { continue }
            vms.append(VMInfo(path: entry.path, name: entry.tool, tool: entry.tool, size: size, maxSize: nil,
                              running: isAppRunning(entry.ids), lastUsed: lastTouched(entry.path), isLinux: true, deleteCommand: nil))
        }

        // Loose virtual disk files anywhere in your folders.
        let diskExtensions: Set<String> = ["vmdk", "vdi", "qcow2", "vhd", "vhdx", "hdd", "utm"]
        for file in result.files where file.size >= 2_000_000_000 {
            let ext = (file.path as NSString).pathExtension.lowercased()
            guard diskExtensions.contains(ext), !vms.contains(where: { file.path.hasPrefix($0.path + "/") }) else { continue }
            vms.append(VMInfo(path: file.path, name: file.name, tool: "virtual disk", size: file.size, maxSize: nil,
                              running: false, lastUsed: file.lastUsed, isLinux: false, deleteCommand: nil))
        }

        for vm in vms { addFinding(for: vm) }
        return vms
    }

    private func addFinding(for vm: VMInfo) {
        let idleDays = vm.lastUsed.map { Date().timeIntervalSince($0) / 86_400 } ?? 999
        let growNote = vm.maxSize.map { $0 > vm.size + 1_000_000_000 ? " Its virtual disk can grow to \(Fmt.bytes($0))." : "" } ?? ""
        let label = vm.tool == "virtual disk" ? "Virtual disk file" : "\(vm.tool) virtual machine"
        var buttons = [Finding.ActionButton(label: "Show in Finder", action: .reveal(vm.path))]

        if vm.running || idleDays < 7 {
            var detail = "\(label) “\(vm.name)” takes \(Fmt.bytes(vm.size)) on your Mac and is \(vm.running ? "running now" : "used \(ago(vm.lastUsed))").\(growNote)"
            if vm.running, vm.tool == "Lima" || vm.tool == "Colima", let inside = probeLima(vm) {
                let unreturned = vm.size - inside.used
                var text = " Inside, Linux is using \(Fmt.bytes(inside.used)) of its \(Fmt.bytes(inside.capacity)) disk."
                if !inside.top.isEmpty {
                    text += " Biggest folders inside: " + inside.top.map { "\($0.path) (\(Fmt.bytes($0.size)))" }.joined(separator: ", ") + "."
                }
                if unreturned >= 1_000_000_000 {
                    text += " About \(Fmt.bytes(unreturned)) is space Linux has already freed that your Mac hasn't got back yet. Run the trim command inside the VM to return it."
                    detail += text
                    buttons.append(.init(label: "Copy Trim Command", action: .copy("sudo fstrim -av")))
                    add(Finding(id: "vm:" + vm.path, kind: .virtualMachine, title: "\(label) “\(vm.name)” can give back space",
                                detail: detail, size: vm.size, reclaimable: unreturned, safety: .safe, paths: [vm.path], buttons: buttons))
                    return
                }
                detail += text + " To make it smaller, delete files you don't need inside the VM, then run the trim command inside it so macOS gets the space back."
                buttons.append(.init(label: "Copy Trim Command", action: .copy("sudo fstrim -av")))
                add(Finding(id: "vm:" + vm.path, kind: .virtualMachine, title: "\(label): \(vm.name)", detail: detail,
                            size: vm.size, reclaimable: 0, safety: .caution, paths: [vm.path], buttons: buttons))
                return
            }
            if vm.isLinux {
                detail += " Files you delete inside a VM don't always give the space back to your Mac. After clearing space inside it, run the command below inside the VM so macOS gets the space back."
                buttons.append(.init(label: "Copy Trim Command", action: .copy("sudo fstrim -av")))
            } else {
                detail += " To shrink it, delete files inside the VM and use \(vm.tool)'s own option to reclaim or compact disk space."
            }
            add(Finding(id: "vm:" + vm.path, kind: .virtualMachine, title: "\(label): \(vm.name)", detail: detail,
                        size: vm.size, reclaimable: 0, safety: .caution, paths: [vm.path], buttons: buttons))
        } else {
            var detail = "\(label) “\(vm.name)” takes \(Fmt.bytes(vm.size)) and hasn't been used since \(ago(vm.lastUsed)). It isn't running."
            detail += " If you've finished with it, deleting it frees all of that space. Everything inside it (its files and installed software) goes with it."
            if let command = vm.deleteCommand {
                detail += " The cleanest way is \(vm.tool)'s own delete command."
                buttons.append(.init(label: "Copy Delete Command", action: .copy(command)))
            }
            if AppModel.isDeletable(vm.path) { buttons.append(.init(label: "Move to Trash…", action: .trash([vm.path]))) }
            add(Finding(id: "vm:" + vm.path, kind: .virtualMachine, title: "Idle \(label.lowercased()): \(vm.name)", detail: detail,
                        size: vm.size, reclaimable: vm.size, safety: .review, paths: [vm.path], buttons: buttons))
        }
    }

    private struct GuestUsage {
        let used: Int64
        let capacity: Int64
        let top: [(path: String, size: Int64)]
    }

    private var limactl: String? {
        ["/opt/homebrew/bin/limactl", "/usr/local/bin/limactl"].first { fm.isExecutableFile(atPath: $0) }
    }

    private func limaStatus(name: String, home limaHome: String) -> String? {
        guard let limactl else { return nil }
        let status = run(limactl, ["list", name, "--format", "{{.Status}}"], environment: ["LIMA_HOME": limaHome], timeout: 10)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return status.isEmpty ? nil : status
    }

    /// Asks a running Lima VM how full its disk really is, and what its biggest folders are.
    /// Read-only (df and du as your normal user inside the VM).
    private func probeLima(_ vm: VMInfo) -> GuestUsage? {
        guard let limactl else { return nil }
        let env = ["LIMA_HOME": (vm.path as NSString).deletingLastPathComponent]
        let name = (vm.path as NSString).lastPathComponent
        let df = run(limactl, ["shell", "--workdir", "/", name, "--", "df", "-kP", "/"], environment: env, timeout: 15)
        let fields = df.split(separator: "\n").dropFirst().first?.split(separator: " ", omittingEmptySubsequences: true) ?? []
        guard fields.count >= 4, let total = Int64(fields[1]), let used = Int64(fields[2]) else { return nil }
        let du = run(limactl, ["shell", "--workdir", "/", name, "--", "sh", "-c",
                               "du -xsk \"$HOME\"/* \"$HOME\"/.cache /tmp /var/cache 2>/dev/null | sort -rn | head -5"],
                     environment: env, timeout: 40)
        let top: [(path: String, size: Int64)] = du.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let kb = Int64(parts[0].trimmingCharacters(in: .whitespaces)), kb >= 1_000_000 else { return nil }
            var path = String(parts[1])
            if let range = path.range(of: "/home/") { path = "~/" + path[range.upperBound...].split(separator: "/").dropFirst().joined(separator: "/") }
            return (path, kb * 1024)
        }
        return GuestUsage(used: used * 1024, capacity: total * 1024, top: top)
    }

    // MARK: Photos

    private func findPhotoLibraries() -> [String] {
        let libraries = sizes.keys.filter { $0.lowercased().hasSuffix(".photoslibrary") }
            + [home + "/Pictures/Photos Library.photoslibrary"].filter { sizes[$0] == nil && exists($0) }
        var found: [String] = []
        for library in Set(libraries) {
            guard let total = size(of: library), total >= 1_000_000_000 else { continue }
            found.append(library)
            let originals = size(of: library + "/originals") ?? 0
            let iCloud = exists(library + "/resources/cpl")
            let name = ((library as NSString).lastPathComponent as NSString).deletingPathExtension
            let openPhotos = Finding.ActionButton(label: "Open Photos", action: .openApp("com.apple.Photos"))
            let warning = " Never delete files inside the library in Finder: it damages the library, and deletions sync to your other devices."

            if iCloud && report.purgeable >= originals / 2 && originals > 0 {
                add(Finding(id: "photos:" + library, kind: .photos, title: "\(name) is already optimised",
                            detail: "Your Photos library uses \(Fmt.bytes(total)) and syncs with iCloud Photos. “Optimise Mac Storage” looks on: macOS removes local originals by itself when it needs space, which is why \(Fmt.bytes(report.purgeable)) shows as purgeable. Nothing to do." + warning,
                            size: total, reclaimable: 0, safety: .safe, paths: [library], buttons: [openPhotos]))
            } else if iCloud && originals >= 2_000_000_000 {
                add(Finding(id: "photos:" + library, kind: .photos, title: "Photos keeps full-size copies from iCloud",
                            detail: "Your Photos library uses \(Fmt.bytes(total)), \(Fmt.bytes(originals)) of it full-size photos and videos that are also stored in iCloud. In Photos, choose Photos ▸ Settings ▸ iCloud ▸ Optimise Mac Storage. Your Mac then keeps small versions and downloads originals when you open them. The space comes back gradually, as macOS needs it." + warning,
                            size: total, reclaimable: originals * 9 / 10, safety: .safe, paths: [library], buttons: [openPhotos]))
            } else {
                add(Finding(id: "photos:" + library, kind: .photos, title: "\(name) (\(Fmt.bytes(total)))",
                            detail: "This Photos library isn't synced with iCloud Photos, so it may be the only copy of these photos. To free space, delete photos you don't want inside Photos, or move the whole library to an external drive (quit Photos, drag the library, then open it from there)." + warning,
                            size: total, reclaimable: 0, safety: .caution, paths: [library], buttons: [openPhotos]))
            }
        }
        return found
    }

    // MARK: macOS-managed space

    private func checkPurgeable() {
        guard report.purgeable >= 2_000_000_000 else { return }
        report.findings.append(Finding(id: "purgeable", kind: .purgeable, title: "\(Fmt.bytes(report.purgeable)) is purgeable",
            detail: "macOS can clear this space by itself whenever something needs room: iCloud files and photos stored online, Time Machine local snapshots and system caches. Finder already counts it as available, so you can use it. It turns into free space gradually.",
            size: report.purgeable, reclaimable: 0, safety: .safe))
    }

    private func checkSystemData() {
        guard report.wholeDisk, report.used > report.measured else { return }
        let gap = report.used - report.measured
        guard gap >= 5_000_000_000 else { return }
        report.findings.append(Finding(id: "systemdata", kind: .systemData, title: "\(Fmt.bytes(gap)) is macOS and hidden system data",
            detail: "Space no app can look inside: macOS itself (the sealed system volume, Preboot and Recovery), local snapshots, and caches and databases macOS protects.\(report.purgeable > 0 ? " Up to \(Fmt.bytes(report.purgeable)) of it is the purgeable space macOS clears by itself." : "") It isn't something to delete by hand. Restarting and installing macOS updates keep it in check.",
            size: gap, reclaimable: 0, safety: .caution))
    }

    private func checkSnapshots() {
        let output = run("/usr/bin/tmutil", ["listlocalsnapshots", "/"])
        let count = output.split(separator: "\n").filter { $0.contains("com.apple.TimeMachine") }.count
        guard count > 0 else { return }
        report.findings.append(Finding(id: "snapshots", kind: .snapshots, title: "\(count) Time Machine local snapshot\(count == 1 ? "" : "s")",
            detail: "Time Machine keeps hourly snapshots on your Mac between backups. macOS deletes them automatically after 24 hours or when space runs low, so they count as purgeable rather than used.",
            size: 0, reclaimable: 0, safety: .safe,
            buttons: [.init(label: "Time Machine Settings", action: .openURL("x-apple.systempreferences:com.apple.Time-Machine-Settings.extension"))]))
    }

    private func checkPendingUpdate() {
        let path = "/Library/Updates"
        guard let size = size(of: path), size >= 500_000_000 else { return }
        add(Finding(id: "updates", kind: .update, title: "A downloaded macOS update is waiting",
            detail: "macOS has downloaded an update (\(Fmt.bytes(size))) that hasn't been installed yet. Installing it clears the download. Back up first if you don't have a recent backup.",
            size: size, reclaimable: size, safety: .safe, paths: [path],
            buttons: [.init(label: "Open Software Update", action: .openURL("x-apple.systempreferences:com.apple.Software-Update-Settings.extension"))]))
    }

    private func checkSwap() {
        let path = "/private/var/vm"
        guard let size = size(of: path), size >= 3_000_000_000 else { return }
        add(Finding(id: "swap", kind: .swap, title: "Swap and sleep files: \(Fmt.bytes(size))",
            detail: "macOS writes memory to disk when apps need more than your Mac has. These files shrink after a restart. Quitting memory-hungry apps keeps them small.",
            size: size, reclaimable: 0, safety: .caution, paths: [path],
            buttons: [.init(label: "Open Memory", action: .page(Category.memory.rawValue))]))
    }

    // MARK: Apps

    private func checkUnusedApps() {
        let cutoff = Date().addingTimeInterval(-90 * 86_400)
        let unused = result.apps.filter { $0.size >= 300_000_000 && ($0.lastUsed ?? .distantPast) < cutoff }
            .sorted { $0.size > $1.size }
        guard !unused.isEmpty else { return }
        let total = unused.reduce(0) { $0 + $1.size }
        let list = unused.prefix(6).map { "\($0.name) (\(Fmt.bytes($0.size)), \($0.lastUsed == nil ? "no record of being opened" : "last opened \(ago($0.lastUsed))"))" }
            .joined(separator: ", ")
        add(Finding(id: "apps:unused", kind: .apps,
            title: "\(unused.count) app\(unused.count == 1 ? "" : "s") you haven't opened in 3 months",
            detail: "\(list)\(unused.count > 6 ? " and \(unused.count - 6) more" : ""). Sizes include each app's data. Removing them in Uninstaller takes their caches and settings too. Apps from the App Store can be downloaded again for free.",
            size: total, reclaimable: total, safety: .review, paths: unused.map(\.path),
            buttons: [.init(label: "Open Uninstaller", action: .page(Category.uninstaller.rawValue))]))
    }

    /// Tools that only do anything on Intel Macs, installed on an Apple silicon Mac.
    private func checkIntelOnlyApps() {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard machine.hasPrefix("arm64") else { return }
        let known: [(id: String, why: String, support: [String])] = [
            ("com.dortania.opencore-legacy-patcher", "OpenCore Legacy Patcher installs new macOS on older Intel Macs. It does nothing on Apple silicon.",
             ["/Library/Application Support/Dortania"]),
        ]
        for entry in known {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.id) else { continue }
            let paths = [url.path] + entry.support.filter(exists)
            let total = paths.compactMap { size(of: $0) }.reduce(0, +)
            let name = (url.lastPathComponent as NSString).deletingPathExtension
            add(Finding(id: "intel:" + entry.id, kind: .apps, title: "\(name) can't do anything on this Mac",
                detail: entry.why + " Removing it and its support files frees \(Fmt.bytes(total)).",
                size: total, reclaimable: total, safety: .safe, paths: paths,
                buttons: [.init(label: "Show in Finder", action: .reveal(url.path)),
                          .init(label: "Move to Trash…", action: .trash(paths.filter(AppModel.isDeletable)))]))
        }
    }

    /// AAX plug-ins only load in Pro Tools; the AU/VST3 copies of the same plug-ins serve every other app.
    private func checkAudioFormats() {
        let aaxRoot = "/Library/Application Support/Avid/Audio/Plug-Ins"
        guard exists(aaxRoot) else { return }
        let proTools = ["com.avid.ProTools", "com.avid.ProToolsFirst", "com.avid.ProToolsIntro"].contains(where: appInstalled)
            || exists("/Applications/Pro Tools.app")
        guard !proTools else { return }
        let aax = children(of: aaxRoot).filter { $0.hasSuffix(".aaxplugin") }
        let total = aax.compactMap { size(of: $0) }.reduce(0, +)
        guard total >= 500_000_000 else { return }
        add(Finding(id: "audio:aax", kind: .audio, title: "Pro Tools plug-in copies (\(aax.count))",
            detail: "\(Fmt.bytes(total)) of AAX plug-ins only load in Pro Tools, which isn't installed. Other music apps use the AU or VST3 versions of the same plug-ins. If you don't plan to use Pro Tools, remove the AAX parts with each maker's installer or uninstaller. Don't delete other files in that folder: plug-ins often share engine files there that every format needs.",
            size: total, reclaimable: total, safety: .caution, paths: aax,
            buttons: [.init(label: "Show in Finder", action: .reveal(aaxRoot))]))
    }

    // MARK: Your files

    /// Big single files in Downloads: archives, installers and disk images are usually done with once used.
    private func checkArchives() {
        let archives: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz", "xz", "bz2", "zst"]
        let installers: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]
        let diskImages: Set<String> = ["img", "raw", "bin", "vmdk", "qcow2", "vhd", "vhdx", "vdi", "wim"]
        for item in result.downloads ?? [] where !item.isDirectory && item.size >= 1_000_000_000 {
            guard !isExplained(item.path) else { continue }
            let ext = (item.name as NSString).pathExtension.lowercased()
            let base = (item.name as NSString).deletingPathExtension
            let extracted = exists(item.parentPath + "/" + base)
                || exists(item.parentPath + "/" + (base as NSString).deletingPathExtension)
            let what: String
            let advice: String
            if archives.contains(ext) {
                what = "archive"
                advice = extracted ? "Its extracted copy is next to it, so the archive itself is probably no longer needed."
                                   : "Once you've extracted what's inside, the archive isn't needed."
            } else if installers.contains(ext) {
                what = "installer"
                advice = "Once the app or system is installed, the installer isn't needed."
            } else if diskImages.contains(ext) {
                what = "disk image"
                advice = "Disk images like this are usually written to a USB drive, SD card or device, or used to set up a virtual machine. Once that's done, the image isn't needed here."
            } else {
                what = "file"
                advice = "Check whether you still need it."
            }
            add(Finding(id: "download:" + item.path, kind: .archive, title: "Big \(what) in Downloads: \(item.name)",
                detail: "\(Fmt.bytes(item.size)), downloaded \(ago(item.modified)). " + advice,
                size: item.size, reclaimable: item.size, safety: extracted && archives.contains(ext) ? .safe : .review, paths: [item.path],
                buttons: [.init(label: "Show in Finder", action: .reveal(item.path)),
                          .init(label: "Move to Trash…", action: .trash([item.path]))]))
        }
    }

    /// Code projects (folders with Git history) in your folders, with idle big ones called out.
    private func findProjects() -> [String] {
        let roots = sizes.keys.filter { path in
            guard path.hasPrefix(home + "/"), !path.hasPrefix(lib + "/") else { return false }
            let parts = path.dropFirst(home.count + 1).split(separator: "/")
            guard parts.count <= 4, !parts.contains(where: { $0.hasPrefix(".") }) else { return false }
            return exists(path + "/.git")
        }
        // Keep only the outermost project (submodules and nested repos count with their parent).
        let outer = roots.filter { root in !roots.contains { $0 != root && root.hasPrefix($0 + "/") } }
        let cutoff = Date().addingTimeInterval(-60 * 86_400)
        for project in outer {
            guard let total = sizes[project], total >= 1_000_000_000 else { continue }
            let touched = [project + "/.git/index", project + "/.git/HEAD", project + "/.git/logs/HEAD"]
                .compactMap(modified).max() ?? modified(project)
            guard (touched ?? .distantPast) < cutoff else { continue }
            let name = (project as NSString).lastPathComponent
            add(Finding(id: "project:" + project, kind: .project, title: "Idle project: \(name)",
                detail: "\(Fmt.bytes(total)) in \(pretty(project)), last worked on \(ago(touched)). If it's finished, archive it to an external drive or cloud storage, or delete its build folders (Developer Junk lists the ones DiskSweep recognises).",
                size: total, reclaimable: 0, safety: .review, paths: [project],
                buttons: [.init(label: "Show in Finder", action: .reveal(project)),
                          .init(label: "Open Developer Junk", action: .page(Category.developer.rawValue))]))
        }
        return outer
    }

    private func checkHomebrew() {
        for prefix in ["/opt/homebrew", "/usr/local"] {
            let cellar = prefix + "/Cellar"
            guard exists(cellar) else { continue }
            var old: Int64 = 0
            var formulas = 0
            for formula in children(of: cellar) {
                let versions = children(of: formula).sorted { (modified($0) ?? .distantPast) > (modified($1) ?? .distantPast) }
                guard versions.count > 1 else { continue }
                formulas += 1
                old += versions.dropFirst().compactMap { size(of: $0) }.reduce(0, +)
            }
            guard old >= 200_000_000 else { continue }
            add(Finding(id: "brew:" + prefix, kind: .developer, title: "Old Homebrew versions: \(Fmt.bytes(old))",
                detail: "\(formulas) Homebrew package\(formulas == 1 ? " keeps" : "s keep") older versions next to the current one. Homebrew's own cleanup command removes them safely.",
                size: old, reclaimable: old, safety: .safe, paths: [],
                buttons: [.init(label: "Copy Cleanup Command", action: .copy("brew cleanup"))]))
        }
    }

    private func checkCloudAndMessages() {
        if let drive = size(of: lib + "/Mobile Documents"), drive >= 5_000_000_000 {
            add(Finding(id: "icloud-drive", kind: .cloud, title: "iCloud Drive keeps \(Fmt.bytes(drive)) on this Mac",
                detail: "Files in iCloud Drive are also stored online. Turn on Optimise Mac Storage (System Settings ▸ your name ▸ iCloud ▸ Drive) and macOS keeps only recently used files on your Mac.",
                size: drive, reclaimable: drive / 2, safety: .safe, paths: [lib + "/Mobile Documents"],
                buttons: [.init(label: "Open iCloud Settings", action: .openURL("x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings"))]))
        }
        if let attachments = size(of: lib + "/Messages/Attachments"), attachments >= 2_000_000_000 {
            add(Finding(id: "messages", kind: .messages, title: "Messages attachments: \(Fmt.bytes(attachments))",
                detail: "Photos, videos and files people sent you in Messages. To trim them, open Messages ▸ Settings ▸ General and set Keep Messages to 1 Year, or review large attachments in System Settings ▸ General ▸ Storage ▸ Messages.",
                size: attachments, reclaimable: 0, safety: .review, paths: [lib + "/Messages"],
                buttons: [.init(label: "Open Messages", action: .openApp("com.apple.MobileSMS"))]))
        }
    }

    /// Hidden folders in your home that Finder doesn't show, made by command-line tools.
    private func checkHiddenFolders() {
        let known: Set<String> = [".Trash", ".lima", ".colima", ".orbstack", ".tart", ".android", ".npm", ".cache",
                                  ".cargo", ".gradle", ".m2", ".pnpm-store", ".bun", ".cocoapods", ".ollama", ".lmstudio"]
        for path in children(of: home) {
            let name = (path as NSString).lastPathComponent
            guard name.hasPrefix("."), !known.contains(name), !isExplained(path),
                  let size = sizes[path], size >= 1_000_000_000 else { continue }
            var detail = "Finder hides folders whose names start with a dot. This one was made by a program or command-line tool."
            var verdict: Finding.Verdict?
            if let guess = FolderModel.predict(path: path, isDirectory: true, size: size), guess.confidence >= 0.6 {
                verdict = .init(kind: guess.kind.rawValue, confidence: guess.confidence, reasons: guess.reasons)
                detail += " DiskSweep's AI thinks it's \(guess.kind.title.lowercased())\(because(guess.reasons)). \(guess.kind.advice)"
            } else {
                detail += " Search the web for “\(name) folder mac” to find out which tool owns it before removing anything."
            }
            add(Finding(id: "hidden:" + path, kind: .hidden, title: "Hidden folder \(name): \(Fmt.bytes(size))",
                detail: detail, size: size, reclaimable: 0, safety: .caution, paths: [path],
                buttons: [.init(label: "Show in Finder", action: .reveal(path))], verdict: verdict))
        }
    }

    // MARK: AI pass

    private func because(_ reasons: [String]) -> String {
        guard !reasons.isEmpty else { return "" }
        let quoted = reasons.map { "“\($0)”" }
        let list = quoted.count > 1 ? quoted.dropLast().joined(separator: ", ") + " and " + quoted.last! : quoted[0]
        return ", because its path mentions \(list)"
    }

    /// Runs DiskSweep's own AI model over every big folder and file the other checks didn't explain,
    /// and points out the ones it's confident are safe to clear (caches, build output, leftovers…).
    private func classifyEverything() {
        guard FolderModel.isAvailable else { return }
        // Folders that only hold other things: judging them as a whole says nothing useful.
        let containers: Set<String> = [
            "/", home, lib, lib + "/Application Support", lib + "/Caches", lib + "/Containers", lib + "/Group Containers",
            lib + "/Developer", lib + "/Logs", home + "/Documents", home + "/Desktop", home + "/Downloads", home + "/Pictures",
            home + "/Movies", home + "/Music", home + "/Applications", "/Library", "/Library/Application Support", "/Applications",
            "/Users", "/Users/Shared", "/private", "/private/var", "/opt", "/usr", "/usr/local", "/System/Volumes/Data", "/Volumes",
        ]
        var candidates: [(path: String, size: Int64, isDir: Bool)] = sizes
            .filter { $0.value >= 1_000_000_000 }
            .map { ($0.key, $0.value, true) }
        candidates += result.files.filter { $0.size >= 1_000_000_000 }.map { ($0.path, $0.size, false) }
        candidates = candidates.filter { c in
            !containers.contains(c.path) && !c.path.contains(".app/") && !c.path.hasSuffix(".app")
                && !c.path.lowercased().contains(".photoslibrary") && !isExplained(c.path)
                && !(c.path.hasPrefix(home + "/") && c.path.dropFirst(home.count + 1).split(separator: "/").count < 2
                     && !c.path.dropFirst(home.count + 1).hasPrefix("."))
        }
        report.aiChecked = candidates.count

        var picked: [(path: String, size: Int64, guess: FolderModel.Prediction)] = []
        for c in candidates.sorted(by: { $0.path.count < $1.path.count }) {
            guard let guess = FolderModel.predict(path: c.path, isDirectory: c.isDir, size: c.size) else { continue }
            if guess.confidence >= 0.8 { report.aiRecognised += 1 }
            guard guess.kind.isReclaimable, guess.confidence >= 0.85,
                  !picked.contains(where: { c.path.hasPrefix($0.path + "/") }) else { continue }
            picked.append((c.path, c.size, guess))
        }
        for item in picked.sorted(by: { $0.size > $1.size }).prefix(8) {
            let name = (item.path as NSString).lastPathComponent
            let percent = Int((item.guess.confidence * 100).rounded())
            let detail = "\(pretty(item.path)), \(Fmt.bytes(item.size)). DiskSweep's AI is \(percent)% sure this is \(item.guess.kind.title.lowercased())\(because(item.guess.reasons)). \(item.guess.kind.advice) The AI judges by name and location and never opens your files, so check it before removing it."
            var buttons: [Finding.ActionButton] = [.init(label: "Show in Finder", action: .reveal(item.path))]
            if AppModel.isDeletable(item.path) { buttons.append(.init(label: "Move to Trash…", action: .trash([item.path]))) }
            add(Finding(id: "ai:" + item.path, kind: .ai, title: "Looks like \(item.guess.kind.title.lowercased()): \(name)",
                        detail: detail, size: item.size, reclaimable: item.size, safety: .review, paths: [item.path],
                        buttons: buttons,
                        verdict: .init(kind: item.guess.kind.rawValue, confidence: item.guess.confidence, reasons: item.guess.reasons)))
        }
    }

    // MARK: Areas

    /// Splits everything measured into areas, each byte counted once: a claimed folder's size minus
    /// the claimed folders inside it.
    private func buildAreas(vms: [VMInfo], photos: [String], projects: [String]) {
        var claims: [(path: String, area: String)] = []
        func claim(_ path: String, _ area: String) { if sizes[path] != nil { claims.append((path, area)) } }

        for vm in vms { claim(vm.path, "Virtual machines") }
        for library in photos { claim(library, "Photos libraries") }
        for project in projects { claim(project, "Code projects") }
        claim(lib + "/Developer", "Developer tools & caches")
        claim(lib + "/Caches", "Caches")
        claim(lib + "/Mobile Documents", "iCloud Drive")
        claim(lib + "/Messages", "Mail & Messages")
        claim(lib + "/Mail", "Mail & Messages")
        claim(lib + "/Audio", "Audio plug-ins & sounds")
        claim(lib, "App data")
        for path in children(of: home) where (path as NSString).lastPathComponent.hasPrefix(".") {
            claim(path, (path as NSString).lastPathComponent == ".Trash" ? "Trash" : "Hidden tool folders")
        }
        claim(home + "/Downloads", "Downloads")
        claim(home + "/Documents", "Documents & Desktop")
        claim(home + "/Desktop", "Documents & Desktop")
        claim(home + "/Music", "Music")
        claim(home + "/Movies", "Movies")
        claim(home + "/Pictures", "Pictures")
        claim(home + "/Applications", "Apps")
        claim(home, "Other files in your home")
        claim("/Applications", "Apps")
        claim("/Library/Audio", "Audio plug-ins & sounds")
        claim("/Library/Application Support/Avid", "Audio plug-ins & sounds")
        claim("/Library/Developer", "Developer tools & caches")
        claim("/opt/homebrew", "Developer tools & caches")
        claim("/usr/local", "Developer tools & caches")
        claim("/Library", "Shared app data (/Library)")
        claim("/Users", "Other users & shared")
        for path in ["/private", "/usr", "/opt", "/bin", "/sbin", "/cores", "/System/Volumes"] { claim(path, "macOS system files") }
        if result.root != "/" && result.root != home { claim(result.root, "Scanned folder") }

        var totals: [String: Int64] = [:]
        let paths = claims.map(\.path)
        for (path, area) in claims {
            // Subtract claimed folders whose nearest claimed ancestor is this one.
            let nested = paths.filter { other in
                other != path && other.hasPrefix(path == "/" ? "/" : path + "/")
                    && !paths.contains { mid in mid != path && mid != other && other.hasPrefix(mid + "/") && mid.hasPrefix(path + "/") }
            }
            let own = (sizes[path] ?? 0) - nested.reduce(0) { $0 + (sizes[$1] ?? 0) }
            totals[area, default: 0] += max(own, 0)
        }
        let claimedTotal = totals.values.reduce(0, +)
        if report.measured > claimedTotal + 500_000_000 {
            totals["Everything else", default: 0] += report.measured - claimedTotal
        }
        if report.wholeDisk, report.used > report.measured {
            totals["macOS & hidden system data", default: 0] += report.used - report.measured
        }

        let info: [String: (symbol: String, detail: String)] = [
            "Virtual machines": ("server.rack", "Linux and other virtual computers running on your Mac"),
            "Photos libraries": ("photo.on.rectangle", "Your Photos app library"),
            "Code projects": ("chevron.left.forwardslash.chevron.right", "Folders with Git history"),
            "Developer tools & caches": ("hammer", "Homebrew, Xcode tools, simulators and build caches"),
            "Caches": ("archivebox", "Files apps keep to load faster; rebuilt when needed"),
            "iCloud Drive": ("icloud", "Local copies of iCloud Drive files"),
            "Mail & Messages": ("message", "Mail, Messages and their attachments"),
            "Audio plug-ins & sounds": ("waveform", "Instruments, effects and sound libraries"),
            "App data": ("folder", "Settings, documents and data apps keep in your Library"),
            "Hidden tool folders": ("eye.slash", "Dot-folders made by command-line tools"),
            "Trash": ("trash", "Waiting to be emptied"),
            "Downloads": ("arrow.down.circle", "Your Downloads folder"),
            "Documents & Desktop": ("doc", "Your Documents and Desktop"),
            "Music": ("music.note", "Your Music folder"),
            "Movies": ("film", "Your Movies folder"),
            "Pictures": ("photo", "Pictures outside the Photos library"),
            "Apps": ("square.grid.2x2", "Installed applications"),
            "Other files in your home": ("house", "Everything else in your home folder"),
            "Shared app data (/Library)": ("building.columns", "App support files shared by all users"),
            "Other users & shared": ("person.2", "Other accounts and the Shared folder"),
            "macOS system files": ("gearshape", "Swap, temporary files and Unix tools"),
            "Scanned folder": ("folder", "The folder you chose"),
            "Everything else": ("ellipsis.circle", "Anything not in the areas above"),
            "macOS & hidden system data": ("lock", "macOS itself, snapshots and protected system data"),
        ]
        report.areas = totals.filter { $0.value >= 100_000_000 }.map { name, size in
            StorageArea(name: name, symbol: info[name]?.symbol ?? "folder", size: size, detail: info[name]?.detail ?? "")
        }.sorted { $0.size > $1.size }
    }

    // MARK: Growth

    private func findGrowth() {
        let previous = SizeHistory.load()
        report.previousScan = previous?.date
        // Folders up to 6 levels deep and at least 50 MB are remembered for next time.
        let current = sizes.filter { path, size in
            size >= 50_000_000 && path.split(separator: "/").count <= 6
        }
        if saveHistory { SizeHistory.save(current, replacingUnder: result.root) }
        guard let previous else { return }

        let old = previous.sizes
        let threshold: Int64 = 1_000_000_000
        var changed: [String: Int64] = [:]
        for (path, now) in current {
            let parent = (path as NSString).deletingLastPathComponent
            guard let before = old[path] ?? (old[parent] != nil ? 0 : nil) else { continue }
            if now - before >= threshold { changed[path] = now - before }
        }
        // Keep the folder that explains the growth: skip a folder when one child accounts for most of it,
        // and skip an ancestor when the folders kept inside it already explain it.
        var kept = changed.filter { path, delta in
            !changed.contains { other, d in (other as NSString).deletingLastPathComponent == path && d * 10 >= delta * 7 }
        }
        kept = kept.filter { path, delta in
            let inside = kept.filter { $0.key.hasPrefix(path + "/") }.values.reduce(0, +)
            return inside * 10 < delta * 7
        }
        // Show the summarising folder, not its sub-folders as well.
        kept = kept.filter { path, _ in !kept.keys.contains { path.hasPrefix($0 + "/") } }
        report.growth = kept.map { path, _ in
            let finding = report.findings.first { f in f.paths.contains { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") } }
            return Growth(path: path, label: growthLabel(path), before: old[path] ?? 0, after: current[path] ?? 0,
                          reason: finding.map(growthReason))
        }
        .sorted { $0.delta > $1.delta }
        .prefix(6).map { $0 }
    }

    private func growthLabel(_ path: String) -> String {
        if let range = path.range(of: ".photoslibrary", options: .caseInsensitive) {
            let library = String(path[..<range.lowerBound])
            return (library as NSString).lastPathComponent
        }
        return pretty(path)
    }

    private func growthReason(_ finding: Finding) -> String {
        switch finding.kind {
        case .photos: finding.reclaimable > 0 ? "Photos is downloading full-size originals from iCloud" : "your Photos library"
        case .virtualMachine: "a virtual machine's disk grew"
        case .archive: "a big download"
        case .project: "a code project"
        case .update: "a macOS update was downloaded"
        case .cloud: "iCloud Drive files were downloaded"
        case .messages: "Messages attachments"
        default: finding.title
        }
    }

    // MARK: Summary

    private func writeSummary() {
        var lines: [String] = []
        var first = "Your Mac has \(Fmt.bytes(report.freeNow)) free"
        if report.purgeable >= 1_000_000_000 {
            first += ", or \(Fmt.bytes(report.freeUsable)) counting space macOS clears by itself when it needs room"
        }
        lines.append(first + ".")

        let top = report.areas.filter { $0.name != "macOS & hidden system data" && $0.name != "Everything else" }.prefix(3)
        if !top.isEmpty {
            let parts = top.map { "\($0.name.lowercased()) (\(Fmt.bytes($0.size)))" }
            let joined = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts[0]
            lines.append("The biggest things on it are \(joined).")
        }
        if let growth = report.growth.first, let since = report.previousScan {
            var line = "Since your last scan \(ago(since)), \(growth.label.isEmpty ? pretty(growth.path) : growth.label) grew by \(Fmt.bytes(growth.delta))"
            if let reason = growth.reason, !reason.hasPrefix("your ") { line += " (\(reason))" }
            lines.append(line + ".")
        }
        if report.aiChecked > 0 {
            lines.append("DiskSweep's AI model looked at \(report.aiChecked) big folders and files and recognised \(report.aiRecognised) of them.")
        }
        let actionable = report.findings.filter { $0.reclaimable > 0 }
        if let best = actionable.first {
            lines.append("The biggest win: \(best.title.prefix(1).lowercased() + best.title.dropFirst()), about \(Fmt.bytes(best.reclaimable)).")
            if actionable.count > 1 {
                lines.append("Following all \(actionable.count) suggestions below could free about \(Fmt.bytes(report.reclaimable)).")
            }
        } else {
            lines.append("Nothing big stands out to remove. Your space is going on things you're using.")
        }
        report.summary = lines
    }

    // MARK: Helpers

    private func run(_ tool: String, _ args: [String], environment: [String: String] = [:], timeout: TimeInterval = 5) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate(); return "" }
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
