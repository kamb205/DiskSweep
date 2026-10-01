import Foundation
import CryptoKit
import CoreServices
import AppKit

struct ScanProgress {
    var phase = "Preparing…"
    var files = 0
    var bytes: Int64 = 0
    var currentPath = ""
}

/// Walks the disk once, measuring folder sizes and collecting cleanup candidates,
/// then refines "last opened" dates via Spotlight and hashes same-size files to find duplicates.
/// Never modifies anything on disk.
final class Scanner: @unchecked Sendable {
    static let minCandidateSize: Int64 = 1_000_000

    private enum Special {
        case junk(Safety, String, name: String? = nil)
        case developer(Safety, String, name: String? = nil)
        case ai(Safety, String)
        case installer(Safety, String)
        case app
        case trash
    }

    /// Package-manager and tool caches inside ~/Library/Caches that belong under Developer Junk.
    private let developerCacheNames: [String: String] = [
        "Yarn": "Yarn package cache", "pip": "pip package cache", "pypoetry": "Poetry cache",
        "CocoaPods": "CocoaPods cache", "JetBrains": "JetBrains IDE caches", "go-build": "Go build cache",
        "deno": "Deno cache", "Homebrew": "Homebrew download cache", "com.apple.dt.Xcode": "Xcode cache",
        "org.swift.swiftpm": "Swift Package Manager cache", "ms-playwright": "Playwright browser downloads",
        "node-gyp": "node-gyp headers", "typescript": "TypeScript cache", "Cypress": "Cypress binaries",
        "electron": "Electron downloads", "uv": "uv package cache", "pnpm": "pnpm cache",
    ]

    /// AI model caches inside ~/.cache.
    private let aiCacheNames: [String: (Safety, String)] = [
        "huggingface": (.review, "Hugging Face model downloads — re-downloaded when needed"),
        "torch": (.safe, "PyTorch model cache"),
        "whisper": (.safe, "Whisper speech model cache"),
        "lm-studio": (.review, "LM Studio models"),
        "clip": (.safe, "CLIP model cache"),
    ]

    private var appBundleIDs: [String: String] = [:]
    private var installedAppNames = Set<String>()
    private var installedBundleIDs = Set<String>()

    private let root: URL
    private let fm = FileManager.default
    private let home = NSHomeDirectory()
    private let lock = NSLock()
    private var _progress = ScanProgress()
    private var _cancelled = false
    private var result: ScanResult
    private var logicalSizes: [String: Int64] = [:]
    private var pendingFiles = 0
    private var pendingBytes: Int64 = 0

    private let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
        .contentAccessDateKey, .contentModificationDateKey,
    ]
    private let keySet: Set<URLResourceKey>
    private let maxRecordDepth = 9

    // Not walked when scanning from "/": the sealed system volume, other volumes and pseudo filesystems.
    private let excludedDirs: Set<String> = [
        "/System", "/Volumes", "/dev", "/net", "/home", "/Network", "/.vol", "/.nofollow", "/.resolve",
        "/.Spotlight-V100", "/.fseventsd", "/.DocumentRevisions-V100", "/.MobileBackups",
    ]
    private let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]
    private let ownBundleID = Bundle.main.bundleIdentifier

    private var lib: String { home + "/Library" }

    init(root: URL) {
        self.root = root
        keySet = Set(keys)
        result = ScanResult(root: root.path)
    }

    // MARK: - Progress & cancellation

    var progress: ScanProgress {
        lock.lock(); defer { lock.unlock() }
        return _progress
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
    }

    private func setPhase(_ phase: String) {
        lock.lock(); _progress.phase = phase; lock.unlock()
    }

    private func flushProgress(path: String? = nil) {
        lock.lock()
        _progress.files += pendingFiles
        _progress.bytes += pendingBytes
        if let path { _progress.currentPath = path }
        lock.unlock()
        pendingFiles = 0
        pendingBytes = 0
    }

    // MARK: - Run

    func run() -> ScanResult? {
        let start = Date()
        setPhase("Scanning files…")
        result.scannedBytes = walk(root, depth: 0, candidates: startsInCandidateZone(root.path))
        flushProgress()
        result.scannedFiles = progress.files
        if isCancelled { return nil }

        setPhase("Matching apps with their data…")
        attachAppData()
        findLeftovers()
        if isCancelled { return nil }

        setPhase("Sorting your Downloads folder…")
        findDownloads()
        if isCancelled { return nil }

        setPhase("Checking when files were last opened…")
        refineLastUsed()
        if isCancelled { return nil }

        setPhase("Looking for duplicate files…")
        findDuplicates()
        if isCancelled { return nil }

        result.files.sort { $0.size > $1.size }
        for keyPath in [\ScanResult.junk, \.developer, \.aiModels, \.installers, \.apps, \.leftovers, \.music] as [WritableKeyPath<ScanResult, [Item]>] {
            result[keyPath: keyPath].sort { $0.size > $1.size }
        }
        result.duration = Date().timeIntervalSince(start)
        return result
    }

    /// Individual files are only offered for deletion inside the user's own areas — never inside
    /// ~/Library (app data) or system folders. Caches and apps are handled separately.
    private func startsInCandidateZone(_ p: String) -> Bool {
        if p == lib || p.hasPrefix(lib + "/") { return false }
        return p == home || p.hasPrefix(home + "/")
            || p.hasPrefix("/Users/Shared") || p.hasPrefix("/Volumes/")
    }

    // MARK: - Walk

    @discardableResult
    private func walk(_ dir: URL, depth: Int, candidates: Bool) -> Int64 {
        if isCancelled { return 0 }
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [])
        } catch {
            result.deniedCount += 1
            if result.deniedSamples.count < 25 { result.deniedSamples.append(dir.path) }
            return 0
        }

        var total: Int64 = 0
        for url in contents {
            if isCancelled { break }
            guard let rv = try? url.resourceValues(forKeys: keySet), rv.isSymbolicLink != true else { continue }
            var path = url.path
            if path.count > 1 && path.hasSuffix("/") { path.removeLast() }

            if rv.isDirectory == true {
                if excludedDirs.contains(path) { continue }
                registerPluginIfNeeded(path)
                if let special = classify(path: path, candidates: candidates) {
                    let size = walk(url, depth: depth + 1, candidates: false)
                    record(special, url: url, size: size, values: rv)
                    total += size
                    continue
                }
                var childCandidates = candidates
                if path == home || path == "/Users/Shared" { childCandidates = true }
                if path == lib || path == home + "/.Trash" || rv.isPackage == true { childCandidates = false }
                total += walk(url, depth: depth + 1, candidates: childCandidates)
            } else {
                let size = Int64(rv.totalFileAllocatedSize ?? rv.fileAllocatedSize ?? 0)
                total += size
                pendingFiles += 1
                pendingBytes += size
                if pendingFiles >= 400 { flushProgress(path: path) }
                if candidates { considerFile(url: url, path: path, size: size, values: rv) }
            }
        }
        if depth < maxRecordDepth { result.folderSizes[dir.path] = total }
        return total
    }

    private func considerFile(url: URL, path: String, size: Int64, values rv: URLResourceValues) {
        let ext = url.pathExtension.lowercased()
        guard !isToolOrSystemFile(path: path, ext: ext) else { return }
        if size >= MusicTagger.minimumSize, MusicTagger.isMusicFile(extension: ext),
           let (group, match) = MusicTagger.group(forFileName: url.lastPathComponent) {
            let kind = MusicTagger.projectExtensions.contains(ext) ? "\(ext.uppercased()) project" : "\(ext.uppercased()) audio"
            let note = match.map { "Name contains “\($0)” · \(kind)" } ?? kind
            result.music.append(Item(path: path, name: url.lastPathComponent, size: size,
                                     lastUsed: maxDate(rv.contentAccessDate, rv.contentModificationDate),
                                     modified: rv.contentModificationDate, isDirectory: false,
                                     safety: .review, note: note, group: group))
        }
        guard size >= Self.minCandidateSize else { return }
        let lastUsed = maxDate(rv.contentAccessDate, rv.contentModificationDate)
        let parent = url.deletingLastPathComponent().path
        let inDownloads = parent.hasPrefix(home + "/Downloads") || parent.hasPrefix(home + "/Desktop")

        let item = Item(path: path, name: url.lastPathComponent, size: size, lastUsed: lastUsed,
                        modified: rv.contentModificationDate, isDirectory: false,
                        safety: .review, note: kindDescription(ext))
        result.files.append(item)
        logicalSizes[path] = Int64(rv.fileSize ?? 0)

        if installerExtensions.contains(ext) {
            let safety: Safety = inDownloads ? .safe : .review
            let note = ext == "iso"
                ? "Disk image — delete if you no longer need it"
                : "Installer — not needed once the app is installed"
            result.installers.append(Item(path: path, name: item.name, size: size, lastUsed: lastUsed,
                                          modified: item.modified, isDirectory: false, safety: safety, note: note))
        } else if ext == "zip" && inDownloads {
            result.installers.append(Item(path: path, name: item.name, size: size, lastUsed: lastUsed,
                                          modified: item.modified, isDirectory: false, safety: .review,
                                          note: "Archive in Downloads — check whether you already extracted it"))
        }
    }

    /// Folders in your home that hold installed tools rather than your own files: removing files
    /// from them breaks programs (Node, Python, Conda, Rust, Flutter, editor extensions…).
    private let toolFolders: Set<String> = [
        "miniconda3", "miniconda", "anaconda3", "anaconda", "miniforge3", "mambaforge", "opt",
        "flutter", "sdk", "development", "homebrew", "bin", "lib", "go",
    ]

    /// Files that look like part of an installed program, or live inside a hidden folder (dotfolders hold
    /// tool installs, settings and Git history). They're never listed as files to remove.
    private func isToolOrSystemFile(path: String, ext: String) -> Bool {
        guard path.hasPrefix(home + "/") else { return false }
        let folders = path.dropFirst(home.count + 1).split(separator: "/").dropLast()
        if folders.contains(where: { $0.hasPrefix(".") }) { return true }
        if let top = folders.first, toolFolders.contains(top.lowercased()) { return true }
        if folders.contains(where: { $0 == "node_modules" || $0 == "site-packages" || $0 == "Frameworks" }) { return true }
        if ["dylib", "so", "a", "o", "framework", "bundle", "plugin", "kext", "jar", "node", "sys", "dll", "exe"].contains(ext) { return true }
        // A program with no extension (executable bit set), e.g. a command-line tool.
        if ext.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return true }
        return false
    }

    /// Project build folders are only offered in normal project folders, never inside hidden tool
    /// folders (~/.nvm, ~/.vscode/extensions…) or tool installs, where they are part of a program.
    private func isInsideToolFolder(_ path: String) -> Bool {
        guard path.hasPrefix(home + "/") else { return true }
        let folders = path.dropFirst(home.count + 1).split(separator: "/").dropLast()
        if folders.contains(where: { $0.hasPrefix(".") || $0 == "node_modules" }) { return true }
        if let top = folders.first, toolFolders.contains(top.lowercased()) { return true }
        return false
    }

    private func classify(path: String, candidates: Bool) -> Special? {
        let ns = path as NSString
        let parent = ns.deletingLastPathComponent
        let name = ns.lastPathComponent
        let parentName = (parent as NSString).lastPathComponent
        let xcode = lib + "/Developer/Xcode"
        let support = lib + "/Application Support"

        if path == home + "/.Trash" { return .trash }

        // System junk: app caches and logs
        if parent == lib + "/Caches" {
            if let note = developerCacheNames[name] { return .developer(.safe, note) }
            return name.hasPrefix("com.apple.")
                ? .junk(.review, "macOS cache — rebuilt automatically, but may be in use")
                : .junk(.safe, "App cache — rebuilt automatically when needed")
        }
        if parent == lib + "/Logs" { return .junk(.safe, "Log files — only useful for troubleshooting") }
        if parent == lib + "/Application Support/MobileSync/Backup" {
            return .junk(.review, "iPhone/iPad backup — remove only if it's backed up in iCloud or no longer needed",
                         name: iOSBackupName(path))
        }
        if path == lib + "/Containers/com.apple.mail/Data/Library/Mail Downloads" {
            return .junk(.safe, "Copies of attachments you opened in Mail — the originals stay in your mail", name: "Mail Downloads")
        }
        if path == support + "/Google/GoogleUpdater/crx_cache" { return .junk(.safe, "Chrome updater download cache") }
        if path == support + "/Google/Chrome/extensions_crx_cache" { return .junk(.safe, "Chrome extension download cache") }

        // Developer: Xcode, simulators, editors, Docker
        if path == xcode + "/DerivedData" { return .developer(.safe, "Xcode build products — rebuilt on next build") }
        if path == xcode + "/Archives" { return .developer(.review, "Xcode archives — only needed to re-submit old builds") }
        if path == xcode + "/DocumentationCache" { return .developer(.safe, "Xcode documentation cache") }
        if parent == xcode && name.hasSuffix("DeviceSupport") {
            return .developer(.safe, "Device debug symbols — re-downloaded when a device connects")
        }
        if path == lib + "/Developer/CoreSimulator/Devices" {
            return .developer(.review, "iOS Simulator devices and the apps installed on them")
        }
        if path == lib + "/Developer/CoreSimulator/Caches" { return .developer(.safe, "iOS Simulator caches") }
        if parent == support + "/Code" && ["Cache", "CachedData", "CachedExtensionVSIXs", "GPUCache"].contains(name) {
            return .developer(.safe, "VS Code cache", name: "VS Code \(name)")
        }
        if path == lib + "/Containers/com.docker.docker/Data/vms" {
            return .developer(.caution, "Docker's virtual disk — removing it deletes all containers and images", name: "Docker disk image")
        }

        // Developer: package-manager caches in the home folder
        let homeCaches: [String: (Safety, String)] = [
            "/.npm": (.safe, "npm download cache — refilled on next install"),
            "/.gradle/caches": (.safe, "Gradle build cache"),
            "/.m2/repository": (.review, "Maven downloaded dependencies"),
            "/.cargo/registry": (.safe, "Rust crate download cache"),
            "/go/pkg/mod": (.safe, "Go module cache"),
            "/.bun/install/cache": (.safe, "Bun package cache"),
            "/.pnpm-store": (.safe, "pnpm package store"),
            "/Library/pnpm/store": (.safe, "pnpm package store"),
            "/.local/share/pnpm/store": (.safe, "pnpm package store"),
            "/.cocoapods/repos": (.safe, "CocoaPods spec repos"),
        ]
        if path.hasPrefix(home), let (safety, note) = homeCaches[String(path.dropFirst(home.count))] {
            return .developer(safety, note, name: String(path.dropFirst(home.count + 1)))
        }

        // AI models
        if parent == home + "/.cache" {
            if let (safety, note) = aiCacheNames[name] { return .ai(safety, note) }
            return .developer(.review, "Command-line tool cache", name: ".cache/\(name)")
        }
        if path == home + "/.ollama/models" { return .ai(.review, "Ollama models — download again with ollama pull") }
        if path == home + "/.lmstudio/models" { return .ai(.review, "LM Studio models") }

        // Developer: project build folders (only in your own folders)
        if candidates && !isInsideToolFolder(path) {
            let artifact = "\(parentName)/\(name)"
            func sibling(_ file: String) -> Bool { fm.fileExists(atPath: parent + "/" + file) }
            switch name {
            case "node_modules" where sibling("package.json"):
                return .developer(.safe, "JavaScript dependencies — reinstall with npm install", name: artifact)
            case ".next" where sibling("package.json"), ".turbo" where sibling("package.json"),
                 ".parcel-cache" where sibling("package.json"), ".svelte-kit" where sibling("package.json"),
                 ".nuxt" where sibling("package.json"):
                return .developer(.safe, "Web framework build cache", name: artifact)
            case "target" where sibling("Cargo.toml"):
                return .developer(.safe, "Rust build output — rebuilt with cargo build", name: artifact)
            case ".build" where sibling("Package.swift"):
                return .developer(.safe, "Swift build output — rebuilt with swift build", name: artifact)
            case ".venv" where fm.fileExists(atPath: path + "/pyvenv.cfg"), "venv" where fm.fileExists(atPath: path + "/pyvenv.cfg"):
                return .developer(.review, "Python virtual environment — recreate it and pip install", name: artifact)
            case "Pods" where sibling("Podfile"):
                return .developer(.safe, "CocoaPods dependencies — reinstall with pod install", name: artifact)
            case "DerivedData" where fm.fileExists(atPath: path + "/info.plist") || fm.fileExists(atPath: path + "/Build"):
                return .developer(.safe, "Xcode build products", name: artifact)
            case "vendor" where sibling("composer.json"):
                return .developer(.safe, "PHP dependencies — reinstall with composer install", name: artifact)
            default:
                if name.hasPrefix("cmake-build-") { return .developer(.safe, "CMake build output", name: artifact) }
            }
        }

        // Apps
        if name.hasSuffix(".app") {
            if candidates && (parent == home + "/Downloads" || parent == home + "/Desktop") {
                return .installer(.review, "App left in \(parentName) — move it to Applications or delete it")
            }
            let appFolders = ["/Applications", home + "/Applications"]
            let grandparent = (parent as NSString).deletingLastPathComponent
            if appFolders.contains(parent) || appFolders.contains(grandparent) { return .app }
        }
        return nil
    }

    private func record(_ special: Special, url: URL, size: Int64, values rv: URLResourceValues) {
        let path = url.path
        let modified = rv.contentModificationDate
        func make(_ name: String, _ lastUsed: Date?, _ safety: Safety, _ note: String) -> Item {
            Item(path: path, name: name, size: size, lastUsed: lastUsed, modified: modified,
                 isDirectory: true, safety: safety, note: note)
        }
        switch special {
        case let .junk(safety, note, name):
            guard size > 0 else { return }
            result.junk.append(make(name ?? url.lastPathComponent, modified, safety, note))
        case let .developer(safety, note, name):
            guard size > 0 else { return }
            result.developer.append(make(name ?? url.lastPathComponent, modified, safety, note))
        case let .ai(safety, note):
            guard size > 0 else { return }
            result.aiModels.append(make(url.lastPathComponent, modified, safety, note))
        case let .installer(safety, note):
            result.installers.append(make(url.lastPathComponent, Self.spotlightLastUsed(path) ?? modified, safety, note))
        case .trash:
            if let contents = try? fm.contentsOfDirectory(atPath: path) {
                result.trashSize = size
                result.trashCount = contents.filter { $0 != ".DS_Store" }.count
            }
        case .app:
            let bundle = Bundle(url: url)
            let bundleID = bundle?.bundleIdentifier ?? ""
            let displayName = (url.lastPathComponent as NSString).deletingPathExtension
            installedAppNames.insert(normalized(displayName))
            if !bundleID.isEmpty { installedBundleIDs.insert(bundleID.lowercased()) }
            if bundleID.hasPrefix("com.apple.") || bundleID == ownBundleID { return }
            appBundleIDs[path] = bundleID
            let lastUsed = Self.spotlightLastUsed(path)
            let version = bundle?.infoDictionary?["CFBundleShortVersionString"] as? String
            let note = lastUsed == nil
                ? "No record of being opened"
                : (version.map { "Version \($0)" } ?? "Application")
            result.apps.append(make(displayName, lastUsed, .caution, note))
        }
    }

    /// "iPhone backup · Alex's iPhone · 3 Mar 2026" from the backup's Info.plist.
    private func iOSBackupName(_ path: String) -> String {
        guard let info = NSDictionary(contentsOfFile: path + "/Info.plist") as? [String: Any] else { return "iOS device backup" }
        let device = (info["Device Name"] as? String) ?? (info["Display Name"] as? String) ?? "iOS device"
        let date = (info["Last Backup Date"] as? Date).map { " · " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
        return "Backup of \(device)\(date)"
    }

    // MARK: - Apps: related data and leftovers

    private func sizeOf(_ path: String) -> Int64? {
        if let folder = result.folderSizes[path] { return folder }
        guard let rv = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isDirectoryKey]) else {
            return nil
        }
        if rv.isDirectory == true { return fm.fileExists(atPath: path) ? 0 : nil }
        return Int64(rv.totalFileAllocatedSize ?? 0)
    }

    /// Finds each app's caches, preferences, containers and support folders so the uninstaller
    /// can remove them together with the app.
    private func attachAppData() {
        for i in result.apps.indices {
            let app = result.apps[i]
            let bundleID = appBundleIDs[app.path] ?? ""
            var candidates = [
                lib + "/Application Support/\(app.name)",
                lib + "/Caches/\(app.name)",
                lib + "/Logs/\(app.name)",
            ]
            if !bundleID.isEmpty {
                candidates += [
                    lib + "/Application Support/\(bundleID)",
                    lib + "/Caches/\(bundleID)",
                    lib + "/Containers/\(bundleID)",
                    lib + "/HTTPStorages/\(bundleID)",
                    lib + "/WebKit/\(bundleID)",
                    lib + "/Application Scripts/\(bundleID)",
                    lib + "/Preferences/\(bundleID).plist",
                    lib + "/Saved Application State/\(bundleID).savedState",
                    lib + "/Logs/\(bundleID)",
                ]
            }
            var related: [String] = []
            var relatedSize: Int64 = 0
            for path in Set(candidates) {
                guard let size = sizeOf(path) else { continue }
                related.append(path)
                relatedSize += size
            }
            guard !related.isEmpty else { continue }
            let note = "App \(Fmt.bytes(app.size)) + \(Fmt.bytes(relatedSize)) of app data"
            result.apps[i] = Item(path: app.path, name: app.name, size: app.size + relatedSize, lastUsed: app.lastUsed,
                                  modified: app.modified, isDirectory: true, safety: .caution,
                                  note: app.lastUsed == nil ? note + " · no record of being opened" : note,
                                  related: related.sorted())
        }
    }

    /// Audio plug-ins count as installed software, so their vendors' support folders
    /// (e.g. iZotope) aren't mistaken for leftovers.
    private func registerPluginIfNeeded(_ path: String) {
        let pluginRoots = ["/Library/Audio/Plug-Ins/", lib + "/Audio/Plug-Ins/"]
        let ext = (path as NSString).pathExtension.lowercased()
        guard ["component", "vst", "vst3", "aaxplugin"].contains(ext),
              pluginRoots.contains(where: { path.hasPrefix($0) }) else { return }
        installedAppNames.insert(normalized(((path as NSString).lastPathComponent as NSString).deletingPathExtension))
        if let bundleID = Bundle(path: path)?.bundleIdentifier { installedBundleIDs.insert(bundleID.lowercased()) }
    }

    private func normalized(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func looksLikeBundleID(_ name: String) -> Bool {
        name.split(separator: ".").count >= 3 && !name.contains(" ")
    }

    private func isInstalled(bundleID: String) -> Bool {
        var parts = bundleID.lowercased().split(separator: ".").map(String.init)
        // Helpers and extensions use the parent app's ID plus a suffix, so try shorter prefixes too.
        while parts.count >= 2 {
            let candidate = parts.joined(separator: ".")
            if installedBundleIDs.contains(candidate)
                || NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate) != nil {
                return true
            }
            parts.removeLast()
        }
        return false
    }

    private func isInstalled(folderName: String) -> Bool {
        if looksLikeBundleID(folderName) { return isInstalled(bundleID: folderName) }
        let key = normalized(folderName)
        guard key.count >= 3 else { return true }
        let vendors = Set(installedBundleIDs.compactMap { id -> String? in
            let parts = id.split(separator: ".")
            return parts.count >= 2 ? normalized(String(parts[1])) : nil
        })
        if vendors.contains(key) { return true }
        return installedAppNames.contains { appName in
            appName.count >= 4 && (key.contains(appName) || appName.contains(key))
        }
    }

    /// Big app-data folders with no matching installed app.
    private func findLeftovers() {
        // Names macOS itself uses for app data; never offered as leftovers.
        let systemFolders: Set<String> = [
            "addressbook", "callhistorydb", "callhistorytransactions", "clouddocs", "crashreporter",
            "differentialprivacy", "fileprovider", "knowledge", "mobilesync", "syncservices", "dock",
            "icdd", "icloud", "appstore", "animoji", "networkserviceproxy", "coreparsec", "caches",
            "applepushservice", "spotlight", "wallpaper", "apple", "steam", "familycircle", "accounts",
        ]
        let supportDirs = [lib + "/Application Support", "/Library/Application Support"]
        let containers = lib + "/Containers"
        let installedDirs = Set(result.folderSizes.keys.filter { $0.hasSuffix(".app") }
            .map { ($0 as NSString).deletingLastPathComponent })

        for (path, size) in result.folderSizes {
            let parent = (path as NSString).deletingLastPathComponent
            let name = (path as NSString).lastPathComponent
            guard supportDirs.contains(parent) || parent == containers else { continue }
            if name.lowercased().hasPrefix("com.apple") || systemFolders.contains(normalized(name)) { continue }

            if parent == containers {
                guard looksLikeBundleID(name), size >= 5_000_000, !isInstalled(bundleID: name) else { continue }
                result.leftovers.append(Item(path: path, name: name, size: size, lastUsed: nil, modified: nil,
                                             isDirectory: true, safety: .review,
                                             note: "Data container for an app that isn't installed"))
            } else {
                // A folder that ships its own app inside (e.g. a patcher or updater) is not a leftover.
                let containsApp = installedDirs.contains { $0 == path || $0.hasPrefix(path + "/") }
                guard size >= 50_000_000, !containsApp, !isInstalled(folderName: name) else { continue }
                let systemWide = parent.hasPrefix("/Library")
                result.leftovers.append(Item(path: path, name: name, size: size, lastUsed: nil, modified: nil,
                                             isDirectory: true, safety: .caution,
                                             note: "No installed app found\(systemWide ? " · shared by all users, needs your password" : "") · could also be game saves or a background tool"))
            }
        }
    }

    // MARK: - Downloads

    /// Every top-level item in ~/Downloads, sorted into `DownloadKind` groups. Only real leftovers are
    /// marked Safe: exact repeat downloads, unfinished downloads, installers and archives that were
    /// already unzipped. Documents, photos, videos and music are always left for the user to review.
    private func findDownloads() {
        let folder = home + "/Downloads"
        let rootPath = root.path == "/" ? "" : root.path
        guard folder == root.path || folder.hasPrefix(rootPath + "/"),
              let urls = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles]) else { return }
        let names = Set(urls.map { $0.lastPathComponent.lowercased() })
        let dayAgo = Date().addingTimeInterval(-86_400)
        var items: [Item] = []
        var sameSize: [Int64: [Int]] = [:]

        for url in urls {
            if isCancelled { return }
            guard let rv = try? url.resourceValues(forKeys: keySet), rv.isSymbolicLink != true else { continue }
            var path = url.path
            if path.hasSuffix("/") { path.removeLast() }
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            let isFolder = rv.isDirectory == true
            let size = isFolder ? (result.folderSizes[path] ?? 0) : Int64(rv.totalFileAllocatedSize ?? rv.fileAllocatedSize ?? 0)
            let lastUsed = maxDate(maxDate(rv.contentAccessDate, rv.contentModificationDate), Self.spotlightLastUsed(path))

            var kind = DownloadKind.kind(forExtension: ext, isFolder: isFolder)
            var safety = Safety.review
            var note: String
            switch kind {
            case .unfinished:
                let stale = (rv.contentModificationDate ?? .distantPast) < dayAgo
                safety = stale ? .safe : .review
                note = stale ? "Unfinished download: the browser stopped before it finished" : "May still be downloading"
            case .installers:
                if ext == "app" {
                    note = "App left in Downloads: move it to Applications or delete it"
                } else {
                    safety = ext == "iso" ? .review : .safe
                    note = ext == "iso" ? "Disk image: delete if you no longer need it" : "Installer: not needed once the app is installed"
                }
            case .archives:
                let base = (name as NSString).deletingPathExtension.replacingOccurrences(of: ".tar", with: "")
                if names.contains(base.lowercased()) {
                    safety = .safe
                    note = "Already unzipped: the folder “\(base)” is next to it"
                } else {
                    note = "Archive: check whether you still need it"
                }
            default:
                note = isFolder ? "Folder" : kindDescription(ext)
            }
            if let used = lastUsed, used < Date().addingTimeInterval(-90 * 86_400) {
                note += " · not opened since \(used.formatted(.dateTime.month(.abbreviated).year()))"
            }
            if !isFolder, kind != .unfinished, let logical = rv.fileSize, logical > 0,
               size >= Int64(logical) / 2 {  // skip iCloud placeholders: reading them would download them
                sameSize[Int64(logical), default: []].append(items.count)
            }
            if isFolder && kind == .other { kind = .folders }
            items.append(Item(path: path, name: name, size: size, lastUsed: lastUsed, modified: rv.contentModificationDate,
                              isDirectory: isFolder, safety: safety, note: note, group: kind.rawValue))
        }

        // The same file downloaded more than once ("Statement.pdf", "Statement (1).pdf"): keep one, offer the rest.
        setPhase("Looking for repeat downloads…")
        for (_, indices) in sameSize where indices.count > 1 {
            if isCancelled { return }
            let byHash = Dictionary(grouping: indices) { fullHash(items[$0].path) ?? UUID().uuidString }
            for (_, copies) in byHash where copies.count > 1 {
                let ordered = copies.sorted {
                    let a = items[$0], b = items[$1]
                    if DownloadKind.looksLikeCopy(a.name) != DownloadKind.looksLikeCopy(b.name) { return !DownloadKind.looksLikeCopy(a.name) }
                    if a.name.count != b.name.count { return a.name.count < b.name.count }
                    return a.modifiedSort < b.modifiedSort
                }
                let keeper = items[ordered[0]].name
                for index in ordered.dropFirst() {
                    let old = items[index]
                    items[index] = Item(path: old.path, name: old.name, size: old.size, lastUsed: old.lastUsed, modified: old.modified,
                                        isDirectory: false, safety: .safe,
                                        note: "Downloaded twice: identical to “\(keeper)”, which is kept",
                                        group: DownloadKind.repeats.rawValue)
                }
            }
        }
        result.downloads = items.filter { $0.size > 0 || $0.group == DownloadKind.unfinished.rawValue }.sorted { $0.size > $1.size }
    }

    // MARK: - Last used

    private func refineLastUsed() {
        let threshold = Date().addingTimeInterval(-30 * 86_400)
        for i in result.files.indices {
            if isCancelled { return }
            let item = result.files[i]
            if let used = item.lastUsed, used > threshold { continue }
            if let spotlight = Self.spotlightLastUsed(item.path), spotlight > item.lastUsedSort {
                result.files[i].lastUsed = spotlight
            }
        }
        let refined = Dictionary(result.files.map { ($0.path, $0.lastUsed) }, uniquingKeysWith: { a, _ in a })
        for i in result.installers.indices where !result.installers[i].isDirectory {
            if let used = refined[result.installers[i].path] { result.installers[i].lastUsed = used }
        }
    }

    static func spotlightLastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    private func maxDate(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (a?, b?): return max(a, b)
        default: return a ?? b
        }
    }

    private func kindDescription(_ ext: String) -> String {
        switch ext {
        case "mp4", "mov", "m4v", "mkv", "avi", "webm": return "Video"
        case "wav", "aif", "aiff", "mp3", "m4a", "flac", "flp": return "Audio"
        case "jpg", "jpeg", "png", "heic", "tiff", "raw", "cr2", "arw", "psd": return "Image"
        case "zip", "rar", "7z", "tar", "gz", "tgz": return "Archive"
        case "dmg", "iso", "pkg", "mpkg", "xip": return "Installer / disk image"
        case "pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "pages", "key", "numbers": return "Document"
        case "vmdk", "vdi", "qcow2", "img": return "Virtual machine disk"
        case "": return "File"
        default: return ext.uppercased() + " file"
        }
    }

    // MARK: - Duplicates

    private func findDuplicates() {
        var bySize: [Int64: [Item]] = [:]
        for item in result.files {
            // Skip cloud placeholders and sparse files: reading them would download data or mislead.
            guard let logical = logicalSizes[item.path], logical >= Self.minCandidateSize,
                  item.size >= logical / 2 else { continue }
            bySize[logical, default: []].append(item)
        }
        let sizeGroups = bySize.filter { $0.value.count > 1 }

        var groups: [DuplicateGroup] = []
        var done = 0
        for (logical, items) in sizeGroups {
            if isCancelled { return }
            done += 1
            if done % 10 == 0 { setPhase("Looking for duplicate files… (\(done) of \(sizeGroups.count))") }

            let unique = removingHardLinks(items)
            guard unique.count > 1 else { continue }
            let byStart = Dictionary(grouping: unique) { partialHash($0.path, size: logical) ?? UUID().uuidString }
            for (_, sameStart) in byStart where sameStart.count > 1 {
                let byContent = Dictionary(grouping: sameStart) { fullHash($0.path) ?? UUID().uuidString }
                for (hash, copies) in byContent where copies.count > 1 {
                    groups.append(DuplicateGroup(id: hash, fileSize: copies[0].size, items: orderedForKeeping(copies)))
                }
            }
        }
        result.duplicates = groups.sorted { $0.wasted > $1.wasted }
    }

    /// The first item is the suggested copy to keep: prefer files outside Downloads/Desktop, then the oldest.
    private func orderedForKeeping(_ items: [Item]) -> [Item] {
        func isTransient(_ item: Item) -> Bool {
            item.path.hasPrefix(home + "/Downloads/") || item.path.hasPrefix(home + "/Desktop/")
        }
        return items.sorted {
            if isTransient($0) != isTransient($1) { return !isTransient($0) }
            return $0.modifiedSort < $1.modifiedSort
        }
    }

    private func removingHardLinks(_ items: [Item]) -> [Item] {
        var seen = Set<String>()
        return items.filter { item in
            var st = stat()
            guard lstat(item.path, &st) == 0 else { return false }
            return seen.insert("\(st.st_dev):\(st.st_ino)").inserted
        }
    }

    private func partialHash(_ path: String, size: Int64) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let chunk = 65_536
        var hasher = SHA256()
        do {
            if let head = try handle.read(upToCount: chunk) { hasher.update(data: head) }
            if size > Int64(chunk * 2) {
                try handle.seek(toOffset: UInt64(size) - UInt64(chunk))
                if let tail = try handle.read(upToCount: chunk) { hasher.update(data: tail) }
            }
        } catch { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func fullHash(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if isCancelled { return nil }
            let more: Bool = autoreleasepool {
                guard let data = try? handle.read(upToCount: 4 * 1_048_576), !data.isEmpty else { return false }
                hasher.update(data: data)
                return true
            }
            if !more { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
