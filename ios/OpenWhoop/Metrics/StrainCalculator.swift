import Foundation
import WhoopProtocol

// MARK: - StrainCalculator
// Edwards TRIMP strain mapped to WHOOP's 0–21 scale.
// Ported from openwhoop-algos/src/strain.rs (bWanShiTong/openwhoop).
//
// Algorithm:
//   1. HR Reserve = maxHR − restingHR
//   2. Per sample: classify %HRR into zone 1–5 (weights 1–5)
//   3. TRIMP = Σ (sampleDurationMin × zoneWeight)
//   4. strain = 21 × ln(TRIMP + 1) / ln(7201)
//
// Calibration: 24 h at max HR → TRIMP 7200 → strain 21.0 exactly.
// Returns nil rather than guessing when inputs are insufficient or invalid.

enum StrainCalculator {

    // 10 minutes at 1 Hz — same minimum as the Rust reference implementation
    static let minReadings = 600

    static let maxStrain = 21.0

    // ln(7201): denominator anchoring strain = 21 at TRIMP = 7200
    private static let ln7201 = 8.882_643_961_783_384

    // MARK: - Public

    // Compute strain score from HR samples with explicit max/resting HR.
    // Returns nil if too few samples or if maxHR ≤ restingHR.
    static func strain(from samples: [HRSample], maxHR: Int, restingHR: Int) -> Double? {
        guard samples.count >= minReadings, maxHR > restingHR else { return nil }
        let sampleMin  = sampleDurationMinutes(samples)
        let hrReserve  = Double(maxHR - restingHR)
        let trimp      = edwardsTrimp(samples: samples, restingHR: restingHR, hrReserve: hrReserve, sampleMin: sampleMin)
        return trimpToStrain(trimp)
    }

    // Estimate max HR as the 95th-percentile BPM from a historical sample set.
    // Requires at least 500 samples to avoid biasing toward resting values.
    // Returns nil when data is insufficient.
    static func detectMaxHR(from samples: [HRSample]) -> Int? {
        guard samples.count >= 500 else { return nil }
        let sorted = samples.map(\.bpm).sorted()
        let idx = Int(Double(sorted.count - 1) * 0.95)
        return sorted[idx]
    }

    // MARK: - Zone weight (Edwards, HRR-based)
    // %HRR = (bpm − restingHR) / hrReserve × 100
    // Below 50% → weight 0 (not counted)

    static func zoneWeight(bpm: Int, restingHR: Int, hrReserve: Double) -> Int {
        let pct = (Double(bpm) - Double(restingHR)) / hrReserve * 100.0
        switch pct {
        case 90...:  return 5
        case 80..<90: return 4
        case 70..<80: return 3
        case 60..<70: return 2
        case 50..<60: return 1
        default:      return 0
        }
    }

    // MARK: - Private

    private static func sampleDurationMinutes(_ samples: [HRSample]) -> Double {
        guard samples.count >= 2 else { return 1.0 / 60.0 }
        let dt = abs(samples[1].ts - samples[0].ts)
        return dt == 0 ? (1.0 / 60.0) : Double(dt) / 60.0
    }

    private static func edwardsTrimp(samples: [HRSample], restingHR: Int, hrReserve: Double, sampleMin: Double) -> Double {
        samples.reduce(0.0) { acc, s in
            acc + sampleMin * Double(zoneWeight(bpm: s.bpm, restingHR: restingHR, hrReserve: hrReserve))
        }
    }

    private static func trimpToStrain(_ trimp: Double) -> Double {
        guard trimp > 0 else { return 0 }
        let raw = maxStrain * log(trimp + 1.0) / ln7201
        return (raw * 100).rounded() / 100
    }
}
