import XCTest
import WhoopProtocol
@testable import OpenWhoop

/// Unit tests for M6 alarm commands — the sim-verifiable gate.
///
/// Tests pin:
///   • Exact byte layout of setAlarmPayload (7 bytes, little-endian)
///   • Framed setAlarmTime packet passes CRC verification and has cmd byte 66
///   • runAlarm / disableAlarm / getAlarmTime have payload [0x01] and correct cmd bytes
///   • enterHighFreqPayload for interval=180s, duration=7200s = [0x02, 0xB4, 0x00, 0x20, 0x1C]
///   • Smart-wake HR heuristic (pure function, no BLE)
///
/// What cannot be verified in the simulator:
///   • Actual strap buzzing (no motor)
///   • Firmware-alarm persistence across BLE disconnect
///   • Smart-wake background BLE (system-level, requires real device + entitlements)
@MainActor
final class AlarmCommandsTests: XCTestCase {

    // MARK: - setAlarmPayload byte layout

    /// Golden-byte test: epochSec=0x6650_1234 → [0x01, 0x34, 0x12, 0x50, 0x66, 0x00, 0x00]
    /// Layout: [form=0x01] [epoch u32 LE = 0x34,0x12,0x50,0x66] [subsec u16 LE = 0x00,0x00]
    func testSetAlarmPayloadGoldenBytes() {
        let payload = WhoopCommand.setAlarmPayload(epochSec: 0x6650_1234)
        XCTAssertEqual(payload, [0x01, 0x34, 0x12, 0x50, 0x66, 0x00, 0x00])
        XCTAssertEqual(payload.count, 7, "SET_ALARM_TIME payload must be exactly 7 bytes")
    }

    func testSetAlarmPayloadIsLittleEndian() {
        // epochSec = 1 → [0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00]
        let payload = WhoopCommand.setAlarmPayload(epochSec: 1)
        XCTAssertEqual(payload[0], 0x01)          // form byte
        XCTAssertEqual(payload[1], 0x01)          // LSB of epoch
        XCTAssertEqual(payload[2], 0x00)
        XCTAssertEqual(payload[3], 0x00)
        XCTAssertEqual(payload[4], 0x00)          // MSB of epoch
        XCTAssertEqual(payload[5], 0x00)          // subsec LSB
        XCTAssertEqual(payload[6], 0x00)          // subsec MSB
    }

    func testSetAlarmPayloadZeroEpoch() {
        let payload = WhoopCommand.setAlarmPayload(epochSec: 0)
        XCTAssertEqual(payload, [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    }

    func testSetAlarmPayloadMaxEpoch() {
        let payload = WhoopCommand.setAlarmPayload(epochSec: 0xFFFF_FFFF)
        XCTAssertEqual(payload[0], 0x01)
        XCTAssertEqual(Array(payload[1...4]), [0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual(Array(payload[5...6]), [0x00, 0x00])
        XCTAssertEqual(payload.count, 7)
    }

    // MARK: - setAlarmTime frame (cmd 66)

    func testSetAlarmTimeFrameVerifiesAndHasCorrectCmd() {
        let payload = WhoopCommand.setAlarmPayload(epochSec: 1_716_500_000)
        let frame   = WhoopCommand.setAlarmTime.frame(seq: 1, payload: payload)
        let check   = verifyFrame(frame)
        XCTAssertTrue(check.ok,           "setAlarmTime frame must pass crc8 + crc32")
        XCTAssertEqual(check.crc8OK,  true, "header CRC8 must be valid")
        XCTAssertEqual(check.crc32OK, true, "body CRC32 must be valid")
        XCTAssertEqual(frame[4], 35,  "type byte must be COMMAND (35)")
        XCTAssertEqual(frame[6], 66,  "cmd byte must be SET_ALARM_TIME (66)")
    }

    func testSetAlarmTimeRawValue() {
        XCTAssertEqual(WhoopCommand.setAlarmTime.rawValue, 66)
        XCTAssertEqual(WhoopCommand.setAlarmTime.label, "Set Alarm Time")
    }

    // MARK: - runAlarm (cmd 68)

    func testRunAlarmPayloadAndFrame() {
        let frame = WhoopCommand.runAlarm.frame(seq: 1, payload: [0x01])
        let check = verifyFrame(frame)
        XCTAssertTrue(check.ok, "runAlarm frame must pass crc8 + crc32")
        XCTAssertEqual(frame[6], 68,   "cmd byte must be RUN_ALARM (68)")
        XCTAssertEqual(frame[7], 0x01, "runAlarm payload must be [0x01]")
    }

    func testRunAlarmRawValue() {
        XCTAssertEqual(WhoopCommand.runAlarm.rawValue, 68)
        XCTAssertEqual(WhoopCommand.runAlarm.label, "Run Alarm")
    }

    // MARK: - disableAlarm (cmd 69)

    func testDisableAlarmPayloadAndFrame() {
        let frame = WhoopCommand.disableAlarm.frame(seq: 1, payload: [0x01])
        let check = verifyFrame(frame)
        XCTAssertTrue(check.ok, "disableAlarm frame must pass crc8 + crc32")
        XCTAssertEqual(frame[6], 69,   "cmd byte must be DISABLE_ALARM (69)")
        XCTAssertEqual(frame[7], 0x01, "disableAlarm payload must be [0x01]")
    }

    func testDisableAlarmRawValue() {
        XCTAssertEqual(WhoopCommand.disableAlarm.rawValue, 69)
        XCTAssertEqual(WhoopCommand.disableAlarm.label, "Disable Alarm")
    }

    // MARK: - getAlarmTime (cmd 67)

    func testGetAlarmTimePayloadAndFrame() {
        let frame = WhoopCommand.getAlarmTime.frame(seq: 1, payload: [0x01])
        let check = verifyFrame(frame)
        XCTAssertTrue(check.ok, "getAlarmTime frame must pass crc8 + crc32")
        XCTAssertEqual(frame[6], 67,   "cmd byte must be GET_ALARM_TIME (67)")
        XCTAssertEqual(frame[7], 0x01, "getAlarmTime payload must be [0x01]")
    }

    func testGetAlarmTimeRawValue() {
        XCTAssertEqual(WhoopCommand.getAlarmTime.rawValue, 67)
        XCTAssertEqual(WhoopCommand.getAlarmTime.label, "Get Alarm Time")
    }

    // MARK: - ENTER_HIGH_FREQ_SYNC smart-wake payload

    /// interval=180s (0x00B4), duration=7200s (0x1C20)
    /// Expected: [0x02, 0xB4, 0x00, 0x20, 0x1C]
    func testEnterHighFreqSmartWakePayloadGoldenBytes() {
        let payload = SmartAlarmController.enterHighFreqPayload(
            intervalSec: 180,
            durationSec: 7200
        )
        XCTAssertEqual(payload, [0x02, 0xB4, 0x00, 0x20, 0x1C])
        XCTAssertEqual(payload.count, 5, "ENTER_HIGH_FREQ_SYNC smart-wake payload must be 5 bytes")
    }

    func testEnterHighFreqPayloadFormByte() {
        // Form byte 0x02 must always be the first byte regardless of interval/duration.
        let payload = SmartAlarmController.enterHighFreqPayload(intervalSec: 60, durationSec: 120)
        XCTAssertEqual(payload[0], 0x02)
    }

    func testEnterHighFreqPayloadLittleEndian() {
        // interval=0x0102, duration=0x0304 → [0x02, 0x02, 0x01, 0x04, 0x03]
        let payload = SmartAlarmController.enterHighFreqPayload(
            intervalSec: 0x0102,
            durationSec: 0x0304
        )
        XCTAssertEqual(payload, [0x02, 0x02, 0x01, 0x04, 0x03])
    }

    /// The ENTER_HIGH_FREQ_SYNC frame with the smart-wake payload must pass CRC verification.
    func testEnterHighFreqSmartWakeFrameVerifies() {
        let payload = SmartAlarmController.enterHighFreqPayload(
            intervalSec: 180,
            durationSec: 7200
        )
        let frame = WhoopCommand.enterHighFreqSync.frame(seq: 1, payload: payload)
        XCTAssertTrue(verifyFrame(frame).ok, "ENTER_HIGH_FREQ_SYNC smart-wake frame must pass CRC")
        XCTAssertEqual(frame[6], 96, "cmd byte must be ENTER_HIGH_FREQ_SYNC (96)")
    }

    // MARK: - Smart-wake HR heuristic

    func testHRHeuristicReturnsTrueOnRise() {
        // Last sample is 6 bpm above minimum → above the 5 bpm threshold
        let samples: [Double] = [55, 54, 56, 57, 61]
        XCTAssertTrue(SmartAlarmController.evaluateHRWindow(samples: samples))
    }

    func testHRHeuristicReturnsFalseOnFlatHR() {
        let samples: [Double] = [60, 60, 61, 60, 61]
        XCTAssertFalse(SmartAlarmController.evaluateHRWindow(samples: samples))
    }

    func testHRHeuristicReturnsFalseOnTooFewSamples() {
        XCTAssertFalse(SmartAlarmController.evaluateHRWindow(samples: []))
        XCTAssertFalse(SmartAlarmController.evaluateHRWindow(samples: [60, 65]))
    }

    func testHRHeuristicReturnsFalseOnHRDrop() {
        // HR dropping — not a wake signal
        let samples: [Double] = [70, 68, 65, 63, 62]
        XCTAssertFalse(SmartAlarmController.evaluateHRWindow(samples: samples))
    }

    func testHRHeuristicExactlyAtThreshold() {
        // Rise = exactly 5 bpm → true (>= threshold)
        let samples: [Double] = [55, 55, 56, 57, 60]
        XCTAssertTrue(SmartAlarmController.evaluateHRWindow(samples: samples))
    }

    // MARK: - AlarmView next-occurrence helper

    func testNextOccurrenceTodayIfInFuture() {
        // todayAt builds a date for today; if it's in the future it should be today's date
        let future = AlarmView.todayAt(hour: 23, minute: 59)
        // This will sometimes be in the past if the test runs after 23:59 — guard defensively
        if future > Date() {
            // The next occurrence is today
            let calendar = Calendar.current
            XCTAssertEqual(calendar.component(.hour,   from: future), 23)
            XCTAssertEqual(calendar.component(.minute, from: future), 59)
        }
    }

    // MARK: - All four alarm raw values in one place (regression)

    func testAlarmCommandRawValues() {
        XCTAssertEqual(WhoopCommand.setAlarmTime.rawValue,  66)
        XCTAssertEqual(WhoopCommand.getAlarmTime.rawValue,  67)
        XCTAssertEqual(WhoopCommand.runAlarm.rawValue,      68)
        XCTAssertEqual(WhoopCommand.disableAlarm.rawValue,  69)
    }
}
