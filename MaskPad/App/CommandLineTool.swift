import AppKit

/// The `maskpad` command-line tool: MaskPad's own executable, run with a command instead of as the app.
///
///     maskpad on        # turn the screen mask on, starting MaskPad if needed
///     maskpad status    # print "on" or "off"
///
/// Settings installs it as a link in /usr/local/bin (`CommandLineToolInstaller`); any link to the
/// executable works, as does running the executable inside MaskPad.app directly.
///
/// It never starts a second copy of the app: it opens the matching `maskpad://` URL with this app bundle,
/// which hands it to the running MaskPad (or launches it), and waits for the reply (see `MaskCommand`).
/// There is no `off`: only a person can remove the mask.
///
/// Exit status: 0 on success, 1 if the mask couldn't be turned on, 2 for a usage error, 3 if MaskPad
/// didn't answer.
enum CommandLineTool {
    static let toolName = "maskpad"
    private static let replyTimeout: TimeInterval = 15

    private static let usage = """
        Usage: maskpad <command>

        Commands:
          on        Turn the screen mask on (starts MaskPad if needed)
          status    Print "on" or "off"
          version   Print the MaskPad version

        The mask can only be turned off at the Mac, with the passcode.
        """

    /// The exit status when `arguments` (argv) ask for the command-line tool; nil to start the app.
    ///
    /// The app is launched by Launch Services with no arguments (Xcode adds `-NS...` options), so only an
    /// exact command word, or running it under the name `maskpad`, selects the tool.
    static func run(arguments: [String]) -> Int32? {
        let invokedAsTool = (arguments.first as NSString?)?.lastPathComponent == toolName
        let command = arguments.dropFirst().first
        switch command {
        case "on":
            return turnOn()
        case "status":
            return printStatus()
        case "version", "--version":
            print(appBundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")
            return 0
        case "help", "--help", "-h":
            print(usage)
            return 0
        case nil where invokedAsTool:
            print(usage)
            return 0
        case let other? where invokedAsTool:
            printError("unknown command \"\(other)\"\n\n\(usage)")
            return 2
        default:
            return nil
        }
    }

    private static func turnOn() -> Int32 {
        switch send(.on) {
        case .on?:
            print("The screen mask is on.")
            return 0
        case .alreadyOn?:
            print("The screen mask is already on.")
            return 0
        case .noPasscode?:
            printError("MaskPad has no passcode yet. Set one in MaskPad Settings.")
            return 1
        case .noAccessibility?:
            printError("MaskPad needs Accessibility permission to block the keyboard and mouse. Grant it in MaskPad Settings.")
            return 1
        case .off?, nil:
            printError("MaskPad didn't answer.")
            return 3
        }
    }

    private static func printStatus() -> Int32 {
        // Not running means not masked; don't start MaskPad just to ask.
        guard isAppRunning else {
            print("off")
            return 0
        }
        switch send(.status) {
        case .on?, .alreadyOn?:
            print("on")
            return 0
        case .off?, .noPasscode?, .noAccessibility?:
            print("off")
            return 0
        case nil:
            printError("MaskPad didn't answer.")
            return 3
        }
    }

    private static var isAppRunning: Bool {
        guard let bundleID = appBundle?.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty == false
    }

    /// Opens the command's URL with this app bundle and waits for the reply; nil on failure or timeout.
    private static func send(_ command: MaskCommand) -> MaskCommandResult? {
        let replyID = UUID().uuidString
        let reply = Reply()
        // Observe before opening the URL, so a fast reply isn't missed.
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: MaskCommand.replyNotificationName(for: appBundle?.bundleIdentifier ?? AppIdentity.bundleIdentifier), object: replyID, queue: nil
        ) { notification in
            let raw = notification.userInfo?[MaskCommand.resultKey] as? String
            reply.finish(raw.flatMap(MaskCommandResult.init(rawValue:)))
        }
        defer { DistributedNotificationCenter.default().removeObserver(observer) }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        // A CLI in another app copy must target the primary copy, rather than launch a duplicate.
        let runningURL = appBundle?.bundleIdentifier.flatMap { identifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })?.bundleURL
        }
        guard let appURL = runningURL ?? appBundle?.bundleURL else {
            printError("can't find MaskPad.app; link to the executable inside it.")
            return nil
        }
        NSWorkspace.shared.open(
            [command.url(replyID: replyID, scheme: appBundle?.object(forInfoDictionaryKey: "MaskPadURLScheme") as? String ?? "maskpad")], withApplicationAt: appURL, configuration: configuration
        ) { _, error in
            if let error {
                printError("couldn't reach MaskPad: \(error.localizedDescription)")
                reply.finish(nil)
            }
        }

        let deadline = Date().addingTimeInterval(replyTimeout)
        while reply.isFinished == false, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        return reply.result
    }

    /// The MaskPad.app this executable is in. Through a symbolic link (`/usr/local/bin/maskpad`),
    /// `Bundle.main` is the link's folder, so the real executable path is resolved instead:
    /// MaskPad.app/Contents/MacOS/MaskPad.
    private static let appBundle: Bundle? = {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let executable = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let bundleURL = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard bundleURL.pathExtension == "app" else { return nil }
        return Bundle(url: bundleURL)
    }()

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data("maskpad: \(message)\n".utf8))
    }

    /// The reply, set from the notification (main run loop) or the open completion (another queue).
    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var value: MaskCommandResult?

        var isFinished: Bool { lock.withLock { finished } }
        var result: MaskCommandResult? { lock.withLock { value } }

        func finish(_ result: MaskCommandResult?) {
            lock.withLock {
                guard finished == false else { return }
                finished = true
                value = result
            }
        }
    }
}
