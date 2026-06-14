import XCTest
import WhoopProtocol
@testable import WhoopStore

/// Per-row `synced` flag: default insert is synced=0 (needs upload); markSynced:true is synced=1
/// (already on server); unsynced reads + mark methods drain by the flag, not a ts cursor.
final class SyncedFlagTests: XCTestCase {

    private let dev = "devS"

    private func freshStore() async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: dev, mac: nil, name: nil)
        return store
    }

    // MARK: - default insert → synced=0

    func testDefaultInsertIsUnsynced() async throws {
        let store = try await freshStore()
        try await store.insert(Streams(hr: [HRSample(ts: 1000, bpm: 60)]), deviceId: dev)
        let unsynced = try await store.unsyncedHR(deviceId: dev, limit: 10)
        XCTAssertEqual(unsynced.map(\.ts), [1000], "default insert leaves row synced=0")
    }

    // MARK: - markSynced:true → synced=1 (not returned by unsynced read)

    func testMarkSyncedInsertIsSynced() async throws {
        let store = try await freshStore()
        try await store.insert(Streams(hr: [HRSample(ts: 1000, bpm: 60)]),
                               deviceId: dev, markSynced: true)
        let unsynced = try await store.unsyncedHR(deviceId: dev, limit: 10)
        XCTAssertTrue(unsynced.isEmpty, "markSynced:true rows are not pending upload (\(unsynced.count))")
    }

    // MARK: - DO NOTHING never clobbers an existing synced value

    func testReinsertDoesNotClobberSynced() async throws {
        let store = try await freshStore()
        // Insert and mark synced (simulating a successful upload).
        try await store.insert(Streams(hr: [HRSample(ts: 1000, bpm: 60)]), deviceId: dev)
        try await store.markHRSynced(deviceId: dev, rows: [HRSample(ts: 1000, bpm: 60)])
        let afterMark = try await store.unsyncedHR(deviceId: dev, limit: 10)
        XCTAssertTrue(afterMark.isEmpty)

        // A later default insert of the SAME key must NOT reset synced back to 0.
        try await store.insert(Streams(hr: [HRSample(ts: 1000, bpm: 60)]), deviceId: dev)
        let afterReinsert = try await store.unsyncedHR(deviceId: dev, limit: 10)
        XCTAssertTrue(afterReinsert.isEmpty,
                      "re-insert (DO NOTHING) must not flip a synced row back to unsynced")

        // And a server-pull (markSynced:true) must NOT silently mark a still-pending row synced.
        try await store.insert(Streams(hr: [HRSample(ts: 2000, bpm: 70)]), deviceId: dev) // synced=0
        try await store.insert(Streams(hr: [HRSample(ts: 2000, bpm: 70)]),
                               deviceId: dev, markSynced: true) // conflict → DO NOTHING
        let stillPending = try await store.unsyncedHR(deviceId: dev, limit: 10).map(\.ts)
        XCTAssertEqual(stillPending, [2000], "pending row stays pending despite a markSynced re-insert")
    }

    // MARK: - unsynced reads order by ts ASC and respect limit

    func testUnsyncedReadOrderAndLimit() async throws {
        let store = try await freshStore()
        try await store.insert(Streams(hr: [
            HRSample(ts: 3000, bpm: 60), HRSample(ts: 1000, bpm: 61), HRSample(ts: 2000, bpm: 62)
        ]), deviceId: dev)
        let page = try await store.unsyncedHR(deviceId: dev, limit: 2)
        XCTAssertEqual(page.map(\.ts), [1000, 2000], "oldest-ts-first, capped at limit")
    }

    // MARK: - mark methods flip exactly the given rows (composite keys)

    func testMarkRRByCompositeKey() async throws {
        let store = try await freshStore()
        try await store.insert(Streams(rr: [
            RRInterval(ts: 1000, rrMs: 800), RRInterval(ts: 1000, rrMs: 820),
            RRInterval(ts: 2000, rrMs: 790)
        ]), deviceId: dev)
        // Mark only two of the three by exact (ts, rrMs).
        try await store.markRRSynced(deviceId: dev, rows: [
            RRInterval(ts: 1000, rrMs: 800), RRInterval(ts: 2000, rrMs: 790)
        ])
        let remaining = try await store.unsyncedRR(deviceId: dev, limit: 10)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.ts, 1000)
        XCTAssertEqual(remaining.first?.rrMs, 820, "only the exact uploaded rr keys are marked synced")
    }

    func testMarkEventsByCompositeKey() async throws {
        let store = try await freshStore()
        try await store.insert(Streams(events: [
            WhoopEvent(ts: 1000, kind: "A", payload: [:]),
            WhoopEvent(ts: 1000, kind: "B", payload: [:])
        ]), deviceId: dev)
        try await store.markEventsSynced(deviceId: dev, rows: [WhoopEvent(ts: 1000, kind: "A", payload: [:])])
        let remaining = try await store.unsyncedEvents(deviceId: dev, limit: 10)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.kind, "B", "only event kind A was marked synced")
    }

    // MARK: - idempotent: marking again is a no-op; backfill stays pending

    func testBackfillRowStaysPendingAfterNewerMarked() async throws {
        let store = try await freshStore()
        // Newer row uploaded + marked.
        try await store.insert(Streams(hr: [HRSample(ts: 2000, bpm: 60)]), deviceId: dev)
        try await store.markHRSynced(deviceId: dev, rows: [HRSample(ts: 2000, bpm: 60)])
        // Older backfill row arrives later.
        try await store.insert(Streams(hr: [HRSample(ts: 500, bpm: 55)]), deviceId: dev)
        let pending = try await store.unsyncedHR(deviceId: dev, limit: 10)
        XCTAssertEqual(pending.map(\.ts), [500],
                       "older backfilled row is selected for upload regardless of ts order")
    }

    // MARK: - every stream's unsynced read + mark round-trips

    func testAllStreamsRoundTrip() async throws {
        let store = try await freshStore()
        try await store.insert(Streams(
            hr: [HRSample(ts: 1, bpm: 60)],
            rr: [RRInterval(ts: 1, rrMs: 800)],
            spo2: [SpO2Sample(ts: 1, red: 1, ir: 2)],
            skinTemp: [SkinTempSample(ts: 1, raw: 3)],
            resp: [RespSample(ts: 1, raw: 4)],
            gravity: [GravitySample(ts: 1, x: 0.1, y: 0.2, z: 9.8)],
            events: [WhoopEvent(ts: 1, kind: "E", payload: [:])],
            battery: [BatterySample(ts: 1, soc: 50, mv: nil)]
        ), deviceId: dev)

        let hrN = try await store.unsyncedHR(deviceId: dev, limit: 10).count
        let rrN = try await store.unsyncedRR(deviceId: dev, limit: 10).count
        let spo2N = try await store.unsyncedSpo2(deviceId: dev, limit: 10).count
        let skinN = try await store.unsyncedSkinTemp(deviceId: dev, limit: 10).count
        let respN = try await store.unsyncedResp(deviceId: dev, limit: 10).count
        let gravN = try await store.unsyncedGravity(deviceId: dev, limit: 10).count
        let evN = try await store.unsyncedEvents(deviceId: dev, limit: 10).count
        let batN = try await store.unsyncedBattery(deviceId: dev, limit: 10).count
        XCTAssertEqual([hrN, rrN, spo2N, skinN, respN, gravN, evN, batN], [1, 1, 1, 1, 1, 1, 1, 1])

        try await store.markHRSynced(deviceId: dev, rows: [HRSample(ts: 1, bpm: 60)])
        try await store.markRRSynced(deviceId: dev, rows: [RRInterval(ts: 1, rrMs: 800)])
        try await store.markSpo2Synced(deviceId: dev, rows: [SpO2Sample(ts: 1, red: 1, ir: 2)])
        try await store.markSkinTempSynced(deviceId: dev, rows: [SkinTempSample(ts: 1, raw: 3)])
        try await store.markRespSynced(deviceId: dev, rows: [RespSample(ts: 1, raw: 4)])
        try await store.markGravitySynced(deviceId: dev, rows: [GravitySample(ts: 1, x: 0.1, y: 0.2, z: 9.8)])
        try await store.markEventsSynced(deviceId: dev, rows: [WhoopEvent(ts: 1, kind: "E", payload: [:])])
        try await store.markBatterySynced(deviceId: dev, rows: [BatterySample(ts: 1, soc: 50, mv: nil)])

        let hrZ = try await store.unsyncedHR(deviceId: dev, limit: 10).count
        let rrZ = try await store.unsyncedRR(deviceId: dev, limit: 10).count
        let spo2Z = try await store.unsyncedSpo2(deviceId: dev, limit: 10).count
        let skinZ = try await store.unsyncedSkinTemp(deviceId: dev, limit: 10).count
        let respZ = try await store.unsyncedResp(deviceId: dev, limit: 10).count
        let gravZ = try await store.unsyncedGravity(deviceId: dev, limit: 10).count
        let evZ = try await store.unsyncedEvents(deviceId: dev, limit: 10).count
        let batZ = try await store.unsyncedBattery(deviceId: dev, limit: 10).count
        XCTAssertEqual([hrZ, rrZ, spo2Z, skinZ, respZ, gravZ, evZ, batZ], [0, 0, 0, 0, 0, 0, 0, 0])
    }
}
