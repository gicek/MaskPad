import AppKit

@main
enum MaskPadMain {
    static func main() {
        // `maskpad on` and friends: the same executable, run as a command-line tool (see `CommandLineTool`).
        if let status = CommandLineTool.run(arguments: CommandLine.arguments) {
            exit(status)
        }
        // The CLI above is a short-lived client, not another GUI instance. Tests use an empty host.
        let instance: SingleInstanceLock?
        let inbox: InstanceLaunchInbox?
        if TestEnvironment.isRunningInTests {
            instance = nil
            inbox = nil
        } else {
            let pendingInbox = InstanceLaunchInbox()
            do {
                guard let acquired = try SingleInstanceLock.acquireForApplication() else {
                    pendingInbox.stop()
                    runDuplicateLaunchClient()
                    return
                }
                instance = acquired
                inbox = pendingInbox
            } catch {
                pendingInbox.stop()
                FileHandle.standardError.write(Data("MaskPad could not acquire its instance lock: \(error)\n".utf8))
                exit(1)
            }
        }
        let app = NSApplication.shared
        // The test host runs an empty app: no status item, hotkeys, or auto-engage.
        let delegate: NSApplicationDelegate = TestEnvironment.isRunningInTests
            ? TestHostDelegate()
            : MaskPadAppDelegate(launchInbox: inbox)
        app.delegate = delegate
        withExtendedLifetime(instance) {
            withExtendedLifetime(delegate) { app.run() }
        }
    }

    /// A duplicate never initializes mask, shortcuts or menus. It only consumes the launch AppleEvent.
    @MainActor private static func runDuplicateLaunchClient() {
        let app = NSApplication.shared
        let delegate = DuplicateLaunchDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

private final class TestHostDelegate: NSObject, NSApplicationDelegate {}

@MainActor
final class MaskPadAppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenuController?
    private let launchInbox: InstanceLaunchInbox?

    init(launchInbox: InstanceLaunchInbox?) {
        self.launchInbox = launchInbox
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Restore brightness left dimmed by a crash or kill during a previous dim.
        MaskScreenDimmer.restorePendingBrightness()

        MainMenu.install()
        statusMenu = StatusMenuController()

        GlobalHotKeyCenter.shared.onTrigger = { MaskActions.run($0) }
        GlobalHotKeyCenter.shared.start(store: HotKeyBindingStore.shared)
        MaskAutoEngage.shared.start()
        AppUpdater.shared.start()
        launchInbox?.start()

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
