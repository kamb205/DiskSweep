import SwiftUI

/// The kinds of things that pile up in ~/Downloads, in the order the Downloads page shows them.
enum DownloadKind: String, CaseIterable {
    case repeats = "Downloaded Twice"
    case unfinished = "Unfinished Downloads"
    case installers = "Installers & Apps"
    case archives = "Archives"
    case videos = "Videos"
    case audio = "Audio & Projects"
    case images = "Images"
    case documents = "Documents"
    case folders = "Folders"
    case other = "Other"

    var symbol: String {
        switch self {
        case .repeats: "doc.on.doc"
        case .unfinished: "arrow.down.circle.dotted"
        case .installers: "shippingbox"
        case .archives: "doc.zipper"
        case .videos: "film"
        case .audio: "waveform"
        case .images: "photo"
        case .documents: "doc.text"
        case .folders: "folder"
        case .other: "questionmark.square.dashed"
        }
    }

    static func kind(forExtension ext: String, isFolder: Bool) -> DownloadKind {
        switch ext {
        case "crdownload", "download", "part", "partial", "opdownload": return .unfinished
        case "dmg", "pkg", "mpkg", "xip", "iso", "app": return .installers
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz": return isFolder ? .folders : .archives
        case "mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv": return .videos
        case "jpg", "jpeg", "png", "heic", "gif", "webp", "tiff", "tif", "bmp", "svg", "psd", "raw", "cr2", "arw", "dng": return .images
        case "pdf", "doc", "docx", "pages", "xls", "xlsx", "csv", "numbers", "ppt", "pptx", "key", "txt", "rtf",
             "md", "odt", "ods", "epub", "acsm", "html", "json", "xml": return .documents
        default:
            if MusicTagger.isMusicFile(extension: ext) { return .audio }
            return isFolder ? .folders : .other
        }
    }

    /// "Statement (1).pdf", "Statement copy.pdf", "Statement-2.pdf": names browsers and Finder give repeat copies.
    static func looksLikeCopy(_ name: String) -> Bool {
        let base = (name as NSString).deletingPathExtension
        return base.range(of: #"( \(\d+\)| copy( \d+)?|-\d)$"#, options: .regularExpression) != nil
    }
}

struct DownloadsView: View {
    var body: some View {
        GroupedItemsView(
            category: .downloads,
            groups: DownloadKind.allCases.map { ($0.rawValue, $0.symbol) },
            unit: "items",
            emptyTitle: "Your Downloads folder is empty", emptySymbol: "arrow.down.circle",
            emptyText: "Nothing to tidy up here.")
    }
}
