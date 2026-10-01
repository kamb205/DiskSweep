import SwiftUI

// MARK: - Memory

struct MemoryView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @State private var confirmingQuitBackground = false
    @State private var confirmingQuitAll = false
    @State private var confirmingFreeUp = false
    @State private var confirmingCache = false
    @State private var forceQuitTarget: AppMemory?

    var body: some View {
        let memory = monitor.memory
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Memory", systemImage: "memorychip").font(.title2.bold())
                    Spacer()
                    Button {
                        confirmingQuitAll = true
                    } label: {
                        Label("Quit All Apps…", systemImage: "xmark.app")
                    }
                    .disabled(monitor.allQuittableApps.isEmpty)
                    Menu {
                        Button("Quit Background Apps…") { confirmingQuitBackground = true }
                            .disabled(monitor.backgroundApps.isEmpty)
                        Button("Clear File Cache… (needs password)") { confirmingCache = true }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .fixedSize()
                    Button {
                        confirmingFreeUp = true
                    } label: {
                        if monitor.isFreeingMemory { ProgressView().controlSize(.small) } else { Label("Free Up Memory", systemImage: "wind") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(monitor.isFreeingMemory)
                    .help("Quits apps you haven't used recently and background apps. No password needed.")
                }
                Text(Category.memory.blurb).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center, spacing: 28) {
                        MemoryGauge(memory: memory).frame(width: 170, height: 170)
                        VStack(alignment: .leading, spacing: 10) {
                            MemoryBar(memory: memory)
                            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                                legendRow("App memory", memory.app, .blue)
                                legendRow("Wired (macOS)", memory.wired, .orange)
                                legendRow("Compressed", memory.compressed, .purple)
                                legendRow("Cached files", memory.cached, .teal)
                                legendRow("Free", memory.free, .gray)
                            }
                            .font(.callout)
                            if memory.swapUsed > 0 {
                                Label("\(Fmt.bytes(Int64(memory.swapUsed))) is swapped to disk. Your Mac needs more memory than it has, which slows it down.",
                                      systemImage: "externaldrive.badge.exclamationmark")
                                    .font(.callout)
                                    .foregroundStyle(memory.pressureLevel > 1 ? .orange : .secondary)
                            }
                        }
                    }
                    .padding(16)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))

                    if let top = monitor.apps.first, memory.pressureLevel > 1, !top.isProtected {
                        Label("\(top.name) is using \(Fmt.bytes(Int64(top.bytes))). Quitting it, or closing tabs and windows in it, will help most.",
                              systemImage: "lightbulb.fill")
                            .foregroundStyle(.orange)
                    }

                    InactiveAppsCard()

                    Text("Apps using memory").font(.headline)
                    VStack(spacing: 0) {
                        ForEach(monitor.apps) { app in
                            AppMemoryRow(app: app, maxBytes: monitor.apps.first?.bytes ?? 1) {
                                forceQuitTarget = app
                            }
                            Divider()
                        }
                    }
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                }
                .padding(16)
            }
        }
        .confirmationDialog("Quit \(monitor.backgroundApps.count) background app\(monitor.backgroundApps.count == 1 ? "" : "s")?",
                            isPresented: $confirmingQuitBackground, titleVisibility: .visible) {
            Button("Quit Them") { monitor.quitBackgroundApps() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(monitor.backgroundApps.map(\.name).joined(separator: ", ") + "\n\nThey may start again next time you log in. To stop that for good, switch them off in Background Items.")
        }
        .confirmationDialog("Quit all \(monitor.allQuittableApps.count) apps?",
                            isPresented: $confirmingQuitAll, titleVisibility: .visible) {
            Button("Quit All") { monitor.quitAllApps() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(monitor.allQuittableApps.map(\.name).joined(separator: ", ") + "\n\nThis includes background apps. DiskSweep and Finder stay open. Apps with unsaved work will ask you to save first.")
        }
        .confirmationDialog(monitor.freeUpTargets.isEmpty ? "Nothing to quit right now" : "Free up memory by quitting \(monitor.freeUpTargets.count) app\(monitor.freeUpTargets.count == 1 ? "" : "s")?",
                            isPresented: $confirmingFreeUp, titleVisibility: .visible) {
            if !monitor.freeUpTargets.isEmpty { Button("Quit and Free Memory") { monitor.freeUpMemory() } }
            Button(monitor.freeUpTargets.isEmpty ? "OK" : "Cancel", role: .cancel) {}
        } message: {
            Text(monitor.freeUpTargets.isEmpty
                 ? "Every open app has been used in the last \(monitor.inactiveMinutes) minutes or is on your Keep Open list. To free more memory, quit an app from the list below."
                 : monitor.freeUpTargets.map { "\($0.name) (\(Fmt.bytes(Int64($0.bytes))))" }.joined(separator: ", ")
                    + "\n\nThese haven't been used in \(monitor.inactiveMinutes)+ minutes or run in the background. Apps with unsaved work will ask you to save first.")
        }
        .confirmationDialog("Clear the file cache?", isPresented: $confirmingCache, titleVisibility: .visible) {
            Button("Clear File Cache") { monitor.clearFileCache() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This uses macOS's purge command, which needs your administrator password. It only frees cached files (\(Fmt.bytes(Int64(monitor.memory.cached))) right now), not memory apps are using, and macOS refills the cache as you work.")
        }
        .confirmationDialog("Force quit \(forceQuitTarget?.name ?? "")?", isPresented: Binding(get: { forceQuitTarget != nil }, set: { if !$0 { forceQuitTarget = nil } }),
                            titleVisibility: .visible) {
            Button("Force Quit", role: .destructive) { if let app = forceQuitTarget { monitor.quit(app, force: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unsaved changes in this app will be lost.")
        }
        .alert("Memory", isPresented: Binding(get: { monitor.memoryMessage != nil }, set: { if !$0 { monitor.memoryMessage = nil } })) {
            Button("OK") { monitor.memoryMessage = nil }
        } message: {
            Text(monitor.memoryMessage ?? "")
        }
    }

    private func legendRow(_ title: String, _ bytes: UInt64, _ color: Color) -> some View {
        GridRow {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title)
            }
            Text(Fmt.bytes(Int64(bytes))).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

struct MemoryGauge: View {
    let memory: MemoryStats
    /// Small version for the menu bar panel: a thinner ring with just the percentage.
    var compact = false

    var body: some View {
        let fraction = memory.total > 0 ? Double(memory.used) / Double(memory.total) : 0
        let color = Color(nsColor: memory.pressureColor)
        let lineWidth: CGFloat = compact ? 7 : 16
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(fraction, 1))
                .stroke(color.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut, value: fraction)
            if compact {
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.callout.bold())
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(lineWidth + 2)
            } else {
            VStack(spacing: 2) {
                Text(Fmt.bytes(Int64(memory.used))).font(.title2.bold()).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.5)
                Text("of \(Fmt.bytes(Int64(memory.total)))").font(.caption).foregroundStyle(.secondary)
                Text("Pressure: \(memory.pressureLabel)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                    .padding(.top, 2)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(lineWidth + 6)
            }
        }
    }
}

struct MemoryBar: View {
    let memory: MemoryStats

    var body: some View {
        let parts: [(UInt64, Color)] = [(memory.app, .blue), (memory.wired, .orange), (memory.compressed, .purple),
                                        (memory.cached, .teal), (memory.free, .gray.opacity(0.5))]
        let total = max(Double(parts.reduce(0) { $0 + $1.0 }), 1)
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    Rectangle().fill(part.1).frame(width: max(geo.size.width * Double(part.0) / total - 2, 0))
                }
            }
        }
        .frame(height: 14)
        .clipShape(Capsule())
    }
}

struct AppMemoryRow: View {
    @EnvironmentObject var monitor: SystemMonitor
    let app: AppMemory
    let maxBytes: UInt64
    let onForceQuit: () -> Void

    private var rowDetail: String {
        var parts: [String] = []
        if app.runningApp?.isActive == true {
            parts.append("In use now")
        } else if let idle = monitor.idleMinutes(app) {
            parts.append(idle < 1 ? "Used just now" : idle < 60 ? "Idle \(idle) min" : "Idle \(idle / 60) h \(idle % 60) min")
        }
        if app.processCount > 1 { parts.append("\(app.processCount) processes") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            FileIcon(path: app.bundlePath, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(app.name).lineLimit(1)
                    if app.isBackground {
                        Text("Background")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(rowDetail).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 230, alignment: .leading)
            GeometryReader { geo in
                Capsule()
                    .fill(.tint.opacity(0.7))
                    .frame(width: max(geo.size.width * Double(app.bytes) / Double(max(maxBytes, 1)), 2), height: 8)
                    .frame(maxHeight: .infinity)
            }
            .frame(height: 16)
            Text(Fmt.bytes(Int64(app.bytes))).monospacedDigit().frame(width: 80, alignment: .trailing)
            if !app.isProtected && !app.isBackground {
                Button {
                    monitor.setKeepOpen(app, !monitor.isKeptOpen(app))
                } label: {
                    Image(systemName: monitor.isKeptOpen(app) ? "pin.fill" : "pin")
                        .foregroundStyle(monitor.isKeptOpen(app) ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.borderless)
                .help(monitor.isKeptOpen(app) ? "On your Keep Open list: never quit as inactive" : "Keep open: never quit this app as inactive")
            }
            if app.isProtected {
                Text("Part of macOS").font(.caption).foregroundStyle(.secondary).frame(width: 130)
            } else {
                HStack(spacing: 6) {
                    Button("Quit") { monitor.quit(app) }
                    Button("Force Quit…", action: onForceQuit)
                }
                .controlSize(.small)
                .frame(width: 130)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

// MARK: - Background items

struct BackgroundItemsView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var model: AppModel

    var body: some View {
        let items = monitor.launchItems.filter {
            model.search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(model.search)
                || $0.label.localizedCaseInsensitiveContains(model.search)
        }
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Background Items", systemImage: "gearshape.2").font(.title2.bold())
                    Text("\(monitor.launchItems.filter(\.isEnabled).count) on · \(monitor.launchItems.filter { !$0.isEnabled }.count) off")
                        .foregroundStyle(.secondary)
                        .padding(.leading, 6)
                    Spacer()
                    Button("Login Items Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .help("Apps that open at login are managed in System Settings")
                    Button { monitor.refreshLaunchItems() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh")
                }
                Text(Category.background.blurb).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 12)
            Divider()

            if items.isEmpty {
                ContentUnavailableView("No background items", systemImage: "checkmark.seal",
                                       description: Text("No third-party apps are running helpers in the background."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            LaunchItemRow(item: item, striped: index.isMultiple(of: 2))
                        }
                    }
                }
            }
        }
        .onAppear { monitor.refreshLaunchItems() }
        .alert("Background Items", isPresented: Binding(get: { monitor.launchMessage != nil }, set: { if !$0 { monitor.launchMessage = nil } })) {
            Button("OK") { monitor.launchMessage = nil }
        } message: {
            Text(monitor.launchMessage ?? "")
        }
    }
}

struct LaunchItemRow: View {
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var model: AppModel
    let item: LaunchItem
    let striped: Bool

    var body: some View {
        HStack(spacing: 12) {
            if let app = item.appPath, FileManager.default.fileExists(atPath: app) {
                FileIcon(path: app, size: 28)
            } else {
                Image(systemName: "gearshape").font(.title2).foregroundStyle(.secondary).frame(width: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayName).fontWeight(.medium)
                    badge(item.scope.rawValue, .secondary)
                    if item.isLeftover { badge("Leftover: app removed", .orange) }
                }
                Text(item.label + (item.program.map { " · " + Fmt.path($0) } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(item.isRunning ? "Running" : (item.isEnabled ? "Not running" : "Off"))
                .font(.caption)
                .foregroundStyle(item.isRunning ? .green : .secondary)
                .frame(width: 80, alignment: .trailing)
            if monitor.changingLaunchItem == item.id {
                ProgressView().controlSize(.small).frame(width: 44)
            } else {
                Toggle("", isOn: Binding(get: { item.isEnabled }, set: { monitor.setEnabled(item, $0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .frame(width: 44)
                    .help(item.isEnabled ? "Switch off: stop it and keep it from starting again" : "Switch back on")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(striped ? AnyShapeStyle(.quaternary.opacity(0.35)) : AnyShapeStyle(.clear))
        .contextMenu {
            Button("Show Item in Finder") { model.reveal([item.plistPath]) }
            if let program = item.program, FileManager.default.fileExists(atPath: program) {
                Button("Show Program in Finder") { model.reveal([program]) }
            }
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

struct InactiveAppsCard: View {
    @EnvironmentObject var monitor: SystemMonitor
    @State private var confirming = false

    static let limits: [(minutes: Int, label: String)] = [(15, "15 minutes"), (30, "30 minutes"), (60, "1 hour"), (120, "2 hours")]

    var body: some View {
        let inactive = monitor.inactiveApps
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Inactive Apps", systemImage: "hourglass").font(.headline)
                Spacer()
                Picker("Not used for", selection: $monitor.inactiveMinutes) {
                    ForEach(Self.limits, id: \.minutes) { Text($0.label).tag($0.minutes) }
                }
                .fixedSize()
            }
            Text(inactive.isEmpty
                 ? "No apps have gone unused for \(Self.label(monitor.inactiveMinutes)). The app you're using, DiskSweep, Finder and apps you've pinned (📌) are never counted."
                 : "\(inactive.map(\.name).joined(separator: ", ")) \(inactive.count == 1 ? "hasn't" : "haven't") been used for \(Self.label(monitor.inactiveMinutes)) or more.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button {
                    confirming = true
                } label: {
                    Label("Quit \(inactive.count) Inactive App\(inactive.count == 1 ? "" : "s")", systemImage: "moon.zzz")
                }
                .disabled(inactive.isEmpty)
                Spacer()
                Toggle("Quit inactive apps automatically", isOn: $monitor.autoQuitInactive)
                    .toggleStyle(.switch)
                    .help("While DiskSweep is running (including from the menu bar), apps unused for this long are quit automatically. Pinned apps are never quit.")
            }
            if monitor.autoQuitInactive, let last = monitor.lastAutoQuit {
                Text("Last auto-quit \(last.date.formatted(date: .omitted, time: .shortened)): \(last.names.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .confirmationDialog("Quit \(inactive.count) inactive app\(inactive.count == 1 ? "" : "s")?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Quit Them") { monitor.quitInactiveApps() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(inactive.map(\.name).joined(separator: ", ") + "\n\nApps with unsaved work will ask you to save first.")
        }
    }

    static func label(_ minutes: Int) -> String {
        limits.first { $0.minutes == minutes }?.label ?? "\(minutes) minutes"
    }
}
