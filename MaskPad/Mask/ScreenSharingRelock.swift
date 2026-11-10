import Foundation

/// Detects and changes the "re-lock when Screen Sharing disconnects" behavior.
///
/// A headless Mac (e.g. a Mac mini) used via Screen Sharing is unlocked inside the session; on
/// disconnect, `RestoreMachineState` puts it back to its pre-connection state, i.e. locked. The lock
/// screen restricts capture and input injection, breaking tools working under the mask. This isn't
/// sleep, so a sleep assertion doesn't prevent it.
///
/// Changing it needs admin rights and affects all remote sessions machine-wide, so it's only done with
/// explicit consent via the system auth prompt, with a way to restore the default. The mask passcode covers physical access.
enum ScreenSharingRelock {
    static let preferencesDomain = "com.apple.RemoteManagement"
    static let preferencesPath = "/Library/Preferences/com.apple.RemoteManagement.plist"
    static let restoreKey = "RestoreMachineState"
    /// Screen Sharing (VNC/ARD) listening port.
    static let screenSharingPort = 5900

    /// Whether the preference value means re-lock on disconnect. A missing key is the default: re-lock.
    static func restoresLock(preferenceValue: Any?) -> Bool {
        switch preferenceValue {
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            return ["no", "false", "0"].contains(string.lowercased()) == false
        default:
            return true
        }
    }

    /// Whether `netstat -an -p tcp` output shows an established inbound Screen Sharing connection.
    /// Only the local address column (4th) counts, so outbound connections to another host's 5900 are ignored.
    static func hasInboundSession(netstatOutput: String, port: Int = screenSharingPort) -> Bool {
        let suffix = ".\(port)"
        return netstatOutput.split(whereSeparator: \.isNewline).contains { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 6, fields[0].hasPrefix("tcp") else { return false }
            return fields[3].hasSuffix(suffix) && fields[5] == "ESTABLISHED"
        }
    }

    /// Whether the current setting re-locks on disconnect. The file is world-readable.
    static func currentRestoresLock() -> Bool {
        let domain = preferencesDomain as CFString
        // Read via cfprefsd, not the plist: a fresh `defaults` write may not be on disk yet.
        CFPreferencesSynchronize(domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
        let value = CFPreferencesCopyValue(restoreKey as CFString, domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
        return restoresLock(preferenceValue: value)
    }

    /// Whether a Screen Sharing session is active. If netstat fails, assumes not (avoids false alerts).
    static func isScreenSharingActive() -> Bool {
        guard let output = run("/usr/sbin/netstat", ["-an", "-p", "tcp"]) else { return false }
        return hasInboundSession(netstatOutput: output)
    }

    /// True when connected via Screen Sharing and disconnecting would re-lock. Spawns a process; avoid the main thread.
    static func needsAttention() -> Bool {
        isScreenSharingActive() && currentRestoresLock()
    }

    typealias ChangeOutcome = AdministratorShell.Outcome

    /// Changes the system setting: `false` writes NO (stay unlocked), `true` deletes the key (system default).
    /// Runs with administrator privileges (`AdministratorShell`); the command is a fixed constant with no
    /// external input interpolated.
    static func setRestoresLock(_ restoresLock: Bool, prompt: String) async -> ChangeOutcome {
        let command = restoresLock
            ? "/usr/bin/defaults delete \(preferencesPath) \(restoreKey)"
            : "/usr/bin/defaults write \(preferencesPath) \(restoreKey) -bool NO"
        return await AdministratorShell.run(command, prompt: prompt)
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read before waiting for exit; the reverse deadlocks if output exceeds the pipe buffer.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
