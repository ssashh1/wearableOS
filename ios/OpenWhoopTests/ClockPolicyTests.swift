import XCTest
@testable import OpenWhoop

final class ClockPolicyTests: XCTestCase {
    // In-sync clock (within threshold) → don't set.
    func testInSyncDoesNotSet() {
        XCTAssertFalse(ClockPolicy.shouldSetClock(deviceClock: 1_000_000, wallNow: 1_000_001,
                                                  driftThreshold: 2))
    }
    // Drifted beyond threshold → set.
    func testDriftedSets() {
        XCTAssertTrue(ClockPolicy.shouldSetClock(deviceClock: 1_000_000, wallNow: 1_000_010,
                                                 driftThreshold: 2))
    }
    // Frozen RTC (way off, e.g. Jan-2025 vs now) → set.
    func testFrozenRtcSets() {
        XCTAssertTrue(ClockPolicy.shouldSetClock(deviceClock: 1_736_000_000, wallNow: 1_779_000_000,
                                                 driftThreshold: 2))
    }
    // Negative drift (device ahead) beyond threshold → set.
    func testDeviceAheadSets() {
        XCTAssertTrue(ClockPolicy.shouldSetClock(deviceClock: 1_000_010, wallNow: 1_000_000,
                                                 driftThreshold: 2))
    }
}
