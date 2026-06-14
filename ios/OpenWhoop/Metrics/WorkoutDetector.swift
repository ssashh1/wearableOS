import Foundation
import WhoopProtocol

// MARK: - DetectedActivity
// A sustained elevated-HR period detected from local hr_samples.
// Not server-computed — labelled explicitly as threshold-based detection.

struct DetectedActivity: Identifiable {
    let id: String
    let startTs: Int
    let endTs: Int
    var durationSeconds: Int { endTs - startTs }
    let avgBPM: Int
    let peakBPM: Int
}

// MARK: - WorkoutDetector

enum WorkoutDetector {

    // Threshold for "elevated" HR.
    static let elevatedThresholdBPM = 100

    // Minimum contiguous elevated time to qualify as an activity.
    static let minActivitySeconds   = 10 * 60   // 10 minutes

    // Two elevated bouts separated by less than this gap are merged into one.
    static let mergeGapSeconds      = 5  * 60   // 5 minutes

    // MARK: - Detection

    // Returns detected activities, newest-first.
    // Returns an empty array (never guesses) when samples are insufficient.
    static func detect(from samples: [HRSample]) -> [DetectedActivity] {
        guard !samples.isEmpty else { return [] }

        // Average HR per 60-second bucket; minute key = ts / 60 * 60
        let byMinute = Dictionary(grouping: samples) { $0.ts / 60 }
        let elevatedMinuteKeys: Set<Int> = Set(
            byMinute.compactMap { minuteKey, group -> Int? in
                let avg = Double(group.map(\.bpm).reduce(0, +)) / Double(group.count)
                return avg > Double(elevatedThresholdBPM) ? minuteKey * 60 : nil
            }
        )
        guard !elevatedMinuteKeys.isEmpty else { return [] }

        // Cluster elevated minutes into bouts (merge gaps ≤ mergeGapSeconds)
        let sorted = elevatedMinuteKeys.sorted()
        var bouts: [(start: Int, end: Int)] = []
        var boutStart = sorted[0]
        var boutEnd   = sorted[0]
        for i in 1..<sorted.count {
            if sorted[i] - boutEnd <= mergeGapSeconds {
                boutEnd = sorted[i]
            } else {
                bouts.append((start: boutStart, end: boutEnd + 60))
                boutStart = sorted[i]
                boutEnd   = sorted[i]
            }
        }
        bouts.append((start: boutStart, end: boutEnd + 60))

        // Filter to minimum duration and compute per-bout stats from raw samples
        return bouts
            .filter { $0.end - $0.start >= minActivitySeconds }
            .map { bout in
                let boutSamples = samples.filter { $0.ts >= bout.start && $0.ts < bout.end }
                let bpms = boutSamples.map(\.bpm)
                let avg  = bpms.isEmpty ? 0 : Int((Double(bpms.reduce(0, +)) / Double(bpms.count)).rounded())
                let peak = bpms.max() ?? 0
                return DetectedActivity(id: "\(bout.start)",
                                        startTs: bout.start, endTs: bout.end,
                                        avgBPM: avg, peakBPM: peak)
            }
            .sorted { $0.startTs > $1.startTs }
    }
}
