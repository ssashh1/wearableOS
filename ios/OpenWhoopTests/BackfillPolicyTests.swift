import XCTest
@testable import OpenWhoop

final class BackfillPolicyTests: XCTestCase {
    func testNeverSyncedAlwaysRuns() {
        for t in [BackfillTrigger.periodic, .connect, .foreground, .manual, .strap] {
            XCTAssertTrue(BackfillPolicy.shouldRun(trigger: t, now: 1000, lastBackfillAt: nil))
        }
    }
    func testPeriodicFloor() {
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .periodic, now: 1000, lastBackfillAt: 200)) // 800s
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .periodic, now: 1000, lastBackfillAt: 100))  // 900s
    }
    func testEventFloor() {
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .connect, now: 1000, lastBackfillAt: 950))    // 50s
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .connect, now: 1000, lastBackfillAt: 910))     // 90s
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .strap, now: 1000, lastBackfillAt: 950))      // 50s
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .strap, now: 1000, lastBackfillAt: 905))       // 95s
    }
    func testManualAlwaysRuns() {
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .manual, now: 1000, lastBackfillAt: 999))
    }
}
