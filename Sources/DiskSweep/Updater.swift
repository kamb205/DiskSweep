import AppKit

/// Picks up newer builds published by build.sh and installs them in place.
///
/// build.sh writes `DiskSweep-update.zip` and `update-build.txt` to the folder named by the
/// DSUpdateFolder key in Info.plist. When that build number is newer than this app's
/// CFBundleVersion, the app offers "Restart to update": a small helper script waits for the app
/// to quit, swaps in the new version at the same location, and opens it again.
enum Updater {
    static var currentBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0" }

    private static var folder: String? { Bundle.main.infoDictionary?["DSUpdateFolder"] as? String }

    /// The newer build number waiting to be installed, if any.
    static func availableBuild() -> String? {
        guard let folder,
              let text = try? String(contentsOfFile: folder + "/update-build.txt", encoding: .utf8),
              FileManager.default.fileExists(atPath: folder + "/DiskSweep-update.zip") else { return nil }
        let build = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Build numbers are timestamps (yyyyMMddHHmmss), so they compare as plain numbers.
        guard let new = Int(build), let current = Int(currentBuild), new > current else { return nil }
        return build
    }

    /// Quits the app and installs the waiting update. Returns false if there's nothing to install.
    @MainActor
    static func installAndRelaunch() -> Bool {
        guard let folder, availableBuild() != nil else { return false }
        let zip = folder + "/DiskSweep-update.zip"
        let destination = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        # Wait for DiskSweep to quit, then swap in the new version and reopen it.
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        TMP=$(mktemp -d)
        if ditto -x -k "\(zip)" "$TMP" && [ -d "$TMP/DiskSweep.app" ]; then
            rm -rf "\(destination).previous"
            mv "\(destination)" "\(destination).previous"
            if mv "$TMP/DiskSweep.app" "\(destination)"; then
                rm -rf "\(destination).previous"
            else
                mv "\(destination).previous" "\(destination)"
            fi
        fi
        rm -rf "$TMP"
        open "\(destination)"
        """
        let scriptPath = NSTemporaryDirectory() + "disksweep-update.sh"
        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptPath]
            try process.run()
        } catch {
            return false
        }
        NSApp.terminate(nil)
        return true
    }
}
