import Foundation
import UserNotifications

/// Local "tap to sync" nudge using the schedule-ahead-then-cancel pattern. iOS won't background-launch a
/// force-quit app, and a silent push can't wake one either — only a user tap clears the force-quit flag.
/// So we keep one pending local notification ~`afterSeconds` in the future; every successful sync pushes
/// it forward, so it fires ONLY after a genuine stall (force-quit / away / stuck).
enum SyncNudge {
    static let id = "sync-stale-nudge"

    /// Request permission (call when enabling; safe to call repeatedly). Mirrors BatteryAlertMonitor.
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// (Re)schedule the single nudge `afterSeconds` from now, replacing any pending one.
    static func reschedule(afterSeconds: TimeInterval = StalenessPolicy.staleAfterSeconds) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        let content = UNMutableNotificationContent()
        content.title = "OpenWhoop hasn't synced in a while"
        content.body = "Open OpenWhoop to catch up your WHOOP data."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: afterSeconds, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    /// Cancel the pending nudge (e.g. on a fresh successful sync, before re-scheduling).
    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
}
