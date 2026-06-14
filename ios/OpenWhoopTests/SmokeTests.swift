import XCTest
import WhoopProtocol

final class SmokeTests: XCTestCase {
    func testWhoopProtocolLinks() {
        // Proves the app test target links the WhoopProtocol package.
        XCTAssertNotNil(WhoopProtocolInfo.schemaResourceURL())
    }
}
