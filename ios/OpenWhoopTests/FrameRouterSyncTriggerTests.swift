import XCTest
import WhoopProtocol
@testable import OpenWhoop

final class FrameRouterSyncTriggerTests: XCTestCase {
    private func bytes(_ hex: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }
    // Real EVENT frame (RAW_DATA_COLLECTION_ON(46)) — reused from FrameRouterTests.
    private let eventRawOn = "aa10005730262e0019d67e676817000016376706"

    @MainActor
    func testEventFrameFiresSyncTrigger() {
        let state = LiveState()
        let router = FrameRouter(state: state)
        var fired = 0
        router.onSyncTrigger = { fired += 1 }
        router.handle(frame: bytes(eventRawOn))
        XCTAssertEqual(fired, 1)
    }
}
