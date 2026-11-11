import IOKit.pwr_mgt
import Testing
@testable import MaskPad

/// Idle auto-engage waits while an app keeps the display awake for a person, but not for MaskPad's own
/// assertion, keep-awake tools, or assertions that only prevent system sleep.
struct DisplaySleepBlockersTests {
    private let display = kIOPMAssertionTypePreventUserIdleDisplaySleep
    private let system = kIOPMAssertionTypePreventUserIdleSystemSleep

    private func watching(_ assertions: [DisplaySleepBlockers.Assertion]) -> Bool {
        DisplaySleepBlockers.isSomeoneWatching(assertions: assertions, ownPID: 100)
    }

    @Test func nothingHeld() {
        #expect(watching([]) == false)
    }

    @Test func videoPlaybackCounts() {
        #expect(watching([.init(pid: 200, processName: "com.apple.WebKit.GPU", type: display)]))
        // The name older apps pass.
        #expect(watching([.init(pid: 200, processName: "VLC", type: kIOPMAssertionTypeNoDisplaySleep)]))
    }

    /// Audio, downloads and backups only keep the system awake; macOS locks the screen during those too.
    @Test func systemSleepAssertionsDoNotCount() {
        #expect(watching([.init(pid: 200, processName: "Music", type: system)]) == false)
        #expect(watching([.init(pid: 200, processName: "WindowServer", type: "UserIsActive")]) == false)
    }

    /// MaskPad holds a display assertion itself while auto-engage is armed.
    @Test func ownAssertionDoesNotCount() {
        #expect(watching([.init(pid: 100, processName: "MaskPad", type: display)]) == false)
    }

    /// Unattended tasks run under keep-awake tools: that is when the mask should turn on.
    @Test func keepAwakeToolsDoNotCount() {
        for name in ["caffeinate", "Amphetamine", "KeepingYouAwake", "Lungo"] {
            #expect(watching([.init(pid: 200, processName: name, type: display)]) == false)
        }
    }

    @Test func releasedAssertionDoesNotCount() {
        #expect(watching([.init(pid: 200, processName: "zoom.us", type: display, isOn: false)]) == false)
    }

    @Test func oneWatcherAmongOthersIsEnough() {
        #expect(watching([
            .init(pid: 100, processName: "MaskPad", type: display),
            .init(pid: 300, processName: "caffeinate", type: display),
            .init(pid: 200, processName: "Music", type: system),
            .init(pid: 400, processName: "Keynote", type: display),
        ]))
    }

    /// The real query answers and is readable (the test host holds no display assertion in tests).
    @Test func currentAssertionsAreReadable() {
        #expect(DisplaySleepBlockers.currentAssertions().allSatisfy { $0.type.isEmpty == false })
    }
}
