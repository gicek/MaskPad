import XCTest
@testable import MaskPad

final class MaskPasscodeTests: XCTestCase {
    func testFormatRequiresExactlySixASCIIDigits() {
        XCTAssertTrue(MaskPasscode.isValidFormat("012345"))
        XCTAssertFalse(MaskPasscode.isValidFormat("12345"))
        XCTAssertFalse(MaskPasscode.isValidFormat("1234567"))
        XCTAssertFalse(MaskPasscode.isValidFormat("12a456"))
        XCTAssertFalse(MaskPasscode.isValidFormat("１２３４５６"))
        XCTAssertFalse(MaskPasscode.isValidFormat(""))
    }

    func testMakeAndMatchRoundTrip() throws {
        let passcode = try XCTUnwrap(MaskPasscode.make(code: "483920"))
        XCTAssertTrue(passcode.matches("483920"))
        XCTAssertFalse(passcode.matches("483921"))
        XCTAssertFalse(passcode.matches("48392"))
    }

    func testMakeRejectsInvalidFormat() {
        XCTAssertNil(MaskPasscode.make(code: "12345"))
        XCTAssertNil(MaskPasscode.make(code: "abcdef"))
    }

    func testCodableRoundTripKeepsMatching() throws {
        let passcode = try XCTUnwrap(MaskPasscode.make(code: "000000"))
        let data = try JSONEncoder().encode(passcode)
        let decoded = try JSONDecoder().decode(MaskPasscode.self, from: data)
        XCTAssertTrue(decoded.matches("000000"))
        XCTAssertFalse(decoded.matches("000001"))
    }

    func testSaltMakesDigestsDiffer() throws {
        let first = try XCTUnwrap(MaskPasscode.make(code: "123456"))
        let second = try XCTUnwrap(MaskPasscode.make(code: "123456"))
        XCTAssertNotEqual(first.digest, second.digest)
    }
}
