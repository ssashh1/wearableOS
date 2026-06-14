import Foundation
import WhoopProtocol

// Purely local, server-free metric computations derived from raw sensor data.
// Every value here is calculated directly from collected samples — nothing is estimated,
// randomized, or inferred from population norms. If there is not enough data to produce
// an accurate result, the function returns nil rather than guessing.

// MARK: - TodayHRStats

struct TodayHRStats {
    let avgBPM: Int
    let peakBPM: Int
    let dataMinutes: Int       // distinct 60-second buckets that contain at least one HR reading
    let elevatedMinutes: Int   // 60-second buckets whose average HR exceeds 100 BPM
}

// MARK: - LocalSleepEstimate
// Derived from overnight HR samples only. Not sleep-staged — shows strap presence, not sleep quality.

struct LocalSleepEstimate {
    let wristOnTs: Int         // epoch of first HR sample in overnight window
    let wristOffTs: Int        // epoch of last HR sample in overnight window
    let durationMinutes: Double
    let avgBPM: Int
    let rhr: Double?           // min 5-min avg HR from the same window
    let hrv: Double?           // RMSSD from overnight R-R intervals
}

// MARK: - LocalMetrics

enum LocalMetrics {

    // MARK: - Resting Heart Rate

    // Lowest 5-minute rolling average HR in the provided sample window.
    // Samples must be sorted ascending by ts (the store returns them this way).
    // Requires at least 5 samples inside a 5-minute window; returns nil otherwise.
    // This matches the standard clinical definition of RHR and approximates WHOOP's approach.
    static func rhr(from samples: [HRSample], windowSeconds: Int = 300) -> Double? {
        guard samples.count >= 5 else { return nil }
        var left = 0
        var runningSum = 0
        var minAvg: Double = .infinity
        for right in 0..<samples.count {
            runningSum += samples[right].bpm
            while samples[right].ts - samples[left].ts > windowSeconds {
                runningSum -= samples[left].bpm
                left += 1
            }
            let count = right - left + 1
            if count >= 5 {
                minAvg = min(minAvg, Double(runningSum) / Double(count))
            }
        }
        return minAvg.isFinite ? minAvg : nil
    }

    // MARK: - Today's HR Summary

    // Compute summary stats from today's HR samples.
    // Returns nil if there are no samples.
    // "elevatedMinutes" uses a fixed 100 BPM threshold — this is transparent and
    // labelled as such in the UI; it is NOT an estimated "active minutes" score.
    static func todayStats(from samples: [HRSample]) -> TodayHRStats? {
        guard !samples.isEmpty else { return nil }

        let bpms = samples.map(\.bpm)
        let avg = Int((Double(bpms.reduce(0, +)) / Double(bpms.count)).rounded())
        let peak = bpms.max() ?? 0

        // Group by 60-second bucket to count distinct covered minutes
        let byMinute = Dictionary(grouping: samples) { $0.ts / 60 }
        let dataMinutes = byMinute.count

        let elevatedMinutes = byMinute.values.filter { bucket in
            let bucketAvg = Double(bucket.map(\.bpm).reduce(0, +)) / Double(bucket.count)
            return bucketAvg > 100
        }.count

        return TodayHRStats(
            avgBPM: avg,
            peakBPM: peak,
            dataMinutes: dataMinutes,
            elevatedMinutes: elevatedMinutes
        )
    }
}
