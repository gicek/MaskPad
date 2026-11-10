import AppKit
import Testing
@testable import MaskPad

struct MaskInputOriginTests {
    private let screenSharing = "/System/Library/CoreServices/RemoteManagement/screensharingd.bundle/Contents/MacOS/screensharingd"
    private func paths(_ table: [Int32: String]) -> (Int32) -> String? { { table[$0] } }

    @Test func hardwareClicksAreAccepted() {
        for type in [NSEvent.EventType.leftMouseUp, .leftMouseDown] {
            #expect(MaskInputOrigin.isPersonPress(type: type, sourcePID: 0, processPath: paths([:])))
        }
    }

    /// A finger on a touch screen arrives as a direct touch from hardware.
    @Test func touchScreenTapsAreAccepted() {
        #expect(NSEvent.EventType.directTouch.rawValue == 37)
        #expect(MaskInputOrigin.isPersonPress(type: .directTouch, sourcePID: 0, processPath: paths([:])))
        // Touches are only taken from hardware, not from another process (not even Screen Sharing).
        #expect(MaskInputOrigin.isPersonPress(type: .directTouch, sourcePID: 412, processPath: paths([412: screenSharing])) == false)
    }

    @Test func screenSharingClicksAreAccepted() {
        #expect(MaskInputOrigin.isPersonPress(type: .leftMouseUp, sourcePID: 412, processPath: paths([412: screenSharing])))
    }

    /// Computer Use agents and automation post clicks from their own process.
    @Test func clicksFromOtherProcessesAreIgnored() {
        let agent = paths([900: "/Applications/Agent.app/Contents/MacOS/Agent", 901: "/usr/bin/osascript"])
        #expect(MaskInputOrigin.isPersonPress(type: .leftMouseUp, sourcePID: 900, processPath: agent) == false)
        #expect(MaskInputOrigin.isPersonPress(type: .leftMouseUp, sourcePID: 901, processPath: agent) == false)
        // A process that has exited, or a path that only looks similar.
        #expect(MaskInputOrigin.isPersonPress(type: .leftMouseUp, sourcePID: 902, processPath: agent) == false)
        let lookalike = paths([903: "/tmp/System/Library/CoreServices/RemoteManagement/x"])
        #expect(MaskInputOrigin.isPersonPress(type: .leftMouseUp, sourcePID: 903, processPath: lookalike) == false)
    }

    /// Accessibility presses run outside any mouse event; Space on a focused button is a key event.
    @Test func pressesWithoutAMouseClickAreIgnored() {
        #expect(MaskInputOrigin.isPersonPress(type: nil, sourcePID: 0, processPath: paths([:])) == false)
        for type in [NSEvent.EventType.keyDown, .keyUp, .rightMouseUp, .appKitDefined, .systemDefined] {
            #expect(MaskInputOrigin.isPersonPress(type: type, sourcePID: 0, processPath: paths([:])) == false)
        }
    }

    @Test func invalidSourceIDsAreIgnored() {
        #expect(MaskInputOrigin.isPersonPress(type: .leftMouseUp, sourcePID: -1, processPath: paths([:])) == false)
        #expect(MaskInputOrigin.isPersonPress(type: .leftMouseUp, sourcePID: Int64(Int32.max) + 1, processPath: paths([:])) == false)
    }

    @Test func processPathResolvesThisProcess() {
        let path = MaskInputOrigin.processPath(getpid())
        #expect(path?.isEmpty == false)
        #expect(MaskInputOrigin.processPath(0) == nil)
    }
}
