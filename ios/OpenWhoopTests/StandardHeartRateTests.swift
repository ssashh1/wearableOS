import XCTest
@testable import OpenWhoop

final class StandardHeartRateTests: XCTestCase {

    // MARK: - Basic 8-bit HR, no R-R

    func testEightBitHRNoRR() {
        // flags=0x00: 8-bit HR, no energy expended, no R-R
        let result = StandardHeartRate.parse([0x00, 70])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.hr, 70)
        XCTAssertEqual(result?.rr, [])
    }

    // MARK: - 16-bit HR (flags bit 0 set)

    func testSixteenBitHRNoRR() {
        // flags=0x01: 16-bit HR=256 (0x00, 0x01 LE), no R-R
        let result = StandardHeartRate.parse([0x01, 0x00, 0x01])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.hr, 256)
        XCTAssertEqual(result?.rr, [])
    }

    func testSixteenBitHRTypical() {
        // flags=0x01: 16-bit HR=72 (0x48, 0x00 LE)
        let result = StandardHeartRate.parse([0x01, 0x48, 0x00])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.hr, 72)
        XCTAssertEqual(result?.rr, [])
    }

    // MARK: - Energy Expended present (bit 3) → skipped, R-R still parsed after

    func testEnergyExpendedSkippedThenRRParsed() {
        // flags=0x18: bit3=energy expended, bit4=R-R present, 8-bit HR
        // Layout: [flags=0x18][hr=60][ee_lo=0xFF][ee_hi=0xFF][rr_lo=0x20][rr_hi=0x04]
        // rr raw = 0x0420 = 1056 → (1056/1024*1000).rounded() = 1031ms
        let flags: UInt8 = 0x18  // bits 3 and 4 set
        let result = StandardHeartRate.parse([flags, 60, 0xFF, 0xFF, 0x20, 0x04])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.hr, 60)
        XCTAssertEqual(result?.rr.count, 1)
        let expected = Int((Double(0x0420) / 1024.0 * 1000.0).rounded())
        XCTAssertEqual(result?.rr.first, expected)
    }

    // MARK: - R-R present (bit 4), single pair

    func testRRPresentSinglePair() {
        // flags=0x10: bit4=R-R present, 8-bit HR=75
        // R-R raw = 850ms → raw value = round(850 * 1024 / 1000) = 870 = 0x0366
        // Back-check: (0x0366 / 1024.0 * 1000.0).rounded() = (870/1024*1000).rounded() = 850
        let rrRaw: Int = Int((850.0 * 1024.0 / 1000.0).rounded())  // = 870 = 0x0366
        let lo = UInt8(rrRaw & 0xFF)   // 0x66
        let hi = UInt8(rrRaw >> 8)     // 0x03
        let result = StandardHeartRate.parse([0x10, 75, lo, hi])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.hr, 75)
        XCTAssertEqual(result?.rr.count, 1)
        // The decode should round-trip to ~850ms
        let expected = Int((Double(rrRaw) / 1024.0 * 1000.0).rounded())
        XCTAssertEqual(result?.rr.first, expected)
    }

    func testRRPresentMultiplePairs() {
        // flags=0x10: R-R present, 8-bit HR=80
        // Two R-R values: raw 0x0352 (850ms-ish), raw 0x038E (910ms-ish)
        // These are the exact raws from the hr72rr fixture (which decode to 850, 910 ms)
        let result = StandardHeartRate.parse([0x10, 80, 0x52, 0x03, 0x8E, 0x03])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.hr, 80)
        XCTAssertEqual(result?.rr.count, 2)
        let rr1 = Int((Double(0x0352) / 1024.0 * 1000.0).rounded())
        let rr2 = Int((Double(0x038E) / 1024.0 * 1000.0).rounded())
        XCTAssertEqual(result?.rr, [rr1, rr2])
    }

    // MARK: - RR scaling: 1/1024 second → ms

    func testRRScaling1024SecondToMs() {
        // 1024 units = 1 second = 1000ms, so raw=1024 should decode to 1000ms
        let flags: UInt8 = 0x10
        let rawRR: Int = 1024  // exactly 1 second
        let lo = UInt8(rawRR & 0xFF)  // 0x00
        let hi = UInt8(rawRR >> 8)    // 0x04
        let result = StandardHeartRate.parse([flags, 65, lo, hi])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.rr.first, 1000)
    }

    func testRRScalingHalfSecond() {
        // raw=512 → 512/1024*1000 = 500ms
        let flags: UInt8 = 0x10
        let result = StandardHeartRate.parse([flags, 65, 0x00, 0x02])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.rr.first, 500)
    }

    // MARK: - Edge cases

    func testEmptyInputReturnsNil() {
        XCTAssertNil(StandardHeartRate.parse([]))
    }

    func testFlagsOnlyNoHRByteReturnsNil() {
        // flags byte present but no HR byte
        XCTAssertNil(StandardHeartRate.parse([0x00]))
    }

    func testSixteenBitHRMissingSecondByteReturnsNil() {
        // flags=0x01 (16-bit) but only one HR byte present
        XCTAssertNil(StandardHeartRate.parse([0x01, 0x48]))
    }
}
