import Foundation
import WhoopProtocol

// Local HRV calculation from raw R-R interval data.
// WHOOP uses RMSSD (Root Mean Square of Successive Differences) for its HRV metric,
// computed over a low-activity overnight window. We approximate that window as
// yesterday 8 PM → today 10 AM in local time, which covers most sleep schedules.
enum HRVCalculator {

    // Minimum number of clean successive R-R pairs required before reporting a value.
    // 60 pairs ≈ 1 minute at 60 BPM — enough to produce a stable RMSSD.
    static let minPairs = 60

    // Artifact rejection: intervals outside this physiological range are dropped.
    // 300 ms → 200 BPM max, 2500 ms → 24 BPM min.
    static let minRR = 300
    static let maxRR = 2500

    // MARK: - Core algorithm

    // Compute RMSSD from an array of successive R-R intervals (milliseconds).
    // Returns nil when there are fewer than `minPairs` clean values.
    // Pass a lower minPairs for live/real-time displays; keep the default (60) for
    // overnight computation where stability matters more than responsiveness.
    static func rmssd(_ intervals: [Int], minPairs: Int = minPairs) -> Double? {
        let clean = intervals.filter { $0 >= minRR && $0 <= maxRR }
        guard clean.count > minPairs else { return nil }
        var sumSqDiff = 0.0
        for i in 1..<clean.count {
            let diff = Double(clean[i] - clean[i - 1])
            sumSqDiff += diff * diff
        }
        return sqrt(sumSqDiff / Double(clean.count - 1))
    }

    // MARK: - Overnight window

    // Compute RMSSD over the overnight window (yesterday 8 PM → today 10 AM local time).
    // Returns nil if there is not enough clean data in that window.
    static func overnightRMSSD(from intervals: [RRInterval], calendar: Calendar = .current) -> Double? {
        let window = overnightWindow(calendar: calendar)
        let windowMs = intervals
            .filter { $0.ts >= window.start && $0.ts <= window.end }
            .map(\.rrMs)
        return rmssd(windowMs)
    }

    // The representative timestamp for a HealthKit HRV sample written for "last night":
    // 2 AM today in local time, clamped to at most 60 seconds ago so HealthKit
    // never receives a future-dated sample.
    static func overnightSampleDate(calendar: Calendar = .current) -> Date {
        let startOfToday = calendar.startOfDay(for: Date())
        let twoAM = startOfToday.addingTimeInterval(2 * 3600)
        return min(twoAM, Date().addingTimeInterval(-60))
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
