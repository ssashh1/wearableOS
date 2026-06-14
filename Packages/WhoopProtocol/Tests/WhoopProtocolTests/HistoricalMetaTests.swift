import XCTest
@testable import WhoopProtocol

/// Tests for classifyHistoricalMeta using real frames built by frameFromPayload (type 49 = METADATA).
///
/// Frame layout: frameFromPayload(data, type:49, seq:0, cmd:N) produces
///   frame[4]=49, frame[5]=0, frame[6]=N (cmd == meta_type byte), frame[7...] = data.
/// MetadataType enum (verified from whoop_protocol.json):
///   1 = HISTORY_START, 2 = HISTORY_END, 3 = HISTORY_COMPLETE
///
/// HISTORY_END post-hook reads `pay = frame[7..<payEnd]` where pay is `<LHLL>` = 14 bytes:
///   pay[0..3]  = unix  (u32 LE)
///   pay[4..5]  = subsec (u16 LE)
///   pay[6..9]  = unk0  (u32 LE)
///   pay[10..13]= trim  (u32 LE)
final class HistoricalMetaTests: XCTestCase {

    // MARK: - helpers

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    private func le16(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
    }

    /// Build a parsed METADATA frame with the given cmd byte and optional payload.
    private func metaParsed(cmd: UInt8, payload: [UInt8] = []) -> ParsedFrame {
        let frame = frameFromPayload(payload, type: 49, seq: 0, cmd: cmd)
        return parseFrame(frame)
    }

    // MARK: - HISTORY_START (cmd=1)

    func testHistoryStart() {
        let p = metaParsed(cmd: 1)
        XCTAssertEqual(p.typeName, "METADATA")
        XCTAssertEqual(classifyHistoricalMeta(p), .start)
    }

    // MARK: - HISTORY_END (cmd=2) with known unix + trim

    func testHistoryEnd() {
        let expectedUnix: UInt32 = 1_700_000_000
        let expectedTrim: UInt32 = 9876
        // payload = unix(4) + subsec(2) + unk0(4) + trim(4) = 14 bytes
        let payload: [UInt8] = le32(expectedUnix) + le16(1000) + le32(0xDEAD) + le32(expectedTrim)
        let p = metaParsed(cmd: 2, payload: payload)
        XCTAssertEqual(p.typeName, "METADATA")
        let result = classifyHistoricalMeta(p)
        XCTAssertEqual(result, .end(unix: expectedUnix, trim: expectedTrim))
    }

    func testHistoryEndShortPayload() {
        // Post-hook requires >=14 bytes; a short payload means parsed keys are absent → .other
        let payload: [UInt8] = [0x01, 0x02, 0x03] // too short
        let p = metaParsed(cmd: 2, payload: payload)
        XCTAssertEqual(classifyHistoricalMeta(p), .other)
    }

    // MARK: - HISTORY_COMPLETE (cmd=3)

    func testHistoryComplete() {
        let p = metaParsed(cmd: 3)
        XCTAssertEqual(p.typeName, "METADATA")
        XCTAssertEqual(classifyHistoricalMeta(p), .complete)
    }

    // MARK: - non-METADATA frame → .other

    func testNonMetadataFrame() {
        // type 40 = REALTIME_DATA (not METADATA)
        let frame = frameFromPayload([0x01, 0x02, 0x03], type: 40, seq: 0, cmd: 0)
        let p = parseFrame(frame)
        XCTAssertNotEqual(p.typeName, "METADATA")
        XCTAssertEqual(classifyHistoricalMeta(p), .other)
    }

    // MARK: - unknown meta_type cmd → .other

    func testUnknownMetaType() {
        let p = metaParsed(cmd: 99) // not in MetadataType enum
        XCTAssertEqual(p.typeName, "METADATA")
        XCTAssertEqual(classifyHistoricalMeta(p), .other)
    }

    // MARK: - parsed dict sanity checks

    func testHistoryStartParsedDict() {
        // Schema.enumName() appends "(rawValue)" → "HISTORY_START(1)"
        let p = metaParsed(cmd: 1)
        XCTAssertEqual(p.parsed["meta_type"], .string("HISTORY_START(1)"))
    }

    func testHistoryEndParsedDict() {
        let unix: UInt32 = 1_600_000_000
        let trim: UInt32 = 42_000
        let payload: [UInt8] = le32(unix) + le16(0) + le32(0) + le32(trim)
        let p = metaParsed(cmd: 2, payload: payload)
        XCTAssertEqual(p.parsed["meta_type"], .string("HISTORY_END(2)"))
        XCTAssertEqual(p.parsed["unix"], .int(Int(unix)))
        XCTAssertEqual(p.parsed["trim_cursor"], .int(Int(trim)))
    }

    func testHistoryCompleteParsedDict() {
        // Schema.enumName() appends "(rawValue)" → "HISTORY_COMPLETE(3)"
        let p = metaParsed(cmd: 3)
        XCTAssertEqual(p.parsed["meta_type"], .string("HISTORY_COMPLETE(3)"))
    }
}
