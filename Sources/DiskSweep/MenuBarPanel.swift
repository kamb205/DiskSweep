import SwiftUI

/// The DiskSweep panel in the menu bar: the most useful actions one click away, without opening
/// the main window.
struct MenuBarPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var monitor: SystemMonitor
    @Environment(\.openWindow) private var openWindow
    @State private var confirmingClean = false
    @State private var confirmingEmpty = false
    @State private var confirmingQuitBackground = false
    @State private var confirmingQuitAll = false
    @State private var showAllApps = false
    @State private var confirmingFreeUp = false
    @State private var confirmingInactive = false

    var body: some View {
        let memory = monitor.memory
        let recommended = model.recommendedItems
        let recommendedBytes = recommended.reduce(0) { $0 + $1.size }
        let trashBytes = model.total(for: .trash)

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "internaldrive.fill").foregroundStyle(.tint)
                Text("DiskSweep").font(.headline)
                Spacer()
                if model.lifetime.bytes > 0 {
                    Label("\(Fmt.bytes(model.lifetime.bytes)) freed", systemImage: "leaf.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                }
            }

            section("Disk") {
                DiskBar(volume: model.volume)
            }

            section("Memory") {
                HStack(spacing: 10) {
                    MemoryGauge(memory: memory, compact: true).frame(width: 58, height: 58).padding(4)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(Fmt.bytes(Int64(memory.used))) of \(Fmt.bytes(Int64(memory.total))) used").font(.callout)
                        Text("Pressure: \(memory.pressureLabel)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(nsColor: memory.pressureColor))
                        if monitor.isFreeingMemory {
                            ProgressView().controlSize(.small)
                        } else {
                            Button { confirmingFreeUp.toggle() } label: { Label("Free Up Memory", systemImage: "wind") }
                                .controlSize(.small)
                        }
                    }
                }
                let quittable = monitor.apps.filter { !$0.isProtected }
                if confirmingFreeUp {
                    VStack(alignment: .leading, spacing: 6) {
                        if monitor.freeUpTargets.isEmpty {
                            Text("Nothing to quit: every app was used in the last \(InactiveAppsCard.label(monitor.inactiveMinutes)) or is pinned. Quit an app below to free more.")
                                .font(.caption)
                            Button("OK") { confirmingFreeUp = false }.controlSize(.small)
                        } else {
                            Text("Quit \(monitor.freeUpTargets.map(\.name).joined(separator: ", "))? They're unused or running in the background.")
                                .font(.caption)
                            HStack {
                                Button("Quit and Free Memory") { confirmingFreeUp = false; monitor.freeUpMemory() }
                                    .buttonStyle(.borderedProminent)
                                Button("Cancel") { confirmingFreeUp = false }
                            }
                            .controlSize(.small)
                        }
                    }
                }
                if let message = monitor.memoryMessage {
                    HStack(alignment: .top) {
                        Text(message).font(.caption).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button { monitor.memoryMessage = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).font(.caption)
                    }
                }
                ForEach(quittable.prefix(showAllApps ? quittable.count : 4)) { app in
                    HStack(spacing: 8) {
                        FileIcon(path: app.bundlePath, size: 16)
                        Text(app.name).lineLimit(1)
                        Spacer()
                        Text(Fmt.bytes(Int64(app.bytes))).monospacedDigit().foregroundStyle(.secondary)
                        Button { monitor.quit(app) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Quit \(app.name)")
                    }
                    .font(.callout)
                }
                if quittable.count > 4 {
                    Button(showAllApps ? "Show fewer" : "Show all \(quittable.count) apps") {
                        withAnimation { showAllApps.toggle() }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                if !monitor.allQuittableApps.isEmpty {
                    confirmButton(confirming: $confirmingQuitAll,
                                  label: "Quit All \(monitor.allQuittableApps.count) Apps",
                                  confirm: "Quit \(monitor.allQuittableApps.map(\.name).joined(separator: ", "))? Includes background apps. Apps with unsaved work will ask you to save first.",
                                  symbol: "xmark.app") { monitor.quitAllApps() }
                }
                let inactive = monitor.inactiveApps
                if !inactive.isEmpty {
                    confirmButton(confirming: $confirmingInactive,
                                  label: "Quit \(inactive.count) Inactive App\(inactive.count == 1 ? "" : "s")",
                                  confirm: "Quit \(inactive.map(\.name).joined(separator: ", "))? Unused for \(InactiveAppsCard.label(monitor.inactiveMinutes))+.",
                                  symbol: "hourglass") { monitor.quitInactiveApps() }
                }
                Toggle("Auto-quit apps unused for \(InactiveAppsCard.label(monitor.inactiveMinutes))", isOn: Binding(
                    get: { monitor.autoQuitInactive }, set: { monitor.autoQuitInactive = $0 }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
                if !monitor.backgroundApps.isEmpty {
                    confirmButton(confirming: $confirmingQuitBackground,
                                  label: "Quit \(monitor.backgroundApps.count) Background App\(monitor.backgroundApps.count == 1 ? "" : "s")",
                                  confirm: "Quit \(monitor.backgroundApps.map(\.name).prefix(3).joined(separator: ", "))?",
                                  symbol: "moon.zzz") { monitor.quitBackgroundApps() }
                }
            }

            section("Clean") {
                if model.hasResults {
                    if recommended.isEmpty {
                        Label("No safe junk left to clean", systemImage: "checkmark.seal").font(.callout).foregroundStyle(.secondary)
                    } else {
                        confirmButton(confirming: $confirmingClean,
                                      label: "Clean \(Fmt.bytes(recommendedBytes)) of Safe Junk",
                                      confirm: "Move \(recommended.count) caches, logs and installers to the Trash?",
                                      symbol: "sparkles", prominent: true) {
                            model.trash(paths: recommended.map(\.path))
                        }
                    }
                } else {
                    Label("Open DiskSweep and run a scan to find junk", systemImage: "magnifyingglass").font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Label(trashBytes > 0 ? "Trash: \(Fmt.bytes(trashBytes))" : "Trash is empty", systemImage: "trash")
                        .font(.callout)
                    Spacer()
                    if trashBytes > 0 {
                        if confirmingEmpty {
                            Button("Erase \(Fmt.bytes(trashBytes))?") { confirmingEmpty = false; model.emptyTrash() }
                                .buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
                            Button("Cancel") { confirmingEmpty = false }.controlSize(.small)
                        } else {
                            Button(model.isEmptyingTrash ? "Emptying…" : "Empty Trash") { confirmingEmpty = true }
                                .controlSize(.small)
                                .disabled(model.isEmptyingTrash)
                        }
                    }
                }
            }

            Divider()
            HStack {
                Button("Open DiskSweep") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Button("Quit DiskSweep") { NSApp.terminate(nil) }
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            MadeWithLove().font(.caption2).frame(maxWidth: .infinity)
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { monitor.refresh() }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    /// A button that asks "are you sure?" inline, since a menu bar panel can't show dialogs well.
    private func confirmButton(confirming: Binding<Bool>, label: String, confirm: String, symbol: String,
                               prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Group {
            if confirming.wrappedValue {
                VStack(alignment: .leading, spacing: 6) {
                    Text(confirm).font(.caption)
                    HStack {
                        Button("Yes") { confirming.wrappedValue = false; action() }
                            .buttonStyle(.borderedProminent)
                        Button("Cancel") { confirming.wrappedValue = false }
                    }
                    .controlSize(.small)
                }
            } else if prominent {
                Button { confirming.wrappedValue = true } label: { Label(label, systemImage: symbol).frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button { confirming.wrappedValue = true } label: { Label(label, systemImage: symbol) }
                    .controlSize(.small)
            }
        }
    }
}
