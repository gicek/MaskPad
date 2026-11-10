import Foundation

/// Installs the `maskpad` command (`CommandLineTool`) from Settings: a symbolic link in /usr/local/bin,
/// which is on the default PATH, to this app's executable. Like other apps' "install command" buttons,
/// because a dragged-in app can't run anything at install time and no user-writable folder is on the
/// default PATH.
///
/// - Without a password when /usr/local/bin exists and is writable (it can be, after Homebrew on Intel);
///   otherwise through the administrator prompt (`AdministratorShell`), creating the folder if needed.
/// - Only a symbolic link is ever replaced or removed; any other file named maskpad is left alone.
/// - The link points at this copy of the app. If the app is moved, or the link points at another copy
///   (a different install or a development build), Settings shows it and offers to install again.
enum CommandLineToolInstaller {
    static let linkPath = "/usr/local/bin/maskpad"

    enum State: Equatable {
        case notInstalled
        /// The link points at this app's executable.
        case installed
        /// A link to another copy of MaskPad, or to something that no longer exists.
        case otherCopy
        /// Something other than a link is at the path; never touched.
        case otherFile
    }

    /// This app's executable, with symbolic links resolved.
    static var target: String {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().path
    }

    static var state: State { state(linkPath: linkPath, target: target) }

    /// The state of `linkPath` for `target`; separate from the real paths for tests.
    static func state(linkPath: String, target: String, fileManager: FileManager = .default) -> State {
        // attributesOfItem doesn't follow a final symbolic link, so a broken link is still found.
        guard let attributes = try? fileManager.attributesOfItem(atPath: linkPath) else { return .notInstalled }
        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else { return .otherFile }
        let resolved = URL(fileURLWithPath: linkPath).resolvingSymlinksInPath().path
        return resolved == URL(fileURLWithPath: target).resolvingSymlinksInPath().path ? .installed : .otherCopy
    }

    /// Creates or replaces the link. Refuses when another kind of file is at the path.
    static func install(prompt: String) async -> AdministratorShell.Outcome {
        guard state != .otherFile else { return .failed("\(linkPath) is not a symbolic link") }
        let directory = (linkPath as NSString).deletingLastPathComponent
        let fileManager = FileManager.default
        if fileManager.isWritableFile(atPath: directory) {
            do {
                if (try? fileManager.destinationOfSymbolicLink(atPath: linkPath)) != nil {
                    try fileManager.removeItem(atPath: linkPath)
                }
                try fileManager.createSymbolicLink(atPath: linkPath, withDestinationPath: target)
                return .applied
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        let link = AdministratorShell.shellQuoted(linkPath)
        // Re-checked as root: only a missing path or an existing link may be replaced.
        let command = "{ /bin/test ! -e \(link) || /bin/test -L \(link); }"
            + " && /bin/mkdir -p \(AdministratorShell.shellQuoted(directory))"
            + " && /bin/ln -sfn \(AdministratorShell.shellQuoted(target)) \(link)"
        return await AdministratorShell.run(command, prompt: prompt)
    }

    /// Removes the link; never another kind of file.
    static func remove(prompt: String) async -> AdministratorShell.Outcome {
        let current = state
        guard current == .installed || current == .otherCopy else { return .applied }
        let directory = (linkPath as NSString).deletingLastPathComponent
        if FileManager.default.isWritableFile(atPath: directory) {
            do {
                try FileManager.default.removeItem(atPath: linkPath)
                return .applied
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        let link = AdministratorShell.shellQuoted(linkPath)
        return await AdministratorShell.run("/bin/test -L \(link) && /bin/rm \(link)", prompt: prompt)
    }
}
