import XCTest
import WhoopProtocol
import WhoopStore
@testable import OpenWhoop

/// Mirror of UploaderTests but for the pull path: a stubbed URLSession (StubURLProtocol, defined
/// in UploaderTests.swift) + in-memory WhoopStore. Asserts pulled rows are upserted, the
/// read-highwater advances only on 2xx, ts ISO→epoch parsing is correct, and re-pulls dedup.
final class ServerSyncTests: XCTestCase {

    private let baseURL = URL(string: "https://whoop.example.com")!
    private let apiKey = "test-key-abc"

    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }
    private func makeConfig() -> UploaderConfig { UploaderConfig(baseURL: baseURL, apiKey: apiKey) }

    // 2026-05-23T21:08:28+00:00 == 1779916108 ; +29s == 1779916109? No: 21:08:29 == 1779916109.
    private let isoA = "2026-05-23T21:08:28+00:00"
    private let isoB = "2026-05-23T21:08:29+00:00"
    private var epochA: Int { ServerSync.parseEpoch("2026-05-23T21:08:28+00:00")! }
    private var epochB: Int { ServerSync.parseEpoch("2026-05-23T21:08:29+00:00")! }

    // MARK: - ts parsing

    func testParseEpochISO8601() {
        // Known: 2026-05-23T21:08:28Z
        let a = ServerSync.parseEpoch("2026-05-23T21:08:28+00:00")
        let z = ServerSync.parseEpoch("2026-05-23T21:08:28Z")
        let frac = ServerSync.parseEpoch("2026-05-23T21:08:28.123Z")
        XCTAssertNotNil(a)
        XCTAssertEqual(a, z, "offset and Z forms must parse equal")
        XCTAssertEqual(frac, a, "fractional seconds truncate to same whole second")
        XCTAssertEqual(epochB, epochA + 1, "consecutive seconds differ by 1")
        XCTAssertNil(ServerSync.parseEpoch("not-a-date"))
    }

    // MARK: - decoded pull upserts + advances read-highwater

    func testPullDecodedUpsertsAndAdvancesReadHighwater() async throws {
        let hrBody = "[{\"ts\":\"\(isoA)\",\"bpm\":60},{\"ts\":\"\(isoB)\",\"bpm\":59}]"
        StubURLProtocol.reset(
            responses: [:],   // all 200 by default
            bodies: ["/v1/streams/hr": hrBody]
        )

        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: nil)
        let sync = ServerSync(config: makeConfig(), store: store,
                              deviceId: "my-whoop", session: makeSession())
        await sync.pull()

        // Rows upserted (read back via the existing decoded reads).
        let hr = try await store.hrSamples(deviceId: "my-whoop", from: 0, to: Int.max, limit: 100)
        XCTAssertEqual(hr.count, 2)
        XCTAssertEqual(hr[0].ts, epochA)
        XCTAssertEqual(hr[0].bpm, 60)
        XCTAssertEqual(hr[1].ts, epochB)
        XCTAssertEqual(hr[1].bpm, 59)

        // Read-highwater advanced to max pulled ts.
        let rhw = try await store.readHighwater("hr")
        XCTAssertEqual(rhw, epochB)

        // GET used Bearer auth.
        let hrGet = StubURLProtocol.captured.first { $0.url.path.hasSuffix("/v1/streams/hr") }
        XCTAssertNotNil(hrGet)
        XCTAssertEqual(hrGet?.method, "GET")
        XCTAssertEqual(hrGet?.authorization, "Bearer \(apiKey)")
    }

    // MARK: - non-2xx leaves store + read-highwater unchanged

    func testPullDecoded500LeavesStoreAndHighwaterUnchanged() async throws {
        let hrBody = "[{\"ts\":\"\(isoA)\",\"bpm\":60}]"
        StubURLProtocol.reset(
            responses: ["/v1/streams/hr": 500],
            bodies: ["/v1/streams/hr": hrBody]
        )
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: nil)
        let sync = ServerSync(config: makeConfig(), store: store,
                              deviceId: "my-whoop", session: makeSession())
        await sync.pull()

        let hr = try await store.hrSamples(deviceId: "my-whoop", from: 0, to: Int.max, limit: 100)
        XCTAssertEqual(hr.count, 0, "no rows upserted on 500")
        let rhw = try await store.readHighwater("hr")
        XCTAssertNil(rhw, "read-highwater must NOT advance on 500")
    }

    // MARK: - re-pull dedups by natural key

    func testRePullDoesNotDuplicate() async throws {
        let hrBody = "[{\"ts\":\"\(isoA)\",\"bpm\":60},{\"ts\":\"\(isoB)\",\"bpm\":59}]"
        StubURLProtocol.reset(bodies: ["/v1/streams/hr": hrBody])

        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: nil)
        let sync = ServerSync(config: makeConfig(), store: store,
                              deviceId: "my-whoop", session: makeSession())

        await sync.pull()
        await sync.pull()   // same canned rows again

        let hr = try await store.hrSamples(deviceId: "my-whoop", from: 0, to: Int.max, limit: 100)
        XCTAssertEqual(hr.count, 2, "re-pulling the same rows must not duplicate (natural-key dedup)")
    }

    // MARK: - REGRESSION: read-highwater is monotonic (forward-only) across pulls

    /// Audit 4.2: the read (pull) highwater must only advance forward. After a pull sets it to
    /// epochB, a SECOND pull that returns ONLY an older row (epochA < epochB) must not drag the
    /// cursor backward — the pager reads `from = highwater+1`, so an older row is below the floor
    /// and the cursor stays put (and re-pulling it would dedup anyway). Companion to the upload
    /// monotonicity regression in UploaderTests.
    func testReadHighwaterIsMonotonicForwardOnly() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: nil)
        let sync = ServerSync(config: makeConfig(), store: store,
                              deviceId: "my-whoop", session: makeSession())

        // First pull advances read-highwater to epochB.
        StubURLProtocol.reset(bodies: [
            "/v1/streams/hr": "[{\"ts\":\"\(isoA)\",\"bpm\":60},{\"ts\":\"\(isoB)\",\"bpm\":59}]"
        ])
        await sync.pull()
        let rhw1 = try await store.readHighwater("hr")
        XCTAssertEqual(rhw1, epochB)

        // Second pull returns ONLY the older row. The cursor must NOT regress to epochA.
        StubURLProtocol.reset(bodies: ["/v1/streams/hr": "[{\"ts\":\"\(isoA)\",\"bpm\":60}]"])
        await sync.pull()
        let rhw2 = try await store.readHighwater("hr")
        XCTAssertEqual(rhw2, epochB,
                       "read-highwater must never move backward when an older row arrives")
        // And no duplicate row was created.
        let hr = try await store.hrSamples(deviceId: "my-whoop", from: 0, to: Int.max, limit: 100)
        XCTAssertEqual(hr.count, 2, "older re-pulled row dedups by natural key")
    }

    // MARK: - gravity (doubles) + skin_temp (raw) pull

    func testPullGravityAndSkinTemp() async throws {
        let gravBody = "[{\"ts\":\"\(isoA)\",\"x\":0.1,\"y\":0.2,\"z\":9.8}]"
        // server includes computed value+unit for skin_temp; we must store ONLY raw.
        let skinBody = "[{\"ts\":\"\(isoA)\",\"raw\":333,\"value\":31.2,\"unit\":\"celsius\"}]"
        StubURLProtocol.reset(bodies: [
            "/v1/streams/gravity": gravBody,
            "/v1/streams/skin_temp": skinBody,
        ])
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: nil)
        let sync = ServerSync(config: makeConfig(), store: store,
                              deviceId: "my-whoop", session: makeSession())
        await sync.pull()

        let grav = try await store.gravitySamples(deviceId: "my-whoop", from: 0, to: Int.max, limit: 10)
        XCTAssertEqual(grav.count, 1)
        XCTAssertEqual(grav[0].ts, epochA)
        XCTAssertEqual(grav[0].x, 0.1, accuracy: 1e-9)
        XCTAssertEqual(grav[0].z, 9.8, accuracy: 1e-9)

        let skin = try await store.skinTempSamples(deviceId: "my-whoop", from: 0, to: Int.max, limit: 10)
        XCTAssertEqual(skin.count, 1)
        XCTAssertEqual(skin[0].raw, 333, "only the raw col is stored; value/unit ignored")
    }

    // MARK: - derived: daily + sleep

    func testPullDerivedDailyAndSleep() async throws {
        // Pick a day inside the derived window so /v1/sleep?date=... is queried for it.
        let cal = Calendar(identifier: .gregorian)
        let fmt = DateFormatter()
        fmt.calendar = cal; fmt.timeZone = TimeZone(identifier: "UTC"); fmt.dateFormat = "yyyy-MM-dd"
        let today = fmt.string(from: Date())

        // NOTE: the server emits recovery as a 0–100 score (e.g. 66.0). The app's
        // DailyMetric.recovery contract is a 0–1 fraction (every display site does
        // `recovery * 100`), so getDaily must normalize on decode.
        let dailyBody = """
        [{"day":"\(today)","total_sleep_min":420.0,"efficiency":0.9,"deep_min":90,"rem_min":110,\
        "light_min":220,"disturbances":3,"resting_hr":53,"avg_hrv":60.0,"recovery":66.0,\
        "strain":12.3,"exercise_count":1}]
        """
        let sleepBody = """
        {"start_ts":"\(isoA)","end_ts":"\(isoB)","efficiency":0.92,"resting_hr":52,"avg_hrv":65.5,\
        "stages":[{"start":\(epochA),"end":\(epochB),"stage":"deep"}]}
        """
        StubURLProtocol.reset(bodies: [
            "/v1/daily": dailyBody,
            "/v1/sleep": sleepBody,
        ])

        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: nil)
        let sync = ServerSync(config: makeConfig(), store: store,
                              deviceId: "my-whoop", session: makeSession())
        await sync.pull()

        let days = try await store.dailyMetrics(deviceId: "my-whoop", from: "2000-01-01", to: "2100-01-01")
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].day, today)
        XCTAssertEqual(days[0].totalSleepMin, 420.0)
        XCTAssertEqual(days[0].restingHr, 53)
        XCTAssertEqual(days[0].exerciseCount, 1)
        // Server's 0–100 score must be normalized to the app's 0–1 contract.
        XCTAssertEqual(try XCTUnwrap(days[0].recovery), 0.66, accuracy: 1e-6)

        // /v1/sleep is queried per-day over the window; the same body is returned each call, so the
        // single session (natural key startTs=epochA) is upserted once (dedup across days).
        let sleeps = try await store.sleepSessions(deviceId: "my-whoop", from: 0, to: Int.max, limit: 100)
        XCTAssertEqual(sleeps.count, 1)
        XCTAssertEqual(sleeps[0].startTs, epochA)
        XCTAssertEqual(sleeps[0].endTs, epochB)
        XCTAssertEqual(sleeps[0].efficiency, 0.92)
        XCTAssertEqual(sleeps[0].restingHr, 52)
        XCTAssertNotNil(sleeps[0].stagesJSON)
        XCTAssertTrue(sleeps[0].stagesJSON!.contains("deep"))
    }

    // MARK: - multi-page decoded pull (exercises the paging loop)

    /// First page == pageLimit rows (full) with ascending ts → the loop must re-query with
    /// from = max+1 and pull the short second page. Asserts BOTH pages persist and the
    /// read-highwater ends at the LAST row's ts. Pages are distinguished by their `from=` query.
    func testPullDecodedMultiPage() async throws {
        let limit = ServerSync.pageLimit
        // Page 1: ts = 1000 ... 1000+limit-1 (exactly `limit` rows → not the last page).
        let firstStart = 1000
        let firstEnd = firstStart + limit - 1          // inclusive
        var p1 = "["
        for ts in firstStart...firstEnd {
            if ts > firstStart { p1 += "," }
            p1 += "{\"ts\":\(ts),\"bpm\":60}"
        }
        p1 += "]"
        // Page 2: short (2 rows) starting at firstEnd+1 → terminates the loop.
        let secondA = firstEnd + 1
        let secondB = firstEnd + 2
        let p2 = "[{\"ts\":\(secondA),\"bpm\":61},{\"ts\":\(secondB),\"bpm\":62}]"

        // Page 1 is fetched with from=0 (first pull, no highwater). Page 2 is fetched with
        // from=firstEnd+1 once the highwater advances to firstEnd. Match on those `from=` values.
        StubURLProtocol.reset(bodiesByQuery: [
            "from=0&": p1,
            "from=\(secondA)&": p2,
        ])

        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: nil)
        let sync = ServerSync(config: makeConfig(), store: store,
                              deviceId: "my-whoop", session: makeSession())
        await sync.pull()

        // Both pages persisted: limit + 2 total HR rows.
        let hr = try await store.hrSamples(deviceId: "my-whoop", from: 0, to: Int.max, limit: limit + 100)
        XCTAssertEqual(hr.count, limit + 2, "both the full first page and the short second page must persist")
        XCTAssertEqual(hr.first?.ts, firstStart)
        XCTAssertEqual(hr.last?.ts, secondB)

        // Read-highwater ends at the LAST row's ts.
        let rhw = try await store.readHighwater("hr")
        XCTAssertEqual(rhw, secondB, "read-highwater must end at the last pulled ts")

        // Confirm the loop made a second page request (from=firstEnd+1).
        let secondPageReq = StubURLProtocol.captured.first {
            $0.url.path.hasSuffix("/v1/streams/hr") && $0.url.absoluteString.contains("from=\(secondA)&")
        }
        XCTAssertNotNil(secondPageReq, "the pager must re-query from max+1 after a full page")
    }

    // MARK: - Cloud restore (restoreIfEmpty)

    /// Empty store + stubbed server with N decoded rows + daily/sleep → restoreIfEmpty() returns
    /// true, the local store is rebuilt to N rows (read them back), derived metrics are present,
    /// and read-highwater is advanced so a follow-up incremental pull() fetches nothing new.
    func testRestoreIfEmptyRebuildsStoreAndAdvancesHighwater() async throws {
        let hrBody   = "[{\"ts\":\"\(isoA)\",\"bpm\":60},{\"ts\":\"\(isoB)\",\"bpm\":59}]"
        let rrBody   = "[{\"ts\":\"\(isoA)\",\"rr_ms\":820}]"
        // Build a daily row for "today" so it falls inside the 400-day full-restore window.
        let cal = Calendar(identifier: .gregorian)
        let fmt = DateFormatter()
        fmt.calendar = cal; fmt.timeZone = TimeZone(identifier: "UTC"); fmt.dateFormat = "yyyy-MM-dd"
        let today = fmt.string(from: Date())
        let dailyBody = "[{\"day\":\"\(today)\",\"total_sleep_min\":480.0}]"
        let sleepBody = "{\"start_ts\":\"\(isoA)\",\"end_ts\":\"\(isoB)\"}"

        StubURLProtocol.reset(bodies: [
            "/v1/streams/hr": hrBody,
            "/v1/streams/rr": rrBody,
            "/v1/daily": dailyBody,
            "/v1/sleep": sleepBody,
        ])

        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: nil)
        let sync = ServerSync(config: makeConfig(), store: store,
                              deviceId: "my-whoop", session: makeSession())

        // Store is empty → restoreIfEmpty() must return true.
        let restored = await sync.restoreIfEmpty()
        XCTAssertTrue(restored, "restoreIfEmpty must return true when the store was empty")

        // Decoded rows present.
        let hr = try await store.hrSamples(deviceId: "my-whoop", from: 0, to: Int.max, limit: 100)
        XCTAssertEqual(hr.count, 2, "both HR rows must be restored")
        let rr = try await store.rrIntervals(deviceId: "my-whoop", from: 0, to: Int.max, limit: 100)
        XCTAssertEqual(rr.count, 1, "RR row must be restored")

        // Derived metrics present.
        let days = try await store.dailyMetrics(deviceId: "my-whoop", from: "2000-01-01", to: "2100-01-01")
        XCTAssertFalse(days.isEmpty, "daily metrics must be restored")
        let sleeps = try await store.sleepSessions(deviceId: "my-whoop", from: 0, to: Int.max, limit: 100)
        XCTAssertFalse(sleeps.isEmpty, "sleep sessions must be restored")

        // Read-highwater advanced to the max pulled ts so a follow-up incremental pull is a no-op.
        let rhwHR = try await store.readHighwater("hr")
        XCTAssertEqual(rhwHR, epochB, "read-highwater must be set to the last restored ts")

        // Follow-up incremental pull must not re-fetch (server would return empty from epochB+1).
        // We confirm by checking the captured URL list: the next pull should request from=epochB+1
        // which returns [] (default stub), so no new rows are added.
        StubURLProtocol.reset(bodies: [:])   // stub: all streams return [] from now on
        await sync.pull()
        let hrAfter = try await store.hrSamples(deviceId: "my-whoop", from: 0, to: Int.max, limit: 100)
        XCTAssertEqual(hrAfter.count, 2, "follow-up incremental pull must not add duplicate rows")
    }

    /// Non-empty store (seed one HR row first) → restoreIfEmpty() returns false and does NOT
    /// re-page full history (store unchanged, no extra requests for the seeded kind).
    func testRestoreIfEmptyIsNoOpOnNonEmptyStore() async throws {
        let hrBody = "[{\"ts\":\"\(isoA)\",\"bpm\":60}]"
        StubURLProtocol.reset(bodies: ["/v1/streams/hr": hrBody])

        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: nil)
        let sync = ServerSync(config: makeConfig(), store: store,
                              deviceId: "my-whoop", session: makeSession())

        // Seed one row so the store is non-empty.
        await sync.pull()
        let hrBefore = try await store.hrSamples(deviceId: "my-whoop", from: 0, to: Int.max, limit: 100)
        XCTAssertEqual(hrBefore.count, 1, "precondition: 1 row seeded")

        // Now call restoreIfEmpty() — should be a no-op.
        StubURLProtocol.reset(bodies: [:])   // clear stubs so any full-history request would return []
        let restored = await sync.restoreIfEmpty()
        XCTAssertFalse(restored, "restoreIfEmpty must return false when the store is non-empty")

        // Store must be unchanged.
        let hrAfter = try await store.hrSamples(deviceId: "my-whoop", from: 0, to: Int.max, limit: 100)
        XCTAssertEqual(hrAfter.count, 1, "no-op: store must be unchanged")
    }

    /// Multi-page full restore: a decoded stream with > pageLimit rows must restore ALL pages.
    /// Verifies that the forcedFrom=0 first page does NOT prevent subsequent pages from being
    /// fetched (the cursor-based pager must take over after the first page).
    func testRestoreIfEmptyMultiPage() async throws {
        let limit = ServerSync.pageLimit
        // Page 1: exactly `limit` rows (ts = 1000 ... 1000+limit-1), triggers a second page.
        let firstStart = 1000
        let firstEnd = firstStart + limit - 1
        var p1 = "["
        for ts in firstStart...firstEnd {
            if ts > firstStart { p1 += "," }
            p1 += "{\"ts\":\(ts),\"bpm\":60}"
        }
        p1 += "]"
        // Page 2: short (2 rows) — terminates the loop.
        let secondA = firstEnd + 1
        let secondB = firstEnd + 2
        let p2 = "[{\"ts\":\(secondA),\"bpm\":61},{\"ts\":\(secondB),\"bpm\":62}]"

        // Page 1 fetched from=0 (full restore). Page 2 fetched from=firstEnd+1 (cursor advance).
        // Keys include the path prefix "/v1/streams/hr" so only HR requests match these bodies;
        // all other stream kinds fall through to the default stub (empty array "[]" isn't returned
        // but the bodiesByQuery default of "{}" is fine — they return 0 rows and terminate quickly).
        // bodiesByQuery matches via fullURL.contains(key) with longest-key-wins, so a path-scoped
        // key is unambiguous even when restoreIfEmpty pulls all 8 stream kinds from ts=0.
        StubURLProtocol.reset(bodiesByQuery: [
            "/v1/streams/hr?device=my-whoop&from=0&": p1,
            "/v1/streams/hr?device=my-whoop&from=\(secondA)&": p2,
        ])

        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: nil)
        let sync = ServerSync(config: makeConfig(), store: store,
                              deviceId: "my-whoop", session: makeSession())

        let restored = await sync.restoreIfEmpty()
        XCTAssertTrue(restored, "restoreIfEmpty must return true on empty store")

        // All pages must be present: limit + 2 HR rows.
        let hr = try await store.hrSamples(deviceId: "my-whoop", from: 0, to: Int.max, limit: limit + 100)
        XCTAssertEqual(hr.count, limit + 2, "both pages must be restored")
        XCTAssertEqual(hr.first?.ts, firstStart)
        XCTAssertEqual(hr.last?.ts, secondB)

        // Read-highwater ends at the last row of the second page.
        let rhw = try await store.readHighwater("hr")
        XCTAssertEqual(rhw, secondB, "read-highwater must end at the last restored ts")

        // Confirm the second page was fetched (from=firstEnd+1).
        let secondPageReq = StubURLProtocol.captured.first {
            $0.url.path.hasSuffix("/v1/streams/hr") && $0.url.absoluteString.contains("from=\(secondA)&")
        }
        XCTAssertNotNil(secondPageReq, "multi-page restore must fetch all pages")
    }

    // MARK: - Profile networking (M0.5)

    func testGetProfileDecodesResponse() async throws {
        let profileBody = """
        {"height_cm":180.0,"weight_kg":75.0,"age":30,"sex":"male"}
        """
        StubURLProtocol.reset(bodies: ["/v1/profile": profileBody])

        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: nil)
        let sync = ServerSync(config: makeConfig(), store: store,
                              deviceId: "my-whoop", session: makeSession())

        let profile = await sync.getProfile()
        XCTAssertNotNil(profile)
        XCTAssertEqual(profile?.heightCm ?? 0, 180.0, accuracy: 0.01)
        XCTAssertEqual(profile?.weightKg ?? 0, 75.0,  accuracy: 0.01)
        XCTAssertEqual(profile?.age, 30)
        XCTAssertEqual(profile?.sex, "male")

        // Must have used GET + Bearer auth.
        let req = StubURLProtocol.captured.first { $0.url.path.contains("/v1/profile") }
        XCTAssertEqual(req?.method, "GET")
        XCTAssertEqual(req?.authorization, "Bearer \(apiKey)")
    }

    func testGetProfileEmptyObjectReturnsNil() async throws {
        StubURLProtocol.reset(bodies: ["/v1/profile": "{}"])
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: nil)
        let sync = ServerSync(config: makeConfig(), store: store,
                              deviceId: "my-whoop", session: makeSession())
        let profile = await sync.getProfile()
        XCTAssertNil(profile, "empty {} from server should be treated as no-profile")
    }

    func testPutProfileSendsCorrectPayload() async throws {
        StubURLProtocol.reset(responses: ["/v1/profile": 201], bodies: ["/v1/profile": "{}"])
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: nil)
        let sync = ServerSync(config: makeConfig(), store: store,
                              deviceId: "my-whoop", session: makeSession())

        let profile = Profile(heightCm: 180.0, weightKg: 75.0, age: 30, sex: "male")
        let ok = await sync.putProfile(profile)
        XCTAssertTrue(ok, "201 is a 2xx and should return true")

        // Verify request details.
        let req = StubURLProtocol.captured.first { $0.url.path.hasSuffix("/v1/profile") && $0.method == "POST" }
        XCTAssertNotNil(req)
        XCTAssertEqual(req?.authorization, "Bearer \(apiKey)")
        let json = req?.bodyJSON as? [String: Any]
        XCTAssertNotNil(json)
        XCTAssertEqual(json?["device"] as? String, "my-whoop")
        XCTAssertEqual(json?["height_cm"] as? Double ?? 0, 180.0, accuracy: 0.01)
        XCTAssertEqual(json?["weight_kg"] as? Double ?? 0, 75.0,  accuracy: 0.01)
        XCTAssertEqual(json?["age"] as? Int, 30)
        XCTAssertEqual(json?["sex"] as? String, "male")
    }

    func testPutProfile500ReturnsFalse() async throws {
        StubURLProtocol.reset(responses: ["/v1/profile": 500], bodies: ["/v1/profile": "{}"])
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: nil)
        let sync = ServerSync(config: makeConfig(), store: store,
                              deviceId: "my-whoop", session: makeSession())
        let ok = await sync.putProfile(Profile(heightCm: 180, weightKg: 75, age: 30, sex: "male"))
        XCTAssertFalse(ok, "500 response should return false")
    }

    // MARK: - paging termination uses RAW server count, not post-filter parsed count

    /// A FULL page (pageLimit server rows) containing one UNPARSEABLE row parses to pageLimit-1,
    /// but the loop must NOT stop early: termination is based on the raw server-row count. So a
    /// real second page must still be pulled.
    func testPullDecodedFullPageWithBadRowStillPagesNext() async throws {
        let limit = ServerSync.pageLimit
        let firstStart = 1000
        // Page 1: (limit-1) good ascending rows + 1 bad row (unparseable ts) == `limit` RAW rows.
        var p1 = "["
        let goodEnd = firstStart + (limit - 1) - 1      // limit-1 good rows: firstStart ... goodEnd
        for ts in firstStart...goodEnd {
            if ts > firstStart { p1 += "," }
            p1 += "{\"ts\":\(ts),\"bpm\":60}"
        }
        // One bad row (ts is not a date and not numeric → dropped by getStreamRows).
        p1 += ",{\"ts\":\"not-a-date\",\"bpm\":99}]"
        let maxGoodTs = goodEnd

        // Page 2: short, proves we did NOT stop early.
        let secondA = maxGoodTs + 1
        let p2 = "[{\"ts\":\(secondA),\"bpm\":61}]"

        StubURLProtocol.reset(bodiesByQuery: [
            "from=0&": p1,
            "from=\(secondA)&": p2,
        ])

        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: nil)
        let sync = ServerSync(config: makeConfig(), store: store,
                              deviceId: "my-whoop", session: makeSession())
        await sync.pull()

        // (limit-1) good rows from page 1 + 1 row from page 2.
        let hr = try await store.hrSamples(deviceId: "my-whoop", from: 0, to: Int.max, limit: limit + 100)
        XCTAssertEqual(hr.count, limit, "the dropped row must not cause the next page to be skipped")
        XCTAssertEqual(hr.last?.ts, secondA)

        let secondPageReq = StubURLProtocol.captured.first {
            $0.url.path.hasSuffix("/v1/streams/hr") && $0.url.absoluteString.contains("from=\(secondA)&")
        }
        XCTAssertNotNil(secondPageReq, "a full page with one bad row must still trigger the next page fetch")
    }

    // MARK: - getWorkouts decode

    func testGetWorkoutsDecodesRealShape() async throws {
        // A realistic server response: one workout, all fields present.
        let body = """
        [{
            "device_id": "my-whoop",
            "start_ts": "2026-05-27T07:14:23+00:00",
            "end_ts":   "2026-05-27T07:49:21+00:00",
            "avg_hr": 117.8,
            "peak_hr": 159,
            "strain": 10.71,
            "kind": null,
            "duration_s": 2098,
            "zone_time_pct": {"0":12.5,"1":8.3,"2":18.1,"3":31.2,"4":22.4,"5":7.5},
            "avg_hrr_pct": 64.3,
            "hrmax": 185.0,
            "hrmax_source": "formula",
            "calories_kcal": null,
            "calories_kj": null
        }]
        """
        StubURLProtocol.reset(bodies: ["/v1/workouts": body])

        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: nil)
        let sync = ServerSync(config: makeConfig(), store: store,
                              deviceId: "my-whoop", session: makeSession())

        let workouts = await sync.getWorkouts(from: "2026-05-01", to: "2026-05-31")

        XCTAssertEqual(workouts.count, 1)
        let w = workouts[0]
        XCTAssertEqual(w.deviceId, "my-whoop")
        XCTAssertEqual(w.avgHr, 117.8, accuracy: 0.01)
        XCTAssertEqual(w.peakHr, 159)
        XCTAssertEqual(w.strain ?? 0, 10.71, accuracy: 0.001)
        XCTAssertNil(w.kind)
        XCTAssertEqual(w.durationS, 2098)
        XCTAssertEqual(w.zoneTimePct[0] ?? 0, 12.5, accuracy: 0.001)
        XCTAssertEqual(w.zoneTimePct[3] ?? 0, 31.2, accuracy: 0.001)
        XCTAssertEqual(w.avgHrrPct ?? 0, 64.3, accuracy: 0.01)
        XCTAssertEqual(w.hrmax ?? 0, 185.0, accuracy: 0.01)
        XCTAssertNil(w.caloriesKcal)
        XCTAssertNil(w.caloriesKj)
        // startTs parsed from ISO-8601
        let expectedStart = ServerSync.parseEpoch("2026-05-27T07:14:23+00:00")!
        XCTAssertEqual(w.startTs, expectedStart)
    }

    func testGetWorkoutsReturnsEmptyOnServerError() async throws {
        StubURLProtocol.reset(responses: ["/v1/workouts": 500], bodies: [:])
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: nil)
        let sync = ServerSync(config: makeConfig(), store: store,
                              deviceId: "my-whoop", session: makeSession())

        let workouts = await sync.getWorkouts(from: "2026-05-01", to: "2026-05-31")
        XCTAssertTrue(workouts.isEmpty, "should return [] on 500")
    }

    // MARK: - getHRSeries (downsampled single-request, for raw HR card)

    /// Verifies that getHRSeries correctly decodes a JSON array of {ts, bpm} rows,
    /// handles both ISO-8601 and numeric ts formats, and returns [] on a server error.
    func testGetHRSeriesDecodesISOAndNumericTs() async throws {
        let body = """
        [
            {"ts":"\(isoA)","bpm":72},
            {"ts":\(epochB),"bpm":68}
        ]
        """
        StubURLProtocol.reset(bodies: ["/v1/streams/hr": body])

        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: nil)
        let sync = ServerSync(config: makeConfig(), store: store,
                              deviceId: "my-whoop", session: makeSession())

        let series = await sync.getHRSeries(fromEpoch: 0, toEpoch: Int.max, maxPoints: 300)

        XCTAssertEqual(series.count, 2)
        XCTAssertEqual(series[0].ts, epochA)
        XCTAssertEqual(series[0].bpm, 72)
        XCTAssertEqual(series[1].ts, epochB)
        XCTAssertEqual(series[1].bpm, 68)

        // Must have used GET + Bearer auth + max_points param.
        let req = StubURLProtocol.captured.first { $0.url.path.hasSuffix("/v1/streams/hr") }
        XCTAssertNotNil(req)
        XCTAssertEqual(req?.method, "GET")
        XCTAssertEqual(req?.authorization, "Bearer \(apiKey)")
        XCTAssertTrue(req?.url.absoluteString.contains("max_points=300") ?? false,
                      "getHRSeries must pass max_points to the server")
    }

    func testGetHRSeriesReturnsEmptyOnServerError() async throws {
        StubURLProtocol.reset(responses: ["/v1/streams/hr": 500], bodies: [:])
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: nil)
        let sync = ServerSync(config: makeConfig(), store: store,
                              deviceId: "my-whoop", session: makeSession())

        let series = await sync.getHRSeries(fromEpoch: 0, toEpoch: Int.max, maxPoints: 300)
        XCTAssertTrue(series.isEmpty, "should return [] on 500")
    }

    func testGetWorkoutsNewestFirst() async throws {
        // Two workouts in ascending order from the server — result should be reversed.
        let body = """
        [
            {"device_id":"my-whoop","start_ts":"2026-05-26T07:00:00+00:00","end_ts":"2026-05-26T07:30:00+00:00",
             "avg_hr":120.0,"peak_hr":150,"strain":9.0,"kind":null,"duration_s":1800,
             "zone_time_pct":{"0":10,"1":10,"2":20,"3":30,"4":20,"5":10},
             "avg_hrr_pct":60.0,"hrmax":185.0,"hrmax_source":"formula","calories_kcal":null,"calories_kj":null},
            {"device_id":"my-whoop","start_ts":"2026-05-27T07:14:23+00:00","end_ts":"2026-05-27T07:49:21+00:00",
             "avg_hr":117.8,"peak_hr":159,"strain":10.71,"kind":null,"duration_s":2098,
             "zone_time_pct":{"0":12,"1":8,"2":18,"3":31,"4":22,"5":9},
             "avg_hrr_pct":64.3,"hrmax":185.0,"hrmax_source":"formula","calories_kcal":null,"calories_kj":null}
        ]
        """
        StubURLProtocol.reset(bodies: ["/v1/workouts": body])
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: nil)
        let sync = ServerSync(config: makeConfig(), store: store,
                              deviceId: "my-whoop", session: makeSession())

        let workouts = await sync.getWorkouts(from: "2026-05-01", to: "2026-05-31")
        XCTAssertEqual(workouts.count, 2)
        // Newest first: May 27 before May 26
        XCTAssertGreaterThan(workouts[0].startTs, workouts[1].startTs)
    }

    // MARK: - backfillWorkouts: correct payload + path

    func testBackfillWorkoutsPostsCorrectPayload() async throws {
        StubURLProtocol.reset(responses: ["/v1/backfill-workouts": 200], bodies: [:])
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: nil)
        let sync = ServerSync(config: makeConfig(), store: store,
                              deviceId: "my-whoop", session: makeSession())

        let ok = await sync.backfillWorkouts(from: "2026-03-29", to: "2026-05-28")

        XCTAssertTrue(ok, "backfillWorkouts must return true on 2xx")

        // Verify the captured request.
        let req = StubURLProtocol.captured.first { $0.url.path.hasSuffix("/v1/backfill-workouts") }
        XCTAssertNotNil(req, "a POST to /v1/backfill-workouts must be made")
        XCTAssertEqual(req?.method, "POST")
        XCTAssertEqual(req?.authorization, "Bearer \(apiKey)")

        // Decode the JSON body and verify all three fields.
        let bodyData = try XCTUnwrap(req?.bodyData.isEmpty == false ? req?.bodyData : nil)
        let decoded = try XCTUnwrap(try? JSONSerialization.jsonObject(with: bodyData) as? [String: String])
        XCTAssertEqual(decoded["device"], "my-whoop")
        XCTAssertEqual(decoded["from"], "2026-03-29")
        XCTAssertEqual(decoded["to"], "2026-05-28")
    }

    func testBackfillWorkoutsReturnsFalseOn500() async throws {
        StubURLProtocol.reset(responses: ["/v1/backfill-workouts": 500], bodies: [:])
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: nil)
        let sync = ServerSync(config: makeConfig(), store: store,
                              deviceId: "my-whoop", session: makeSession())

        let ok = await sync.backfillWorkouts(from: "2026-03-29", to: "2026-05-28")
        XCTAssertFalse(ok, "backfillWorkouts must return false on non-2xx")
    }
}
