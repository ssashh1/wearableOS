import Foundation
import WhoopProtocol

// Local HRV calculation from raw R-R interval data.
// WHOOP uses RMSSD (Root Mean Square of Successive Differences) for its live HRV metric.
// Apple HealthKit's heartRateVariabilitySDNN type requires SDNN, not RMSSD — these are
// different algorithms. This file implements both; callers must use the correct one.
enum HRVCalculator {

    // Minimum clean successive pairs (RMSSD) or intervals (SDNN) before reporting a value.
    // 60 pairs ≈ 1 minute at 60 BPM.
    static let minPairs = 60

    // Physiological range filter: intervals outside this range are noise or artifacts.
    // 300 ms → 200 BPM max, 2000 ms → 30 BPM min (2500 ms was too lenient: 24 BPM).
    static let minRR = 300
    static let maxRR = 2000

    // Malik criterion: reject a successive pair if |rr[i] - rr[i-1]| exceeds this.
    // Catches missed beats, ectopic beats, and motion transients that pass the range filter.
    private static let malikThresholdMs = 200

    // Bad-ratio guard: if more than this fraction of pairs are rejected, the window is too
    // noisy and the surviving pairs are suspect. Return nil instead of a misleading value.
    private static let maxBadRatio = 0.4

    // MARK: - RMSSD (live display, from timestamped RRSample stream)

    // Primary overload for live data. Applies four levels of artifact rejection:
    //   1. Range filter (minRR–maxRR)
    //   2. Time-gap filter: >30s between BLE notifications = session boundary, not consecutive beats
    //   3. Malik criterion: |diff| > 200ms = ectopic/missed-beat; pair is SKIPPED, not contamination
    //   4. Bad-ratio guard: >40% of ARTIFACT pairs (range+gap only) → hardware dropout, return nil
    //
    // Malik skips are excluded from the bad-ratio because PPG wristbands frequently produce
    // doubled intervals (missed optical beats) that Malik correctly skips; those skips do not
    // contaminate the valid pairs that remain.
    static func rmssd(_ samples: [RRSample], minPairs: Int = minPairs) -> Double? {
        var sumSqDiff = 0.0
        var validPairs = 0
        var totalPairs = 0
        var artifactPairs = 0  // range + gap only; Malik skips excluded from contamination count
        guard samples.count >= 2 else { return nil }
        for i in 1..<samples.count {
            let prev = samples[i - 1], curr = samples[i]
            totalPairs += 1
            guard prev.rrMs >= minRR && prev.rrMs <= maxRR,
                  curr.rrMs >= minRR && curr.rrMs <= maxRR else { artifactPairs += 1; continue }
            guard curr.ts.timeIntervalSince(prev.ts) <= 30.0 else { artifactPairs += 1; continue }
            guard abs(curr.rrMs - prev.rrMs) <= malikThresholdMs else { continue }
            let diff = Double(curr.rrMs - prev.rrMs)
            sumSqDiff += diff * diff
            validPairs += 1
        }
        guard totalPairs == 0 || Double(artifactPairs) / Double(totalPairs) <= maxBadRatio else { return nil }
        guard validPairs >= minPairs else { return nil }
        return sqrt(sumSqDiff / Double(validPairs))
    }

    // Overload for stored/historical [Int] arrays (MetricsRepository 7-night history loop).
    // Applies range + Malik + bad-ratio rejection; no time-gap check (data is pre-windowed by caller).
    static func rmssd(_ intervals: [Int], minPairs: Int = minPairs) -> Double? {
        let clean = intervals.filter { $0 >= minRR && $0 <= maxRR }
        guard clean.count >= 2 else { return nil }
        var sumSqDiff = 0.0
        var validPairs = 0
        var totalPairs = 0
        for i in 1..<clean.count {
            totalPairs += 1
            guard abs(clean[i] - clean[i - 1]) <= malikThresholdMs else { continue }
            let diff = Double(clean[i] - clean[i - 1])
            sumSqDiff += diff * diff
            validPairs += 1
        }
        guard totalPairs == 0 || Double(totalPairs - validPairs) / Double(totalPairs) <= maxBadRatio else { return nil }
        guard validPairs >= minPairs else { return nil }
        return sqrt(sumSqDiff / Double(validPairs))
    }

    // MARK: - SDNN (Apple HealthKit writes only)

    // Standard deviation of NN intervals. Apple's heartRateVariabilitySDNN type expects this
    // algorithm specifically — do NOT use RMSSD values here.
    // Applies the same Malik filter as RMSSD to remove ectopic/missed beats before computing
    // SDNN; without this, doubled PPG intervals (2× normal RR) massively inflate the variance.
    static func sdnn(_ intervals: [Int], minIntervals: Int = minPairs) -> Double? {
        let clean = intervals.filter { $0 >= minRR && $0 <= maxRR }
        var nn = [Int]()
        if let first = clean.first { nn.append(first) }
        for i in 1..<clean.count {
            if abs(clean[i] - nn.last!) <= malikThresholdMs { nn.append(clean[i]) }
        }
        guard nn.count >= minIntervals else { return nil }
        let mean = Double(nn.reduce(0, +)) / Double(nn.count)
        let variance = nn.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(nn.count - 1)
        return sqrt(variance)
    }

    // MARK: - Overnight windows

    // RMSSD over the overnight window (yesterday 8 PM → today 10 AM local time).
    static func overnightRMSSD(from intervals: [RRInterval], calendar: Calendar = .current) -> Double? {
        let window = overnightWindow(calendar: calendar)
        let windowMs = intervals
            .filter { $0.ts >= window.start && $0.ts <= window.end }
            .map(\.rrMs)
        return rmssd(windowMs)
    }

    // SDNN over the overnight window — use this for Apple HealthKit writes.
    static func overnightSDNN(from intervals: [RRInterval], calendar: Calendar = .current) -> Double? {
        let window = overnightWindow(calendar: calendar)
        let windowMs = intervals
            .filter { $0.ts >= window.start && $0.ts <= window.end }
            .map(\.rrMs)
        return sdnn(windowMs)
    }

    // The representative timestamp for a HealthKit HRV sample written for "last night":
    // 2 AM today in local time, clamped to at most 60 seconds ago so HealthKit
    // never receives a future-dated sample.
    static func overnightSampleDate(calendar: Calendar = .current) -> Date {
        let startOfToday = calendar.startOfDay(for: Date())
        let twoAM = startOfToday.addingTimeInterval(2 * 3600)
        return min(twoAM, Date().addingTimeInterval(-60))
    }

    // MARK: - Debug breakdown (used by HRVDebugView)

    struct RMSSDDebug {
        let totalPairs: Int
        let validPairs: Int
        let rejectedByRange: Int
        let rejectedByGap: Int
        let rejectedByMalik: Int
        let value: Double?
    }

    static func rmssdDebug(_ samples: [RRSample], minPairs: Int = 15) -> RMSSDDebug {
        guard samples.count >= 2 else {
            return RMSSDDebug(totalPairs: 0, validPairs: 0, rejectedByRange: 0,
                              rejectedByGap: 0, rejectedByMalik: 0, value: nil)
        }
        var sumSqDiff = 0.0
        var validPairs = 0
        var totalPairs = 0
        var byRange = 0, byGap = 0, byMalik = 0
        for i in 1..<samples.count {
            let prev = samples[i - 1], curr = samples[i]
            totalPairs += 1
            if prev.rrMs < minRR || prev.rrMs > maxRR || curr.rrMs < minRR || curr.rrMs > maxRR {
                byRange += 1; continue
            }
            if curr.ts.timeIntervalSince(prev.ts) > 30.0 { byGap += 1; continue }
            if abs(curr.rrMs - prev.rrMs) > malikThresholdMs { byMalik += 1; continue }
            let diff = Double(curr.rrMs - prev.rrMs)
            sumSqDiff += diff * diff
            validPairs += 1
        }
        let artifactPairs = byRange + byGap
        let artifactRatio = totalPairs > 0 ? Double(artifactPairs) / Double(totalPairs) : 0.0
        let value: Double? = (artifactRatio <= maxBadRatio && validPairs >= minPairs)
            ? sqrt(sumSqDiff / Double(validPairs)) : nil
        return RMSSDDebug(totalPairs: totalPairs, validPairs: validPairs, rejectedByRange: byRange,
                          rejectedByGap: byGap, rejectedByMalik: byMalik, value: value)
    }

    // MARK: - Private

    private struct Window { let start: Int; let end: Int }

    private static func overnightWindow(calendar: Calendar) -> Window {
        let startOfToday = calendar.startOfDay(for: Date())
        let windowStart = startOfToday.addingTimeInterval(-4 * 3600)  // yesterday 8 PM
        let windowEnd   = startOfToday.addingTimeInterval(10 * 3600)  // today 10 AM
        return Window(start: Int(windowStart.timeIntervalSince1970),
                      end:   Int(windowEnd.timeIntervalSince1970))
    }
}
