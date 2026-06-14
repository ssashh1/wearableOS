import XCTest
@testable import OpenWhoop

/// Unit tests for the pure battery-alert crossing logic. The tricky parts are edge-triggering
/// (fire once on the way down, not repeatedly), re-arming after a charge, the no-prior-reading
/// case, and both thresholds tripping in one big drop.
final class BatteryAlertsTests: XCTestCase {
    private let both = BatteryAlertConfig(warnEnabled: true, warnThreshold: 50,
                                          lowEnabled: true, lowThreshold: 20)

    private func eval(_ prev: Double?, _ cur: Double, _ c: BatteryAlertConfig) -> [Int] {
        BatteryAlertEvaluator.evaluate(previous: prev, current: cur, config: c).map(\.threshold)
    }

    func test_noPriorReading_neverFires() {
        XCTAssertEqual(eval(nil, 10, both), [])
    }

    func test_crossingDownThroughWarn_fires() {
        XCTAssertEqual(eval(55, 45, both), [50])
    }

    func test_reachingThresholdExactly_fires() {
        // "notify when it gets to 50%": 51 → 50 counts as reaching it.
        XCTAssertEqual(eval(51, 50, both), [50])
    }

    func test_notCrossing_doesNotFire() {
        XCTAssertEqual(eval(55, 52, both), [])
    }

    func test_alreadyBelow_stayingBelow_doesNotFire() {
        // Sitting at 19%, dropping to 18% must NOT re-spam the low alert.
        XCTAssertEqual(eval(19, 18, both), [])
    }

    func test_rising_doesNotFire_thenReArms() {
        XCTAssertEqual(eval(45, 55, both), [], "charging back up should not fire")
        XCTAssertEqual(eval(55, 45, both), [50], "after recharge, a fresh drop fires again")
    }

    func test_bigDropCrossesBothThresholds() {
        XCTAssertEqual(eval(55, 15, both), [50, 20])
    }

    func test_disabledThreshold_doesNotFire() {
        let warnOnly = BatteryAlertConfig(warnEnabled: true, warnThreshold: 50,
                                          lowEnabled: false, lowThreshold: 20)
        XCTAssertEqual(eval(55, 15, warnOnly), [50], "low disabled → only warn fires")
    }
}
