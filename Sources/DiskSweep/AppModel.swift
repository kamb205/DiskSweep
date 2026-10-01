import AppKit
import SwiftUI

struct TrashReport: Identifiable {
    let id = UUID()
    let movedCount: Int
    let movedBytes: Int64
    let failures: [(path: String, reason: String)]
}

struct VolumeInfo {
    var total: Int64 = 0
    var available: Int64 = 0
    var used: Int64 { max(total - available, 0) }
}

/// One step in the back/forward history: a sidebar page plus, for Space Lens, the folder being viewed.
struct NavigationStop: Equatable {
    var category: Category
    var folder: String?
}

@MainActor
final class AppModel: ObservableObject {
    enum Scope: String, CaseIterable, Identifiable {
        case entireDisk = "Entire Disk"
        case home = "Home Folder"
        case custom = "Choose Folder…"
        var id: String { rawValue }
    }

    enum Phase { case idle, scanning, done }

    static let largeSizeOptions: [Int64] = [50_000_000, 100_000_000, 250_000_000, 500_000_000, 1_000_000_000]
    static let oldSizeOptions: [Int64] = [1_000_000, 10_000_000, 50_000_000, 100_000_000]
    static let oldDayOptions: [(days: Int, label: String)] = [(90, "3 months"), (180, "6 months"), (365, "1 year"), (730, "2 years")]

    @Published var scope: Scope = .entireDisk
    @Published var customFolder: URL?
    @Published var phase: Phase = .idle
    @Published var progress = ScanProgress()
    @Published private(set) var result: ScanResult?
    @Published var selection: Set<String> = []
    @Published private(set) var location = NavigationStop(category: .dashboard)
    @Published private(set) var backStack: [NavigationStop] = []
    @Published private(set) var forwardStack: [NavigationStop] = []
    @Published var largeMin: Int64 = 100_000_000 { didSet { recomputeLists() } }
    @Published var oldDays = 180 { didSet { recomputeLists() } }
    @Published var oldMin: Int64 = 10_000_000 { didSet { recomputeLists() } }
    @Published var search = ""
    @Published private(set) var lists: [Category: [Item]] = [:]
    @Published private(set) var totals: [Category: Int64] = [:]
    @Published var hasFullDiskAccess = AppModel.checkFullDiskAccess()
    @Published var volume = VolumeInfo()
    @Published var isTrashing = false
    @Published var confirmingTrash = false
    @Published var isEmptyingTrash = false
    @Published var trashReport: TrashReport?
    @Published var showAccessRequired = false
    /// A newer build published by build.sh, waiting for "Restart to update".
    @Published private(set) var availableUpdate: String?
    /// Items currently in the Trash; nil when the Trash can't be read (needs Full Disk Access).
    @Published private(set) var trashEntries: [TrashEntry]?
    @Published var trashSelection: Set<String> = []
    @Published var trashMessage: String?
    @Published private(set) var lifetime = LifetimeStats.load() {
        didSet { if lifetime != oldValue { lifetime.save() } }
    }

    private var scanner: Scanner?
    private var progressTimer: Timer?
    private var liveTimer: Timer?
    private var liveTicks = 0
    private var isRefreshingTrash = false
    private(set) var itemIndex: [String: Item] = [:]
    private(set) var children: [String: [String]] = [:]
    /// Folders and files ticked in Space Lens that aren't in any other list.
    private var spaceLensItems: [String: Item] = [:]

    init() {
        refreshVolume()
        availableUpdate = Updater.availableBuild()
        restoreLastScan()
        startLiveUpdates()
    }

    /// Reopens the last scan's results (saved after every scan and cleanup), so restarting or
    /// updating the app doesn't mean scanning again. Items deleted since are dropped right away.
    private func restoreLastScan() {
        guard !isSnapshotRun, let cached = ScanCache.load() else { return }
        result = cached
        rebuildIndexes()
        phase = hasFullDiskAccess ? .done : .idle
        pruneMissing()
        refreshTrash()
    }

    private func saveScan() {
        guard let result, !isSnapshotRun else { return }
        Task.detached(priority: .utility) { ScanCache.save(result) }
    }

    func installUpdate() {
        if !Updater.installAndRelaunch() { availableUpdate = nil }
    }

    /// Skips the Full Disk Access gate for the developer layout-snapshot tool.
    private var isSnapshotRun: Bool { DebugSnapshot.directory != nil }

    // MARK: - Navigation

    var category: Category { location.category }

    /// Sidebar selection. Setting it records history so Back returns to the previous page.
    var categoryBinding: Binding<Category> {
        Binding(get: { self.location.category }, set: { self.navigate(to: $0) })
    }

    var spaceLensFolder: String { location.folder ?? result?.root ?? "/" }

    func navigate(to category: Category, folder: String? = nil) {
        let stop = NavigationStop(category: category, folder: folder)
        guard stop != location else { return }
        backStack.append(location)
        forwardStack.removeAll()
        location = stop
        search = ""
    }

    func openFolder(_ folder: String) { navigate(to: .spaceLens, folder: folder) }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(location)
        location = previous
        search = ""
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(location)
        location = next
        search = ""
    }

    private func resetNavigation() {
        location = NavigationStop(category: .dashboard)
        backStack = []
        forwardStack = []
    }

    // MARK: - Scanning

    var scanRoot: URL? {
        switch scope {
        case .entireDisk: URL(fileURLWithPath: "/")
        case .home: URL(fileURLWithPath: NSHomeDirectory())
        case .custom: customFolder
        }
    }

    var hasResults: Bool { result != nil }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            customFolder = url
            scope = .custom
        }
    }

    /// Previous results are kept until the new scan finishes, so cancelling returns to them.
    func startScan() {
        hasFullDiskAccess = Self.checkFullDiskAccess()
        guard hasFullDiskAccess || isSnapshotRun else {
            showAccessRequired = true
            return
        }
        guard let root = scanRoot else { chooseFolder(); return }
        let scanner = Scanner(root: root)
        self.scanner = scanner
        progress = ScanProgress()
        phase = .scanning
        hasFullDiskAccess = Self.checkFullDiskAccess()

        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.progress = scanner.progress }
        }

        Task {
            let scanned = await Task.detached(priority: .userInitiated) { scanner.run() }.value
            progressTimer?.invalidate()
            progressTimer = nil
            self.scanner = nil
            if let scanned {
                finish(scanned)
            } else {
                phase = hasResults ? .done : .idle
            }
        }
    }

    func cancelScan() { scanner?.cancel() }

    /// Goes to the start screen without throwing away the current results.
    func showStartScreen() { phase = .idle }

    func backToResults() { if hasResults { phase = .done } }

    private func finish(_ scanned: ScanResult) {
        spaceLensItems = [:]
        result = scanned
        selection = []
        search = ""
        resetNavigation()
        rebuildIndexes()
        refreshVolume()
        refreshTrash()
        phase = .done
        saveScan()
    }

    private func rebuildIndexes() {
        recomputeLists()
        guard let result else { return }
        var index: [String: Item] = [:]
        for item in result.files + result.duplicates.flatMap(\.items) { index[item.path] = item }
        for (path, item) in spaceLensItems where index[path] == nil { index[path] = item }
        for category in Category.itemCategories {
            for item in lists[category] ?? [] { index[item.path] = item }
        }
        itemIndex = index

        var kids: [String: [String]] = [:]
        for path in result.folderSizes.keys {
            let parent = (path as NSString).deletingLastPathComponent
            if parent != path { kids[parent, default: []].append(path) }
        }
        children = kids
    }

    func refreshVolume() {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        let target = scanRoot ?? URL(fileURLWithPath: "/")
        if let values = try? target.resourceValues(forKeys: keys) {
            volume = VolumeInfo(total: Int64(values.volumeTotalCapacity ?? 0),
                                available: values.volumeAvailableCapacityForImportantUsage ?? 0)
        }
    }

    // MARK: - Category data

    var duplicateGroups: [DuplicateGroup] { result?.duplicates ?? [] }

    /// Lists and totals are cached and only rebuilt when the scan result or a filter changes,
    /// so ticking a checkbox doesn't re-filter thousands of files.
    private func recomputeLists() {
        guard let result else {
            lists = [:]
            totals = [:]
            return
        }
        let cutoff = Date().addingTimeInterval(-Double(oldDays) * 86_400)
        let newLists: [Category: [Item]] = [
            .systemJunk: result.junk,
            .developer: result.developer,
            .aiModels: result.aiModels,
            .installers: result.installers,
            .large: result.files.filter { $0.size >= largeMin },
            .old: result.files.filter { $0.size >= oldMin && $0.lastUsedSort < cutoff },
            .duplicates: result.duplicates.flatMap(\.items),
            .music: result.music,
            .downloads: result.downloads ?? [],
            .uninstaller: result.apps,
            .leftovers: result.leftovers,
        ]
        var newTotals: [Category: Int64] = [:]
        for (category, items) in newLists { newTotals[category] = items.reduce(0) { $0 + $1.size } }
        newTotals[.duplicates] = result.duplicates.reduce(0) { $0 + $1.wasted }
        newTotals[.trash] = trashEntries.map { $0.reduce(0) { $0 + $1.size } } ?? result.trashSize ?? 0
        newTotals[.spaceLens] = result.scannedBytes
        newTotals[.dashboard] = recommended(in: newLists).reduce(0) { $0 + $1.size }
        lists = newLists
        totals = newTotals
    }

    func items(for category: Category) -> [Item] { lists[category] ?? [] }

    func total(for category: Category) -> Int64 { totals[category] ?? 0 }

    func count(for category: Category) -> Int {
        switch category {
        case .duplicates: duplicateGroups.count
        case .trash: trashEntries?.count ?? result?.trashCount ?? 0
        case .dashboard: recommendedItems.count
        default: items(for: category).count
        }
    }

    /// Items that are safe to remove without review: they're rebuilt or downloaded again automatically.
    private func recommended(in lists: [Category: [Item]]) -> [Item] {
        var seen = Set<String>()
        return [Category.systemJunk, .developer, .aiModels, .installers, .downloads]
            .flatMap { lists[$0] ?? [] }
            .filter { seen.insert($0.path).inserted }
            .filter { $0.safety == .safe && !Self.belongsToRunningApp($0) && Self.isDeletable($0.path) }
    }

    /// A cache of an app that's open right now is left out of the one-click selection: the app may be
    /// using it, and it would rebuild it straight away anyway.
    private static func belongsToRunningApp(_ item: Item) -> Bool {
        guard item.path.hasPrefix(NSHomeDirectory() + "/Library/Caches/") else { return false }
        let name = (item.path as NSString).lastPathComponent.lowercased()
        return NSWorkspace.shared.runningApplications.contains { app in
            if let id = app.bundleIdentifier?.lowercased(), name == id || name.hasPrefix(id + ".") { return true }
            if let appName = app.localizedName?.lowercased(), appName.count >= 3, name == appName { return true }
            return false
        }
    }

    var recommendedItems: [Item] { recommended(in: lists) }

    func selectRecommended() { selection.formUnion(recommendedItems.map(\.path)) }

    // MARK: - Selection

    func binding(for path: String) -> Binding<Bool> {
        Binding(
            get: { self.selection.contains(path) },
            set: { checked in
                if checked { self.selection.insert(path) } else { self.selection.remove(path) }
            }
        )
    }

    func selectAll(in category: Category, items: [Item]) {
        if category == .duplicates {
            selectExtraCopies()
        } else {
            selection.formUnion(items.map(\.path))
        }
    }

    func deselectAll(_ items: [Item]) {
        selection.subtract(items.map(\.path))
    }

    /// Selects every copy except the suggested one to keep in each duplicate group.
    func selectExtraCopies() {
        for group in duplicateGroups {
            guard let keep = group.items.first else { continue }
            selection.remove(keep.path)
            selection.formUnion(group.items.dropFirst().map(\.path))
        }
    }

    var selectedBytes: Int64 {
        selection.reduce(0) { $0 + (itemIndex[$1]?.size ?? 0) }
    }

    var selectedCautionCount: Int {
        selection.filter { itemIndex[$0]?.safety == .caution }.count
    }

    /// Duplicate groups where every copy is selected — deleting them would lose the file entirely.
    var fullySelectedDuplicateGroups: Int {
        duplicateGroups.filter { group in group.items.allSatisfy { selection.contains($0.path) } }.count
    }

    // MARK: - Trash

    func trashSelected() { trash(paths: Array(selection)) }

    /// Moves the given items (and, for apps, their related data) to the Trash.
    func trash(paths: [String]) {
        guard !paths.isEmpty, !isTrashing else { return }
        let runningApps = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
        isTrashing = true

        Task {
            var moved: [String] = []
            var movedBytes: Int64 = 0
            var failed: [(path: String, reason: String)] = []
            for path in paths {
                guard Self.isDeletable(path) else {
                    failed.append((path, "Protected location — skipped"))
                    continue
                }
                if runningApps.contains(path) {
                    failed.append((path, "App is running — quit it and try again"))
                    continue
                }
                // Already gone, e.g. a cache that was also part of an uninstalled app.
                guard FileManager.default.fileExists(atPath: path) else {
                    moved.append(path)
                    continue
                }
                do {
                    // Goes through Finder, which asks for your password for items owned by the system.
                    let mapping = try await NSWorkspace.shared.recycle([URL(fileURLWithPath: path)])
                    moved.append(path)
                    let size = itemIndex[path]?.size ?? 0
                    movedBytes += size
                    if let trashPath = mapping.values.first?.path {
                        lifetime.recordTrashed(bytes: size, trashPath: trashPath, originalPath: path)
                    }
                    let related = (itemIndex[path]?.related ?? [])
                        .filter { Self.isDeletable($0) && FileManager.default.fileExists(atPath: $0) }
                    if !related.isEmpty {
                        _ = try? await NSWorkspace.shared.recycle(related.map { URL(fileURLWithPath: $0) })
                        moved.append(contentsOf: related)
                    }
                } catch {
                    failed.append((path, error.localizedDescription))
                }
            }
            applyRemoval(Set(moved))
            isTrashing = false
            refreshVolume()
            trashReport = TrashReport(movedCount: paths.count - failed.count, movedBytes: movedBytes, failures: failed)
        }
    }

    nonisolated static func isDeletable(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        let lib = home + "/Library"
        let protected: Set<String> = [
            "/", home, lib, home + "/Documents", home + "/Desktop", home + "/Downloads",
            home + "/Pictures", home + "/Movies", home + "/Music", home + "/Applications", home + "/Public",
            lib + "/Application Support", lib + "/Caches", lib + "/Containers", lib + "/Group Containers",
            lib + "/Logs", lib + "/Developer", home + "/.cache",
            "/Applications", "/Users/Shared", "/Volumes", "/Library/Application Support",
        ]
        if protected.contains(path) { return false }
        func inside(_ tree: String) -> Bool { path == tree || path.hasPrefix(tree + "/") }
        // Never offer things macOS, iCloud, your mail/messages or your sign-ins rely on.
        let protectedTrees = [
            lib + "/Keychains", lib + "/Preferences", lib + "/Mobile Documents", lib + "/CloudStorage",
            lib + "/Accounts", lib + "/Mail", lib + "/Messages", lib + "/Calendars", lib + "/Safari",
            lib + "/Cookies", lib + "/IdentityServices", lib + "/Sharing", lib + "/Biome",
            lib + "/Daemon Containers", lib + "/Application Support/AddressBook", lib + "/Application Support/Knowledge",
            lib + "/Application Support/CallHistoryDB", lib + "/Application Support/FileProvider",
            lib + "/Application Support/CloudDocs", lib + "/Application Support/Apple",
            "/Library/Application Support/Apple",
            home + "/.Trash", home + "/.ssh", home + "/.gnupg",
        ]
        if protectedTrees.contains(where: inside) { return false }
        // Apple's own app data, except Mail's copies of opened attachments (offered as junk).
        let mailDownloads = lib + "/Containers/com.apple.mail/Data/Library/Mail Downloads"
        for appleData in [lib + "/Containers/com.apple.", lib + "/Group Containers/group.com.apple.",
                          lib + "/Application Support/com.apple.", "/Library/Application Support/com.apple."]
        where path.hasPrefix(appleData) && !inside(mailDownloads) {
            return false
        }
        // Git history (deleting it breaks the project) and photo libraries.
        if path.hasSuffix("/.git") || path.contains("/.git/") { return false }
        if path.lowercased().contains(".photoslibrary") { return false }
        // Apple's apps and DiskSweep itself.
        if path.hasSuffix(".app"), let id = Bundle(path: path)?.bundleIdentifier,
           id.hasPrefix("com.apple.") || id == Bundle.main.bundleIdentifier {
            return false
        }
        let allowedRoots = [home + "/", "/Applications/", "/Users/Shared/", "/Volumes/", "/Library/Application Support/"]
        return allowedRoots.contains { path.hasPrefix($0) }
    }

    private func applyRemoval(_ removed: Set<String>) {
        guard var r = result, !removed.isEmpty else { return }
        let keep: (Item) -> Bool = { !removed.contains($0.path) }
        r.files = r.files.filter(keep)
        r.junk = r.junk.filter(keep)
        r.developer = r.developer.filter(keep)
        r.aiModels = r.aiModels.filter(keep)
        r.installers = r.installers.filter(keep)
        r.apps = r.apps.filter(keep)
        r.leftovers = r.leftovers.filter(keep)
        r.music = r.music.filter(keep)
        r.downloads = r.downloads?.filter(keep)
        spaceLensItems = spaceLensItems.filter { path, _ in
            !removed.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        r.duplicates = r.duplicates.compactMap { group in
            var g = group
            g.items = g.items.filter(keep)
            return g.items.count > 1 ? g : nil
        }
        let removedFolders = removed.filter { r.folderSizes[$0] != nil }
        let removedSizes = Dictionary(uniqueKeysWithValues: removed.map { ($0, r.folderSizes[$0] ?? itemIndex[$0]?.size ?? 0) })
        if !removedFolders.isEmpty {
            r.folderSizes = r.folderSizes.filter { key, _ in
                !removedFolders.contains { key == $0 || key.hasPrefix($0 + "/") }
            }
        }
        for (path, size) in removedSizes {
            var ancestor = (path as NSString).deletingLastPathComponent
            while true {
                if let current = r.folderSizes[ancestor] { r.folderSizes[ancestor] = max(current - size, 0) }
                let next = (ancestor as NSString).deletingLastPathComponent
                if next == ancestor { break }
                ancestor = next
            }
        }
        let trashedBytes = removed.reduce(Int64(0)) { $0 + (itemIndex[$1]?.size ?? 0) }
        r.scannedBytes = max(r.scannedBytes - trashedBytes, 0)
        result = r
        selection.subtract(removed)
        rebuildIndexes()
        refreshTrash()
        saveScan()
    }

    /// Asks Finder to empty the Trash, exactly like Finder › Empty Trash.
    func emptyTrash() {
        isEmptyingTrash = true
        Task {
            let succeeded = await Task.detached { () -> Bool in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", "tell application \"Finder\" to empty trash"]
                do {
                    try process.run()
                    process.waitUntilExit()
                    return process.terminationStatus == 0
                } catch {
                    return false
                }
            }.value
            isEmptyingTrash = false
            if !succeeded { trashMessage = "Finder couldn't empty the Trash. Check that DiskSweep is allowed to control Finder in Privacy & Security › Automation." }
            trashSelection = []
            refreshTrash()
            refreshVolume()
        }
    }

    // MARK: - Space Lens selection

    /// Whether a folder or file shown in Space Lens may be ticked for the Trash.
    func canSelectInSpaceLens(_ path: String) -> Bool { Self.isDeletable(path) }

    /// Tick state for a Space Lens row or circle slice. Ticking creates a list item for it, so it
    /// goes through the same confirmation and Move to Trash flow as everything else.
    func spaceLensBinding(for path: String) -> Binding<Bool> {
        Binding(
            get: { self.selection.contains(path) },
            set: { checked in
                if checked { self.selectInSpaceLens(path) } else { self.selection.remove(path) }
            }
        )
    }

    func selectInSpaceLens(_ path: String) {
        guard canSelectInSpaceLens(path) else { return }
        if itemIndex[path] == nil {
            let size = result?.folderSizes[path] ?? TrashReader.allocatedSize(of: path)
            let isFolder = result?.folderSizes[path] != nil
            let underLibrary = path.hasPrefix(NSHomeDirectory() + "/Library/") || path.hasPrefix("/Library/")
            let item = Item(path: path, name: (path as NSString).lastPathComponent, size: size, lastUsed: nil,
                            modified: nil, isDirectory: isFolder, safety: underLibrary ? .caution : .review,
                            note: "Picked in Space Lens")
            spaceLensItems[path] = item
            itemIndex[path] = item
        }
        selection.insert(path)
    }

    // MARK: - Trash items

    /// Re-reads the Trash in the background and updates the Trash Bins page and sidebar total.
    func refreshTrash() {
        guard !isRefreshingTrash else { return }
        isRefreshingTrash = true
        Task {
            let entries = await Task.detached(priority: .utility) { TrashReader.load() }.value
            isRefreshingTrash = false
            if entries != trashEntries {
                trashEntries = entries
                let present = Set(entries?.map(\.path) ?? [])
                trashSelection.formIntersection(present)
                if entries != nil && hasFullDiskAccess { lifetime.settle() }
                recomputeLists()
            }
        }
    }

    var selectedTrashEntries: [TrashEntry] {
        (trashEntries ?? []).filter { trashSelection.contains($0.path) }
    }

    /// Moves the selected items out of the Trash, back to where they were deleted from.
    func putBackSelected() {
        let entries = selectedTrashEntries
        guard !entries.isEmpty else { return }
        // Clear the pending records first, so the 5-second refresh can't count these as erased
        // while they're on their way out of the Trash.
        var records: [String: LifetimeStats.Pending] = [:]
        for entry in entries {
            if let record = lifetime.recordPutBack(trashPath: entry.path) { records[entry.path] = record }
        }
        Task {
            let outcome = await Task.detached { () -> (restored: [String], restoredFrom: [String], failed: [String]) in
                var restored: [String] = []
                var restoredFrom: [String] = []
                var failed: [String] = []
                for entry in entries {
                    do {
                        restored.append(Fmt.path(try TrashReader.putBack(entry)))
                        restoredFrom.append(entry.path)
                    } catch {
                        failed.append("\(entry.name): \(error.localizedDescription)")
                    }
                }
                return (restored, restoredFrom, failed)
            }.value
            let restoredFrom = Set(outcome.restoredFrom)
            for (path, record) in records where !restoredFrom.contains(path) {
                lifetime.undoPutBack(trashPath: path, record)
            }
            trashSelection = []
            var message = "Put back \(outcome.restored.count) item\(outcome.restored.count == 1 ? "" : "s")."
            if let first = outcome.restored.first {
                message += outcome.restored.count == 1 ? " It's now at \(first)." : " For example: \(first)."
            }
            if !outcome.failed.isEmpty { message += "\n\nCouldn't put back:\n" + outcome.failed.prefix(5).joined(separator: "\n") }
            trashMessage = message
            refreshTrash()
            refreshVolume()
        }
    }

    /// Permanently erases the selected Trash items. This can't be undone.
    func deleteSelectedPermanently() {
        let entries = selectedTrashEntries
        guard !entries.isEmpty else { return }
        Task {
            let failed = await Task.detached { () -> [String] in
                var failed: [String] = []
                for entry in entries {
                    do { try TrashReader.deletePermanently(entry) }
                    catch { failed.append(entry.name) }
                }
                return failed
            }.value
            trashSelection = []
            if !failed.isEmpty {
                trashMessage = "\(failed.count) item(s) couldn't be erased, usually because they belong to the system. Use Empty Trash to remove them:\n" + failed.prefix(5).joined(separator: "\n")
            }
            refreshTrash()
            refreshVolume()
        }
    }

    // MARK: - Live updates

    /// Keeps the numbers current without a full rescan: free space and the Trash every 5 seconds,
    /// and every 15 seconds drops items that were deleted or moved outside DiskSweep.
    private func startLiveUpdates() {
        liveTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveTick() }
        }
    }

    private func liveTick() {
        liveTicks += 1
        refreshVolume()
        availableUpdate = Updater.availableBuild()
        if phase == .idle { hasFullDiskAccess = Self.checkFullDiskAccess() }
        // Count pending items that were erased, even if the Trash was emptied in Finder.
        // Needs Full Disk Access: without it the Trash looks empty and everything would count.
        if hasFullDiskAccess && !lifetime.pending.isEmpty { lifetime.settle() }
        guard phase == .done, !isTrashing else { return }
        refreshTrash()
        if liveTicks % 3 == 0 { pruneMissing() }
    }

    private func pruneMissing() {
        let paths = Array(itemIndex.keys)
        Task {
            let missing = await Task.detached(priority: .utility) {
                Set(paths.filter { !FileManager.default.fileExists(atPath: $0) })
            }.value
            if !missing.isEmpty { applyRemoval(missing) }
        }
    }

    // MARK: - System helpers

    nonisolated static func checkFullDiskAccess() -> Bool { FullDiskAccess.isGranted() }

    func openFullDiskAccessSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    /// Full Disk Access is granted to one specific copy of the app, so it should live in /Applications.
    nonisolated static var isInstalledInApplications: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    nonisolated static var appPath: String { Bundle.main.bundlePath }

    /// Shows this app in Finder so it can be dragged straight into the Full Disk Access list.
    func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    /// macOS only applies a new Full Disk Access grant after the app restarts.
    func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func reveal(_ paths: [String]) {
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
    }

    func openTrash() {
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
    }
}
