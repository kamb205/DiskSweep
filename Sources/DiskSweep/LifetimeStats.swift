import Foundation

/// All-time totals of space DiskSweep has freed, kept between launches in UserDefaults.
///
/// Space only counts once it has really been freed. Moving something to the Trash makes it
/// *pending*; when it later leaves the Trash, DiskSweep checks where it went:
/// - back at its original location (Put Back in DiskSweep or Finder) → not counted;
/// - gone (Trash emptied or item erased) → counted.
/// "Back at its original location" means the same file system object (device + inode), so a
/// cache folder an app recreated at the same path doesn't look like a put-back item.
struct LifetimeStats: Equatable {
    struct Pending: Equatable {
        var bytes: Int64
        var originalPath: String
        var device: Int64
        var inode: Int64
    }

    var bytes: Int64 = 0
    var items = 0
    var since: Date?
    /// Path inside the Trash → item waiting to be erased.
    var pending: [String: Pending] = [:]

    var pendingBytes: Int64 { pending.values.reduce(0) { $0 + $1.bytes } }

    // v2: earlier versions counted space as soon as it was moved to the Trash.
    private static let key = "lifetimeStats.v2"

    static func load() -> LifetimeStats {
        guard let dict = UserDefaults.standard.dictionary(forKey: key) else { return LifetimeStats() }
        var stats = LifetimeStats()
        stats.bytes = (dict["bytes"] as? NSNumber)?.int64Value ?? 0
        stats.items = (dict["items"] as? NSNumber)?.intValue ?? 0
        stats.since = dict["since"] as? Date
        for (path, value) in (dict["pending"] as? [String: [String: Any]]) ?? [:] {
            guard let original = value["original"] as? String else { continue }
            stats.pending[path] = Pending(bytes: (value["bytes"] as? NSNumber)?.int64Value ?? 0,
                                          originalPath: original,
                                          device: (value["dev"] as? NSNumber)?.int64Value ?? 0,
                                          inode: (value["ino"] as? NSNumber)?.int64Value ?? 0)
        }
        return stats
    }

    func save() {
        var dict: [String: Any] = [
            "bytes": NSNumber(value: bytes),
            "items": NSNumber(value: items),
            "pending": pending.mapValues { p -> [String: Any] in
                ["bytes": NSNumber(value: p.bytes), "original": p.originalPath,
                 "dev": NSNumber(value: p.device), "ino": NSNumber(value: p.inode)]
            },
        ]
        if let since { dict["since"] = since }
        UserDefaults.standard.set(dict, forKey: Self.key)
    }

    /// Remembers an item DiskSweep just moved to the Trash. Nothing is counted yet.
    mutating func recordTrashed(bytes amount: Int64, trashPath: String, originalPath: String) {
        let path = Self.normalize(trashPath)
        guard let id = Self.fileID(path) else { return }
        pending[path] = Pending(bytes: amount, originalPath: originalPath, device: id.device, inode: id.inode)
    }

    /// DiskSweep's own Put Back: never counted, wherever the item is restored to. Called *before*
    /// the item moves, so a refresh in between can't mistake it for erased. Returns the record so
    /// it can be restored with `undoPutBack` if putting back fails.
    mutating func recordPutBack(trashPath: String) -> Pending? {
        pending.removeValue(forKey: Self.normalize(trashPath))
    }

    mutating func undoPutBack(trashPath: String, _ record: Pending) {
        pending[Self.normalize(trashPath)] = record
    }

    /// Settles pending items that have left the Trash: counts erased ones, drops restored ones.
    mutating func settle() {
        for (trashPath, item) in pending {
            if FileManager.default.fileExists(atPath: trashPath) { continue } // still in the Trash
            pending[trashPath] = nil
            if let id = Self.fileID(item.originalPath), id.device == item.device, id.inode == item.inode {
                continue // put back where it came from
            }
            bytes += item.bytes
            items += 1
            if since == nil { since = Date() }
        }
    }

    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func fileID(_ path: String) -> (device: Int64, inode: Int64)? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return (Int64(st.st_dev), Int64(st.st_ino))
    }
}
