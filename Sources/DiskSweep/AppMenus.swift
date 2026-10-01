import AppKit
import SwiftUI

/// The menus at the top of the screen: File, Go, Clean, Speed and Help, all wired to DiskSweep's
/// own features. Anything that removes or quits something asks first, like the buttons in the window.
struct DiskSweepCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject var monitor: SystemMonitor

    private var canBrowse: Bool { model.hasResults && model.phase != .scanning }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Scan…") { model.showStartScreen() }
                .keyboardShortcut("n")
                .disabled(model.phase == .scanning)
            Button("Rescan") { model.startScan() }
                .keyboardShortcut("r")
                .disabled(!canBrowse)
            Button("Back to Results") { model.backToResults() }
                .disabled(!(model.hasResults && model.phase == .idle))
            Divider()
            Button("Show Trash in Finder") { model.openTrash() }
        }

        CommandMenu("Go") {
            Button("Back") { model.goBack() }.disabled(!canBrowse || !model.canGoBack)
            Button("Forward") { model.goForward() }.disabled(!canBrowse || !model.canGoForward)
            ForEach(Category.sections, id: \.title) { section in
                Divider()
                Text(section.title)
                ForEach(section.categories) { category in
                    let index = Category.allCases.firstIndex(of: category) ?? 99
                    if index < 9 {
                        Button(category.title) { go(to: category) }
                            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                            .disabled(!canBrowse)
                    } else {
                        Button(category.title) { go(to: category) }
                            .disabled(!canBrowse)
                    }
                }
            }
        }

        CommandMenu("Clean") {
            Button("Select Recommended Junk") {
                go(to: .dashboard)
                model.selectRecommended()
            }
            .disabled(!canBrowse || model.recommendedItems.isEmpty)
            Button("Move Selected to Trash…") { model.confirmingTrash = true }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!canBrowse || model.selection.isEmpty || model.isTrashing)
            Divider()
            Button("Empty Trash…") {
                let size = model.total(for: .trash)
                if confirm("Empty the Trash?",
                           (size > 0 ? "\(Fmt.bytes(size)) will be erased. " : "") + "Items in the Trash are erased for good and can't be put back.",
                           button: "Empty Trash") {
                    model.emptyTrash()
                }
            }
            .disabled(model.isEmptyingTrash)
        }

        CommandMenu("Speed") {
            Button("Free Up Memory…") {
                let targets = monitor.freeUpTargets
                guard !targets.isEmpty else {
                    inform("Nothing to quit right now", "No apps are unused or running in the background. Close tabs in your browser, or quit an app you're not using, to free more memory.")
                    return
                }
                if confirm("Free up memory?", "Quits \(targets.map(\.name).joined(separator: ", ")). They're unused or running in the background. Apps with unsaved work will ask you to save first.", button: "Quit and Free Memory") {
                    monitor.freeUpMemory()
                    if canBrowse { go(to: .memory) }
                }
            }
            .keyboardShortcut("m", modifiers: [.command, .option])
            Button("Quit Inactive Apps…") {
                let inactive = monitor.inactiveApps
                if confirm("Quit \(inactive.count) inactive app\(inactive.count == 1 ? "" : "s")?", inactive.map(\.name).joined(separator: ", ") + "\n\nApps with unsaved work will ask you to save first.", button: "Quit Them") {
                    monitor.quitInactiveApps()
                }
            }
            .disabled(monitor.inactiveApps.isEmpty)
            Button("Quit All Apps…") {
                let apps = monitor.allQuittableApps
                if confirm("Quit all \(apps.count) apps?", apps.map(\.name).joined(separator: ", ") + "\n\nDiskSweep and Finder stay open. Apps with unsaved work will ask you to save first.", button: "Quit All") {
                    monitor.quitAllApps()
                    if canBrowse { go(to: .memory) }
                }
            }
            .disabled(monitor.allQuittableApps.isEmpty)
            Divider()
            Toggle("Quit Inactive Apps Automatically", isOn: $monitor.autoQuitInactive)
            Button("Speed Settings Checklist") { go(to: .speedSettings) }
                .disabled(!canBrowse)
        }

        CommandGroup(replacing: .help) {
            Button("DiskSweep Help") {
                inform("DiskSweep Help", "This app is fucking goated, you don't need help. 🐐")
            }
            .keyboardShortcut("?", modifiers: .command)
            Divider()
            Button("Full Disk Access Settings…") { model.openFullDiskAccessSettings() }
        }
    }

    private func go(to category: Category) {
        model.backToResults()
        model.navigate(to: category)
    }

    private func confirm(_ title: String, _ text: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func inform(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
