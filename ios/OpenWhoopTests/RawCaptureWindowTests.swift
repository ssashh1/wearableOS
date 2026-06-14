import XCTest
@testable import OpenWhoop

final class RawCaptureWindowTests: XCTestCase {

    func testClampBounds() {
        XCTAssertEqual(RawCaptureWindow.clamp(0), 1, "below min → min")
        XCTAssertEqual(RawCaptureWindow.clamp(-100), 1, "negative → min")
        XCTAssertEqual(RawCaptureWindow.clamp(1000), 300, "above max → max")
        XCTAssertEqual(RawCaptureWindow.clamp(30), 30, "in-range unchanged")
        XCTAssertEqual(RawCaptureWindow.clamp(1), 1, "min boundary")
        XCTAssertEqual(RawCaptureWindow.clamp(300), 300, "max boundary")
    }

    func testInactiveByDefault() {
        let w = RawCaptureWindow()
        XCTAssertFalse(w.isActive(at: 0))
        XCTAssertFalse(w.isActive(at: 1_000_000))
    }

    func testActiveBeforeAtAndAfterDeadline() {
        var w = RawCaptureWindow()
        w.open(at: 100, duration: 30)        // deadline = 130
        XCTAssertTrue(w.isActive(at: 100), "active at open")
        XCTAssertTrue(w.isActive(at: 129), "active before deadline")
        XCTAssertTrue(w.isActive(at: 130), "active AT deadline (inclusive)")
        XCTAssertFalse(w.isActive(at: 130.001), "inactive past deadline")
        XCTAssertFalse(w.isActive(at: 200), "inactive well past deadline")
    }

    func testCloseDeactivates() {
        var w = RawCaptureWindow()
        w.open(at: 100, duration: 30)
        XCTAssertTrue(w.isActive(at: 110))
        w.close()
        XCTAssertFalse(w.isActive(at: 110), "closed → inactive even before deadline")
    }

    func testOpenClampsDuration() {
        var w = RawCaptureWindow()
        w.open(at: 0, duration: 10_000)      // clamped to 300 → deadline 300
        XCTAssertTrue(w.isActive(at: 300))
        XCTAssertFalse(w.isActive(at: 301), "duration clamped to max")
    }
}
