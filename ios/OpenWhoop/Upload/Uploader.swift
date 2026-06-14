import Foundation
import WhoopProtocol
import WhoopStore

// MARK: - Uploader

/// Drains both decoded streams and raw batch outbox to the server.
/// Idempotent and retry-safe: rows / batches are marked synced ONLY on HTTP 2xx.
/// Non-2xx or thrown errors leave state unchanged for retry.
///
/// Decoded streams drain by a per-row `synced` flag (NOT a forward-only highwater): each drain
/// reads a page of `synced = 0` rows oldest-ts-first, POSTs them, and marks EXACTLY those rows
/// synced on 2xx. This correctly uploads backfilled (older-ts) rows the historical offload inserts
/// after a recent live row already advanced past them — the old highwater stranded those forever.
final class Uploader {
    /// Page size for a decoded-stream drain. HR is 1 Hz and dominant, so pages are generous.
    private static let pageLimit = 5000

    private let config: UploaderConfig
    private let store: WhoopStore
    private let deviceId: String
    private let session: URLSession

    init(config: UploaderConfig,
         store: WhoopStore,
         deviceId: String,
         session: URLSession = .shared) {
        self.config = config
        self.store = store
        self.deviceId = deviceId
        self.session = session
    }

    /// Drain all pending decoded streams.
    ///
    /// Raw upload is NO LONGER part of the default drain path: the app is decoded-only by
    /// default (raw capture is OFF unless the research toggle is enabled). `drainRaw()` and the
    /// `/v1/ingest` raw path remain available below for an explicit, future research export, but
    /// they MUST NOT run automatically here.
    func drain() async {
        await drainDecoded()
    }

    // MARK: - Decoded drain

    private func drainDecoded() async {
        // Each stream is a separate POST and drains by its own `synced = 0` page.
        await drainHR()
        await drainRR()
        await drainEvents()
        await drainBattery()
        // Type-47 V24 biometric streams (raw ADC; cloud computes human units).
        await drainSpo2()
        await drainSkinTemp()
        await drainResp()
        await drainGravity()
    }

    /// Generic decoded drain: page `synced = 0` rows (oldest ts first), POST each page, and mark
    /// EXACTLY the uploaded rows synced on 2xx. Stops on the first non-2xx / failure (rows stay
    /// `synced = 0` → retried next connect). Uploads backfilled/out-of-order rows correctly because
    /// selection is by the per-row flag, not a ts cursor. Idempotent: re-presenting a synced row to
    /// the server is harmless (server upserts by natural key).
    ///
    /// `read` returns one page (already ordered ts ASC, `synced = 0`, capped at `limit`).
    /// `bodyKey` + `encode` build the JSON body for that stream. `mark` flips the page synced.
    private func drainStream<Row>(
        read: (_ limit: Int) async throws -> [Row],
        bodyKey: String,
        encode: (Row) -> [String: Any],
        mark: ([Row]) async throws -> Void
    ) async {
        while true {
            guard let rows = try? await read(Self.pageLimit), !rows.isEmpty else { return }
            let streamsBody: [String: Any] = [bodyKey: rows.map(encode)]
            if await postDecoded(streams: streamsBody) {
                try? await mark(rows)
            } else {
                return   // server/network failure → stop; rows stay synced=0, retry next connect
            }
            if rows.count < Self.pageLimit { return }   // last page
        }
    }

    private func drainHR() async {
        await drainStream(
            read: { try await self.store.unsyncedHR(deviceId: self.deviceId, limit: $0) },
            bodyKey: "hr",
            encode: { ["ts": $0.ts, "bpm": $0.bpm] },
            mark: { try await self.store.markHRSynced(deviceId: self.deviceId, rows: $0) })
    }

    private func drainRR() async {
        await drainStream(
            read: { try await self.store.unsyncedRR(deviceId: self.deviceId, limit: $0) },
            bodyKey: "rr",
            encode: { ["ts": $0.ts, "rr_ms": $0.rrMs] },
            mark: { try await self.store.markRRSynced(deviceId: self.deviceId, rows: $0) })
    }

    private func drainEvents() async {
        await drainStream(
            read: { try await self.store.unsyncedEvents(deviceId: self.deviceId, limit: $0) },
            bodyKey: "events",
            encode: { ev -> [String: Any] in
                var d: [String: Any] = ["ts": ev.ts, "kind": ev.kind]
                if let payloadData = try? JSONEncoder().encode(ev.payload),
                   let payloadObj = try? JSONSerialization.jsonObject(with: payloadData) {
                    d["payload"] = payloadObj
                }
                return d
            },
            mark: { try await self.store.markEventsSynced(deviceId: self.deviceId, rows: $0) })
    }

    private func drainBattery() async {
        await drainStream(
            read: { try await self.store.unsyncedBattery(deviceId: self.deviceId, limit: $0) },
            bodyKey: "battery",
            encode: { b -> [String: Any] in
                var d: [String: Any] = ["ts": b.ts]
                if let soc = b.soc { d["soc"] = soc }
                if let mv = b.mv { d["mv"] = mv }
                return d
            },
            mark: { try await self.store.markBatterySynced(deviceId: self.deviceId, rows: $0) })
    }

    private func drainSpo2() async {
        await drainStream(
            read: { try await self.store.unsyncedSpo2(deviceId: self.deviceId, limit: $0) },
            bodyKey: "spo2",
            encode: { ["ts": $0.ts, "red": $0.red, "ir": $0.ir] },
            mark: { try await self.store.markSpo2Synced(deviceId: self.deviceId, rows: $0) })
    }

    private func drainSkinTemp() async {
        await drainStream(
            read: { try await self.store.unsyncedSkinTemp(deviceId: self.deviceId, limit: $0) },
            bodyKey: "skin_temp",
            encode: { ["ts": $0.ts, "raw": $0.raw] },
            mark: { try await self.store.markSkinTempSynced(deviceId: self.deviceId, rows: $0) })
    }

    private func drainResp() async {
        await drainStream(
            read: { try await self.store.unsyncedResp(deviceId: self.deviceId, limit: $0) },
            bodyKey: "resp",
            encode: { ["ts": $0.ts, "raw": $0.raw] },
            mark: { try await self.store.markRespSynced(deviceId: self.deviceId, rows: $0) })
    }

    private func drainGravity() async {
        await drainStream(
            read: { try await self.store.unsyncedGravity(deviceId: self.deviceId, limit: $0) },
            bodyKey: "gravity",
            encode: { ["ts": $0.ts, "x": $0.x, "y": $0.y, "z": $0.z] },
            mark: { try await self.store.markGravitySynced(deviceId: self.deviceId, rows: $0) })
    }

    /// POST to /v1/ingest-decoded. Returns true on 2xx.
    @discardableResult
    private func postDecoded(streams: [String: Any]) async -> Bool {
        let body: [String: Any] = [
            "device": ["id": deviceId],
            "streams": streams
        ]
        return await post(path: "/v1/ingest-decoded", body: body)
    }

    // MARK: - Raw drain (explicit research export only)

    /// Drain the ENTIRE raw outbox (pages until empty), so a backfill backlog clears in one
    /// connected session rather than ~one page per connect. Stops on the first server/network
    /// failure (the batch stays pending → retried next connect). An unreadable batch is skipped
    /// but tracked so paging can't spin on it.
    ///
    /// NOTE: This is intentionally NOT called from `drain()`. Raw capture is OFF by default and
    /// this path exists only for a future, explicit research export. Decoded streams are the
    /// product of record; raw is never auto-uploaded.
    func drainRaw() async {
        var attempted = Set<String>()
        while true {
            guard let pending = try? await store.pendingRawBatches(limit: 50) else { return }
            let fresh = pending.filter { !attempted.contains($0.batchId) }
            if fresh.isEmpty { return }   // nothing new to do this drain
            for meta in fresh {
                attempted.insert(meta.batchId)
                guard let frames = try? await store.rawFrames(batchId: meta.batchId) else { continue }
                let body: [String: Any] = [
                    "batch_id": meta.batchId,
                    "device": ["device_id": meta.deviceId],
                    "clock_ref": [
                        "device": meta.clockRef.device,
                        "wall": meta.clockRef.wall
                    ],
                    "decode_streams": false,
                    "frames": frames.map { ["hex": $0.hexString] }
                ]
                let now = Int(Date().timeIntervalSince1970)
                if await post(path: "/v1/ingest", body: body) {
                    try? await store.markRawBatchSynced(batchId: meta.batchId, at: now)
                } else {
                    return   // server/network failure → stop; retry on next connect
                }
            }
        }
    }

    // MARK: - HTTP helper

    /// Perform a POST with JSON body. Returns true on 2xx.
    private func post(path: String, body: [String: Any]) async -> Bool {
        guard let url = URL(string: path, relativeTo: config.baseURL)
                     ?? URL(string: config.baseURL.absoluteString + path) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return false }
        request.httpBody = data
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }
}

// MARK: - [UInt8] hex encoding

private extension Array where Element == UInt8 {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
