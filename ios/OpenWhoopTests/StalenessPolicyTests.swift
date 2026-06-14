import XCTest
@testable import OpenWhoop

final class StalenessPolicyTests: XCTestCase {
    func testNeverSynced() {
        XCTAssertEqual(StalenessPolicy.state(lastSyncedAt: nil, now: 10_000), .neverSynced)
    }
    func testCaughtUpWithinOneHour() {
        XCTAssertEqual(StalenessPolicy.state(lastSyncedAt: 10_000 - 1800, now: 10_000), .caughtUp) // 30m
    }
    func testCatchingUpPastOneHour() {
        XCTAssertEqual(StalenessPolicy.state(lastSyncedAt: 10_000 - 4000, now: 10_000), .catchingUp) // 66m
    }
    func testStalePastNudgeThreshold() {
        // 6h = 21600s. WHOOP tile would say catching-up; our nudge threshold = .stale.
        XCTAssertEqual(StalenessPolicy.state(lastSyncedAt: 10_000 - 22_000, now: 10_000), .stale)
    }
}
