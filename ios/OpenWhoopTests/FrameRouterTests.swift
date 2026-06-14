import XCTest
import WhoopProtocol
@testable import OpenWhoop

final class FrameRouterTests: XCTestCase {

    private func bytes(_ hex: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    // Real REALTIME_DATA frame from capture.jsonl: HR=60, no R-R.
    private let hr60 = "aa1800ff28020f3de10128663c00000000000000000001010d844e7c"
    // Real HR frame mutated to HR=72, R-R=[850,910] (CRCs recomputed, crc_ok=true).
    private let hr72rr = "aa1800ff28020f3de1012866480252038e0300000000010182605bf0"
    // Real COMMAND_RESPONSE / GET_BATTERY_LEVEL → 25.5%.
    private let batteryResp = "aa10005724231a0a01ff0000000000002f1ea284"
    // Real EVENT: RAW_DATA_COLLECTION_ON(46).
    private let eventRawOn = "aa10005730262e0019d67e676817000016376706"
    // CRC-correct EVENT: BLE_BONDED(23).
    private let eventBonded = "aa110042303017170019d67e6768170000fa67bd08"

    @MainActor func testRealtimeHRUpdatesHeartRate() {
        let state = LiveState()
        let router = FrameRouter(state: state)
        router.handle(frame: bytes(hr60))
        XCTAssertEqual(state.heartRate, 60)
        XCTAssertEqual(state.rr, [])
        XCTAssertEqual(state.lastFrameType, "REALTIME_DATA")
    }

    @MainActor func testRealtimeWithRRUpdatesHeartRateAndRR() {
        let state = LiveState()
        let router = FrameRouter(state: state)
        router.handle(frame: bytes(hr72rr))
        XCTAssertEqual(state.heartRate, 72)
        XCTAssertEqual(state.rr, [850, 910])
    }

    @MainActor func testBatteryResponseUpdatesBatteryPct() {
        let state = LiveState()
        let router = FrameRouter(state: state)
        router.handle(frame: bytes(batteryResp))
        XCTAssertEqual(state.batteryPct, 25.5)
        XCTAssertEqual(state.lastFrameType, "COMMAND_RESPONSE")
    }

    @MainActor func testBondedEventFlipsBondedTrue() {
        let state = LiveState()
        XCTAssertFalse(state.bonded)
        let router = FrameRouter(state: state)
        router.handle(frame: bytes(eventBonded))
        XCTAssertTrue(state.bonded, "BLE_BONDED(23) event must set bonded=true")
        XCTAssertEqual(state.lastEvent, "BLE_BONDED(23)")
    }

    @MainActor func testNonBondedEventDoesNotFlipBonded() {
        let state = LiveState()
        let router = FrameRouter(state: state)
        router.handle(frame: bytes(eventRawOn))
        XCTAssertFalse(state.bonded)
        XCTAssertEqual(state.lastEvent, "RAW_DATA_COLLECTION_ON(46)")
    }

    // Regression: routing a REALTIME_DATA frame with rr_count=0 must NOT wipe
    // R-R intervals that were previously populated from another source (e.g. 0x2A37).
    // Frame: real capture.jsonl entry "aa1800ff28020f3de10128663c00000000000000000001010d844e7c"
    // (HR=60, rr_count=0, rr_intervals=[]).  Confirmed via parseFrame below.
    @MainActor func testRealtimeDataZeroRRDoesNotClobberPriorRR() {
        // Verify via parseFrame that the fixture frame has empty rr_intervals.
        let frameBytes = bytes(hr60)
        let parsed = parseFrame(frameBytes)
        XCTAssertTrue(parsed.ok, "fixture frame must parse OK")
        XCTAssertTrue(parsed.crcOK == true, "fixture frame must have valid CRC")
        let rrFromFrame = parsed.parsed["rr_intervals"]?.intArrayValue ?? []
        XCTAssertTrue(rrFromFrame.isEmpty, "hr60 fixture must have empty rr_intervals (rr_count=0)")

        let state = LiveState()
        let router = FrameRouter(state: state)
        // Seed state with R-R from a frame that actually carries intervals.
        router.handle(frame: bytes(hr72rr))
        XCTAssertEqual(state.rr, [850, 910], "seeded R-R must be present before routing zero-RR frame")

        // Route the rr_count=0 REALTIME_DATA frame — state.rr must survive.
        router.handle(frame: frameBytes)
        XCTAssertEqual(state.rr, [850, 910],
                       "routing REALTIME_DATA with rr_count=0 must NOT clobber prior R-R")
    }

    @MainActor func testCRCFailedFrameIsIgnored() {
        let state = LiveState()
        let router = FrameRouter(state: state)
        // Corrupt the last (crc32) byte of the HR=60 frame so verification fails.
        var corrupt = bytes(hr60)
        corrupt[corrupt.count - 1] ^= 0xFF
        router.handle(frame: corrupt)
        XCTAssertNil(state.heartRate, "frame with bad CRC must not update state")
    }

    @MainActor func testParseFrameOracleAgreesWithRouter() {
        // The router must surface exactly what parseFrame reports — parseFrame is the oracle.
        let parsed = parseFrame(bytes(hr72rr))
        XCTAssertEqual(parsed.parsed["heart_rate"]?.intValue, 72)
        XCTAssertEqual(parsed.parsed["rr_intervals"]?.intArrayValue, [850, 910])
        let state = LiveState()
        FrameRouter(state: state).handle(frame: bytes(hr72rr))
        XCTAssertEqual(state.heartRate, parsed.parsed["heart_rate"]?.intValue)
        XCTAssertEqual(state.rr, parsed.parsed["rr_intervals"]?.intArrayValue)
    }
}
