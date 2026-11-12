import AppKit

/// Short-lived launch client: forward Apple's initial open/reopen event, then exit without app services.
@MainActor
final class DuplicateLaunchDelegate: NSObject, NSApplicationDelegate {
    private var handledLaunch = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Direct executable launches may have no AppleEvent at all. Allow the launch event queue to
        // drain before the fallback; URL launches finish immediately in application(_:open:).
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard handledLaunch == false else { return }
            reopenPrimary()
            NSApp.terminate(nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handledLaunch = true
        Self.forward(urls)
        NSApp.terminate(nil)
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        handledLaunch = true
        reopenPrimary()
        NSApp.terminate(nil)
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        handledLaunch = true
        reopenPrimary()
        NSApp.terminate(nil)
        return false
    }

    static func forward(_ urls: [URL]) {
        for url in urls where MaskCommand.parse(url) != nil {
            DistributedNotificationCenter.default().postNotificationName(
                AppIdentity.forwardURLNotification, object: url.absoluteString,
                userInfo: nil, deliverImmediately: true
            )
        }
    }

    private func reopenPrimary() {
        DistributedNotificationCenter.default().postNotificationName(
            AppIdentity.reopenNotification, object: nil, userInfo: nil, deliverImmediately: true
        )
    }
}
