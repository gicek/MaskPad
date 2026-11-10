import AppKit

@main
enum MaskPadMain {
    static func main() {
        // `maskpad on` and friends: the same executable, run as a command-line tool (see `CommandLineTool`).
        if let status = CommandLineTool.run(arguments: CommandLine.arguments) {
            exit(status)
        }
        let app = NSApplication.shared
        // The test host runs an empty app: no status item, hotkeys, or auto-engage.
        let delegate: NSApplicationDelegate = TestEnvironment.isRunningInTests
            ? TestHostDelegate()
            : MaskPadAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

private final class TestHostDelegate: NSObject, NSApplicationDelegate {}

@MainActor
final class MaskPadAppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Restore brightness left dimmed by a crash or kill during a previous dim.
        MaskScreenDimmer.restorePendingBrightness()

        MainMenu.install()
        statusMenu = StatusMenuController()

        GlobalHotKeyCenter.shared.onTrigger = { MaskActions.run($0) }
        GlobalHotKeyCenter.shared.start(store: HotKeyBindingStore.shared)
        MaskAutoEngage.shared.start()
        AppUpdater.shared.start()

        // First run: open settings if there's no passcode or no Accessibility permission.
        if MaskPasscodeStore.shared.hasPasscode == false || MaskController.canBlockLocalInput == false {
            SettingsWindowController.shared.show()
        }
    }

    /// Refuse quit requests (e.g. AppleScript quit) while masked. kill, crashes, and holding the
    /// power button still end the process; that's the documented recovery path, and the login password still protects the Mac.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MaskController.shared.isEngaged ? .terminateCancel : .terminateNow
    }

    /// `maskpad://` URLs from launchers, Shortcuts, `open` or the `maskpad` tool (see `MaskCommand`).
    /// Delivered after `applicationDidFinishLaunching`, also when the URL launched the app.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            MaskActions.handle(url)
        }
    }

    /// Reopening the running app (Finder, `open`, Launchpad) shows settings; otherwise it would appear to do nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return false
    }
}
