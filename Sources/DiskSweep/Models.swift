import Foundation
import SwiftUI

enum Category: String, CaseIterable, Identifiable, Hashable {
    case dashboard, memory, background, speedSettings, systemJunk, developer, aiModels, installers, downloads, trash
    case large, old, duplicates, spaceLens
    case music
    case uninstaller, leftovers

    static let sections: [(title: String, categories: [Category])] = [
        ("Smart Care", [.dashboard]),
        ("Speed", [.memory, .background, .speedSettings]),
        ("Cleanup", [.systemJunk, .developer, .aiModels, .installers, .downloads, .trash]),
        ("Files", [.large, .old, .duplicates, .spaceLens]),
        ("Music", [.music]),
        ("Applications", [.uninstaller, .leftovers]),
    ]

    /// Categories that list items you can tick and move to the Trash.
    static let itemCategories: [Category] = [
        .systemJunk, .developer, .aiModels, .installers, .downloads, .large, .old, .duplicates, .music, .uninstaller, .leftovers,
    ]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Smart Care"
        case .memory: "Memory"
        case .background: "Background Items"
        case .speedSettings: "Speed Settings"
        case .systemJunk: "System Junk"
        case .developer: "Developer Junk"
        case .aiModels: "AI Models"
        case .installers: "Installers"
        case .downloads: "Downloads"
        case .trash: "Trash Bins"
        case .large: "Large Files"
        case .old: "Old Files"
        case .duplicates: "Duplicates"
        case .spaceLens: "Space Lens"
        case .music: "Music & Stems"
        case .uninstaller: "Uninstaller"
        case .leftovers: "App Leftovers"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "sparkles"
        case .memory: "memorychip"
        case .background: "gearshape.2"
        case .speedSettings: "speedometer"
        case .systemJunk: "archivebox"
        case .developer: "hammer"
        case .aiModels: "brain"
        case .installers: "shippingbox"
        case .downloads: "arrow.down.circle"
        case .trash: "trash"
        case .large: "arrow.up.doc"
        case .old: "clock.arrow.circlepath"
        case .duplicates: "doc.on.doc"
        case .spaceLens: "chart.pie"
        case .music: "music.note.list"
        case .uninstaller: "square.grid.2x2"
        case .leftovers: "folder.badge.questionmark"
        }
    }

    var blurb: String {
        switch self {
        case .memory: "What's using your Mac's memory right now. Quitting the apps at the top of the list is the most effective way to speed up a Mac that's running slowly."
        case .background: "Helpers that apps leave running in the background or start at login. Switching one off stops it now and keeps it from starting again. Apple's own system items are never shown."
        case .speedSettings: "Settings in macOS and Chrome that make a real difference on a slow Mac. DiskSweep only reads them. Each tip opens the right place so you can switch it yourself, and the ticks update when you come back."
        case .dashboard: "A summary of everything DiskSweep found. Start with the recommended items: they're safe to remove and macOS or your apps rebuild them as needed."
        case .systemJunk: "App caches and log files. Apps rebuild caches automatically, so these are usually safe to remove. Quit the app first for best results."
        case .developer: "Package-manager caches (npm, pip, Homebrew, Cargo…), Xcode data and project build folders like node_modules, target and .venv. All of them can be downloaded or rebuilt."
        case .aiModels: "Downloaded AI models and caches from tools like Ollama, Hugging Face, LM Studio and PyTorch. They're often several GB each and can be downloaded again."
        case .installers: "Disk images, installer packages and loose apps in Downloads or Desktop that are rarely needed after installing."
        case .downloads: "Everything in your Downloads folder, sorted by kind. Only true leftovers are marked Safe: files you downloaded twice, unfinished downloads, installers and zips you already unzipped. Documents, photos and music are never ticked for you, so look through them yourself."
        case .trash: "Items you've already moved to the Trash still take up space until the Trash is emptied."
        case .large: "The biggest files in your user folders. Review them before deleting, because they may be documents or media you want to keep."
        case .old: "Files you haven't opened in a long time, based on file access dates and Spotlight's record of when you last used them."
        case .duplicates: "Files with byte-for-byte identical contents. \"Select Extra Copies\" keeps one copy of each and selects the rest."
        case .spaceLens: "Browse your disk by folder size. Click a slice of the circle or a folder in the list to look inside it."
        case .music: "Your audio and DAW project files, grouped by what their names say: masters, unmastered bounces, vocals, bass, drums, samples, stems and more. Keep a whole group, or tick only the files you want to remove."
        case .uninstaller: "Installed apps with their size and when you last opened them. Removing an app also removes its caches, preferences and data. Apple's built-in apps are never listed."
        case .leftovers: "Large app-data folders that don't match any installed app, usually left behind by apps you deleted. Check each one: game saves and background tools can look like leftovers too."
        }
    }
}

enum Safety: Int, Comparable, Hashable, Codable {
    case safe, review, caution

    static func < (lhs: Safety, rhs: Safety) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .safe: "Safe"
        case .review: "Review"
        case .caution: "Careful"
        }
    }

    var color: Color {
        switch self {
        case .safe: .green
        case .review: .orange
        case .caution: .red
        }
    }
}

struct Item: Identifiable, Hashable, Codable {
    let path: String
    let name: String
    let size: Int64
    var lastUsed: Date?
    let modified: Date?
    let isDirectory: Bool
    let safety: Safety
    let note: String
    /// Extra paths removed together with this item (an app's caches, preferences and data).
    var related: [String] = []
    /// Sub-group within a page, e.g. "Bass & 808s" on the Music page.
    var group: String? = nil

    var id: String { path }
    var lastUsedSort: Date { lastUsed ?? .distantPast }
    var modifiedSort: Date { modified ?? .distantPast }
    var safetyRank: Int { safety.rawValue }
    var parentPath: String { (path as NSString).deletingLastPathComponent }
}

struct DuplicateGroup: Identifiable, Codable {
    let id: String
    let fileSize: Int64
    var items: [Item]

    var wasted: Int64 { fileSize * Int64(max(items.count - 1, 0)) }
}

struct ScanResult: Codable {
    var root: String
    var files: [Item] = []
    var junk: [Item] = []
    var developer: [Item] = []
    var aiModels: [Item] = []
    var installers: [Item] = []
    var apps: [Item] = []
    var leftovers: [Item] = []
    var music: [Item] = []
    /// Optional so results cached by older versions still load.
    var downloads: [Item]? = nil
    var duplicates: [DuplicateGroup] = []
    /// nil when the Trash couldn't be read (needs Full Disk Access).
    var trashSize: Int64?
    var trashCount = 0
    var folderSizes: [String: Int64] = [:]
    var deniedCount = 0
    var deniedSamples: [String] = []
    var scannedFiles = 0
    var scannedBytes: Int64 = 0
    var duration: TimeInterval = 0
}

enum Fmt {
    static func items(_ count: Int) -> String { "\(count) item\(count == 1 ? "" : "s")" }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private static let minimumMeaningfulDate = Date(timeIntervalSince1970: 946_684_800) // 2000-01-01

    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    static func relative(_ date: Date?) -> String {
        guard let date, date > minimumMeaningfulDate else { return "Unknown" }
        if Date().timeIntervalSince(date) < 86_400 { return "Today" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    static func path(_ p: String) -> String {
        let home = NSHomeDirectory()
        if p == home { return "~" }
        if p.hasPrefix(home + "/") { return "~" + p.dropFirst(home.count) }
        return p
    }
}

/// Saves the latest scan so DiskSweep reopens to your results, e.g. after installing an update.
enum ScanCache {
    private static var url: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DiskSweep", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("last-scan.plist")
    }

    static func save(_ result: ScanResult) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(result) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> ScanResult? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(ScanResult.self, from: data)
    }
}
