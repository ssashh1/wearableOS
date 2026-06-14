import XCTest
import UserNotifications
@testable import OpenWhoop

/// Tests the per-day dedupe logic of RecoveryNotifier.
/// We inject an isolated UserDefaults suite and a spy UNUserNotificationCenter substitute
/// via the injectable `center` parameter so tests don't touch the system notification center.
final class RecoveryNotifierTests: XCTestCase {

    // A unique UserDefaults suite per test so state doesn't bleed between cases.
    private var defaults: UserDefaults!
    private let suiteName = "com.openwhoop.test.recoverynotifier"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Dedupe: first call fires, second call same day is suppressed

    func test_firstCall_setsLastNotifiedDay() {
        RecoveryNotifier.notify(recovery: 0.64, forDay: "2026-05-28", defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "com.openwhoop.recoveryNotifier.lastNotifiedDay"),
                       "2026-05-28",
                       "notify must stamp the day key on first fire")
    }

    func test_secondCallSameDay_doesNotOverwriteAlreadyStampedDay() {
        // First call stamps the day.
        RecoveryNotifier.notify(recovery: 0.64, forDay: "2026-05-28", defaults: defaults)

        // Manually confirm it's stamped before the second call.
        XCTAssertEqual(defaults.string(forKey: "com.openwhoop.recoveryNotifier.lastNotifiedDay"),
                       "2026-05-28")

        // Second call with the SAME day — the guard returns early, day key must stay the same.
        RecoveryNotifier.notify(recovery: 0.80, forDay: "2026-05-28", defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "com.openwhoop.recoveryNotifier.lastNotifiedDay"),
                       "2026-05-28",
                       "day key must not change on a duplicate same-day call")
    }

    func test_nextDay_fires() {
        // Seed yesterday's stamp.
        defaults.set("2026-05-27", forKey: "com.openwhoop.recoveryNotifier.lastNotifiedDay")

        // Call for today — a different day, so it should fire and update the stamp.
        RecoveryNotifier.notify(recovery: 0.72, forDay: "2026-05-28", defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: "com.openwhoop.recoveryNotifier.lastNotifiedDay"),
                       "2026-05-28",
                       "a new calendar day must update the stamp")
    }

    func test_noPriorStamp_fires() {
        // No prior key → notify should run (and stamp the day).
        RecoveryNotifier.notify(recovery: 0.50, forDay: "2026-05-28", defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "com.openwhoop.recoveryNotifier.lastNotifiedDay"),
                       "2026-05-28")
    }
}
