import Foundation

struct TrashEntry: Identifiable, Hashable {
    let path: String
    let name: String
    let size: Int64
    let trashedDate: Date?
    /// Where the item was before it was trashed, when macOS recorded it.
    let originalPath: String?
    var id: String { path }
}

/// Reads the contents of the user's Trash, including the "Put Back" locations Finder stores in
/// the Trash's .DS_Store file. Reading the Trash requires Full Disk Access.
enum TrashReader {
    static var trashPath: String { NSHomeDirectory() + "/.Trash" }

    /// nil when the Trash can't be read.
    static func load() -> [TrashEntry]? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: trashPath) else { return nil }
        let origins = putBackLocations()
        return names
            .filter { $0 != ".DS_Store" && $0 != ".localized" }
            .map { name in
                let path = trashPath + "/" + name
                let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.addedToDirectoryDateKey])
                return TrashEntry(path: path, name: name, size: allocatedSize(of: path),
                                  trashedDate: values?.addedToDirectoryDate, originalPath: origins[name])
            }
            .sorted { $0.size > $1.size }
    }

    /// Moves an item out of the Trash, back to where it came from when known. If the original folder
    /// is gone, or no location was recorded, it goes to ~/Downloads/Restored from Trash.
    /// An existing file is never overwritten: the restored copy gets a "(restored)" suffix.
    /// Returns where the item ended up.
    static func putBack(_ entry: TrashEntry) throws -> String {
        let fm = FileManager.default
        var destination: String
        var isDirectory: ObjCBool = false
        if let original = entry.originalPath,
           fm.fileExists(atPath: (original as NSString).deletingLastPathComponent, isDirectory: &isDirectory),
           isDirectory.boolValue {
            destination = original
        } else {
            let folder = NSHomeDirectory() + "/Downloads/Restored from Trash"
            try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
            destination = folder + "/" + entry.name
        }
        if fm.fileExists(atPath: destination) {
            let ns = destination as NSString
            let ext = ns.pathExtension
            let stem = (ns.lastPathComponent as NSString).deletingPathExtension
            var n = 1
            repeat {
                let suffix = n == 1 ? " (restored)" : " (restored \(n))"
                destination = ns.deletingLastPathComponent + "/" + stem + suffix + (ext.isEmpty ? "" : "." + ext)
                n += 1
            } while fm.fileExists(atPath: destination)
        }
        try fm.moveItem(atPath: entry.path, toPath: destination)
        return destination
    }

    /// Permanently erases one item from the Trash. Only paths directly inside the Trash are accepted.
    static func deletePermanently(_ entry: TrashEntry) throws {
        guard (entry.path as NSString).deletingLastPathComponent == trashPath else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.removeItem(atPath: entry.path)
    }

    static func allocatedSize(of path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard values.isDirectory == true else { return Int64(values.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [])
        while let child = enumerator?.nextObject() as? URL {
            total += Int64((try? child.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: - .DS_Store "put back" records

    /// Maps item names in the Trash to their original full paths, from Finder's `ptbL`
    /// (original folder) and `ptbN` (original name) records.
    static func putBackLocations() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: trashPath + "/.DS_Store"),
              let records = DSStore(data: data)?.records() else { return [:] }
        var folders: [String: String] = [:]
        var names: [String: String] = [:]
        for record in records {
            if record.code == "ptbL", case let .string(folder) = record.value { folders[record.filename] = folder }
            if record.code == "ptbN", case let .string(name) = record.value { names[record.filename] = name }
        }
        var result: [String: String] = [:]
        for (item, folder) in folders {
            // ptbL is relative to the volume root, e.g. "Users/name/Downloads/".
            let base = folder.hasPrefix("/") ? folder : "/" + folder
            let original = names[item] ?? item
            result[item] = (base.hasSuffix("/") ? base : base + "/") + original
        }
        return result
    }
}

/// Minimal reader for the .DS_Store format (a B-tree stored in a "buddy allocator" file).
struct DSStore {
    enum Value { case string(String), other }
    struct Record { let filename: String; let code: String; let value: Value }

    private let data: Data
    private var blockAddresses: [UInt32] = []
    private var rootBlock: UInt32 = 0

    init?(data: Data) {
        self.data = data
        guard data.count > 36, readU32(4) == 0x4275_6431 /* "Bud1" */ else { return nil }
        let infoOffset = Int(readU32(8))
        var pos = infoOffset + 4
        let blockCount = Int(readU32(pos))
        pos += 8
        for i in 0..<blockCount { blockAddresses.append(readU32(pos + i * 4)) }
        pos += ((blockCount + 255) / 256) * 256 * 4
        let directoryCount = Int(readU32(pos))
        pos += 4
        for _ in 0..<directoryCount {
            let length = Int(data[data.startIndex + pos])
            let name = String(decoding: data[(data.startIndex + pos + 1)..<(data.startIndex + pos + 1 + length)], as: UTF8.self)
            pos += 1 + length
            let block = readU32(pos)
            pos += 4
            if name == "DSDB", let offset = blockOffset(block) { rootBlock = readU32(offset) }
        }
        guard rootBlock != 0 || !blockAddresses.isEmpty else { return nil }
    }

    func records() -> [Record] {
        var out: [Record] = []
        var visited = Set<UInt32>()
        readNode(rootBlock, into: &out, visited: &visited)
        return out
    }

    private func readNode(_ block: UInt32, into out: inout [Record], visited: inout Set<UInt32>) {
        guard visited.insert(block).inserted, let start = blockOffset(block) else { return }
        var pos = start
        let rightChild = readU32(pos)
        let count = Int(readU32(pos + 4))
        pos += 8
        for _ in 0..<count {
            if rightChild != 0 {
                readNode(readU32(pos), into: &out, visited: &visited)
                pos += 4
            }
            guard let (record, next) = readRecord(at: pos) else { return }
            out.append(record)
            pos = next
        }
        if rightChild != 0 { readNode(rightChild, into: &out, visited: &visited) }
    }

    private func readRecord(at start: Int) -> (Record, Int)? {
        var pos = start
        guard let (filename, afterName) = readUTF16(at: pos) else { return nil }
        pos = afterName
        let code = readFourCC(pos)
        let type = readFourCC(pos + 4)
        pos += 8
        var value = Value.other
        switch type {
        case "bool": pos += 1
        case "long", "shor", "type": pos += 4
        case "comp", "dutc": pos += 8
        case "blob": pos += 4 + Int(readU32(pos))
        case "ustr":
            guard let (string, next) = readUTF16(at: pos) else { return nil }
            value = .string(string)
            pos = next
        default: return nil
        }
        return (Record(filename: filename, code: code, value: value), pos)
    }

    private func blockOffset(_ index: UInt32) -> Int? {
        guard Int(index) < blockAddresses.count else { return nil }
        let address = blockAddresses[Int(index)]
        let offset = Int(address & ~0x1F) + 4
        return offset < data.count ? offset : nil
    }

    private func readU32(_ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let i = data.startIndex + offset
        return UInt32(data[i]) << 24 | UInt32(data[i + 1]) << 16 | UInt32(data[i + 2]) << 8 | UInt32(data[i + 3])
    }

    private func readFourCC(_ offset: Int) -> String {
        guard offset + 4 <= data.count else { return "" }
        return String(decoding: data[(data.startIndex + offset)..<(data.startIndex + offset + 4)], as: UTF8.self)
    }

    private func readUTF16(at offset: Int) -> (String, Int)? {
        let length = Int(readU32(offset))
        let start = offset + 4
        let end = start + length * 2
        guard length < 4096, end <= data.count else { return nil }
        var units: [UInt16] = []
        units.reserveCapacity(length)
        var i = data.startIndex + start
        while i < data.startIndex + end {
            units.append(UInt16(data[i]) << 8 | UInt16(data[i + 1]))
            i += 2
        }
        return (String(decoding: units, as: UTF16.self), end)
    }
}
