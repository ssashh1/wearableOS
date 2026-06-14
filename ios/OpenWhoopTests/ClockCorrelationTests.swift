import XCTest
import WhoopProtocol
import WhoopStore
@testable import OpenWhoop

final class ClockCorrelationTests: XCTestCase {

    /// Build a real GET_CLOCK COMMAND_RESPONSE frame (type 36, cmd 11).
    private func clockFrame(device: UInt32) -> [UInt8] {
        var pay: [UInt8] = [0x0a, 0x01]
        pay += [UInt8(device & 0xFF), UInt8((device >> 8) & 0xFF),
                UInt8((device >> 16) & 0xFF), UInt8((device >> 24) & 0xFF)]
        return frameFromPayload(pay, type: 36, seq: 1, cmd: 11)
    }

    func testClockRefFromGetClockResponse() {
        let parsed = parseFrame(clockFrame(device: 1_700_000_000))
        XCTAssertEqual(parsed.parsed["clock"]?.intValue, 1_700_000_000,
                       "fixture must decode a GET_CLOCK clock value")
        let ref = ClockCorrelation.clockRef(from: parsed, wall: 1_716_400_000)
        XCTAssertEqual(ref, ClockRef(device: 1_700_000_000, wall: 1_716_400_000))
    }

    func testNonClockFrameReturnsNil() {
        // A frame with no "clock" key → nil.
        let ref = ClockCorrelation.clockRef(
            from: parseFrame([0x00, 0x01, 0x02]), wall: 1_716_400_000)
        XCTAssertNil(ref)
    }
}
