import Foundation

/// Detects whether macOS has granted DiskSweep Full Disk Access.
///
/// macOS has no API that answers this directly, so we try to read files that only Full Disk Access
/// unlocks. The user's own TCC database is the reliable signal: it belongs to the user (so normal
/// file permissions allow reading it) but macOS privacy protection blocks it with EPERM unless the
/// app has Full Disk Access. Note: /Library/Application Support/com.apple.TCC is readable
/// without access on recent macOS, so it must not be used as a test.
enum FullDiskAccess {
    static func isGranted() -> Bool {
        // README screenshots run against a made-up home folder (DISKSWEEP_DEMO_SCREENSHOTS, snapshot mode only).
        if DebugSnapshot.directory != nil, ProcessInfo.processInfo.environment["DISKSWEEP_DEMO_SCREENSHOTS"] != nil { return true }
        let home = NSHomeDirectory()
        let userTCC = home + "/Library/Application Support/com.apple.TCC/TCC.db"
        if FileManager.default.fileExists(atPath: userTCC) {
            let fd = open(userTCC, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return true
            }
            return false
        }
        // Fallback for the rare Mac without a user TCC database: these folders are also protected.
        let protectedFolders = [
            home + "/Library/Safari",
            home + "/Library/Messages",
            home + "/Library/Mail",
            home + "/Library/Containers/com.apple.Safari",
        ]
        return protectedFolders.contains { (try? FileManager.default.contentsOfDirectory(atPath: $0)) != nil }
    }
}
