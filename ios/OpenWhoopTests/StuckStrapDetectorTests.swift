import XCTest
@testable import OpenWhoop

final class StuckStrapDetectorTests: XCTestCase {
    private func make() -> StuckStrapDetector { StuckStrapDetector(stuckAfterSeconds: 600, behindGapSeconds: 300) }

    // First observation seeds, never stuck.
    func testFirstObservationNotStuck() {
        var d = make()
        XCTAssertFalse(d.observe(strapNewestTs: 9000, ourFrontierTs: 1000, now: 5000))
    }
    // Caught up / off-wrist (strap not ahead of us) → never stuck, even after a long time.
    func testCaughtUpNotStuck() {
        var d = make()
        _ = d.observe(strapNewestTs: 1050, ourFrontierTs: 1000, now: 5000) // 50s behind < 300 gap
        XCTAssertFalse(d.observe(strapNewestTs: 1050, ourFrontierTs: 1000, now: 9000))
    }
    // Behind + frontier advancing → catching up, not stuck.
    func testCatchingUpNotStuck() {
        var d = make()
        _ = d.observe(strapNewestTs: 9000, ourFrontierTs: 1000, now: 5000)
        XCTAssertFalse(d.observe(strapNewestTs: 9000, ourFrontierTs: 4000, now: 5300)) // advanced
        XCTAssertFalse(d.observe(strapNewestTs: 9000, ourFrontierTs: 7000, now: 5600)) // advanced
    }
    // Behind + frontier frozen past the window → stuck.
    func testBehindAndFrozenIsStuck() {
        var d = make()
        _ = d.observe(strapNewestTs: 9000, ourFrontierTs: 1000, now: 5000)
        XCTAssertFalse(d.observe(strapNewestTs: 9000, ourFrontierTs: 1000, now: 5500)) // 500s < 600
        XCTAssertTrue(d.observe(strapNewestTs: 9000, ourFrontierTs: 1000, now: 5601))  // 601s → stuck
    }
    // Recovery: stuck, then frontier advances → clears.
    func testRecoveryClears() {
        var d = make()
        _ = d.observe(strapNewestTs: 9000, ourFrontierTs: 1000, now: 5000)
        XCTAssertTrue(d.observe(strapNewestTs: 9000, ourFrontierTs: 1000, now: 5601))
        XCTAssertFalse(d.observe(strapNewestTs: 9000, ourFrontierTs: 3000, now: 5700)) // advanced → clear
    }
    // nil inputs (no range / no data yet) → not stuck.
    func testNilNotStuck() {
        var d = make()
        XCTAssertFalse(d.observe(strapNewestTs: nil, ourFrontierTs: 1000, now: 9999))
        XCTAssertFalse(d.observe(strapNewestTs: 9000, ourFrontierTs: nil, now: 9999))
    }
}
