import XCTest
@testable import MaskPad

/// System cursor hiding is reference-counted, so hides and shows must stay balanced; otherwise the cursor
/// stays hidden or never hides.
@MainActor
final class MaskCursorHiderTests: XCTestCase {
    private var hides = 0
    private var shows = 0
    private var backgroundEnables = 0

    private func makeHider() -> MaskCursorHider {
        MaskCursorHider(
            hideCursor: { [unowned self] in hides += 1 },
            showCursor: { [unowned self] in shows += 1 },
            enableBackgroundCursorControl: { [unowned self] in backgroundEnables += 1 }
        )
    }

    func testRepeatedHidesHideOnceAndShowOnce() {
        let hider = makeHider()
        hider.hide()
        hider.hide()
        XCTAssertEqual(hides, 1)
        XCTAssertTrue(hider.isHidden)

        hider.show()
        XCTAssertEqual(shows, 1)
        XCTAssertFalse(hider.isHidden)
    }

    func testShowingWhenNotHiddenDoesNothing() {
        let hider = makeHider()
        hider.show()
        XCTAssertEqual(shows, 0)
        hider.hide()
        hider.show()
        hider.show()
        XCTAssertEqual(shows, 1)
    }

    /// Switching apps makes the system show the cursor and `reassert` hides it again; showing must undo
    /// every hide, or the cursor stays hidden.
    func testReassertedHidesAreAllBalancedOnShow() {
        let hider = makeHider()
        hider.hide()
        hider.reassert()
        hider.reassert()
        XCTAssertEqual(hides, 3)
        hider.show()
        XCTAssertEqual(shows, 3)
        // The next cycle starts from zero.
        hider.hide()
        hider.show()
        XCTAssertEqual(shows, 4)
    }

    /// Switching apps while the cursor isn't hidden does not hide it.
    func testReassertWhenNotHiddenDoesNothing() {
        let hider = makeHider()
        hider.reassert()
        XCTAssertEqual(hides, 0)
    }

    /// The background cursor-hiding connection property is set only once.
    func testBackgroundCursorControlIsEnabledOnce() {
        let hider = makeHider()
        hider.hide()
        hider.show()
        hider.hide()
        XCTAssertEqual(backgroundEnables, 1)
        XCTAssertEqual(hides, 2)
    }
}

@MainActor
final class BrightnessRecoveryTests: XCTestCase {
    func testJournalIsDurableBeforeDimmingAndFailedRestoreIsRetained() {
        var disk: [String: Float] = [:]
        var hardware: [String: Float] = ["screen-A": 0.7]
        var allowRestore = false
        let recovery = BrightnessRecovery(load: { disk }, save: { disk = $0; return true },
            read: { hardware[$0] }, write: { id, value in
                XCTAssertEqual(disk[id], 0.7)
                if value > 0 && !allowRestore { return false }
                hardware[id] = value
                return true
            })
        recovery.dim("screen-A")
        XCTAssertEqual(hardware["screen-A"], 0)
        recovery.restore()
        XCTAssertEqual(disk["screen-A"], 0.7)
        allowRestore = true
        recovery.restore()
        XCTAssertTrue(disk.isEmpty)
        XCTAssertEqual(hardware["screen-A"], 0.7)
    }

    func testFailedJournalWriteNeverChangesHardware() {
        var writes = 0
        let recovery = BrightnessRecovery(load: { [:] }, save: { _ in false },
            read: { _ in 0.5 }, write: { _, _ in writes += 1; return true })
        recovery.dim("screen-A")
        XCTAssertEqual(writes, 0)
    }

    func testRestartNeverMapsOriginalOntoDifferentDevice() {
        var disk: [String: Float] = ["screen-A": 0.7]
        var hardware: [String: Float] = ["screen-B": 0.4]
        let recovery = BrightnessRecovery(load: { disk }, save: { disk = $0; return true },
            read: { hardware[$0] }, write: { hardware[$0] = $1; return true })
        recovery.restore()
        XCTAssertEqual(hardware, ["screen-B": 0.4])
        XCTAssertEqual(disk, ["screen-A": 0.7])
        hardware["screen-A"] = 0
        recovery.restore()
        XCTAssertTrue(disk.isEmpty)
        XCTAssertEqual(hardware["screen-A"], 0.7)
    }
}
