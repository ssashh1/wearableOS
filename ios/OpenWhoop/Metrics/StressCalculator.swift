import Foundation
import WhoopProtocol

// MARK: - StressCalculator
// Baevsky Stress Index from R-R intervals.
// Ported from openwhoop-algos/src/stress.rs (bWanShiTong/openwhoop).
//
// Algorithm:
//   1. Build a histogram of RR intervals in 50ms bins (Baevsky's standard)
//   2. Find the modal bin (most frequent)
//   3. mode    = center of modal bin (ms)
//   4. vr      = (max − min) / 1000  [variability range in seconds]
//   5. a_mode  = (modeFreq / count) × 100  [% of intervals in modal bin]
//   6. score   = a_mode / (2 × vr × mode/1000)   [capped at 10.0]
//
// Score range 0–10: higher = more sympathetic dominance / stress.
// Near-zero variability → maximum stress (10.0).
//
// Returns nil rather than guessing when data is insufficient.

enum StressCalculator {

    // Minimum RR intervals required (matches Rust reference default)
    static let minIntervals = 120

    // 50ms histogram bin width per Baevsky's standard
    private static let binWidthMs = 50

    // MARK: - Public

    // Compute stress score from raw RR intervals in milliseconds.
    static func stress(from intervals: [Int]) -> Double? {
        guard intervals.count >= minIntervals else { return nil }
        return StressParams(intervals)?.score()
    }

    // Compute stress from WhoopProtocol RRInterval records.
    // Prefers real device-measured intervals; falls back to BPM-derived RR when
    // fewer than minIntervals real intervals are available.
    static func stress(from rrRecords: [RRInterval], fallbackHR: [HRSample] = []) -> Double? {
        let values = rrRecords.map(\.rrMs)
        if values.count >= minIntervals {
            return stress(from: values)
        }
        guard fallbackHR.count >= minIntervals else { return nil }
        let derived = fallbackHR.map { Int((60_000.0 / Double($0.bpm)).rounded()) }
        return stress(from: derived)
    }

    // MARK: - Private

    private struct StressParams {
        let min: Int
        let max: Int
        let mode: Int       // center of modal bin (ms)
        let modeFreq: Int
        let count: Int

        init?(_ intervals: [Int]) {
            guard let lo = intervals.min(), let hi = intervals.max() else { return nil }
            self.min = lo
            self.max = hi
            self.count = intervals.count

            // Build 50ms-bin histogram
            var bins: [Int: Int] = [:]
            for rr in intervals {
                bins[rr / StressCalculator.binWidthMs, default: 0] += 1
            }
            guard let (modeBin, modeFreq) = bins.max(by: { $0.value < $1.value }) else { return nil }

            self.modeFreq = modeFreq
            self.mode = modeBin * StressCalculator.binWidthMs + StressCalculator.binWidthMs / 2
        }

        func score() -> Double {
            let vr = Double(max - min) / 1000.0
            // Zero variability → pure sympathetic dominance → maximum stress
            guard vr >= 0.0001 else { return 10.0 }
            let aMode = (Double(modeFreq) / Double(count)) * 100.0
            let raw = aMode / (2.0 * vr * Double(mode) / 1000.0)
            return Swift.min(raw.rounded(), 1000.0) / 100.0
        }
    }
}
