import XCTest
@testable import OpenWhoop

final class StressCalculatorTests: XCTestCase {

    // MARK: - Minimum count guard

    func testStress_tooFewIntervals_returnsNil() {
        let rr = Array(repeating: 800, count: 50)
        XCTAssertNil(StressCalculator.stress(from: rr))
    }

    func testStress_lowerMin_returnsResultWithFewerIntervals() {
        let rr = Array(repeating: 800, count: 40)
        XCTAssertNil(StressCalculator.stress(from: rr))
        XCTAssertNotNil(StressCalculator.stress(from: rr, min: 30))
    }

    // MARK: - Range filtering

    func testStress_outOfRangeRejected_preventsDistortion() {
        // 120 valid 800ms intervals + one low (250ms) and one high (2500ms) outlier.
        // Without filtering: vr = (2500-250)/1000 = 2.25s → SI collapses to ~0.
        // With filtering:    all clean intervals are identical → vr=0 → score=10.0.
        var rr = Array(repeating: 800, count: 120)
        rr.append(250)   // below minRR=300
        rr.append(2500)  // above maxRR=2000
        let result = StressCalculator.stress(from: rr)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 10.0, accuracy: 0.001)
    }

    func testStress_tooFewAfterRangeFilter_returnsNil() {
        // Only 50 valid intervals; the other 100 are out of range.
        let valid = Array(repeating: 800, count: 50)
        let noise = Array(repeating: 2500, count: 100)
        XCTAssertNil(StressCalculator.stress(from: valid + noise))
    }

    // MARK: - Edge cases

    func testStress_zeroVariability_returnsMaxStress() {
        // Perfectly stable RR → vr=0 → zero-variability guard fires → score=10.0.
        // Physiologically: rigid HR with no variability = extreme sympathetic dominance.
        let rr = Array(repeating: 800, count: 120)
        let result = StressCalculator.stress(from: rr)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 10.0, accuracy: 0.001)
    }

    func testStress_scoreAlwaysInRange() {
        // High variability (600ms to 1195ms in 5ms steps): many bins, each with equal
        // frequency → low aMode → low SI → score near 0 but still in [0, 10].
        let rr = (0..<120).map { 600 + $0 * 5 }
        let result = StressCalculator.stress(from: rr)
        XCTAssertNotNil(result)
        XCTAssertGreaterThanOrEqual(result!, 0.0)
        XCTAssertLessThanOrEqual(result!, 10.0)
    }

    // MARK: - Known value

    func testStress_knownValue() {
        // 70 × 800ms + 50 × 1000ms (120 total, all in range)
        //
        // Histogram (50ms bins):
        //   bin 16 (800ms → 800/50=16): center = 16*50+25 = 825ms, count = 70  ← MODE
        //   bin 20 (1000ms → 1000/50=20): center = 20*50+25 = 1025ms, count = 50
        //
        // aMode  = (70/120) * 100 = 58.333…%
        // vr     = (1000 - 800) / 1000 = 0.2s
        // mode   = 825ms = 0.825s
        // raw SI = 58.333 / (2 × 0.2 × 0.825) = 58.333 / 0.33 = 176.77
        //        → rounded = 177, capped = 177, score = 177/100 = 1.77
        let rr = Array(repeating: 800, count: 70) + Array(repeating: 1000, count: 50)
        let result = StressCalculator.stress(from: rr)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 1.77, accuracy: 0.01)
    }
}
