import XCTest
import WhoopProtocol
@testable import OpenWhoop

final class CommandsTests: XCTestCase {

    // Golden frame from the verified prototype: TOGGLE_REALTIME_HR(3), seq 0x28, payload [0x01].
    // [0xAA][len=0x0008 LE][crc8][type=35][seq=0x28][cmd=3][payload=0x01][crc32 LE]
    func testToggleRealtimeHRMatchesGoldenFrame() {
        let frame = WhoopCommand.toggleRealtimeHR.frame(seq: 0x28, payload: [0x01])
        let hex = frame.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "aa0800a823280301c1abb7f9")
    }

    func testBuiltFrameIsStructurallyValid() {
        let frame = WhoopCommand.toggleRealtimeHR.frame(seq: 0x28, payload: [0x01])
        let check = verifyFrame(frame)
        XCTAssertTrue(check.ok, "frame must pass crc8 + crc32 verification")
        XCTAssertEqual(check.crc8OK, true)
        XCTAssertEqual(check.crc32OK, true)
    }

    func testFrameFieldOffsets() {
        // type at off 4, seq at off 5, cmd at off 6, payload begins at off 7.
        let frame = WhoopCommand.getBatteryLevel.frame(seq: 0x0A, payload: [0xAB, 0xCD])
        XCTAssertEqual(frame[0], 0xAA)                       // SOF
        XCTAssertEqual(frame[4], 35)                          // type = COMMAND
        XCTAssertEqual(frame[5], 0x0A)                        // seq
        XCTAssertEqual(frame[6], WhoopCommand.getBatteryLevel.rawValue) // cmd = 26
        XCTAssertEqual(frame[7], 0xAB)                        // payload[0]
        XCTAssertEqual(frame[8], 0xCD)                        // payload[1]
    }

    func testLengthHeaderCoversInnerPlusEnvelope() {
        // len u16 LE = (3 + payload.count) + 4
        let frame = WhoopCommand.getHelloHarvard.frame(seq: 0, payload: [0x00])
        let length = Int(frame[1]) | (Int(frame[2]) << 8)
        XCTAssertEqual(length, (3 + 1) + 4)                   // = 8
        XCTAssertEqual(frame.count, length + 4)               // total = len + 4 crc bytes
    }

    func testDefaultPayloadIsSingleZeroByte() {
        // Mirrors the prototype's default payload b"\x00".
        let frame = WhoopCommand.getClock.frame(seq: 0)
        XCTAssertEqual(frame[7], 0x00)
        XCTAssertEqual(frame.count, (3 + 1) + 4 + 4)
    }

    func testCuratedRawValuesAreCorrect() {
        XCTAssertEqual(WhoopCommand.toggleRealtimeHR.rawValue, 3)
        XCTAssertEqual(WhoopCommand.reportVersionInfo.rawValue, 7)
        XCTAssertEqual(WhoopCommand.setClock.rawValue, 10)
        XCTAssertEqual(WhoopCommand.getClock.rawValue, 11)
        XCTAssertEqual(WhoopCommand.sendHistoricalData.rawValue, 22)
        XCTAssertEqual(WhoopCommand.historicalDataResult.rawValue, 23)
        XCTAssertEqual(WhoopCommand.getBatteryLevel.rawValue, 26)
        XCTAssertEqual(WhoopCommand.getDataRange.rawValue, 34)
        XCTAssertEqual(WhoopCommand.getHelloHarvard.rawValue, 35)
        XCTAssertEqual(WhoopCommand.getAdvertisingNameHarvard.rawValue, 76)
        XCTAssertEqual(WhoopCommand.startRawData.rawValue, 81)
        XCTAssertEqual(WhoopCommand.stopRawData.rawValue, 82)
        XCTAssertEqual(WhoopCommand.enterHighFreqSync.rawValue, 96)
        XCTAssertEqual(WhoopCommand.getExtendedBatteryInfo.rawValue, 98)
        XCTAssertEqual(WhoopCommand.toggleIMUMode.rawValue, 106)
        XCTAssertEqual(WhoopCommand.enableOpticalData.rawValue, 107)
    }

    // SET_CLOCK(10), seq 0, payload = <unix u32 LE> + 5 zero pad. Verify the frame is
    // structurally valid (crc8 + crc32) and the payload bytes land at the right offsets.
    func testSetClockFramesValidly() {
        let unix: UInt32 = 0x6650_1234
        let payload: [UInt8] = [0x34, 0x12, 0x50, 0x66, 0, 0, 0, 0, 0]
        let frame = WhoopCommand.setClock.frame(seq: 0, payload: payload)
        let check = verifyFrame(frame)
        XCTAssertTrue(check.ok, "SET_CLOCK frame must pass crc8 + crc32 verification")
        XCTAssertEqual(frame[4], 35)                 // type = COMMAND
        XCTAssertEqual(frame[6], 10)                 // cmd = SET_CLOCK
        XCTAssertEqual(Array(frame[7..<16]), payload) // 9-byte payload
        _ = unix
    }

    // ENTER_HIGH_FREQ_SYNC(96) with an EMPTY payload — the handshake step that unlocks type-47.
    func testEnterHighFreqSyncFramesValidlyWithEmptyPayload() {
        let frame = WhoopCommand.enterHighFreqSync.frame(seq: 0, payload: [])
        let check = verifyFrame(frame)
        XCTAssertTrue(check.ok, "ENTER_HIGH_FREQ_SYNC frame must pass crc8 + crc32 verification")
        XCTAssertEqual(frame[4], 35)                 // type = COMMAND
        XCTAssertEqual(frame[6], 96)                 // cmd = ENTER_HIGH_FREQ_SYNC
        // inner = [type, seq, cmd] only (no payload) → len = 3 + 4 = 7, total = len + 4 = 11
        let length = Int(frame[1]) | (Int(frame[2]) << 8)
        XCTAssertEqual(length, 3 + 4)
        XCTAssertEqual(frame.count, length + 4)
    }

    func testGetAdvertisingNameHarvardFramesValidly() {
        let frame = WhoopCommand.getAdvertisingNameHarvard.frame(seq: 0, payload: [0x00])
        let check = verifyFrame(frame)
        XCTAssertTrue(check.ok)
        XCTAssertEqual(frame[6], 76)                 // cmd = GET_ADVERTISING_NAME_HARVARD
    }

    func testExitHighFreqSyncCommandExists() {
        XCTAssertEqual(WhoopCommand.exitHighFreqSync.rawValue, 97)
        XCTAssertEqual(WhoopCommand.exitHighFreqSync.label, "Exit High-Freq Sync")
    }
    // The framed packet for EXIT (cmd 97, payload [0x00]) is well-formed: 0xAA SOF, type=35.
    func testExitHighFreqSyncFrames() {
        let frame = WhoopCommand.exitHighFreqSync.frame(seq: 1, payload: [0x00])
        XCTAssertEqual(frame.first, 0xAA)
        XCTAssertEqual(frame[4], WhoopCommand.commandType) // inner type byte = 35 (COMMAND)
        XCTAssertEqual(frame[6], 97)                       // inner cmd byte
    }
}
