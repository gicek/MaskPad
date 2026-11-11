import Foundation
import IOKit.pwr_mgt

/// Whether something on the Mac is keeping the display awake because a person is watching it: video
/// playback, a video call, a presentation, a game, screen recording or mirroring.
///
/// macOS doesn't start the screen saver or lock while an app holds a `PreventUserIdleDisplaySleep` power
/// assertion, however long the keyboard and mouse stay idle. Idle auto-engage (`MaskAutoEngage`) waits
/// for the same reason: covering the screen in the middle of a film or a meeting helps nobody.
///
/// Two kinds of holder don't count:
/// - **MaskPad itself**, which holds this assertion while auto-engage is armed and while masked.
/// - **Keep-awake tools** (`caffeinate`, Amphetamine and the like). They say "don't sleep", not "someone
///   is watching", and long unattended tasks run under them: exactly when the mask should turn on. They
///   are recognized by process name, so a tool missing from the list makes auto-engage wait.
///
/// Assertions that only prevent system sleep (audio playback, downloads, backups) never count; macOS
/// locks the screen during those too.
enum DisplaySleepBlockers {
    struct Assertion: Equatable {
        var pid: Int32
        var processName: String
        var type: String
        var isOn = true
    }

    /// Process names of tools that keep the Mac awake on the user's request, compared case-insensitively.
    static let keepAwakeTools: Set<String> = [
        "caffeinate", "amphetamine", "keepingyouawake", "lungo", "caffeine", "caffeinated", "theine",
    ]

    /// The current name and the one older apps still pass, which the system reports unchanged.
    private static let displaySleepTypes: Set<String> = [
        kIOPMAssertionTypePreventUserIdleDisplaySleep, kIOPMAssertionTypeNoDisplaySleep,
    ]

    /// Whether an app other than MaskPad or a keep-awake tool keeps the display awake right now.
    static func isSomeoneWatching() -> Bool {
        isSomeoneWatching(assertions: currentAssertions(), ownPID: ProcessInfo.processInfo.processIdentifier)
    }

    /// Pure rule, for tests.
    static func isSomeoneWatching(assertions: [Assertion], ownPID: Int32) -> Bool {
        assertions.contains { assertion in
            assertion.isOn
                && displaySleepTypes.contains(assertion.type)
                && assertion.pid != ownPID
                && keepAwakeTools.contains(assertion.processName.lowercased()) == false
        }
    }

    /// Every power assertion held on the Mac; empty if the system doesn't answer, so auto-engage goes ahead.
    static func currentAssertions() -> [Assertion] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byProcess = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return [] }
        return byProcess.flatMap { pid, assertions in
            assertions.compactMap { assertion in
                guard let type = assertion[kIOPMAssertionTypeKey] as? String else { return nil }
                let level = (assertion[kIOPMAssertionLevelKey] as? NSNumber)?.uint32Value
                return Assertion(
                    pid: pid.int32Value,
                    processName: assertion["Process Name"] as? String ?? "",
                    type: type,
                    isOn: level != UInt32(kIOPMAssertionLevelOff)
                )
            }
        }
    }
}
