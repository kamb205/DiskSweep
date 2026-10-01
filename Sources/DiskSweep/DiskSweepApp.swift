import AppKit
import SwiftUI

@main
struct DiskSweepApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var monitor = SystemMonitor()
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some Scene {
        WindowGroup("DiskSweep", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(monitor)
                .frame(minWidth: 1000, minHeight: 700)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.hasFullDiskAccess = AppModel.checkFullDiskAccess()
                }
                .task { await DebugSnapshot.run(model: model, monitor: monitor) }
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About DiskSweep") {
                    let credits = NSMutableAttributedString(
                        string: "Made with ♥ by Kamran · 2026",
                        attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
                    )
                    credits.addAttribute(.foregroundColor, value: NSColor.systemRed,
                                         range: (credits.string as NSString).range(of: "♥"))
                    let style = NSMutableParagraphStyle()
                    style.alignment = .center
                    credits.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: credits.length))
                    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
                }
            }
            CommandGroup(after: .appSettings) {
                Toggle("Show DiskSweep in Menu Bar", isOn: $showMenuBarIcon)
            }
            DiskSweepCommands(model: model, monitor: monitor)
        }

        // Test runs (layout snapshots) never add a second icon to the menu bar.
        MenuBarExtra(isInserted: Binding(get: { showMenuBarIcon && DebugSnapshot.directory == nil },
                                         set: { showMenuBarIcon = $0 })) {
            MenuBarPanel()
                .environmentObject(model)
                .environmentObject(monitor)
        } label: {
            Image(systemName: "internaldrive.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.availableUpdate != nil && model.phase != .scanning { UpdateBanner() }
            switch model.phase {
            case .idle: StartView()
            case .scanning: ScanningView()
            case .done: MainView()
            }
        }
    }
}

struct UpdateBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.white)
            Text("A new version of DiskSweep is ready.").fontWeight(.semibold)
            Text("Your scan results are kept.").foregroundStyle(.white.opacity(0.8))
            Spacer()
            Button("Restart to Update") { model.installUpdate() }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.25))
                .disabled(model.isTrashing)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.blue.gradient)
    }
}

// MARK: - Shared pieces

struct MadeWithLove: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("Made with")
            Image(systemName: "heart.fill").foregroundStyle(.red)
            Text("by **Kamran** · 2026")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()

    func icon(for path: String) -> NSImage {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

struct FileIcon: View {
    let path: String
    var size: CGFloat = 18

    var body: some View {
        Image(nsImage: IconCache.shared.icon(for: path))
            .resizable()
            .frame(width: size, height: size)
    }
}

struct SafetyBadge: View {
    let safety: Safety

    var body: some View {
        Text(safety.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(safety.color)
            .background(safety.color.opacity(0.15), in: Capsule())
    }
}

struct FullDiskAccessBanner: View {
    @EnvironmentObject var model: AppModel
    var deniedCount: Int?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 8) {
                Text(model.hasFullDiskAccess ? "Some folders were skipped" : "Full Disk Access is OFF. DiskSweep can't scan yet")
                    .font(.headline)
                Text(intro)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !AppModel.isInstalledInApplications {
                    Label("DiskSweep is running from \(Fmt.path((AppModel.appPath as NSString).deletingLastPathComponent)). Drag it into your Applications folder and open it from there first. Access is granted to one specific copy of the app.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !model.hasFullDiskAccess {
                    VStack(alignment: .leading, spacing: 3) {
                        step(1, "Click **Open Privacy Settings**.")
                        step(2, "DiskSweep won't be in the list yet. Click the **+** button below the list. You may need to enter your password.")
                        step(3, "Choose **DiskSweep** in Applications, or drag it in from the Finder window **Show DiskSweep** opens.")
                        step(4, "Make sure its switch is on. This screen turns green within a few seconds. If it doesn't, click **Relaunch DiskSweep**.")
                    }
                    .font(.callout)
                }

                HStack {
                    Button("Open Privacy Settings") { model.openFullDiskAccessSettings() }
                        .buttonStyle(.borderedProminent)
                    Button("Show DiskSweep") { model.revealApp() }
                    Button("Relaunch DiskSweep") { model.relaunch() }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.3)))
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var intro: String {
        var text = model.hasFullDiskAccess
            ? "Some system-protected folders can't be read even with Full Disk Access. "
            : "To scan your whole Mac, including the Trash, Mail, Messages, Photos and app data, macOS requires you to turn on Full Disk Access for DiskSweep. Your files never leave your Mac. "
        if let deniedCount, deniedCount > 0 { text += "\(deniedCount) folders were skipped in this scan." }
        return text
    }
}

// MARK: - Start

struct StartView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 64))
                .foregroundStyle(.linearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom))
            VStack(spacing: 6) {
                Text("DiskSweep").font(.largeTitle.bold())
                Text("Find large, old, duplicate and leftover files, then choose what to remove.")
                    .foregroundStyle(.secondary)
            }

            if model.volume.total > 0 {
                DiskBar(volume: model.volume).frame(width: 420)
            }

            VStack(spacing: 12) {
                Picker("Scan", selection: $model.scope) {
                    ForEach(AppModel.Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 420)
                .onChange(of: model.scope) { _, scope in
                    if scope == .custom && model.customFolder == nil { model.chooseFolder() }
                    model.refreshVolume()
                }

                if model.scope == .custom {
                    HStack {
                        Text(model.customFolder.map { Fmt.path($0.path) } ?? "No folder chosen")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Change…") { model.chooseFolder() }
                    }
                    .frame(width: 420)
                }

                HStack(spacing: 12) {
                    if model.hasResults {
                        Button {
                            model.backToResults()
                        } label: {
                            Label("Back to Results", systemImage: "chevron.left")
                                .frame(width: 160)
                        }
                        .controlSize(.large)
                    }
                    Button {
                        model.startScan()
                    } label: {
                        Label(model.hasResults ? "Scan Again" : "Start Scan", systemImage: "magnifyingglass")
                            .frame(width: 160)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                }
            }

            if model.hasFullDiskAccess {
                Label("Full Disk Access is on. DiskSweep can scan everything.", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
            } else {
                FullDiskAccessBanner().frame(width: 600)
            }

            Spacer()
            VStack(spacing: 8) {
                Label("Nothing is removed without your confirmation, and removed items go to the Trash so you can restore them.",
                      systemImage: "checkmark.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                MadeWithLove()
            }
            .padding(.bottom, 20)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Full Disk Access is required", isPresented: $model.showAccessRequired) {
            Button("Open Privacy Settings") { model.openFullDiskAccessSettings() }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("DiskSweep needs Full Disk Access before it can scan. In Privacy & Security › Full Disk Access, click +, choose DiskSweep, turn it on, then come back and start the scan.")
        }
    }
}

// MARK: - Scanning

struct ScanningView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 10)
            HStack(spacing: 14) {
                ProgressView().controlSize(.regular)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.progress.phase).font(.title3.weight(.semibold))
                    Text("\(model.progress.files.formatted()) files · \(Fmt.bytes(model.progress.bytes))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.hasResults ? "Cancel and Go Back" : "Cancel") { model.cancelScan() }
                    .keyboardShortcut(.cancelAction)
            }
            .frame(width: 520)
            Text(Fmt.path(model.progress.currentPath))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 520, alignment: .leading)

            Divider().frame(width: 520).padding(.vertical, 6)

            CatGallery()
            Spacer(minLength: 10)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DiskBar: View {
    let volume: VolumeInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let fraction = volume.total > 0 ? CGFloat(volume.used) / CGFloat(volume.total) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(.linearGradient(colors: [.blue, fraction > 0.85 ? .red : .purple],
                                              startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 12)
            HStack {
                Text("\(Fmt.bytes(volume.used)) used of \(Fmt.bytes(volume.total))")
                Spacer()
                Text("\(Fmt.bytes(volume.available)) available").foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }
}
