import AppKit

/// A launch agent or daemon: the mechanism apps use to keep helpers running in the background
/// or start them at login. Turning one off with launchctl stops it now *and* keeps it from
/// starting again, which is what makes cleaning up background processes permanent.
struct LaunchItem: Identifiable, Equatable {
    enum Scope: String {
        case userAgent = "Just you"
        case allUsersAgent = "All users"
        case systemDaemon = "System"
    }

    let label: String
    let plistPath: String
    let scope: Scope
    let program: String?
    let isEnabled: Bool
    let isRunning: Bool
    var id: String { plistPath }

    /// The program it starts no longer exists, usually because its app was deleted.
    var isLeftover: Bool { program.map { !FileManager.default.fileExists(atPath: $0) } ?? false }

    /// The app the program belongs to, for showing its icon and name.
    var appPath: String? {
        guard let program, let range = program.range(of: ".app/") else { return nil }
        return String(program[..<range.lowerBound]) + ".app"
    }

    var displayName: String {
        if let appPath { return ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension }
        return label
    }
}

enum BackgroundItems {
    private static var uid: uid_t { getuid() }

    static func load() -> [LaunchItem] {
        let home = NSHomeDirectory()
        let folders: [(String, LaunchItem.Scope)] = [
            (home + "/Library/LaunchAgents", .userAgent),
            ("/Library/LaunchAgents", .allUsersAgent),
            ("/Library/LaunchDaemons", .systemDaemon),
        ]
        let disabledUser = disabledLabels(domain: "gui/\(uid)")
        let disabledSystem = disabledLabels(domain: "system")
        let loadedUser = loadedUserLabels()

        var items: [LaunchItem] = []
        for (folder, scope) in folders {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            for name in names where name.hasSuffix(".plist") {
                let path = folder + "/" + name
                guard let plist = NSDictionary(contentsOfFile: path) as? [String: Any],
                      let label = plist["Label"] as? String,
                      !label.hasPrefix("com.apple.") else { continue }
                let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
                let disabledByPlist = plist["Disabled"] as? Bool ?? false
                let enabled: Bool
                let running: Bool
                if scope == .systemDaemon {
                    enabled = !(disabledSystem[label] ?? disabledByPlist)
                    running = enabled && isLoaded("system/\(label)")
                } else {
                    enabled = !(disabledUser[label] ?? disabledByPlist)
                    running = loadedUser.contains(label)
                }
                items.append(LaunchItem(label: label, plistPath: path, scope: scope, program: program,
                                        isEnabled: enabled, isRunning: running))
            }
        }
        return items.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Turns an item off (stop it and keep it from starting) or back on. System daemons need
    /// administrator rights, so macOS shows its own password prompt for those.
    static func setEnabled(_ item: LaunchItem, _ enabled: Bool) -> Bool {
        if item.scope == .systemDaemon {
            let target = "system/\(item.label)"
            let command = enabled
                ? "launchctl enable \(target); launchctl bootstrap system \(shellQuote(item.plistPath)) 2>/dev/null; true"
                : "launchctl bootout \(target) 2>/dev/null; launchctl disable \(target)"
            return runAsAdmin(command)
        }
        let target = "gui/\(uid)/\(item.label)"
        if enabled {
            let ok = launchctl(["enable", target])
            _ = launchctl(["bootstrap", "gui/\(uid)", item.plistPath])
            return ok
        }
        _ = launchctl(["bootout", target])
        return launchctl(["disable", target])
    }

    // MARK: - launchctl

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Bool {
        run("/bin/launchctl", arguments).status == 0
    }

    private static func isLoaded(_ target: String) -> Bool {
        run("/bin/launchctl", ["print", target]).status == 0
    }

    private static func loadedUserLabels() -> Set<String> {
        let output = run("/bin/launchctl", ["list"]).output
        return Set(output.split(separator: "\n").dropFirst().compactMap { line in
            line.split(separator: "\t").last.map(String.init)
        })
    }

    /// Parses `launchctl print-disabled`, whose lines look like `"com.example.agent" => disabled`.
    private static func disabledLabels(domain: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for line in run("/bin/launchctl", ["print-disabled", domain]).output.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let state = parts[1].trimmingCharacters(in: .whitespaces)
            result[label] = state.hasPrefix("disabled") || state.hasPrefix("true")
        }
        return result
    }

    private static func runAsAdmin(_ command: String) -> Bool {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"]).status == 0
    }

    private static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
