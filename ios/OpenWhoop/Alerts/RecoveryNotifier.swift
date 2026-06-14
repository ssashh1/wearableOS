import Foundation
import UserNotifications

/// Posts a single "Recovery ready" local notification once per calendar day when
/// the server-computed recovery score is available. The deduplication key is the
/// UTC calendar date stored in UserDefaults; notifications fire at most once per day
/// even if `notify(recovery:forDay:)` is called multiple times.
///
/// Pattern mirrors BatteryAlertMonitor / SyncNudge: UNUserNotificationCenter +
/// requestAuthorization + stable notification identifier so re-fires replace rather
/// than stack.
enum RecoveryNotifier {
    private static let lastNotifiedKey = "com.openwhoop.recoveryNotifier.lastNotifiedDay"
    /// Stable identifier so a repeat request replaces the previous one (no stacking).
    private static let notificationId = "recovery-ready-daily"

    /// Request notification permission (safe to call multiple times; iOS coalesces).
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Fire a "Recovery ready" notification for `recovery` (0–1) if one has not already
    /// been posted for today (UTC). `day` should be the YYYY-MM-DD string of the metric row
    /// so the dedupe is keyed to the metric date rather than the wall clock.
    ///
    /// - Parameters:
    ///   - recovery: recovery score in [0, 1].
    ///   - forDay: YYYY-MM-DD string for the metric's calendar day (UTC).
    ///   - defaults: injectable UserDefaults for unit-testing.
    ///   - center: injectable UNUserNotificationCenter for unit-testing.
    static func notify(recovery: Double,
                        forDay day: String,
                        defaults: UserDefaults = .standard,
                        center: UNUserNotificationCenter = .current()) {
        // Dedupe: skip if we already posted for this exact day.
        let lastDay = defaults.string(forKey: lastNotifiedKey)
        guard lastDay != day else { return }

        // Stamp the day BEFORE posting so a re-entrant call doesn't double-fire.
        defaults.set(day, forKey: lastNotifiedKey)

        let pct = Int((recovery * 100).rounded())
        let content = UNMutableNotificationContent()
        content.title = "Recovery ready"
        content.body  = "Today's recovery is \(pct)%."
        content.sound = .default

        // nil trigger = deliver immediately.
        let request = UNNotificationRequest(identifier: notificationId,
                                            content: content,
                                            trigger: nil)
        center.add(request)
    }
}
