import AppKit
import SwiftUI

/// Settings window (singleton). A menu bar app has no Dock icon, so it must activate itself when shown.
/// A fixed 870 x 630 window; individual pages scroll without moving the navigation.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        // Not while masked: the window would be hidden under the mask and must not be usable anyway.
        guard MaskController.shared.isEngaged == false else { return }
        let isNew = window == nil
        let window = self.window ?? makeWindow()
        self.window = window
        refreshTitle()
        NSApp.activate(ignoringOtherApps: true)
        if isNew { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    func refreshTitle() {
        window?.title = L("MaskPad Settings")
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(settings: .shared, hotKeys: .shared))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = L("MaskPad Settings")
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.minSize = SettingsMetrics.windowSize
        window.maxSize = SettingsMetrics.windowSize
        window.setFrame(NSRect(origin: .zero, size: SettingsMetrics.windowSize), display: false)
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Release the view so the next open re-reads passcode, permission, login item, and Screen Sharing state.
        // The Accessibility guide flies from this window, so cancel it too.
        window = nil
        AccessibilityGuide.shared.cancel()
    }
}
