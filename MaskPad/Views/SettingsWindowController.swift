import AppKit
import SwiftUI

/// Settings window (singleton). A menu bar app has no Dock icon, so it must activate itself when shown.
/// Stable, resizable dimensions keep navigation in place as settings pages change.
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
        NSApp.activate(ignoringOtherApps: true)
        if isNew { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(settings: .shared, hotKeys: .shared))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = L("MaskPad Settings")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.contentMinSize = NSSize(width: 720, height: 500)
        let availableHeight = NSScreen.main?.visibleFrame.height ?? 700
        window.setContentSize(NSSize(width: 800, height: min(640, max(500, availableHeight - 60))))
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
