import Foundation

/// Runs a shell command as root after the system's administrator password prompt, through osascript
/// `do shell script … with administrator privileges`. Used for the few system changes MaskPad offers:
/// the Screen Sharing relock setting and installing the `maskpad` command.
///
/// Commands are built by the callers from fixed strings; anything variable in them (a path) must be
/// passed through `shellQuoted`.
enum AdministratorShell {
    enum Outcome: Equatable {
        case applied
        case cancelled
        case failed(String)
    }

    /// Runs `command` off the main thread. `prompt` is shown in the password dialog.
    static func run(_ command: String, prompt: String) async -> Outcome {
        let script = "do shell script \"\(appleScriptEscaped(command))\" with prompt \"\(appleScriptEscaped(prompt))\" with administrator privileges"
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let stderr = Pipe()
            process.standardError = stderr
            process.standardOutput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return .failed(error.localizedDescription)
            }
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return outcome(status: process.terminationStatus, stderr: String(decoding: data, as: UTF8.self))
        }.value
    }

    /// Maps osascript's exit status and stderr to an outcome. Cancelling the auth prompt yields AppleScript error -128.
    static func outcome(status: Int32, stderr: String) -> Outcome {
        if status == 0 { return .applied }
        if stderr.contains("-128") { return .cancelled }
        return .failed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func appleScriptEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Quotes `text` as one word for /bin/sh: in single quotes, with each single quote written as '\''.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
