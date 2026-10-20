// Trains DiskSweep's folder classifier and writes Sources/DiskSweep/FolderModelWeights.swift.
//
//   swiftc -O Scripts/train_folder_model.swift Sources/DiskSweep/FolderModel.swift \
//          Sources/DiskSweep/FolderModelWeights.swift -o /tmp/train && /tmp/train
//
// (FolderModelWeights.swift only needs to exist to compile; it's replaced at the end.)
// Training data is generated from templates of real macOS paths. Part of every name list (apps,
// projects, games…) is held out, so the reported test accuracy is on names the model never saw.

import Foundation

// MARK: - Name pools (generic, nothing specific to one Mac)

var rng = SystemRandomNumberGenerator()
struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var x = state
        x ^= x >> 33; x = x &* 0xff51afd7ed558ccd; x ^= x >> 33
        return x
    }
}
var gen = Seeded(state: 20261020)
func pick<T>(_ a: [T]) -> T { a[Int(gen.next() % UInt64(a.count))] }
func chance(_ p: Double) -> Bool { Double(gen.next() % 10_000) / 10_000 < p }

let apps = ["Slack", "Spotify", "Discord", "Zoom", "Figma", "Notion", "Obsidian", "Telegram", "WhatsApp", "Signal",
            "Microsoft Teams", "Microsoft Word", "Microsoft Excel", "Microsoft Outlook", "OneDrive", "Dropbox", "Google Drive",
            "Steam", "Epic Games Launcher", "Battle.net", "Minecraft", "Roblox", "Blender", "Unity Hub", "Unreal Engine",
            "Adobe Photoshop", "Adobe Premiere Pro", "Adobe Lightroom", "Adobe Illustrator", "After Effects", "Final Cut Pro",
            "Logic Pro", "GarageBand", "Ableton Live", "FL Studio", "Pro Tools", "Cubase", "Reaper", "Native Instruments",
            "OBS", "VLC", "IINA", "HandBrake", "Postman", "Docker", "Visual Studio Code", "Cursor", "Sublime Text",
            "IntelliJ IDEA", "PyCharm", "Android Studio", "Xcode", "GitHub Desktop", "Sourcetree", "Tower", "TablePlus",
            "1Password", "Bitwarden", "Raycast", "Alfred", "Rectangle", "CleanShot X", "Arc", "Brave Browser", "Firefox",
            "Opera", "Vivaldi", "Microsoft Edge", "Zen Browser", "Mail", "Messages", "Music", "TV", "Podcasts", "Books",
            "Kindle", "Audible", "Canva", "Affinity Photo", "Affinity Designer", "Sketch", "Framer", "Webflow", "Linear",
            "Todoist", "Things", "Evernote", "Bear", "Craft", "Notability", "GoodNotes", "Skype", "Webex", "Loom",
            "ChatGPT", "Claude", "Perplexity", "LM Studio", "Ollama", "DaVinci Resolve", "Capture One", "Pixelmator Pro",
            "Kontakt", "Serum", "Splice", "Izotope", "Waves Central", "Arturia", "Spitfire Audio", "UVI Portal",
            "Parallels Desktop", "VMware Fusion", "UTM", "VirtualBox", "CrossOver", "Whisky", "Heroic", "Lunar Client",
            "Shottr", "Keka", "The Unarchiver", "Transmission", "qBittorrent", "JDownloader", "Free Download Manager"]
let words = ["data", "files", "assets", "stuff", "media", "export", "render", "store", "content", "library", "share", "work",
             "archive", "projects", "clips", "sessions", "packs", "resources", "local", "user", "main", "default"]
let projects = ["website", "portfolio", "api-server", "my-app", "game-engine", "thesis", "blog", "dashboard", "mobile-app",
                "backend", "frontend", "cli-tool", "bot", "scraper", "shop", "landing-page", "chat-app", "ml-experiments",
                "compiler", "emulator", "launcher", "plugin", "homework", "client-site", "side-project", "snake-game",
                "weather-app", "notes", "tracker", "invoice-tool", "music-player", "photo-editor", "renderer", "kernel",
                "port", "recomp", "toolkit", "sdk-samples", "firmware", "pipeline", "infra", "monorepo", "design-system"]
let bundlePrefixes = ["com", "io", "org", "net", "dev", "app"]
let vendors = ["spotify", "tinyspeck", "microsoft", "google", "adobe", "figma", "notion", "discord", "zoom", "electron",
               "jetbrains", "docker", "valvesoftware", "epicgames", "blender", "obsproject", "videolan", "native-instruments",
               "ableton", "image-line", "izotope", "steinberg", "openai", "anthropic", "mozilla", "brave", "operasoftware",
               "github", "postmanlabs", "readdle", "agilebits", "raycast", "linear", "todoist", "culturedcode", "bohemian"]
let games = ["Counter-Strike 2", "Dota 2", "Baldurs Gate 3", "Cyberpunk 2077", "Hades II", "Stardew Valley", "Terraria",
             "Civilization VI", "Football Manager 2024", "Fortnite", "Rocket League", "Hollow Knight", "Celeste",
             "Death Stranding", "Resident Evil Village", "No Mans Sky", "Disco Elysium", "Factorio", "Rimworld",
             "Elden Ring", "Minecraft", "World of Warcraft", "Diablo IV", "League of Legends", "Valorant", "Apex Legends"]
let models = ["llama3.1-8b", "mistral-7b-instruct", "qwen2.5-14b", "phi-4", "gemma-2-9b", "deepseek-r1", "stable-diffusion-xl",
              "whisper-large-v3", "flux-dev", "bert-base-uncased", "clip-vit-large", "codellama-13b", "mixtral-8x7b"]
let vmNames = ["ubuntu", "debian", "fedora", "windows11", "win10", "kali", "arch", "default", "dev", "builder", "docker",
               "k8s", "macos-sonoma", "macos-ventura", "test-vm", "lab", "server", "android"]
let docNames = ["Tax Return", "CV", "Invoices", "Bank Statements", "Contracts", "University", "Coursework", "Essays",
                "Meeting Notes", "Scans", "Receipts", "Recipes", "Travel", "Wedding", "Kids", "Family", "Work", "Clients",
                "Assignments", "Lecture Slides", "Mortgage", "Insurance", "Payslips", "Applications"]
let mediaNames = ["Holiday 2024", "Wedding Video", "GoPro", "Drone Footage", "Concert", "Birthday", "Screen Recordings",
                  "Raw Footage", "Exports", "Family Videos", "Vlogs", "Shoot", "Interview"]
let versions = ["1.0", "2.3.1", "14.2", "17.0.1", "3.12", "18.1.8", "22.04", "0.9.7", "26.0", "11.0.2"]

// Hold out about a fifth of every pool for the test set.
func split<T>(_ a: [T]) -> (train: [T], test: [T]) {
    var train: [T] = [], test: [T] = []
    for (i, x) in a.enumerated() { if i % 5 == 3 { test.append(x) } else { train.append(x) } }
    return (train, test)
}

struct Pools {
    var apps: [String], projects: [String], vendors: [String], games: [String], models: [String], vms: [String], docs: [String], media: [String]
}
let trainPools = Pools(apps: split(apps).train, projects: split(projects).train, vendors: split(vendors).train,
                       games: split(games).train, models: split(models).train, vms: split(vmNames).train,
                       docs: split(docNames).train, media: split(mediaNames).train)
let testPools = Pools(apps: split(apps).test, projects: split(projects).test, vendors: split(vendors).test,
                      games: split(games).test, models: split(models).test, vms: split(vmNames).test,
                      docs: split(docNames).test, media: split(mediaNames).test)

func bundleID(_ p: Pools) -> String {
    "\(pick(bundlePrefixes)).\(pick(p.vendors)).\(pick(["app", "desktop", "client", "mac", pick(p.apps).lowercased().replacingOccurrences(of: " ", with: "")]))"
}
func uuid() -> String { UUID().uuidString }
func hex(_ n: Int) -> String { (0..<n).map { _ in String("0123456789abcdef".randomElement(using: &gen)!) }.joined() }

// MARK: - Templates

/// A template produces (path, isDirectory, size) for one class.
typealias Template = (Pools) -> (String, Bool, Int64)
let GB: Int64 = 1_000_000_000
func size(_ lo: Double, _ hi: Double) -> Int64 { Int64((lo + Double(gen.next() % 1000) / 1000 * (hi - lo)) * Double(GB)) }

let templates: [FolderKind: [Template]] = [
    .cache: [
        { p in ("~/Library/Caches/\(bundleID(p))", true, size(0.1, 3)) },
        { p in ("~/Library/Caches/\(pick(p.apps))", true, size(0.1, 3)) },
        { p in ("~/Library/Application Support/\(pick(p.apps))/Cache", true, size(0.1, 2)) },
        { p in ("~/Library/Application Support/\(pick(p.apps))/Code Cache", true, size(0.1, 1)) },
        { p in ("~/Library/Application Support/\(pick(p.apps))/GPUCache", true, size(0.05, 0.5)) },
        { p in ("~/Library/Application Support/\(pick(p.apps))/Service Worker/CacheStorage", true, size(0.1, 2)) },
        { p in ("~/Library/Containers/\(bundleID(p))/Data/Library/Caches", true, size(0.1, 3)) },
        { p in ("~/Library/Group Containers/\(hex(10).uppercased()).\(bundleID(p))/Library/Caches", true, size(0.1, 2)) },
        { p in ("~/.cache/\(pick(["thumbnails", "fontconfig", "mesa_shader_cache", "go-build", "ms-playwright", "puppeteer", "selenium", "yarn", "bazel", "ccache", "sccache"]))", true, size(0.2, 8)) },
        { p in ("~/Library/Caches/\(pick(["com.spotify.client", "Google", "com.microsoft.VSCode.ShipIt", "Homebrew", "pip", "Yarn", "CocoaPods", "JetBrains", "go-build", "node-gyp", "ms-playwright", "electron"]))", true, size(0.2, 6)) },
        { p in ("~/Library/Application Support/\(pick(p.apps))/\(pick(["ShaderCache", "DawnCache", "CachedData", "cache2", "Crashpad/pending", "media_cache", "image_cache", "thumbnail-cache", "PreviewCache", "WaveformCache", "PeakFiles"]))", true, size(0.1, 4)) },
        { p in ("/Library/Caches/\(bundleID(p))", true, size(0.1, 2)) },
        { p in ("~/\(pick(p.projects))/\(pick([".cache", ".parcel-cache", ".turbo", ".next/cache", ".gradle", ".pytest_cache", ".mypy_cache", ".ruff_cache"]))", true, size(0.1, 2)) },
        { p in ("~/Library/Developer/Xcode/DocumentationCache", true, size(0.5, 2)) },
        { p in ("~/Library/Caches/\(pick(["Google/Chrome", "Google/Chrome/Default", "BraveSoftware/Brave-Browser", "Microsoft Edge", "Firefox/Profiles", "com.operasoftware.Opera", "Arc", "Vivaldi", "Mozilla/firefox"]))\(pick(["", "/Default", "/Profile 1", "/Cache"]))", true, size(0.2, 3)) },
        { p in ("~/Library/Caches/\(pick(p.apps))/\(pick(words))", true, size(0.1, 2)) },
        { p in ("~/Library/Application Support/\(pick(["Google/Chrome", "BraveSoftware/Brave-Browser", "Microsoft Edge"]))/\(pick(["Default", "Profile 1"]))/\(pick(["Cache", "Code Cache", "GPUCache", "Service Worker/CacheStorage"]))", true, size(0.2, 3)) },
        { p in ("~/Library/Caches/\(pick(p.apps).replacingOccurrences(of: " ", with: ""))/\(pick(["cache", "Cache.db", "fsCachedData", "com.apple.metal"]))", true, size(0.1, 1)) },
    ],
    .logs: [
        { p in ("~/Library/Logs/\(pick(p.apps))", true, size(0.05, 2)) },
        { p in ("~/Library/Logs/DiagnosticReports", true, size(0.05, 1)) },
        { p in ("/Library/Logs/\(pick(["DiagnosticReports", "CrashReporter", pick(p.apps)]))", true, size(0.05, 1)) },
        { p in ("~/Library/Application Support/\(pick(p.apps))/\(pick(["logs", "Logs", "log", "crashes", "Crash Reports"]))", true, size(0.05, 2)) },
        { p in ("~/\(pick(p.projects))/\(pick(["logs", "log"]))", true, size(0.05, 3)) },
        { p in ("~/\(pick(p.projects))/\(pick(["build", "debug", "server", "output", "error", "trace"])).log", false, size(0.1, 3)) },
        { p in ("/private/var/log/\(pick(["asl", "system.log", "install.log", "DiagnosticMessages"]))", true, size(0.05, 1)) },
        { p in ("~/Library/Containers/\(bundleID(p))/Data/Library/Logs", true, size(0.05, 1)) },
    ],
    .temp: [
        { p in ("/private/var/folders/\(hex(2))/\(hex(30))/T/\(bundleID(p))", true, size(0.1, 3)) },
        { p in ("/private/var/folders/\(hex(2))/\(hex(30))/T/\(pick(["TemporaryItems", "tmp" + hex(6), "com.apple.dt.Xcode", "pip-build", "npm-" + hex(5)]))", true, size(0.1, 3)) },
        { p in ("/private/tmp/\(pick(["build-" + hex(4), "scratch", "tmp" + hex(6), pick(p.projects) + "-tmp", "extract", "downloads"]))", true, size(0.1, 5)) },
        { p in ("~/\(pick(p.projects))/\(pick(["tmp", "temp", ".tmp", "scratch"]))", true, size(0.1, 3)) },
        { p in ("~/Library/Application Support/\(pick(p.apps))/\(pick(["tmp", "Temp", "temp", "pending", "staging", "Partial Downloads"]))", true, size(0.1, 2)) },
        { p in ("~/Downloads/\(pick(p.apps))-\(hex(6)).\(pick(["crdownload", "download", "part", "partial"]))", false, size(0.1, 6)) },
    ],
    .buildOutput: [
        { p in ("~/\(pick(["Projects", "Developer", "code", "src", "dev", "repos", "GitHub", "Documents/Projects"]))/\(pick(p.projects))/\(pick(["build", "dist", "out", "target", ".build", "bin/Debug", "obj", "cmake-build-debug", "cmake-build-release", "Build", "DerivedData", ".next", "_build", "release", "Debug", "x64/Release"]))", true, size(0.1, 10)) },
        { p in ("~/Library/Developer/Xcode/DerivedData/\(pick(p.projects).replacingOccurrences(of: "-", with: ""))-\(hex(28))", true, size(0.3, 8)) },
        { p in ("~/Library/Developer/Xcode/DerivedData", true, size(1, 40)) },
        { p in ("~/\(pick(["Projects", "Developer", "code"]))/\(pick(p.projects))/\(pick(["build", "out", "target"]))/\(pick(["release", "debug", "obj", "intermediates", "classes", "CMakeFiles"]))", true, size(0.1, 5)) },
        { p in ("~/\(pick(["Projects", "code"]))/\(pick(p.projects))/build-\(pick(["arm64", "x86_64", "ps5", "android", "ios", "release", "debug", "wasm", "linux"]))", true, size(0.1, 6)) },
        { p in ("~/Library/Developer/Xcode/Archives/\(Int.random(in: 2022...2026, using: &gen))-0\(Int.random(in: 1...9, using: &gen))-1\(Int.random(in: 0...9, using: &gen))", true, size(0.1, 2)) },
        { p in ("~/\(pick(["Projects", "code"]))/\(pick(p.projects))/\(pick(["build", "out"]))/\(pick(p.projects)).\(pick(["o", "a", "elf", "wasm", "obj"]))", false, size(0.1, 2)) },
    ],
    .dependencies: [
        { p in ("~/\(pick(["Projects", "Developer", "code", "src", "Desktop", "Documents"]))/\(pick(p.projects))/node_modules", true, size(0.2, 3)) },
        { p in ("~/\(pick(["Projects", "code"]))/\(pick(p.projects))/\(pick([".venv", "venv", "env", "Pods", "vendor", "Carthage", ".dart_tool", "packages", "deps", "third_party", "3rdparty", ".deps", "external"]))", true, size(0.2, 5)) },
        { p in ("~/\(pick([".npm", ".npm/_cacache", ".yarn/cache", ".pnpm-store", ".bun/install/cache", ".m2/repository", ".gradle/caches", ".cargo/registry", ".cargo/git", ".nuget/packages", ".ivy2/cache", ".cocoapods/repos", ".composer/cache", ".pub-cache", ".gem", ".cpan"]))", true, size(0.5, 15)) },
        { p in ("~/go/pkg/mod", true, size(0.5, 10)) },
        { p in ("~/Library/Caches/pip/wheels", true, size(0.2, 4)) },
        { p in ("~/\(pick(["Projects", "code"]))/\(pick(p.projects))/.venv/lib/python3.\(Int.random(in: 9...13, using: &gen))/site-packages", true, size(0.2, 5)) },
        { p in ("~/.local/share/\(pick(["virtualenvs", "pnpm/store", "uv", "pipx/venvs", "fnm", "mise/installs/node"]))", true, size(0.2, 6)) },
    ],
    .toolchain: [
        { p in ("/opt/homebrew/Cellar/\(pick(["llvm", "gcc", "python@3.13", "node", "openjdk", "rust", "go", "qt", "ffmpeg", "opencv", "boost", "ghidra", "dotnet"]))/\(pick(versions))", true, size(0.2, 3)) },
        { p in ("/opt/homebrew/\(pick(["Cellar", "lib", "opt", "share", "Caskroom"]))", true, size(1, 10)) },
        { p in ("/usr/local/\(pick(["Cellar", "lib", "go", "share/dotnet", "texlive"]))", true, size(1, 8)) },
        { p in ("~/\(pick([".rustup/toolchains", ".rustup", ".sdkman", ".pyenv/versions", ".nvm/versions", ".rbenv/versions", ".juliaup", ".ghcup", ".swiftly", ".dotnet", ".wasmtime", ".espressif", ".platformio", ".arduino15", ".conan2", ".vcpkg", ".deno", ".bun"]))", true, size(0.3, 8)) },
        { p in ("~/Library/Android/sdk", true, size(3, 30)) },
        { p in ("~/Library/Android/sdk/\(pick(["system-images", "ndk", "platforms", "build-tools", "emulator"]))", true, size(1, 15)) },
        { p in ("~/\(pick(["miniconda3", "anaconda3", "miniforge3", "flutter", "sdk", "development/flutter", "opt/toolchains", "x-tools", "toolchains"]))", true, size(1, 15)) },
        { p in ("/Library/Developer/CommandLineTools", true, size(1, 5)) },
        { p in ("/Applications/Xcode.app/Contents/Developer/Platforms/\(pick(["iPhoneOS", "iPhoneSimulator", "XROS", "AppleTVOS", "WatchOS"])).platform", true, size(2, 10)) },
        { p in ("~/Library/Developer/Xcode/iOS DeviceSupport/\(pick(["17.4", "18.0", "18.2", "26.0"])) (\(hex(6).uppercased()))", true, size(1, 5)) },
        { p in ("~/\(pick(["Projects", "work", "code"]))/\(pick(["PS5_PayloadSDK", "devkitPro", "esp-idf", "zephyr-sdk", "android-ndk-r26", "llvm-project", "emsdk", "wasi-sdk", "gcc-arm-none-eabi", "Vulkan-SDK", "openwrt-sdk"]))", true, size(0.5, 10)) },
        { p in ("~/Library/Application Support/\(pick(["JetBrains/Toolbox/apps", "Code/User/globalStorage", "Google/AndroidStudio", "Cursor/extensions"]))", true, size(0.5, 5)) },
    ],
    .virtualMachine: [
        { p in ("~/.lima/\(pick(p.vms))", true, size(5, 90)) },
        { p in ("~/.lima/\(pick(p.vms))/\(pick(["disk", "diffdisk", "basedisk"]))", false, size(5, 90)) },
        { p in ("~/.colima/_lima/colima\(pick(["", "-" + pick(p.vms)]))", true, size(5, 60)) },
        { p in ("~/Parallels/\(pick(p.vms).capitalized).pvm", true, size(20, 120)) },
        { p in ("~/Virtual Machines.localized/\(pick(p.vms).capitalized).vmwarevm", true, size(20, 120)) },
        { p in ("~/VirtualBox VMs/\(pick(p.vms).capitalized)", true, size(10, 80)) },
        { p in ("~/VirtualBox VMs/\(pick(p.vms))/\(pick(p.vms)).vdi", false, size(10, 80)) },
        { p in ("~/Library/Containers/com.utmapp.UTM/Data/Documents/\(pick(p.vms).capitalized).utm", true, size(10, 80)) },
        { p in ("~/.tart/vms/\(pick(p.vms))", true, size(20, 80)) },
        { p in ("~/.android/avd/\(pick(["Pixel_8", "Pixel_7_Pro", "Medium_Phone", "Pixel_Tablet", "Nexus_5X"]))_API_\(Int.random(in: 30...35, using: &gen)).avd", true, size(3, 15)) },
        { p in ("~/\(pick(["VMs", "Virtual Machines", "Documents/VMs", "vm"]))/\(pick(p.vms)).\(pick(["qcow2", "vmdk", "img", "vhdx", "raw"]))", false, size(5, 80)) },
        { p in ("~/Library/Developer/CoreSimulator/Devices", true, size(2, 40)) },
        { p in ("~/Library/Developer/CoreSimulator/Devices/\(uuid())", true, size(0.5, 6)) },
        { p in ("~/Library/Group Containers/\(hex(10).uppercased()).com.\(pick(["parallels", "vmware", "utmapp"])).desktop/VMs", true, size(10, 80)) },
    ],
    .containers: [
        { p in ("~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", false, size(10, 64)) },
        { p in ("~/Library/Containers/com.docker.docker/Data/vms", true, size(10, 64)) },
        { p in ("~/.orbstack/data", true, size(5, 50)) },
        { p in ("~/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data", true, size(5, 50)) },
        { p in ("~/.local/share/containers/\(pick(["storage", "podman/machine"]))", true, size(5, 40)) },
        { p in ("~/.docker/\(pick(["buildx", "desktop", "volumes"]))", true, size(1, 20)) },
        { p in ("~/.colima/default/\(pick(["docker", "containerd"]))", true, size(2, 30)) },
        { p in ("~/\(pick(["Projects", "code"]))/\(pick(p.projects))/\(pick(["docker-volumes", "pgdata", "db-data", ".docker-data"]))", true, size(0.5, 10)) },
    ],
    .aiModels: [
        { p in ("~/.cache/huggingface/hub/models--\(pick(["meta-llama", "mistralai", "Qwen", "google", "openai", "stabilityai"]))--\(pick(p.models))", true, size(2, 40)) },
        { p in ("~/.cache/huggingface", true, size(2, 80)) },
        { p in ("~/.ollama/models", true, size(4, 80)) },
        { p in ("~/.ollama/models/blobs", true, size(4, 80)) },
        { p in ("~/.lmstudio/models/\(pick(["lmstudio-community", "TheBloke", "bartowski"]))/\(pick(p.models))-GGUF", true, size(2, 30)) },
        { p in ("~/\(pick(["models", "Models", "ai/models", "Documents/AI", "stable-diffusion-webui/models/Stable-diffusion", "ComfyUI/models/checkpoints"]))/\(pick(p.models)).\(pick(["gguf", "safetensors", "ckpt", "bin", "pt", "onnx", "mlpackage"]))", false, size(1, 30)) },
        { p in ("~/.cache/\(pick(["torch/hub/checkpoints", "whisper", "clip", "lm-studio", "gpt4all", "llama.cpp"]))", true, size(0.5, 20)) },
        { p in ("~/Library/Application Support/\(pick(["Diffusion Bee", "Draw Things", "LM Studio", "Jan", "GPT4All", "Msty", "Pinokio"]))/\(pick(["models", "Models", "checkpoints"]))", true, size(2, 40)) },
    ],
    .mediaLibrary: [
        { p in ("~/Pictures/\(pick(["Photos Library", "Photos Library 2", "Old Photos Library", "iPhone Photos"])).photoslibrary", true, size(5, 300)) },
        { p in ("~/Pictures/Photos Library.photoslibrary/\(pick(["originals", "resources/derivatives", "Masters", "resources/renders"]))", true, size(2, 250)) },
        { p in ("~/Music/\(pick(["Music", "iTunes"]))/\(pick(["Media.localized", "Media", "iTunes Media", "Music Library.musiclibrary"]))", true, size(2, 200)) },
        { p in ("~/Movies/\(pick(p.media)).fcpbundle", true, size(10, 300)) },
        { p in ("~/Movies/\(pick(["iMovie Library", "iMovie Theater"])).imovielibrary", true, size(5, 200)) },
        { p in ("~/Pictures/\(pick(["Lightroom", "Lightroom Library", "Capture One"]))/\(pick(["Lightroom Catalog Previews.lrdata", "Lightroom Catalog.lrcat-data", "Capture One Catalog.cocatalog"]))", true, size(2, 60)) },
        { p in ("~/Movies/\(pick(["TV", "TV/Media", "Final Cut Original Media", "DaVinci Resolve", "CacheClip"]))", true, size(5, 200)) },
        { p in ("~/Pictures/\(pick(["Photo Booth Library", "Image Capture", "Aperture Library.aplibrary"]))", true, size(0.5, 30)) },
        { p in ("~/Movies/\(pick(p.media)).\(pick(["mov", "mp4", "mkv", "braw", "mxf"]))", false, size(1, 50)) },
        { p in ("~/Movies/\(pick(p.media))", true, size(2, 200)) },
    ],
    .deviceBackup: [
        { p in ("~/Library/Application Support/MobileSync/Backup/\(hex(8).uppercased())-\(hex(16).uppercased())", true, size(5, 200)) },
        { p in ("~/Library/Application Support/MobileSync/Backup", true, size(5, 300)) },
        { p in ("/Volumes/\(pick(["Backup", "Time Machine", "External"]))/Backups.backupdb", true, size(50, 900)) },
        { p in ("~/\(pick(["Backups", "Backup", "Documents/Backups", "Old Mac Backup", "Desktop/Backup"]))\(pick(["", "/" + pick(p.docs), "/" + pick(p.apps)]))", true, size(1, 100)) },
        { p in ("~/\(pick(["Backups", "Documents"]))/\(pick(["MacBook", "iPhone", "Laptop", "Phone", "Old Mac", pick(p.projects)])) \(pick(["backup", "Backup", "bak", "archive"])) \(Int.random(in: 2018...2026, using: &gen)).\(pick(["sparsebundle", "dmg", "zip", "tar.gz", "bak"]))", false, size(2, 200)) },
        { p in ("~/Library/Application Support/\(pick(["Google/DriveFS", "Backblaze", "Arq", "CrashPlan"]))/\(pick(["backup", "cache", "data"]))", true, size(1, 40)) },
        { p in ("/Library/Application Support/\(pick(["iTunes/iPod Software Updates", "Apple/MobileSync"]))", true, size(1, 20)) },
    ],
    .installer: [
        { p in ("~/Downloads/\(pick(p.apps).replacingOccurrences(of: " ", with: ""))-\(pick(versions)).\(pick(["dmg", "pkg", "zip", "mpkg", "xip"]))", false, size(0.1, 15)) },
        { p in ("~/Downloads/\(pick(["Install macOS Tahoe.app", "Install macOS Sequoia.app", "Xcode_26.xip", "ubuntu-24.04-desktop-arm64.iso", "Win11_24H2_English_Arm64.iso", "debian-12-arm64-netinst.iso", "kali-linux-2025-installer.iso"]))", false, size(1, 15)) },
        { p in ("~/\(pick(["Downloads", "Desktop", "Documents"]))/\(pick(p.games + p.apps)) (\(pick(["setup", "installer", "repack", "portable", "full"]))).\(pick(["rar", "zip", "7z", "iso", "tar.gz", "dmg"]))", false, size(0.5, 50)) },
        { p in ("~/Downloads/\(pick(p.media + p.docs + p.projects)).\(pick(["zip", "rar", "7z", "tar.gz", "tgz", "tar.xz"]))", false, size(0.2, 20)) },
        { p in ("~/Downloads/\(pick(["raspios", "ubuntu", "armbian", "openwrt", "batocera", "retropie", "android", "lineage", "recovery", "firmware"]))-\(pick(versions)).\(pick(["img", "img.xz", "img.gz", "bin", "iso", "wim"]))", false, size(0.5, 15)) },
        { p in ("/Library/Updates/\(Int.random(in: 10...99, using: &gen))\(Int.random(in: 0...9, using: &gen))-\(Int.random(in: 10000...99999, using: &gen))", true, size(0.5, 12)) },
        { p in ("~/Library/Application Support/\(pick(p.apps))/\(pick(["Updates", "updates", "ShipIt", "Installers", "update-cache", "pending-update"]))", true, size(0.2, 3)) },
        { p in ("~/Library/Caches/\(bundleID(p)).ShipIt", true, size(0.1, 2)) },
        { p in ("/Library/Updates", true, size(0.5, 12)) },
        { p in ("/Library/Updates/\(pick(["Rosetta", "ProductMetadata", "index"]))", true, size(0.1, 2)) },
    ],
    .gameData: [
        { p in ("~/Library/Application Support/Steam/steamapps/common/\(pick(p.games))", true, size(2, 150)) },
        { p in ("~/Library/Application Support/Steam/steamapps", true, size(10, 300)) },
        { p in ("~/Library/Application Support/\(pick(["Epic/EpicGamesLauncher", "Battle.net", "minecraft", "Riot Games", "GOG.com/Galaxy", "Heroic/games", "CrossOver/Bottles"]))", true, size(1, 100)) },
        { p in ("/Users/Shared/\(pick(["Epic Games", "Battle.net", "Blizzard"]))/\(pick(p.games))", true, size(5, 150)) },
        { p in ("~/Library/Application Support/\(pick(["Sports Interactive", "Paradox Interactive", "Feral Interactive", "Aspyr", "Larian Studios"]))/\(pick(p.games))", true, size(0.5, 30)) },
        { p in ("~/Library/Containers/\(pick(["com.feralinteractive", "com.aspyr", "com.larian", "com.blizzard"])).\(pick(p.games).lowercased().replacingOccurrences(of: " ", with: ""))/Data", true, size(1, 40)) },
        { p in ("~/\(pick(["Games", "Documents/My Games", "Applications/Games"]))/\(pick(p.games))", true, size(1, 80)) },
        { p in ("~/Library/Application Support/\(pick(p.games))/\(pick(["saves", "Saves", "SaveGames", "shaders", "mods"]))", true, size(0.1, 10)) },
        { p in ("~/\(pick(["ROMs", "Emulation", "Games/ROMs"]))/\(pick(["PS2", "PS3", "Switch", "GameCube", "Wii", "N64", "PSP"]))", true, size(1, 200)) },
    ],
    .appData: [
        { p in ("~/Library/Application Support/\(pick(p.apps))", true, size(0.1, 10)) },
        { p in ("~/Library/Containers/\(bundleID(p))", true, size(0.1, 10)) },
        { p in ("~/Library/Containers/\(bundleID(p))/Data", true, size(0.1, 10)) },
        { p in ("~/Library/Group Containers/\(hex(10).uppercased()).\(bundleID(p))", true, size(0.1, 5)) },
        { p in ("~/Library/Application Support/\(pick(p.apps))/\(pick(["IndexedDB", "databases", "Local Storage", "User Data", "Profiles", "Workspaces", "storage", "db", "Database", "Settings", "Projects", "Library"]))", true, size(0.1, 5)) },
        { p in ("/Library/Application Support/\(pick(p.apps))", true, size(0.1, 6)) },
        { p in ("~/Library/Application Support/\(bundleID(p))", true, size(0.1, 5)) },
        { p in ("~/Library/Application Support/\(pick(p.apps))/\(pick(["Presets", "Templates", "Content", "Assets", "Brushes", "Fonts", "LUTs"]))", true, size(0.1, 8)) },
    ],
    .documents: [
        { p in ("~/Documents/\(pick(p.docs))", true, size(0.1, 20)) },
        { p in ("~/Desktop/\(pick(p.docs))", true, size(0.1, 10)) },
        { p in ("~/Documents/\(pick(p.docs))/\(pick(p.docs)) \(Int.random(in: 2015...2026, using: &gen)).\(pick(["pdf", "docx", "pages", "xlsx", "key", "pptx", "numbers"]))", false, size(0.1, 2)) },
        { p in ("~/Documents", true, size(1, 80)) },
        { p in ("~/Desktop", true, size(0.5, 40)) },
        { p in ("~/Documents/\(pick(["Scans", "Screenshots", "School", "Work", "Personal", "Archive", "Old Files"]))", true, size(0.5, 30)) },
        { p in ("~/Pictures/\(pick(["Screenshots", "Wallpapers", "Exports", "Edits", pick(p.media)]))", true, size(0.2, 20)) },
        { p in ("~/Movies/\(pick(["Screen Recordings", "Recordings", "Exports"]))", true, size(1, 50)) },
    ],
    .sourceCode: [
        { p in ("~/\(pick(["Projects", "Developer", "code", "src", "dev", "repos", "GitHub", "Documents/GitHub", "work"]))/\(pick(p.projects))", true, size(0.1, 20)) },
        { p in ("~/\(pick(["Projects", "Developer", "code", "src", "repos"]))", true, size(1, 80)) },
        { p in ("~/\(pick(["Projects", "code", "repos"]))/\(pick(p.projects))/\(pick(["src", "Sources", "lib", "app", "packages", "crates", "include", "tests", "docs", "scripts", "tools"]))", true, size(0.1, 3)) },
        { p in ("~/\(pick(["Projects", "code", "repos"]))/\(pick(p.projects))/.git", true, size(0.1, 10)) },
        { p in ("~/\(pick(["Projects", "code"]))/\(pick(p.projects))/.git/objects/pack", true, size(0.1, 10)) },
    ],
    .audioContent: [
        { p in ("/Library/Audio/Plug-Ins/\(pick(["Components", "VST3", "VST", "CLAP"]))", true, size(0.5, 10)) },
        { p in ("/Library/Audio/Plug-Ins/\(pick(["Components", "VST3", "VST"]))/\(pick(["Serum", "Ozone 11", "Neutron 4", "Kontakt 7", "Omnisphere", "Massive X", "FabFilter Pro-Q 3", "Valhalla VintageVerb", "Vital", "Diva", "Nectar 4", "RX 11"])).\(pick(["component", "vst3", "vst"]))", true, size(0.05, 1)) },
        { p in ("/Library/Application Support/Avid/Audio/Plug-Ins/\(pick(["Ozone", "Neutron", "Kontakt", "Pro-Q", "Serum", "Nectar"]))\(Int.random(in: 3...11, using: &gen)).aaxplugin", true, size(0.05, 1)) },
        { p in ("/Library/Application Support/Avid/Audio/Plug-Ins", true, size(1, 10)) },
        { p in ("/Library/Application Support/\(pick(["Spectrasonics/STEAM", "Native Instruments", "Arturia/Samples", "Spitfire Audio", "Toontrack", "UVI", "Output", "EastWest", "Heavyocity", "Steinberg/Content", "GarageBand/Instrument Library", "Logic/Apple Loops"]))", true, size(2, 100)) },
        { p in ("~/\(pick(["Music", "Documents", "Sounds"]))/\(pick(["Native Instruments", "Kontakt Libraries", "Samples", "Splice", "Sample Packs", "Drum Kits", "Loops", "Ableton/User Library", "Image-Line/FL Studio/Data/Patches"]))", true, size(1, 80)) },
        { p in ("~/Music/\(pick(["Audio Music Apps", "GarageBand", "Logic", "Ableton"]))/\(pick(["Sampler Instruments", "Apple Loops", "Packs", "Plug-In Settings"]))", true, size(0.5, 30)) },
        { p in ("~/Library/Audio/\(pick(["Plug-Ins/Components", "Plug-Ins/VST3", "Sounds", "Presets"]))", true, size(0.2, 10)) },
        { p in ("\(pick(["/Library/Audio", "~/Library/Audio", "/Library/Application Support/Avid", "/Library/Application Support/Avid/Audio"]))", true, size(0.5, 12)) },
    ],
    .cloudSync: [
        { p in ("~/Library/Mobile Documents/com~apple~CloudDocs", true, size(1, 100)) },
        { p in ("~/Library/Mobile Documents/\(pick(["iCloud~md~obsidian", "com~apple~Pages", "com~apple~Numbers", "iCloud~com~goodnotes"]))", true, size(0.1, 10)) },
        { p in ("~/Library/CloudStorage/\(pick(["OneDrive-Personal", "GoogleDrive-name@gmail.com", "Dropbox", "Box-Box", "OneDrive-SharedLibraries"]))", true, size(1, 100)) },
        { p in ("~/\(pick(["Dropbox", "OneDrive", "Google Drive", "Box", "pCloud Drive", "MEGA"]))", true, size(1, 100)) },
        { p in ("~/Library/Application Support/\(pick(["Google/DriveFS", "OneDrive", "Dropbox", "com.getdropbox.dropbox", "Box/Box"]))", true, size(0.5, 20)) },
        { p in ("~/Library/Containers/com.microsoft.OneDrive-mac/Data", true, size(0.2, 5)) },
    ],
    .browserData: [
        { p in ("~/Library/Application Support/\(pick(["Google/Chrome", "BraveSoftware/Brave-Browser", "Microsoft Edge", "Vivaldi", "Arc/User Data", "com.operasoftware.Opera", "Chromium"]))", true, size(0.5, 15)) },
        { p in ("~/Library/Application Support/\(pick(["Google/Chrome", "BraveSoftware/Brave-Browser", "Microsoft Edge"]))/\(pick(["Default", "Profile 1", "Profile 2"]))", true, size(0.5, 10)) },
        { p in ("~/Library/Application Support/Firefox/Profiles/\(hex(8)).default-release", true, size(0.3, 8)) },
        { p in ("~/Library/Safari", true, size(0.1, 3)) },
        { p in ("~/Library/Containers/com.apple.Safari/Data/Library", true, size(0.1, 3)) },
    ],
    .mailMessages: [
        { p in ("~/Library/Mail/V\(Int.random(in: 8...11, using: &gen))", true, size(0.5, 30)) },
        { p in ("~/Library/Mail", true, size(0.5, 30)) },
        { p in ("~/Library/Messages/Attachments", true, size(0.5, 50)) },
        { p in ("~/Library/Messages", true, size(0.5, 50)) },
        { p in ("~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads", true, size(0.1, 3)) },
        { p in ("~/Library/Group Containers/\(pick(["UBF8T346G9.Office/Outlook/Outlook 15 Profiles", "group.net.whatsapp.WhatsApp.shared/Message/Media", "6N38VWS5BX.ru.keepcoder.Telegram"]))", true, size(0.5, 30)) },
        { p in ("~/Library/Application Support/\(pick(["Telegram Desktop", "Signal", "Slack", "discord", "WhatsApp"]))/\(pick(["Media", "attachments.noindex", "media_cache", "Cache_Data"]))", true, size(0.2, 10)) },
    ],
    .system: [
        { p in ("/private/var/vm", true, size(1, 20)) },
        { p in ("/private/var/vm/\(pick(["swapfile0", "swapfile1", "sleepimage"]))", false, size(1, 8)) },
        { p in ("/private/var/db/\(pick(["uuidtext", "diagnostics", "dyld", "Spotlight-V100", "KernelExtensionManagement", "analyticsd", "oah"]))", true, size(0.2, 3)) },
        { p in ("/System/Library/\(pick(["AssetsV2", "Frameworks", "PrivateFrameworks", "Caches"]))", true, size(1, 10)) },
        { p in ("/System/Volumes/Data/System/Library/\(pick(["AssetsV2", "Caches", "Templates"]))", true, size(1, 10)) },
        { p in ("/Library/\(pick(["Apple", "Frameworks", "Extensions", "Filesystems", "Preferences", "StagedExtensions", "SystemExtensions", "Printers"]))", true, size(0.1, 3)) },
        { p in ("/usr/\(pick(["lib", "libexec", "share", "standalone"]))", true, size(0.1, 3)) },
        { p in ("/private/var/folders", true, size(1, 10)) },
        { p in ("~/Library/\(pick(["Biome", "Metadata/CoreSpotlight", "Daemon Containers", "Trial", "Assistant", "Suggestions", "IntelligencePlatform", "DuetExpertCenter"]))", true, size(0.1, 3)) },
    ],
    .application: [
        { p in ("/Applications/\(pick(p.apps)).app", true, size(0.1, 5)) },
        { p in ("/Applications/\(pick(p.apps)).app/Contents\(pick(["", "/Frameworks", "/Resources", "/MacOS", "/PlugIns", "/Helpers"]))", true, size(0.1, 4)) },
        { p in ("~/Applications/\(pick(p.apps)).app", true, size(0.1, 5)) },
        { p in ("/Applications/\(pick(p.apps))/\(pick(p.apps)).app", true, size(0.1, 5)) },
        { p in ("/Applications/\(pick(p.apps)).app/Contents/Frameworks/\(pick(p.apps)) Framework.framework\(pick(["", "/Versions", "/Versions/A"]))", true, size(0.2, 3)) },
        { p in ("/Applications/\(pick(["Adobe", "Microsoft", "Utilities", "Games", "Steam"])) \(pick(["Acrobat DC", "Office", "Creative Cloud", ""]))", true, size(0.5, 8)) },
    ],
]

// MARK: - Dataset

struct Example { let features: [String]; let label: Int }
let classes = FolderKind.allCases
func makeSet(_ pools: Pools, perTemplate: Int) -> [Example] {
    var out: [Example] = []
    for (label, kind) in classes.enumerated() {
        for template in templates[kind] ?? [] {
            for _ in 0..<perTemplate {
                let (path, isDir, sz) = template(pools)
                out.append(Example(features: FolderModel.features(path: path, isDirectory: isDir, size: sz, home: "/Users/nobody"), label: label))
            }
        }
    }
    return out
}
var train = makeSet(trainPools, perTemplate: 60)
let test = makeSet(testPools, perTemplate: 12)
print("classes: \(classes.count), training examples: \(train.count), test examples: \(test.count)")

// Vocabulary: features seen at least twice in training.
var counts: [String: Int] = [:]
for e in train { for f in e.features { counts[f, default: 0] += 1 } }
let vocab = counts.filter { $0.value >= 2 }.keys.sorted()
var index: [String: Int] = [:]
for (i, t) in vocab.enumerated() { index[t] = i }
print("vocabulary: \(vocab.count) features")

// MARK: - Training: softmax regression with SGD

let K = classes.count, V = vocab.count
var W = [Float](repeating: 0, count: V * K)
var b = [Float](repeating: 0, count: K)
let encoded = train.map { e in (e.features.compactMap { index[$0] }, e.label) }
let epochs = 25
var lr: Float = 0.3
let l2: Float = 1e-5
for epoch in 1...epochs {
    var order = Array(encoded.indices)
    order.shuffle(using: &gen)
    var loss: Double = 0
    for i in order {
        let (feats, y) = encoded[i]
        var z = b
        for f in feats { let base = f * K; for c in 0..<K { z[c] += W[base + c] } }
        let m = z.max()!
        var p = z.map { expf($0 - m) }
        let s = p.reduce(0, +)
        for c in 0..<K { p[c] /= s }
        loss -= log(Double(max(p[y], 1e-9)))
        for c in 0..<K {
            let g = p[c] - (c == y ? 1 : 0)
            b[c] -= lr * g
            for f in feats { W[f * K + c] -= lr * (g + l2 * W[f * K + c]) }
        }
    }
    if epoch % 5 == 0 { print("epoch \(epoch): loss \(String(format: "%.4f", loss / Double(encoded.count)))") }
    lr *= 0.9
}

// MARK: - Evaluation on held-out names

func classify(_ feats: [String]) -> (Int, Double) {
    var z = b
    for f in feats { if let r = index[f] { for c in 0..<K { z[c] += W[r * K + c] } } }
    let m = z.max()!
    let p = z.map { exp(Double($0 - m)) }
    let s = p.reduce(0, +)
    let best = p.indices.max { p[$0] < p[$1] }!
    return (best, p[best] / s)
}
func accuracy(_ set: [Example]) -> Double {
    Double(set.filter { classify($0.features).0 == $0.label }.count) / Double(set.count)
}
print(String(format: "train accuracy %.1f%%, held-out test accuracy %.1f%%", accuracy(train) * 100, accuracy(test) * 100))
var confusion: [String: Int] = [:]
for e in test {
    let (guess, _) = classify(e.features)
    if guess != e.label { confusion["\(classes[e.label].rawValue) → \(classes[guess].rawValue)", default: 0] += 1 }
}
for (pair, n) in confusion.sorted(by: { $0.value > $1.value }).prefix(10) { print("  confused \(n)× \(pair)") }

// MARK: - Write weights

// Drop features whose weights are all close to zero.
var keep: [Int] = []
for r in 0..<V where (0..<K).contains(where: { abs(W[r * K + $0]) >= 0.01 }) { keep.append(r) }
var floats = b
for r in keep { floats.append(contentsOf: W[(r * K)..<(r * K + K)]) }
let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
let base64 = data.base64EncodedString(options: [.lineLength76Characters])
let vocabText = keep.map { vocab[$0] }.joined(separator: "\n")
let out = """
// Generated by Scripts/train_folder_model.swift on \(ISO8601DateFormatter().string(from: Date())). Don't edit by hand.
// \(K) classes, \(keep.count) features, held-out test accuracy \(String(format: "%.1f%%", accuracy(test) * 100)).

enum FolderModelWeights {
    static let classes = "\(classes.map(\.rawValue).joined(separator: ","))"

    static let vocabulary = #\"\"\"
\(vocabText)
\"\"\"#

    static let packed = \"\"\"
\(base64)
\"\"\"
}

"""
let dest = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Sources/DiskSweep/FolderModelWeights.swift"
try! out.write(toFile: dest, atomically: true, encoding: .utf8)
print("wrote \(dest) (\(keep.count) features, \(data.count / 1024) KB of weights)")
