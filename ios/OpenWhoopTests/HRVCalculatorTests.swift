import XCTest
@testable import OpenWhoop

final class HRVCalculatorTests: XCTestCase {

    // MARK: - Helpers

    /// Builds an [RRSample] with uniformly spaced timestamps (1 s apart per sample).
    private func samples(_ values: [Int], startDate: Date = Date()) -> [RRSample] {
        values.enumerated().map { i, v in
            RRSample(ts: startDate.addingTimeInterval(Double(i)), rrMs: v)
        }
    }

    // MARK: - RMSSD([Int]) — stored-data overload

    func testRMSSD_stableIntervals_lowValue() {
        // All intervals equal → successive differences = 0 → RMSSD = 0
        let rr = Array(repeating: 800, count: 80)
        let result = HRVCalculator.rmssd(rr, minPairs: 60)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 0.0, accuracy: 0.001)
    }

    func testRMSSD_variedIntervals_reasonableValue() {
        // Alternating 750/850 → successive diff always 100 → RMSSD = 100
        var rr = [Int]()
        for _ in 0..<80 { rr.append(750); rr.append(850) }
        let result = HRVCalculator.rmssd(rr, minPairs: 60)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 100.0, accuracy: 1.0)
    }

    func testRMSSD_tooFewPairs_returnsNil() {
        let rr = Array(repeating: 800, count: 10)
        XCTAssertNil(HRVCalculator.rmssd(rr, minPairs: 15))
    }

    func testRMSSD_outOfRangeIntervals_rejected() {
        // Only 10 in-range values + many out-of-range
        var rr = Array(repeating: 800, count: 10)
        rr += Array(repeating: 2500, count: 200)  // 2500ms > maxRR=2000ms, all rejected
        // After range filter only 10 remain — not enough pairs for minPairs=60
        XCTAssertNil(HRVCalculator.rmssd(rr, minPairs: 60))
    }

    func testRMSSD_malikRejection_reducesInflation() {
        // Without Malik: 800→1700 diff=900 would massively inflate RMSSD
        // With Malik (threshold=200ms): that pair is rejected, leaving stable pairs
        var rr = [Int]()
        for _ in 0..<40 { rr.append(800); rr.append(802) }  // stable pairs, diff=2
        rr.insert(1700, at: 20)  // single missed-beat interval (in range but huge diff)
        let result = HRVCalculator.rmssd(rr, minPairs: 15)
        // Result should be close to 2ms (the stable pairs dominate), not inflated by the 1700
        XCTAssertNotNil(result)
        XCTAssertLessThan(result!, 20.0, "Malik rejection should prevent 1700ms outlier from inflating RMSSD above 20ms")
    }

    func testRMSSD_tooManyBadPairs_returnsNil() {
        // Alternating 800/1700 — every pair spans the missed-beat → Malik rejects all → nil
        var rr = [Int]()
        for _ in 0..<100 { rr.append(800); rr.append(1700) }
        XCTAssertNil(HRVCalculator.rmssd(rr, minPairs: 15))
    }

    func testRMSSD_knownValue() {
        // rr = [800, 810, 790, 810, 790, ...] (71 elements → 70 pairs)
        // pair 0: diff=10, sq=100; pairs 1-69: diff=±20, sq=400 each
        // RMSSD = sqrt((100 + 69*400) / 70) = sqrt(27700/70) = sqrt(395.71) ≈ 19.89
        var rr = [Int]()
        rr.append(800)
        for i in 0..<70 {
            rr.append(i % 2 == 0 ? 810 : 790)
        }
        let result = HRVCalculator.rmssd(rr, minPairs: 60)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 19.89, accuracy: 0.01)
    }

    // MARK: - RMSSD([RRSample]) — live overload with timestamps

    func testRMSSD_samples_stableNoTimegap() {
        let s = samples(Array(repeating: 800, count: 80))
        let result = HRVCalculator.rmssd(s, minPairs: 15)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 0.0, accuracy: 0.001)
    }

    func testRMSSD_samples_timegapRejected() {
        // Two contiguous batches separated by 60 seconds — the boundary pair is rejected
        var base = Date()
        var s = samples(Array(repeating: 800, count: 30), startDate: base)
        base = base.addingTimeInterval(30 + 60)  // 60s gap after last sample
        s += samples(Array(repeating: 800, count: 30), startDate: base)
        // The single pair straddling the 60s gap is rejected; the rest are stable
        let result = HRVCalculator.rmssd(s, minPairs: 15)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 0.0, accuracy: 0.001, "Cross-session pair rejected; stable pairs give RMSSD=0")
    }

    func testRMSSD_samples_tooFewPairs_returnsNil() {
        let s = samples([800, 802, 799])
        XCTAssertNil(HRVCalculator.rmssd(s, minPairs: 15))
    }

    // MARK: - SDNN

    func testSDNN_allEqual_zero() {
        let rr = Array(repeating: 1000, count: 80)
        let result = HRVCalculator.sdnn(rr, minIntervals: 60)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 0.0, accuracy: 0.001)
    }

    func testSDNN_knownValue() {
        // [900, 1100] repeated 40 times: mean=1000, deviations=±100
        // variance = (40*10000 + 40*10000) / (80-1) = 800000/79 ≈ 10126.58
        // SDNN = sqrt(10126.58) ≈ 100.63
        let rr = Array(repeating: [900, 1100], count: 40).flatMap { $0 }
        let result = HRVCalculator.sdnn(rr, minIntervals: 60)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 100.63, accuracy: 0.5)
    }

    func testSDNN_tooFewIntervals_returnsNil() {
        let rr = [800, 810, 790]
        XCTAssertNil(HRVCalculator.sdnn(rr, minIntervals: 60))
    }

    func testSDNN_outOfRangeRejected() {
        // Mix of valid + out-of-range (>2000ms); only valid remain
        let valid = Array(repeating: 800, count: 80)
        let noise = Array(repeating: 2500, count: 50)
        let result = HRVCalculator.sdnn(valid + noise, minIntervals: 60)
        XCTAssertNotNil(result, "Enough valid intervals remain after range filter")
        XCTAssertEqual(result!, 0.0, accuracy: 0.001, "All valid intervals equal → SDNN=0")
    }

    // MARK: - maxRR constant

    func testMaxRR_is2000() {
        XCTAssertEqual(HRVCalculator.maxRR, 2000, "maxRR must be 2000ms (30 BPM floor)")
    }

    // MARK: - RMSSDDebug

    func testRMSSDDebug_countsRejections() {
        // 20 stable pairs + 1 out-of-range interval + 1 Malik-violating pair
        var rr = [Int]()
        rr.append(800)
        for _ in 0..<20 { rr.append(802) }  // stable
        rr.append(2500)                       // out of range
        rr.append(800)
        rr.append(1500)                       // Malik violation (diff=700)
        rr.append(800)
        let s = samples(rr)
        let dbg = HRVCalculator.rmssdDebug(s, minPairs: 15)
        XCTAssertGreaterThan(dbg.rejectedByRange, 0, "2500ms interval should be rejected by range filter")
        XCTAssertGreaterThan(dbg.rejectedByMalik, 0, "800→1500 diff=700ms should be rejected by Malik")
    }
}
