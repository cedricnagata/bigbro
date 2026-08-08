import Foundation
import XCTest

@testable import BigBroControl

final class FramingTests: XCTestCase {
    func testAFrameIsALengthPrefixFollowedByTheBody() throws {
        let body = Data(#"{"command":"status"}"#.utf8)
        let frame = Framing.frame(body)

        XCTAssertEqual(frame.count, 4 + body.count)
        XCTAssertEqual(Array(frame.prefix(4)), [0, 0, 0, UInt8(body.count)])
        XCTAssertEqual(frame.suffix(from: 4), body)
    }

    func testTheLengthIsBigEndian() throws {
        // 0x0102 = 258. Little-endian would read this back as 513.
        let frame = Framing.frame(Data(repeating: 0x41, count: 258))
        XCTAssertEqual(try Framing.bodyLength(of: frame.prefix(4)), 258)
    }

    func testAnEmptyBodyRoundTrips() throws {
        let frame = Framing.frame(Data())
        XCTAssertEqual(frame.count, 4)
        XCTAssertEqual(try Framing.bodyLength(of: frame), 0)
    }

    func testAnAbsurdLengthIsRejectedRatherThanAllocated() {
        // A desync or a hostile peer. Reading it as a size would try to allocate it.
        let prefix = Data([0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try Framing.bodyLength(of: prefix)) { error in
            guard case ControlError.malformedFrame = error else {
                return XCTFail("expected malformedFrame, got \(error)")
            }
        }
    }

    func testATruncatedPrefixIsRejected() {
        XCTAssertThrowsError(try Framing.bodyLength(of: Data([0, 0])))
    }
}

final class FormattingTests: XCTestCase {
    /// The same table as `tests/test_memory.py::test_human`. Both sides assert it
    /// because the whole point of porting `human()` by hand was that the app and
    /// `bigbro status` must never render the same integer differently.
    func testHumanMatchesTheDaemon() {
        XCTAssertEqual(Formatting.human(nil), "?")
        XCTAssertEqual(Formatting.human(0), "0 B")
        XCTAssertEqual(Formatting.human(512), "512 B")
        XCTAssertEqual(Formatting.human(2048), "2 KB")
        XCTAssertEqual(Formatting.human(5 * 1024 * 1024), "5.0 MB")
        XCTAssertEqual(Formatting.human(12 * 1024 * 1024 * 1024), "12.0 GB")
    }

    func testUnknownIsAQuestionMarkNotZero() {
        // "0 B" would read as "using nothing", which is a different claim.
        XCTAssertEqual(Formatting.human(nil), "?")
        XCTAssertNotEqual(Formatting.human(nil), "0 B")
    }
}
