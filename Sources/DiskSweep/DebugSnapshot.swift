import AppKit
import SwiftUI

/// Developer tool for checking layout: when DISKSWEEP_SNAPSHOT_DIR is set, the app scans the home
/// folder, visits every page and saves a PNG of its own window for each, then quits.
/// Capturing its own window needs no screen-recording permission. Inactive in normal use.
enum DebugSnapshot {
    static var directory: String? { ProcessInfo.processInfo.environment["DISKSWEEP_SNAPSHOT_DIR"] }

    @MainActor
    static func run(model: AppModel, monitor: SystemMonitor) async {
        // Developer test for the updater: install the waiting update immediately.
        if ProcessInfo.processInfo.environment["DISKSWEEP_TEST_UPDATE"] != nil {
            try? await Task.sleep(for: .seconds(1))
            model.installUpdate()
            return
        }
        guard let directory else { return }
        try? await Task.sleep(for: .seconds(1))
        if let window = mainWindow {
            window.setFrame(NSRect(x: 80, y: 80, width: 1280, height: 800), display: true)
        }
        capture(to: directory + "/00-start.png")

        model.scope = .home
        model.startScan()
        try? await Task.sleep(for: .seconds(6))
        capture(to: directory + "/01-scanning.png")
        while model.phase != .done { try? await Task.sleep(for: .milliseconds(500)) }

        if let tick = ProcessInfo.processInfo.environment["DISKSWEEP_SNAPSHOT_TICK"] { model.selectInSpaceLens(tick) }
        let only = ProcessInfo.processInfo.environment["DISKSWEEP_SNAPSHOT_PAGES"]?.split(separator: ",").map(String.init)
        for (index, category) in Category.allCases.enumerated() where only?.contains(category.rawValue) ?? true {
            model.navigate(to: category)
            try? await Task.sleep(for: .seconds(1.5))
            capture(to: directory + String(format: "/%02d-%@.png", index + 2, category.rawValue))
        }
        if only == nil || only!.contains("menubar") { captureMenuBarPanel(model: model, monitor: monitor, to: directory + "/99-menubar.png") }
        NSApp.terminate(nil)
    }

    @MainActor
    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.frame.width > 600 }
    }

    /// Renders the menu bar panel in an off-screen window, since its popover can't be opened here.
    @MainActor
    private static func captureMenuBarPanel(model: AppModel, monitor: SystemMonitor, to path: String) {
        let host = NSHostingView(rootView: MenuBarPanel().environmentObject(model).environmentObject(monitor)
            .background(Color(nsColor: .windowBackgroundColor)))
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        window.orderOut(nil)
    }

    @MainActor
    private static func capture(to path: String) {
        guard let window = mainWindow,
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
