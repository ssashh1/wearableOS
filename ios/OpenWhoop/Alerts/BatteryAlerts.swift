import Foundation

/// UserDefaults keys shared between the settings UI (`@AppStorage`) and `BatteryAlertMonitor`.
/// Defaults: alerts OFF, warn at 50%, low at 20%.
public enum BatteryAlertKeys {
    public static let warnEnabled   = "batteryWarnEnabled"
    public static let warnThreshold = "batteryWarnThreshold"
    public static let lowEnabled    = "batteryLowEnabled"
    public static let lowThreshold  = "batteryLowThreshold"
    /// Internal: last battery % we saw, persisted so crossing detection survives app restarts.
    static let lastReading = "batteryAlertLastReading"

    public static let defaultWarnThreshold = 50
    public static let defaultLowThreshold  = 20
}

/// The two configurable battery alerts. Thresholds are whole percentages.
public struct BatteryAlertConfig: Equatable {
    public var warnEnabled: Bool
    public var warnThreshold: Int
    public var lowEnabled: Bool
    public var lowThreshold: Int

    public init(warnEnabled: Bool, warnThreshold: Int, lowEnabled: Bool, lowThreshold: Int) {
        self.warnEnabled = warnEnabled
        self.warnThreshold = warnThreshold
        self.lowEnabled = lowEnabled
        self.lowThreshold = lowThreshold
    }
}

/// One alert that fired because the battery crossed its threshold on the way down.
public struct BatteryAlert: Equatable {
    public let threshold: Int
}

public enum BatteryAlertEvaluator {
    /// Decide which enabled alerts should fire for a transition from `previous` to `current` %.
    ///
    /// Edge-triggered: an alert fires only when the battery crosses DOWN through its threshold —
    /// `previous` strictly above and `current` at or below. This means:
    /// - reaching the threshold (51 → 50) fires once,
    /// - staying below it (19 → 18) does NOT re-fire,
    /// - charging back above it re-arms it for the next drop,
    /// - with no prior reading (`previous == nil`) nothing fires — we only alert on an observed drop.
    public static func evaluate(previous: Double?,
                                current: Double,
                                config: BatteryAlertConfig) -> [BatteryAlert] {
        guard let previous else { return [] }
        func crossed(_ threshold: Int) -> Bool {
            previous > Double(threshold) && current <= Double(threshold)
        }
        var fired: [BatteryAlert] = []
        if config.warnEnabled, crossed(config.warnThreshold) {
            fired.append(BatteryAlert(threshold: config.warnThreshold))
        }
        if config.lowEnabled, crossed(config.lowThreshold) {
            fired.append(BatteryAlert(threshold: config.lowThreshold))
        }
        return fired
    }
}
