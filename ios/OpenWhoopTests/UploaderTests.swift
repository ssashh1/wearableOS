import XCTest
import WhoopProtocol
import WhoopStore
@testable import OpenWhoop

// MARK: - StubURLProtocol

/// Intercepts all requests and returns a scripted response.
/// Bodies are captured by reading httpBodyStream (URLProtocol always uses the stream path
/// for sessions configured with protocolClasses).
final class StubURLProtocol: URLProtocol {

    // Per-test scripted responses keyed by URL path suffix.
    // e.g. "/v1/ingest-decoded" → 200, "/v1/ingest" → 500
    // Thread-safe via a simple static lock (tests run serially).
    static var responses: [String: Int] = [:]

    // Optional per-test response bodies keyed by URL path suffix (the first matching key wins).
    // Defaults to "{}" when no key matches (preserves prior behaviour for the POST tests).
    static var bodies: [String: String] = [:]

    // Optional per-test response bodies keyed by a substring of the FULL URL (path + query).
    // Checked BEFORE `bodies`, so a test can return different pages for the same path by matching
    // the distinct `from=` query value of each page request (longest matching key wins).
    static var bodiesByQuery: [String: String] = [:]

    // Captured requests in order received.
    static var captured: [CapturedRequest] = []

    struct CapturedRequest {
        let url: URL
        let method: String
        let authorization: String?
        let bodyData: Data
        var bodyJSON: Any? { try? JSONSerialization.jsonObject(with: bodyData) }
    }

    static func reset(responses: [String: Int] = [:],
                      bodies: [String: String] = [:],
                      bodiesByQuery: [String: String] = [:]) {
        Self.responses = responses
        Self.bodies = bodies
        Self.bodiesByQuery = bodiesByQuery
        Self.captured = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Drain body: URLProtocol sees httpBodyStream, not httpBody.
        var bodyData = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            let bufSize = 4096
            var buf = [UInt8](repeating: 0, count: bufSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buf, maxLength: bufSize)
                if read > 0 { bodyData.append(contentsOf: buf[..<read]) }
                else { break }
            }
            stream.close()
        } else if let body = request.httpBody {
            bodyData = body
        }

        let captured = StubURLProtocol.CapturedRequest(
            url: request.url!,
            method: request.httpMethod ?? "GET",
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            bodyData: bodyData
        )
        StubURLProtocol.captured.append(captured)

        let path = request.url?.path ?? ""
        let fullURL = request.url?.absoluteString ?? ""
        // Longest matching key wins, so "/v1/streams/skin_temp" isn't shadowed by "/v1/streams".
        func matchValue<V>(_ map: [String: V]) -> V? {
            map.filter { path.hasSuffix($0.key) }
               .max(by: { $0.key.count < $1.key.count })?.value
        }
        // bodiesByQuery matches on the full URL (path + query) so pages differing only by `from=`
        // can return distinct bodies. Longest matching key wins.
        func matchQuery(_ map: [String: String]) -> String? {
            map.filter { fullURL.contains($0.key) }
               .max(by: { $0.key.count < $1.key.count })?.value
        }
        let code = matchValue(Self.responses) ?? 200
        let bodyString = matchQuery(Self.bodiesByQuery) ?? matchValue(Self.bodies) ?? "{}"
        let response = HTTPURLResponse(url: request.url!,
                                       statusCode: code,
                                       httpVersion: nil,
                                       headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(bodyString.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - UploaderTests

final class UploaderTests: XCTestCase {

    private let baseURL = URL(string: "https://whoop.example.com")!
    private let apiKey = "test-key-abc"

    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    private func makeConfig() -> UploaderConfig {
        UploaderConfig(baseURL: baseURL, apiKey: apiKey)
    }

    // MARK: - decoded 200

    func testDecodedDrain200MarksRowsSyncedAndPostsCorrectShape() async throws {
        StubURLProtocol.reset(responses: ["/v1/ingest-decoded": 200])

        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "devA", mac: nil, name: nil)
        let streams = Streams(
            hr: [HRSample(ts: 1000, bpm: 60), HRSample(ts: 1001, bpm: 61)],
            rr: [RRInterval(ts: 1000, rrMs: 1000)]
        )
        try await store.insert(streams, deviceId: "devA")

        let uploader = Uploader(config: makeConfig(), store: store,
                                deviceId: "devA", session: makeSession())
        await uploader.drain()

        // All uploaded rows are now marked synced (synced = 1 → no unsynced rows remain).
        let unsyncedHR = try await store.unsyncedCountForTest(table: "hrSample", deviceId: "devA")
        let unsyncedRR = try await store.unsyncedCountForTest(table: "rrInterval", deviceId: "devA")
        XCTAssertEqual(unsyncedHR, 0, "all hr rows marked synced after 2xx")
        XCTAssertEqual(unsyncedRR, 0, "all rr rows marked synced after 2xx")

        // Battery and events NOT posted (empty → skipped)
        let paths = StubURLProtocol.captured.map { $0.url.path }
        XCTAssertFalse(paths.contains(where: { $0.hasSuffix("/v1/ingest") }),
                       "raw ingest endpoint should not be called")

        // Find the hr POST
        let hrPost = StubURLProtocol.captured.first {
            guard let json = $0.bodyJSON as? [String: Any],
                  let ss = json["streams"] as? [String: Any] else { return false }
            return ss["hr"] != nil
        }
        XCTAssertNotNil(hrPost, "Should have an hr POST")

        if let hrPost = hrPost {
            // Authorization header
            XCTAssertEqual(hrPost.authorization, "Bearer \(apiKey)")

            // Body shape
            let json = hrPost.bodyJSON as? [String: Any]
            XCTAssertNotNil(json)
            let device = json?["device"] as? [String: Any]
            XCTAssertEqual(device?["id"] as? String, "devA")
            let ss = json?["streams"] as? [String: Any]
            let hrRows = ss?["hr"] as? [[String: Any]]
            XCTAssertEqual(hrRows?.count, 2)
            XCTAssertEqual(hrRows?[0]["ts"] as? Int, 1000)
            XCTAssertEqual(hrRows?[0]["bpm"] as? Int, 60)
            XCTAssertEqual(hrRows?[1]["ts"] as? Int, 1001)
            XCTAssertEqual(hrRows?[1]["bpm"] as? Int, 61)
        }

        // Find the rr POST
        let rrPost = StubURLProtocol.captured.first {
            guard let json = $0.bodyJSON as? [String: Any],
                  let ss = json["streams"] as? [String: Any] else { return false }
            return ss["rr"] != nil
        }
        XCTAssertNotNil(rrPost, "Should have an rr POST")

        // Confirm no battery or events POST
        let batteryPost = StubURLProtocol.captured.first {
            guard let json = $0.bodyJSON as? [String: Any],
                  let ss = json["streams"] as? [String: Any] else { return false }
            return ss["battery"] != nil
        }
        XCTAssertNil(batteryPost, "Should NOT post battery when empty")

        let eventsPost = StubURLProtocol.captured.first {
            guard let json = $0.bodyJSON as? [String: Any],
                  let ss = json["streams"] as? [String: Any] else { return false }
            return ss["events"] != nil
        }
        XCTAssertNil(eventsPost, "Should NOT post events when empty")
    }

    // MARK: - decoded 500 leaves rows synced=0 for retry

    func testDecodedDrain500LeavesRowsUnsynced() async throws {
        StubURLProtocol.reset(responses: ["/v1/ingest-decoded": 500])

        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "devA", mac: nil, name: nil)
        try await store.insert(
            Streams(hr: [HRSample(ts: 2000, bpm: 72)]),
            deviceId: "devA")

        let uploader = Uploader(config: makeConfig(), store: store,
                                deviceId: "devA", session: makeSession())
        await uploader.drain()

        let unsynced = try await store.unsyncedCountForTest(table: "hrSample", deviceId: "devA")
        XCTAssertEqual(unsynced, 1, "row must stay synced=0 on 500 so it retries next drain")
    }

    // MARK: - decoded idempotent: second drain is a no-op (rows already synced)

    func testDecodedDrainIdempotent() async throws {
        StubURLProtocol.reset(responses: ["/v1/ingest-decoded": 200])

        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "devA", mac: nil, name: nil)
        try await store.insert(
            Streams(hr: [HRSample(ts: 3000, bpm: 65)]),
            deviceId: "devA")

        let uploader = Uploader(config: makeConfig(), store: store,
                                deviceId: "devA", session: makeSession())

        // First drain: posts 1 hr row and marks it synced.
        await uploader.drain()
        let firstUnsynced = try await store.unsyncedCountForTest(table: "hrSample", deviceId: "devA")
        XCTAssertEqual(firstUnsynced, 0, "row synced after first drain")

        // Second drain: no synced=0 rows remain, so no hr POST is made.
        StubURLProtocol.reset(responses: ["/v1/ingest-decoded": 200])
        await uploader.drain()
        let hrPosts = StubURLProtocol.captured.filter {
            guard let json = $0.bodyJSON as? [String: Any],
                  let ss = json["streams"] as? [String: Any] else { return false }
            return ss["hr"] != nil
        }
        XCTAssertEqual(hrPosts.count, 0,
                       "second drain should not POST already-synced hr rows")
    }

    // MARK: - REGRESSION: the backfill data-loss bug

    /// THE BUG: the old uploader used a forward-only `WHERE ts > highwater` cursor. Once the
    /// highwater jumped to a recent ts (live data), every backfilled row with an OLDER ts was
    /// permanently skipped. This is the repro: upload a NEWER row first (advancing the old cursor),
    /// then insert an OLDER row (simulating the historical offload backfilling the 14-day store) and
    /// confirm the older row IS uploaded on the next drain. With the broken highwater logic this
    /// older row would never be sent; the per-row `synced` flag selects it regardless of ts order.
    func testBackfilledOlderRowIsUploadedAfterNewerRow() async throws {
        StubURLProtocol.reset(responses: ["/v1/ingest-decoded": 200])
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "devA", mac: nil, name: nil)

        // 1) A recent live row arrives and is uploaded (would advance the old highwater to 1001).
        try await store.insert(Streams(hr: [HRSample(ts: 1001, bpm: 61)]), deviceId: "devA")
        let uploader = Uploader(config: makeConfig(), store: store,
                                deviceId: "devA", session: makeSession())
        await uploader.drain()
        let afterFirst = try await store.unsyncedCountForTest(table: "hrSample", deviceId: "devA")
        XCTAssertEqual(afterFirst, 0, "the newer row is uploaded and marked synced")

        // 2) Backfill: an OLDER-ts row (ts=500 < 1001) lands from the historical offload.
        try await store.insert(Streams(hr: [HRSample(ts: 500, bpm: 55)]), deviceId: "devA")
        let afterBackfill = try await store.unsyncedCountForTest(table: "hrSample", deviceId: "devA")
        XCTAssertEqual(afterBackfill, 1, "the backfilled older row is unsynced (synced=0)")

        // 3) Next drain MUST upload the older row (the bug: old highwater logic skipped it forever).
        StubURLProtocol.reset(responses: ["/v1/ingest-decoded": 200])
        await uploader.drain()
        let afterDrain = try await store.unsyncedCountForTest(table: "hrSample", deviceId: "devA")
        XCTAssertEqual(afterDrain, 0, "the backfilled older row IS uploaded and marked synced")
        // Confirm the POST actually carried the older row.
        let hrPost = StubURLProtocol.captured.first {
            guard let json = $0.bodyJSON as? [String: Any],
                  let ss = json["streams"] as? [String: Any] else { return false }
            return ss["hr"] != nil
        }
        let rows = (hrPost?.bodyJSON as? [String: Any]).flatMap { ($0["streams"] as? [String: Any])?["hr"] as? [[String: Any]] }
        XCTAssertEqual(rows?.count, 1)
        XCTAssertEqual(rows?.first?["ts"] as? Int, 500, "the older backfilled row was uploaded")
    }

    /// A NEWER row drained after an earlier drain still uploads (selection is the per-row flag,
    /// so newer rows upload exactly like older ones — no cursor ordering dependence).
    func testNewerRowUploadsOnSubsequentDrain() async throws {
        StubURLProtocol.reset(responses: ["/v1/ingest-decoded": 200])
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "devA", mac: nil, name: nil)
        try await store.insert(Streams(hr: [HRSample(ts: 1000, bpm: 60)]), deviceId: "devA")
        let uploader = Uploader(config: makeConfig(), store: store,
                                deviceId: "devA", session: makeSession())
        await uploader.drain()
        let n1 = try await store.unsyncedCountForTest(table: "hrSample", deviceId: "devA")
        XCTAssertEqual(n1, 0)

        try await store.insert(Streams(hr: [HRSample(ts: 2000, bpm: 62)]), deviceId: "devA")
        StubURLProtocol.reset(responses: ["/v1/ingest-decoded": 200])
        await uploader.drain()
        let n2 = try await store.unsyncedCountForTest(table: "hrSample", deviceId: "devA")
        XCTAssertEqual(n2, 0, "the newer row uploads on the subsequent drain")
    }

    // MARK: - raw 200: batches synced

    func testRawDrain200MarksBatchesSynced() async throws {
        StubURLProtocol.reset(responses: ["/v1/ingest": 200])

        let store = try await WhoopStore.inMemory()

        let meta1 = RawBatchMeta(batchId: "batch-1", deviceId: "devB",
                                  clockRef: ClockRef(device: 100_000, wall: 1_700_000_000),
                                  capturedAt: 1_700_000_001, startTs: 100_000, endTs: 100_010,
                                  frameCount: 2, byteSize: 20)
        let meta2 = RawBatchMeta(batchId: "batch-2", deviceId: "devB",
                                  clockRef: ClockRef(device: 200_000, wall: 1_700_001_000),
                                  capturedAt: 1_700_001_001, startTs: 200_000, endTs: 200_010,
                                  frameCount: 1, byteSize: 10)
        try await store.enqueueRawBatch(meta1, frames: [[0xAA, 0xBB], [0xCC, 0xDD]])
        try await store.enqueueRawBatch(meta2, frames: [[0x11, 0x22, 0x33]])

        let uploader = Uploader(config: makeConfig(), store: store,
                                deviceId: "devB", session: makeSession())
        await uploader.drainRaw()   // raw is no longer in the default drain() path

        // Both batches should be synced now
        let pending = try await store.pendingRawBatches(limit: 20)
        XCTAssertEqual(pending.count, 0, "all raw batches should be marked synced on 200")

        // Two requests to /v1/ingest
        let rawPosts = StubURLProtocol.captured.filter { $0.url.path.hasSuffix("/v1/ingest") }
        XCTAssertEqual(rawPosts.count, 2, "should have posted both batches")

        // Validate shape of first raw POST
        if let first = rawPosts.first {
            XCTAssertEqual(first.authorization, "Bearer \(apiKey)")
            let json = first.bodyJSON as? [String: Any]
            XCTAssertNotNil(json)
            XCTAssertEqual(json?["batch_id"] as? String, "batch-1")
            XCTAssertEqual((json?["decode_streams"] as? Bool), false)
            let device = json?["device"] as? [String: Any]
            XCTAssertEqual(device?["device_id"] as? String, "devB")
            let clockRef = json?["clock_ref"] as? [String: Any]
            XCTAssertEqual(clockRef?["device"] as? Int, 100_000)
            XCTAssertEqual(clockRef?["wall"] as? Int, 1_700_000_000)
            let frames = json?["frames"] as? [[String: Any]]
            XCTAssertEqual(frames?.count, 2)
            // Frames should have "hex" keys
            XCTAssertNotNil(frames?[0]["hex"])
        }
    }

    // MARK: - raw 500: batches remain pending

    func testRawDrain500LeavsBatchesPending() async throws {
        StubURLProtocol.reset(responses: ["/v1/ingest": 500])

        let store = try await WhoopStore.inMemory()

        let meta = RawBatchMeta(batchId: "batch-x", deviceId: "devC",
                                 clockRef: ClockRef(device: 50_000, wall: 1_700_500_000),
                                 capturedAt: 1_700_500_001, startTs: 50_000, endTs: 50_005,
                                 frameCount: 1, byteSize: 5)
        try await store.enqueueRawBatch(meta, frames: [[0xFF]])

        let uploader = Uploader(config: makeConfig(), store: store,
                                deviceId: "devC", session: makeSession())
        await uploader.drainRaw()   // raw is no longer in the default drain() path

        let pending = try await store.pendingRawBatches(limit: 20)
        XCTAssertEqual(pending.count, 1, "batch must remain pending on 500 — retry safe")
    }

    // MARK: - new biometric streams: spo2 / skin_temp / resp / gravity

    func testDrainPostsNewBiometricStreamsWithCorrectKeys() async throws {
        StubURLProtocol.reset(responses: ["/v1/ingest-decoded": 200])

        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "devA", mac: nil, name: nil)
        let streams = Streams(
            spo2: [SpO2Sample(ts: 5000, red: 111, ir: 222)],
            skinTemp: [SkinTempSample(ts: 5001, raw: 333)],
            resp: [RespSample(ts: 5002, raw: 444)],
            gravity: [GravitySample(ts: 5003, x: 0.1, y: 0.2, z: 9.8)]
        )
        try await store.insert(streams, deviceId: "devA")

        let uploader = Uploader(config: makeConfig(), store: store,
                                deviceId: "devA", session: makeSession())
        await uploader.drain()

        // Each new stream's rows are marked synced after the 2xx.
        let spo2N = try await store.unsyncedCountForTest(table: "spo2Sample", deviceId: "devA")
        let skinN = try await store.unsyncedCountForTest(table: "skinTempSample", deviceId: "devA")
        let respN = try await store.unsyncedCountForTest(table: "respSample", deviceId: "devA")
        let gravN = try await store.unsyncedCountForTest(table: "gravitySample", deviceId: "devA")
        XCTAssertEqual([spo2N, skinN, respN, gravN], [0, 0, 0, 0])

        func streamPost(_ key: String) -> [String: Any]? {
            StubURLProtocol.captured.compactMap {
                guard let json = $0.bodyJSON as? [String: Any],
                      let ss = json["streams"] as? [String: Any],
                      ss[key] != nil else { return nil }
                return ss
            }.first
        }

        // spo2 → {ts, red, ir}
        let spo2Rows = streamPost("spo2")?["spo2"] as? [[String: Any]]
        XCTAssertEqual(spo2Rows?.count, 1)
        XCTAssertEqual(spo2Rows?[0]["ts"] as? Int, 5000)
        XCTAssertEqual(spo2Rows?[0]["red"] as? Int, 111)
        XCTAssertEqual(spo2Rows?[0]["ir"] as? Int, 222)

        // skin_temp → {ts, raw}
        let skinRows = streamPost("skin_temp")?["skin_temp"] as? [[String: Any]]
        XCTAssertEqual(skinRows?.count, 1)
        XCTAssertEqual(skinRows?[0]["ts"] as? Int, 5001)
        XCTAssertEqual(skinRows?[0]["raw"] as? Int, 333)

        // resp → {ts, raw}
        let respRows = streamPost("resp")?["resp"] as? [[String: Any]]
        XCTAssertEqual(respRows?.count, 1)
        XCTAssertEqual(respRows?[0]["ts"] as? Int, 5002)
        XCTAssertEqual(respRows?[0]["raw"] as? Int, 444)

        // gravity → {ts, x, y, z}
        let gravRows = streamPost("gravity")?["gravity"] as? [[String: Any]]
        XCTAssertEqual(gravRows?.count, 1)
        XCTAssertEqual(gravRows?[0]["ts"] as? Int, 5003)
        XCTAssertEqual(gravRows?[0]["x"] as? Double, 0.1)
        XCTAssertEqual(gravRows?[0]["y"] as? Double, 0.2)
        XCTAssertEqual(gravRows?[0]["z"] as? Double, 9.8)
    }

    // MARK: - drain() never POSTs raw by default

    func testDrainDoesNotPostRawByDefault() async throws {
        StubURLProtocol.reset(responses: ["/v1/ingest-decoded": 200, "/v1/ingest": 200])

        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "devA", mac: nil, name: nil)
        try await store.insert(Streams(hr: [HRSample(ts: 7000, bpm: 70)]), deviceId: "devA")
        // Seed a pending raw batch — drain() must NOT touch it.
        let meta = RawBatchMeta(batchId: "raw-1", deviceId: "devA",
                                clockRef: ClockRef(device: 1, wall: 2),
                                capturedAt: 3, startTs: 1, endTs: 2,
                                frameCount: 1, byteSize: 1)
        try await store.enqueueRawBatch(meta, frames: [[0xAB]])

        let uploader = Uploader(config: makeConfig(), store: store,
                                deviceId: "devA", session: makeSession())
        await uploader.drain()

        let rawPosts = StubURLProtocol.captured.filter { $0.url.path.hasSuffix("/v1/ingest") }
        XCTAssertTrue(rawPosts.isEmpty, "drain() must NEVER POST to the raw /v1/ingest endpoint")
        // And the raw batch is still pending (untouched).
        let pending = try await store.pendingRawBatches(limit: 20)
        XCTAssertEqual(pending.count, 1, "raw batch left pending — never auto-uploaded")
    }
}
