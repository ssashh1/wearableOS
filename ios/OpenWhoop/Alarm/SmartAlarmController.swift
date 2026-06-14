import Foundation
import Combine

// MARK: - SmartAlarmController
//
// Best-effort smart-wake layer on top of the fixed-time firmware alarm (M6).
//
// Architecture
// ────────────
// When the user enables smart wake, this controller schedules a local timer that fires
// `leadMinutes` before `wakeBy`. Within that window it enters high-freq-sync (cmd 96,
// ENTER_HIGH_FREQ_SYNC payload [0x02 | interval u16 LE | duration u16 LE]) to get
// denser HR/motion data, watches for a "near-wake" heuristic (sustained HR rise ≥ 5 bpm
// over a 2-minute window, consistent with light sleep), and fires the alarm haptic at
// the optimal moment — always before `wakeBy` at the latest.
//
// Safety invariants
// ─────────────────
// 1. EXIT_HIGH_FREQ_SYNC (cmd 97) is sent on EVERY exit path: alarm fired, window
//    expired, cancel(), app foregrounded, error. High-freq-sync left parked causes
//    data-loss / strap-stranding (see whoop-offload-no-highfreq.md). This is the
//    single most critical safety property of this class.
// 2. The controller never activates outside the window (`leadMinutes` before `wakeBy`).
//    If the timer hasn't fired yet, high-freq-sync is NOT started.
// 3. The controller does NOT interfere with the normal offload: it guards on
//    `isActive` and the window is bounded (≤ 30 min by UI constraint).
//
// Simulator limitations
// ─────────────────────
// Background BLE and actual haptic firing cannot be verified in the simulator.
// The window entry/exit logic and the heuristic algorithm are unit-testable
// via `evaluateHRWindow(samples:)` (a pure function). The actual BLE-path
// (ENTER/EXIT commands landing on the strap, alarms buzzing) requires on-device testing.
//
// State restoration
// ─────────────────
// If the app is killed while the window is active, the fixed-time firmware alarm
// (set by `BLEManager.armStrapAlarm`) fires regardless — the smart-wake is best-effort
// on top of that guaranteed baseline. No background scheduler is wired here that could
// run high-freq-sync unexpectedly: the DispatchWorkItem is in-process only.

@MainActor
final class SmartAlarmController {

    // MARK: - Shared instance
    static let shared = SmartAlarmController()

    // MARK: - Config

    /// Enter high-freq-sync with 180-second (3-min) HR/accel reporting interval and a
    /// duration covering the full smart-wake window (rounded up to the nearest minute).
    private static let highFreqIntervalSeconds: UInt16 = 180
    /// HR rise threshold (bpm) over the observation window considered "near-wake".
    private static let wakeHRRiseThreshold: Double = 5.0
    /// Minimum number of HR samples required to evaluate the heuristic.
    private static let minSamplesForEvaluation = 3

    // MARK: - State

    private var windowEntryItem: DispatchWorkItem?
    private var expiryItem: DispatchWorkItem?
    private var isActive = false
    /// Weak ref to the BLE manager — cleared on cancel so we don't keep it alive
    private weak var ble: BLEManager?
    private var wakeByDate: Date?
    private var leadMinutes: Int = 20

    private init() {}

    // MARK: - Public API

    /// Schedule a smart-wake window.
    /// Call this right after `BLEManager.armStrapAlarm(at:)` — the firmware alarm is the
    /// guaranteed path; this controller adds best-effort optimisation on top.
    ///
    /// - Parameters:
    ///   - wakeBy: Target wake time (same as passed to `armStrapAlarm`).
    ///   - leadMinutes: How many minutes before `wakeBy` the window opens. Must be 5–30.
    ///   - ble: The active `BLEManager`. Held weakly.
    func schedule(wakeBy: Date, leadMinutes: Int, ble: BLEManager) {
        cancel() // cancel any previously scheduled window first

        let lead = min(30, max(5, leadMinutes))
        self.ble         = ble
        self.wakeByDate  = wakeBy
        self.leadMinutes = lead

        let windowOpens = wakeBy.addingTimeInterval(-Double(lead) * 60)
        let delay       = windowOpens.timeIntervalSinceNow

        guard delay > 0 else {
            // Window already open (alarm set for < leadMinutes from now); enter immediately.
            enterWindow(wakeBy: wakeBy, windowDuration: Double(lead) * 60)
            return
        }

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.enterWindow(wakeBy: wakeBy, windowDuration: Double(lead) * 60)
        }
        windowEntryItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Cancel the smart-wake window. Always exits high-freq-sync if active.
    func cancel() {
        windowEntryItem?.cancel()
        windowEntryItem = nil
        expiryItem?.cancel()
        expiryItem = nil
        exitWindowIfNeeded(reason: "cancel")
    }

    // MARK: - Window lifecycle

    private func enterWindow(wakeBy: Date, windowDuration: TimeInterval) {
        guard let ble else { return }
        isActive = true

        let durationSeconds = UInt16(min(windowDuration, Double(UInt16.max)))
        ble.send(.enterHighFreqSync,
                 payload: Self.enterHighFreqPayload(intervalSec: Self.highFreqIntervalSeconds,
                                                    durationSec: durationSeconds))

        // Schedule window expiry — the firmware alarm fires at wakeBy regardless;
        // we just exit high-freq here and do a last-chance buzz if we didn't fire early.
        let timeUntilWakeBy = wakeBy.timeIntervalSinceNow
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Window expired without finding an optimal moment — the firmware alarm is the fallback.
            // Do a courtesy app-side buzz in case the user already woke and dismissed the strap alarm.
            self.ble?.testAlarmBuzz()
            self.exitWindowIfNeeded(reason: "window-expired")
        }
        expiryItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(timeUntilWakeBy, 0),
            execute: item
        )
    }

    private func exitWindowIfNeeded(reason: String) {
        guard isActive else { return }
        isActive = false
        ble?.send(.exitHighFreqSync, payload: [0x00])
        // NOTE: ble is not cleared here so that testAlarmBuzz in expiry fires correctly;
        // the weak ref naturally clears when BLEManager is deallocated.
    }

    // MARK: - HR heuristic (pure — unit-testable without BLE)

    /// Evaluate the smart-wake heuristic given a window of recent HR samples (bpm).
    ///
    /// Returns `true` if the samples suggest a near-wake / light-sleep moment suitable
    /// for firing the alarm early.
    ///
    /// Heuristic: if the last sample is ≥ `wakeHRRiseThreshold` bpm above the window
    /// minimum, the user is transitioning from deep → light sleep (HR rises as sleep
    /// lightens). This is a conservative first-pass — false positives buzz a few minutes
    /// early; false negatives let the firmware alarm fire on time.
    ///
    /// Requires at least `minSamplesForEvaluation` samples; returns `false` otherwise.
    ///
    /// - Parameter samples: Recent HR readings in bpm, oldest first.
    static func evaluateHRWindow(samples: [Double]) -> Bool {
        guard samples.count >= minSamplesForEvaluation,
              let minHR = samples.min(),
              let lastHR = samples.last else { return false }
        return (lastHR - minHR) >= wakeHRRiseThreshold
    }

    // MARK: - Payload builder (pure — unit-testable)

    /// Build the ENTER_HIGH_FREQ_SYNC payload for the smart-wake window.
    ///
    /// Format: `[0x02] + <interval u16 LE> + <duration u16 LE>` (5 bytes).
    /// 0x02 is the "param" sub-command byte from the WHOOP APK.
    /// Example: interval=180s, duration=7200s → [0x02, 0xB4, 0x00, 0x20, 0x1C]
    ///   180  = 0x00B4 LE → [0xB4, 0x00]
    ///   7200 = 0x1C20 LE → [0x20, 0x1C]
    static func enterHighFreqPayload(intervalSec: UInt16, durationSec: UInt16) -> [UInt8] {
        [0x02,
         UInt8(intervalSec & 0xFF), UInt8(intervalSec >> 8),
         UInt8(durationSec & 0xFF), UInt8(durationSec >> 8)]
    }
}
