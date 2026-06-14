import Foundation
import UserNotifications

/// Watches battery readings and posts local notifications when they cross the configured
/// thresholds. Reads its config live from `UserDefaults` (the same keys the settings UI writes
/// via `@AppStorage`), and persists the previous reading there so crossing detection survives
/// app restarts. `notify` is injectable so tests can observe firings without the system framework.
@MainActor
public final class BatteryAlertMonitor {
    private let defaults: UserDefaults
    private let notify: (BatteryAlert) -> Void

    public init(defaults: UserDefaults = .standard,
                notify: ((BatteryAlert) -> Void)? = nil) {
        self.defaults = defaults
        self.notify = notify ?? BatteryAlertMonitor.postLocalNotification
    }

    private var config: BatteryAlertConfig {
        BatteryAlertConfig(
            warnEnabled: defaults.bool(forKey: BatteryAlertKeys.warnEnabled),
            warnThreshold: defaults.object(forKey: BatteryAlertKeys.warnThreshold) as? Int
                ?? BatteryAlertKeys.defaultWarnThreshold,
            lowEnabled: defaults.bool(forKey: BatteryAlertKeys.lowEnabled),
            lowThreshold: defaults.object(forKey: BatteryAlertKeys.lowThreshold) as? Int
                ?? BatteryAlertKeys.defaultLowThreshold)
    }

    /// Feed one battery reading (0–100). Fires any alerts crossed since the last reading.
    public func handle(battery current: Double) {
        let previous = defaults.object(forKey: BatteryAlertKeys.lastReading) as? Double
        defaults.set(current, forKey: BatteryAlertKeys.lastReading)
        for alert in BatteryAlertEvaluator.evaluate(previous: previous, current: current, config: config) {
            notify(alert)
        }
    }

    /// Ask for local-notification permission. Call when the user turns an alert on.
    public static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func postLocalNotification(_ alert: BatteryAlert) {
        let content = UNMutableNotificationContent()
        content.title = "WHOOP battery at \(alert.threshold)%"
        content.body = "Your WHOOP has dropped to \(alert.threshold)%."
        content.sound = .default
        // nil trigger = deliver now. Stable id per threshold so a repeat replaces rather than stacks.
        let request = UNNotificationRequest(identifier: "battery-alert-\(alert.threshold)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
