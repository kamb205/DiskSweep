import Foundation

/// DiskSweep's own machine-learning model: it reads a folder's or file's path (names, extensions,
/// where it sits, how big it is) and predicts what kind of data it is, with a confidence and the
/// words that drove the decision. It's a softmax (multinomial logistic regression) classifier
/// trained by `Scripts/train_folder_model.swift`; the learned weights are in `FolderModelWeights.swift`.
/// Runs entirely on the Mac. This file must stay self-contained: the trainer compiles it too.
enum FolderModel {
    struct Prediction {
        let kind: FolderKind
        let confidence: Double
        /// Words from the path that pushed the model towards this answer, strongest first.
        let reasons: [String]
    }

    // MARK: Features

    /// Turns a path into the features the model reads. The trainer uses the same function, so
    /// training and the app always agree.
    static func features(path rawPath: String, isDirectory: Bool, size: Int64, home: String = NSHomeDirectory()) -> [String] {
        var path = rawPath
        if path == home || path.hasPrefix(home + "/") {
            path = "~" + path.dropFirst(home.count)
        } else if path.hasPrefix("/Users/") {
            // Another user's home: drop their name so names never become features.
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            path = "~/" + parts.dropFirst(2).joined(separator: "/")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var out = Set<String>()
        out.insert(isDirectory ? "@dir" : "@file")

        let sizeBucket: String
        switch size {
        case 50_000_000_000...: sizeBucket = "xxl"
        case 10_000_000_000...: sizeBucket = "xl"
        case 1_000_000_000...: sizeBucket = "l"
        case 100_000_000...: sizeBucket = "m"
        default: sizeBucket = "s"
        }
        out.insert("@size:" + sizeBucket)
        out.insert("@depth:\(min(components.count, 8))")

        if let first = components.first {
            switch first {
            case "~":
                out.insert("@home")
                if components.count > 1, components[1] == "Library" {
                    out.insert("@lib")
                    if components.count > 2 { out.insert("@lib:" + squash(components[2])) }
                }
            case "Library": out.insert("@syslib")
            case "Applications": out.insert("@apps")
            case "System", "private", "usr", "bin", "sbin", "cores": out.insert("@sys")
            case "opt": out.insert("@opt")
            case "Volumes": out.insert("@volumes")
            default: break
            }
        }
        if components.dropFirst().contains(where: { $0.hasPrefix(".") }) { out.insert("@hidden") }
        if components.contains(where: { $0.hasSuffix(".app") }) { out.insert("@inapp") }

        let tail = Array(components.suffix(5))
        for (index, component) in tail.enumerated() {
            let isLast = index == tail.count - 1
            let ext = (component as NSString).pathExtension.lowercased()
            if !ext.isEmpty, ext.count <= 12, ext.allSatisfy({ $0.isLetter || $0.isNumber }) {
                out.insert((isLast ? "ext:" : "pext:") + ext)
            }
            for word in words(component) {
                out.insert("w:" + word)
                if isLast { out.insert("last:" + word) }
                if index >= tail.count - 2, word.count >= 6 {
                    let chars = Array(word)
                    for start in 0...(chars.count - 4) { out.insert("g:" + String(chars[start..<start + 4])) }
                }
            }
        }
        return Array(out)
    }

    private static func squash(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Splits "DerivedData", "node_modules", "com.apple.Safari" or "Photos Library 2" into lowercase words.
    static func words(_ component: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for ch in component {
            if ch.isLetter || ch.isNumber {
                if let p = previous, !current.isEmpty,
                   (p.isLowercase && ch.isUppercase) || (p.isLetter && ch.isNumber) || (p.isNumber && ch.isLetter) {
                    words.append(current)
                    current = ""
                }
                current.append(ch)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
            previous = ch
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }.filter { $0.count >= 2 && !$0.allSatisfy(\.isNumber) }
    }

    // MARK: Inference

    private struct Weights {
        let classes: [FolderKind]
        let bias: [Float]
        let index: [String: Int]
        let matrix: [Float]
    }

    private static let weights: Weights? = {
        guard let data = Data(base64Encoded: FolderModelWeights.packed, options: .ignoreUnknownCharacters) else { return nil }
        let vocab = FolderModelWeights.vocabulary.split(separator: "\n").map(String.init)
        let classes = FolderModelWeights.classes.split(separator: ",").compactMap { FolderKind(rawValue: String($0)) }
        let count = classes.count
        let floats: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard count > 0, floats.count == count + vocab.count * count else { return nil }
        var index: [String: Int] = [:]
        for (i, token) in vocab.enumerated() { index[token] = i }
        return Weights(classes: classes, bias: Array(floats[0..<count]), index: index, matrix: Array(floats[count...]))
    }()

    static var isAvailable: Bool { weights != nil }

    static func predict(path: String, isDirectory: Bool, size: Int64) -> Prediction? {
        guard let w = weights else { return nil }
        let count = w.classes.count
        var scores = w.bias
        var used: [(token: String, row: Int)] = []
        for token in features(path: path, isDirectory: isDirectory, size: size) {
            guard let row = w.index[token] else { continue }
            used.append((token, row))
            let base = row * count
            for c in 0..<count { scores[c] += w.matrix[base + c] }
        }
        let top = scores.max() ?? 0
        let exps = scores.map { exp(Double($0 - top)) }
        let total = exps.reduce(0, +)
        guard let best = exps.indices.max(by: { exps[$0] < exps[$1] }) else { return nil }
        // The words that pushed hardest towards the winning class (meta features are left out of the explanation).
        var scored: [(word: String, weight: Float)] = []
        for (token, row) in used {
            guard token.hasPrefix("w:") || token.hasPrefix("last:") || token.hasPrefix("ext:") else { continue }
            let weight = w.matrix[row * count + best]
            guard weight > 0.3, let colon = token.firstIndex(of: ":") else { continue }
            scored.append((String(token[token.index(after: colon)...]), weight))
        }
        scored.sort { $0.weight > $1.weight }
        let reasons = scored.map(\.word)
        var seen = Set<String>()
        return Prediction(kind: w.classes[best], confidence: exps[best] / total,
                          reasons: reasons.filter { seen.insert($0).inserted }.prefix(3).map { $0 })
    }
}

/// What the model can recognise.
enum FolderKind: String, CaseIterable, Codable {
    case cache, logs, temp, buildOutput, dependencies, toolchain, virtualMachine, containers, aiModels
    case mediaLibrary, deviceBackup, installer, gameData, appData, documents, sourceCode, audioContent
    case cloudSync, browserData, mailMessages, system, application

    var title: String {
        switch self {
        case .cache: "Cache"
        case .logs: "Log files"
        case .temp: "Temporary files"
        case .buildOutput: "Build output"
        case .dependencies: "Downloaded dependencies"
        case .toolchain: "Developer toolchain or SDK"
        case .virtualMachine: "Virtual machine"
        case .containers: "Container images"
        case .aiModels: "AI models"
        case .mediaLibrary: "Media library"
        case .deviceBackup: "Backup"
        case .installer: "Installer or archive"
        case .gameData: "Game data"
        case .appData: "App data"
        case .documents: "Your documents"
        case .sourceCode: "Source code"
        case .audioContent: "Audio plug-ins and sound libraries"
        case .cloudSync: "Cloud-synced files"
        case .browserData: "Browser data"
        case .mailMessages: "Mail and Messages"
        case .system: "System files"
        case .application: "Application"
        }
    }

    /// What it means and what to do, in plain words.
    var advice: String {
        switch self {
        case .cache: "Caches are copies an app keeps so it loads faster. Apps rebuild them when needed, so removing one is safe (quit the app first)."
        case .logs: "Log files only help when troubleshooting. They're safe to remove."
        case .temp: "Temporary files left behind by apps or tools. Usually safe to remove once nothing is using them."
        case .buildOutput: "Compiled output from building software. It's recreated the next time the project is built."
        case .dependencies: "Libraries a project or tool downloaded. They're downloaded again automatically when needed, which can take a while."
        case .toolchain: "Compilers, SDKs or tools that programs depend on. They can be reinstalled, but anything that uses them stops working until you do."
        case .virtualMachine: "A virtual computer's disk. Deleting it deletes everything inside that computer."
        case .containers: "Container images and volumes (for example Docker). They're downloaded or rebuilt from their definitions, but volumes can hold data."
        case .aiModels: "Downloaded AI models. They're large and can be downloaded again."
        case .mediaLibrary: "A photo, music or video library. Manage it inside its app, never by deleting files in Finder."
        case .deviceBackup: "A backup. Only remove it if you have another copy or no longer need it."
        case .installer: "An installer, disk image or archive. Once used, it usually isn't needed."
        case .gameData: "Game files or saves. Games can be re-downloaded from their store, but saves may not be."
        case .appData: "Data an app keeps: settings, accounts and documents. Removing it resets the app or loses data."
        case .documents: "Your own files. Only you can decide whether to keep them."
        case .sourceCode: "Code you or a project wrote. Keep it unless it's backed up elsewhere."
        case .audioContent: "Instruments, effects or sound libraries for music apps. Remove them with their maker's installer."
        case .cloudSync: "Local copies of cloud files. Turning on the cloud app's storage-saving option frees space without deleting anything."
        case .browserData: "Your browser profile: history, passwords and settings. Clear caches from inside the browser instead."
        case .mailMessages: "Mail or Messages data. Trim it from inside the app."
        case .system: "Managed by macOS. Don't remove it by hand."
        case .application: "An installed app. Remove apps you don't use with Uninstaller, which takes their data too."
        }
    }

    /// Kinds where removing the item frees space without losing anything you made.
    var isReclaimable: Bool {
        [.cache, .logs, .temp, .buildOutput, .dependencies, .installer].contains(self)
    }

    var symbol: String {
        switch self {
        case .cache, .temp: "archivebox"
        case .logs: "doc.text"
        case .buildOutput, .dependencies, .toolchain: "hammer"
        case .virtualMachine, .containers: "server.rack"
        case .aiModels: "brain"
        case .mediaLibrary: "photo.on.rectangle"
        case .deviceBackup: "externaldrive"
        case .installer: "shippingbox"
        case .gameData: "gamecontroller"
        case .appData: "folder"
        case .documents: "doc"
        case .sourceCode: "chevron.left.forwardslash.chevron.right"
        case .audioContent: "waveform"
        case .cloudSync: "icloud"
        case .browserData: "globe"
        case .mailMessages: "message"
        case .system: "gearshape"
        case .application: "app"
        }
    }
}
