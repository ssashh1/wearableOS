import Foundation
import WhoopProtocol

// MARK: - SleepPeriod

struct SleepPeriod: Identifiable {
    var id: String { "\(startTs)" }
    let startTs: Int    // unix seconds
    let endTs: Int      // unix seconds
    var durationMinutes: Double { Double(endTs - startTs) / 60.0 }
}

// MARK: - SleepDetector
// Gravity-vector sleep detection.
// Ported from bWanShiTong/openwhoop activity.rs.
//
// Algorithm:
//   1. Per consecutive sample pair: compute delta magnitude |g(t) − g(t−1)|
//   2. delta < 0.01g → "still"
//   3. 15-minute buckets: ≥ 70% still → sleep bucket
//   4. Cluster contiguous sleep buckets, tolerating ≤ 20-min gaps
//   5. Keep periods ≥ 60 min
//
// Gravity values are IEEE-754 f32 decoded to Double, stored as g-force.
// At rest, |g| ≈ 1g; the 0.01g delta threshold detects micro-movements.
//
// Returns [] rather than guessing when data is insufficient.

enum SleepDetector {

    // Thresholds matching activity.rs
    static let stillThresholdG  = 0.01       // delta magnitude (g) below which → "still"
    static let bucketSeconds    = 15 * 60    // 15-minute classification window
    static let stillFractionMin = 0.70       // fraction of still samples to classify bucket as sleep
    static let minSleepSeconds  = 60 * 60    // discard periods shorter than 60 min
    static let maxGapSeconds    = 20 * 60    // bridge gaps ≤ 20 min between sleep buckets

    // MARK: - Public

    static func detectSleep(from samples: [GravitySample]) -> [SleepPeriod] {
        guard samples.count >= 2 else { return [] }

        // 1. Compute per-sample stillness flag from consecutive delta
        var flags: [(ts: Int, isStill: Bool)] = []
        flags.reserveCapacity(samples.count - 1)
        for i in 1..<samples.count {
            let prev = samples[i - 1], curr = samples[i]
            let dx = curr.x - prev.x
            let dy = curr.y - prev.y
            let dz = curr.z - prev.z
            let delta = (dx * dx + dy * dy + dz * dz).squareRoot()
            flags.append((ts: curr.ts, isStill: delta < stillThresholdG))
        }

        guard let firstTs = flags.first?.ts, let lastTs = flags.last?.ts else { return [] }

        // 2. Classify 15-minute buckets using a two-pointer sweep (O(n))
        let bucketCount = (lastTs - firstTs) / bucketSeconds + 1
        var sleepBuckets: [Int] = []
        var pLeft = 0

        for b in 0..<bucketCount {
            let lo = firstTs + b * bucketSeconds
            let hi = lo + bucketSeconds
            while pLeft < flags.count && flags[pLeft].ts < lo { pLeft += 1 }
            var total = 0, stills = 0
            var p = pLeft
            while p < flags.count && flags[p].ts < hi {
                total += 1
                if flags[p].isStill { stills += 1 }
                p += 1
            }
            if total > 0 && Double(stills) / Double(total) >= stillFractionMin {
                sleepBuckets.append(lo)
            }
        }

        // 3. Cluster and filter
        return cluster(sleepBuckets)
    }

    // MARK: - Private

    private static func cluster(_ bucketStarts: [Int]) -> [SleepPeriod] {
        guard !bucketStarts.isEmpty else { return [] }
        var periods: [SleepPeriod] = []
        var periodStart = bucketStarts[0]
        var periodEnd   = bucketStarts[0] + bucketSeconds

        for ts in bucketStarts.dropFirst() {
            if ts - periodEnd <= maxGapSeconds {
                periodEnd = ts + bucketSeconds
            } else {
                if periodEnd - periodStart >= minSleepSeconds {
                    periods.append(SleepPeriod(startTs: periodStart, endTs: periodEnd))
                }
                periodStart = ts
                periodEnd   = ts + bucketSeconds
            }
        }
        if periodEnd - periodStart >= minSleepSeconds {
            periods.append(SleepPeriod(startTs: periodStart, endTs: periodEnd))
        }
        return periods
    }
}
