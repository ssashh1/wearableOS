import Foundation
import WhoopProtocol
import WhoopStore

// MARK: - ServerSync

/// Pulls server-side decoded streams + derived metrics back to the phone so that
/// History = union(phone-collected, server-computed). The mirror of `Uploader`, but GET
/// instead of POST: same `UploaderConfig` (baseURL + Bearer apiKey), injected `URLSession`.
///
/// Idempotent and retry-safe: the per-stream READ-highwater advances ONLY on a successful 2xx
/// pull-and-upsert. A non-2xx / thrown error stops that stream and leaves its read-highwater
/// (and the store) unchanged, so the next pull retries. All upserts are by natural key, so
/// re-pulling the same rows never duplicates.
final class ServerSync {
    private let config: UploaderConfig
    private let store: WhoopStore
    private let deviceId: String
    private let session: URLSession

    /// Decoded streams pulled incrementally by `ts` (epoch seconds). Names match the server's
    /// `/v1/streams/{kind}` path segment AND the upload highwater names (Uploader.swift).
    static let decodedKinds = ["hr", "rr", "spo2", "skin_temp", "resp", "gravity", "battery", "events"]

    /// Page size for an incremental stream pull. Mirrors Uploader's 5000-row pages.
    static let pageLimit = 5000

    /// How many days back to re-pull derived metrics (daily + sleep) each sync. They're small and
    /// idempotent, so a fixed recent window each time is simpler than a cursor and self-heals
    /// server-side recomputation. Documented constant so it's easy to widen later.
    static let derivedWindowDays = 60

    /// On a fresh-reinstall full restore, derived metrics are pulled over this wider window so the
    /// entire known history (not just the most-recent 60 days) is rebuilt locally. Default is large
    /// enough to cover multi-year strap history; override in tests for speed.
    static let fullRestoreWindowDays = 400

    init(config: UploaderConfig,
         store: WhoopStore,
         deviceId: String,
         session: URLSession = .shared) {
        self.config = config
        self.store = store
        self.deviceId = deviceId
        self.session = session
    }

    func pull() async {
        await pullDecoded()
        await pullDerived()
    }

    // MARK: - Cloud restore (fresh reinstall)

    /// Detect whether this device's decoded store is empty: no rows in any decoded-stream table AND
    /// no read-highwater cursors set. Either condition alone could indicate a partial/interrupted
    /// restore, so BOTH must be true for us to declare the store "empty" and kick a full restore.
    ///
    /// This is intentionally strict: if ANY cursor is set (even for streams with 0 local rows), we
    /// treat it as non-empty and fall through to incremental pull — the cursor already encodes how
    /// far the previous restore got. Only a fully pristine store (new install, data cleared) runs
    /// the wide-window restore path.
    private func isDecodedStoreEmpty() async -> Bool {
        // Check decoded rows via storageStats (decodedRows = sum across all 8 stream tables).
        guard let stats = try? await store.storageStats() else { return false }
        if stats.decodedRows > 0 { return false }
        // Check read-highwater cursors: any set cursor means we've pulled at least once before.
        for kind in ServerSync.decodedKinds {
            if (try? await store.readHighwater(kind)) != nil { return false }
        }
        return true
    }

    /// Called once on store bootstrap / first connect. Detects a fresh-reinstall empty store and,
    /// if found, pulls the FULL history from the server (not just the recent incremental window):
    ///
    /// - Decoded streams: same paging logic as `pullDecoded` but unconditionally from `from=0`
    ///   (ignores any stale cursor). Read-highwater is advanced after each page so a subsequent
    ///   incremental `pull()` fetches only new rows.
    /// - Derived metrics: pulled over `fullRestoreWindowDays` (default 400d) instead of the
    ///   normal 60-day incremental window, so the full daily/sleep history is rebuilt.
    ///
    /// Returns `true` if a restore ran (store was empty), `false` if the store was non-empty (no-op).
    /// Idempotent: `isDecodedStoreEmpty()` is the gate; a non-empty store is never re-paged.
    @discardableResult
    func restoreIfEmpty() async -> Bool {
        guard await isDecodedStoreEmpty() else { return false }
        // Full decoded restore: page all streams from ts=0, ignoring any cursor.
        await pullDecodedFull()
        // Full derived restore: wider window than the normal incremental 60-day window.
        await pullDerivedFull()
        return true
    }

    // MARK: - JSON coercion helpers (shared by buildStreams / getDaily / getSleep)

    /// Coerce a JSON value (NSNumber from JSONSerialization, or a plain Int) to Int.
    static func int(_ r: [String: Any], _ k: String) -> Int? {
        if let n = r[k] as? NSNumber { return n.intValue }
        if let i = r[k] as? Int { return i }
        return nil
    }
    /// Coerce a JSON value (NSNumber, Double, or Int) to Double.
    static func dbl(_ r: [String: Any], _ k: String) -> Double? {
        if let n = r[k] as? NSNumber { return n.doubleValue }
        if let d = r[k] as? Double { return d }
        if let i = r[k] as? Int { return Double(i) }
        return nil
    }

    // MARK: - Decoded streams

    private func pullDecoded() async {
        for kind in ServerSync.decodedKinds {
            await pullStream(kind)
        }
    }

    /// Full-restore variant: page all decoded streams unconditionally from ts=0, bypassing any
    /// existing read-highwater cursor. The highwater is still advanced after each successful page
    /// so a subsequent incremental `pull()` resumes from where the restore finished.
    private func pullDecodedFull() async {
        for kind in ServerSync.decodedKinds {
            await pullStream(kind, forcedFrom: 0)
        }
    }

    /// Pull one decoded stream, paging until the server returns a short page.
    /// Advances the READ-highwater to the max pulled ts ONLY after a successful upsert.
    ///
    /// - Parameter forcedFrom: When non-nil, use this value as the starting `from` for the first
    ///   page (overriding the read-highwater cursor). Subsequent pages still advance normally via
    ///   the max-ts-in-page cursor. Pass `0` for a full restore; pass `nil` for incremental pull
    ///   (reads the stored cursor as usual).
    ///
    /// CURSOR CONTRACT — this relies on the server's `read.py query_stream`, which runs
    /// `... WHERE ts >= from AND ts <= to ORDER BY ts LIMIT %s` (ascending `ts`, page-bounded by
    /// `limit`). Because rows come back sorted ascending and capped at `limit`, we can advance the
    /// read-highwater to `max(ts in page)` after a page and re-query `from = max+1` to get the next
    /// page with no gaps and no overlap. `store.insert` is a SINGLE transaction, so advancing the
    /// highwater only AFTER it succeeds means a crash/throw mid-insert leaves the highwater behind
    /// the data (we re-pull, dedup by natural key) — never ahead of it (which would lose rows).
    ///
    /// Paging termination is based on the RAW server-row count (`rawCount`), NOT the parsed count:
    /// `getStreamRows` drops rows it can't parse (missing/bad ts) via compactMap, so a full page
    /// with one bad row would parse short and falsely look like the last page, skipping a real next
    /// page. We stop only when the server itself returned fewer than `pageLimit` rows.
    private func pullStream(_ kind: String, forcedFrom: Int? = nil) async {
        // On the very first iteration, `forcedFrom` overrides the cursor (used by full restore to
        // start unconditionally from ts=0). After the first page the highwater is advanced, so
        // all subsequent pages read the cursor the normal way. `overrideFrom` is consumed once.
        var overrideFrom: Int? = forcedFrom
        // MONOTONICITY (audit 4.2): track the highwater as a local var, initialized from the
        // persisted cursor and updated in-loop alongside `setReadHighwater`. This mirrors the
        // `overrideFrom` consumed-local pattern and means monotonicity is by-construction — no
        // extra per-page DB read needed to clamp the cursor forward-only.
        var highwater: Int = (try? await store.readHighwater(kind)) ?? Int.min
        while true {
            let from: Int
            if let forced = overrideFrom {
                from = forced
                overrideFrom = nil   // consume: subsequent pages use the cursor
            } else {
                from = highwater <= 0 ? 0 : highwater + 1
            }
            guard let (rows, rawCount) = await getStreamRows(kind: kind, from: from, to: Int.max,
                                                             limit: ServerSync.pageLimit) else {
                return   // server/network failure → stop this stream; retry next pull
            }
            if rows.isEmpty {
                // No parseable rows. If the server actually sent a full page (all unparseable), we
                // can't advance the cursor past them — bail to avoid an infinite re-pull loop.
                return
            }

            // Build a Streams payload for this kind and upsert (reuses store.insert).
            guard let streams = ServerSync.buildStreams(kind: kind, rows: rows) else { return }
            let maxTs = rows.compactMap { ServerSync.int($0, "ts") }.max()
            do {
                // store.insert is ON CONFLICT DO NOTHING → the server never overwrites a
                // locally-decoded row on a ts conflict (History = union; local decode wins).
                // markSynced: true — these rows are ALREADY on the server (we just pulled them),
                // so they must NOT be re-uploaded. A ts conflict with a locally-collected row keeps
                // that row's own synced value (DO NOTHING never clobbers synced).
                try await store.insert(streams, deviceId: deviceId, markSynced: true)
            } catch {
                return   // local persistence failed → don't advance; retry next pull
            }
            if let maxTs = maxTs, maxTs > highwater {
                // Clamp forward-only: `highwater` is the running max; `maxTs` is the max ts in
                // THIS page. A misbehaving/clock-skewed server could return a row OLDER than the
                // current cursor — advancing to that would regress the cursor and spin needlessly.
                // Because `highwater` is tracked locally we never need a second DB read to compare.
                try? await store.setReadHighwater(kind, maxTs)
                highwater = maxTs
            }
            if rawCount < ServerSync.pageLimit { return }   // last page (per RAW server count)
        }
    }

    /// Convert raw server JSON rows (ts already parsed to epoch Int) into a `Streams` for one kind.
    /// Returns nil for an unknown kind. Decoded `value`/`unit` columns the server may add for the
    /// raw-ADC streams (spo2/skin_temp/resp) are intentionally ignored — only the raw cols are stored.
    static func buildStreams(kind: String, rows: [[String: Any]]) -> Streams? {
        let int = ServerSync.int
        let dbl = ServerSync.dbl
        var s = Streams()
        switch kind {
        case "hr":
            s.hr = rows.compactMap { r in
                guard let ts = int(r, "ts"), let bpm = int(r, "bpm") else { return nil }
                return HRSample(ts: ts, bpm: bpm)
            }
        case "rr":
            s.rr = rows.compactMap { r in
                guard let ts = int(r, "ts"), let rrMs = int(r, "rr_ms") ?? int(r, "rrMs") else { return nil }
                return RRInterval(ts: ts, rrMs: rrMs)
            }
        case "spo2":
            s.spo2 = rows.compactMap { r in
                guard let ts = int(r, "ts"), let red = int(r, "red"), let ir = int(r, "ir") else { return nil }
                return SpO2Sample(ts: ts, red: red, ir: ir)
            }
        case "skin_temp":
            s.skinTemp = rows.compactMap { r in
                guard let ts = int(r, "ts"), let raw = int(r, "raw") else { return nil }
                return SkinTempSample(ts: ts, raw: raw)
            }
        case "resp":
            s.resp = rows.compactMap { r in
                guard let ts = int(r, "ts"), let raw = int(r, "raw") else { return nil }
                return RespSample(ts: ts, raw: raw)
            }
        case "gravity":
            s.gravity = rows.compactMap { r in
                guard let ts = int(r, "ts"),
                      let x = dbl(r, "x"), let y = dbl(r, "y"), let z = dbl(r, "z") else { return nil }
                return GravitySample(ts: ts, x: x, y: y, z: z)
            }
        case "battery":
            s.battery = rows.compactMap { r in
                guard let ts = int(r, "ts") else { return nil }
                let charging = (r["charging"] as? Bool) ?? (int(r, "charging").map { $0 != 0 })
                return BatterySample(ts: ts, soc: dbl(r, "soc"), mv: int(r, "mv"), charging: charging)
            }
        case "events":
            s.events = rows.compactMap { r in
                guard let ts = int(r, "ts"), let kindStr = r["kind"] as? String else { return nil }
                var payload: [String: ParsedValue] = [:]
                if let p = r["payload"] as? [String: Any],
                   let data = try? JSONSerialization.data(withJSONObject: p),
                   let decoded = try? JSONDecoder().decode([String: ParsedValue].self, from: data) {
                    payload = decoded
                }
                return WhoopEvent(ts: ts, kind: kindStr, payload: payload)
            }
        default:
            return nil
        }
        return s
    }

    /// GET /v1/streams/{kind}; parse each row's ISO-8601 `ts` to epoch Int (in place). Returns nil
    /// on non-2xx / network error / malformed body so the caller stops + retries.
    ///
    /// Returns `(parsedRows, rawCount)` where `rawCount` is the number of rows the SERVER returned
    /// in this page (before any ts-parse drops). The pager uses `rawCount` (not parsedRows.count)
    /// to decide whether this was the last page, so a dropped/unparseable row in a full page can't
    /// be mistaken for a short final page.
    private func getStreamRows(kind: String, from: Int, to: Int, limit: Int) async -> (rows: [[String: Any]], rawCount: Int)? {
        let toParam = to == Int.max ? String(Int(Date().timeIntervalSince1970) + 86_400) : String(to)
        let path = "/v1/streams/\(kind)?device=\(deviceId)&from=\(from)&to=\(toParam)&limit=\(limit)"
        guard let body = await get(path: path),
              let arr = (try? JSONSerialization.jsonObject(with: body)) as? [[String: Any]] else {
            return nil
        }
        let rawCount = arr.count
        // Normalise ts (ISO-8601 string or already-numeric) → epoch Int.
        let rows: [[String: Any]] = arr.compactMap { row -> [String: Any]? in
            var r = row
            if let tsStr = row["ts"] as? String {
                guard let epoch = ServerSync.parseEpoch(tsStr) else { return nil }
                r["ts"] = epoch
            } else if let n = row["ts"] as? NSNumber {
                r["ts"] = n.intValue
            } else {
                return nil
            }
            return r
        }
        return (rows, rawCount)
    }

    // MARK: - Derived metrics (daily + sleep)

    /// Pull derived metrics (daily + sleep). Cadence: invoked on connect AND on the periodic sync
    /// timer (same as `pull()`); these are small, idempotent upserts so re-pulling is cheap.
    ///
    /// EFFICIENCY: `/v1/sleep` is a per-date endpoint, but `/v1/daily` already returns ONLY the days
    /// that have computed metrics (sleep is the primary driver of a daily row). So instead of fanning
    /// out one `/v1/sleep?date=` request per calendar day in the window (~61), we fetch `/v1/daily`
    /// once and then request `/v1/sleep` ONLY for the `day` values it returned — typically a handful.
    /// Idempotent: re-pulled sessions dedup on natural key (deviceId, startTs).
    func pullDerived() async {
        await pullDerivedWindow(days: ServerSync.derivedWindowDays)
    }

    /// Full-restore variant: pull derived over the wider `fullRestoreWindowDays` window so
    /// multi-year history is rebuilt, not just the recent 60-day incremental window.
    private func pullDerivedFull() async {
        await pullDerivedWindow(days: ServerSync.fullRestoreWindowDays)
    }

    /// Core derived-pull implementation. Pulls `/v1/daily` over a `days`-wide window ending now,
    /// then `/v1/sleep` for each day that has a daily metric row. Shared by incremental + restore.
    private func pullDerivedWindow(days windowDays: Int) async {
        let now = Date()
        let cal = Calendar(identifier: .gregorian)
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd"

        guard let start = cal.date(byAdding: .day, value: -windowDays, to: now) else { return }
        let fromDay = fmt.string(from: start)
        let toDay = fmt.string(from: now)

        // /v1/daily over the window. This is the authoritative list of days WITH data.
        guard let days = await getDaily(from: fromDay, to: toDay) else { return }
        if !days.isEmpty {
            try? await store.upsertDailyMetrics(days, deviceId: deviceId)
        }

        // /v1/sleep is per-date; fetch ONLY the days that appear in /v1/daily (days with computed
        // metrics) rather than every calendar day in the window. Idempotent upserts.
        for metric in days {
            if let sessions = await getSleep(date: metric.day), !sessions.isEmpty {
                try? await store.upsertSleepSessions(sessions, deviceId: deviceId)
            }
        }
    }

    private func getDaily(from: String, to: String) async -> [DailyMetric]? {
        let path = "/v1/daily?device=\(deviceId)&from=\(from)&to=\(to)"
        guard let body = await get(path: path),
              let arr = (try? JSONSerialization.jsonObject(with: body)) as? [[String: Any]] else {
            return nil
        }
        let int = ServerSync.int
        let dbl = ServerSync.dbl
        return arr.compactMap { r in
            guard let day = r["day"] as? String else { return nil }
            return DailyMetric(day: day,
                               totalSleepMin: dbl(r, "total_sleep_min") ?? dbl(r, "totalSleepMin"),
                               efficiency: dbl(r, "efficiency"),
                               deepMin: dbl(r, "deep_min") ?? dbl(r, "deepMin"),
                               remMin: dbl(r, "rem_min") ?? dbl(r, "remMin"),
                               lightMin: dbl(r, "light_min") ?? dbl(r, "lightMin"),
                               disturbances: int(r, "disturbances"),
                               restingHr: int(r, "resting_hr") ?? int(r, "restingHr"),
                               avgHrv: dbl(r, "avg_hrv") ?? dbl(r, "avgHrv"),
                               // Server emits recovery as a 0–100 score; the app's
                               // DailyMetric.recovery contract is a 0–1 fraction (all
                               // display sites do `recovery * 100`). Normalize here.
                               recovery: dbl(r, "recovery").map { $0 / 100.0 },
                               strain: dbl(r, "strain"),
                               exerciseCount: int(r, "exercise_count") ?? int(r, "exerciseCount"),
                               spo2Pct: dbl(r, "spo2_pct") ?? dbl(r, "spo2Pct"),
                               skinTempDevC: dbl(r, "skin_temp_dev_c") ?? dbl(r, "skinTempDevC"),
                               respRateBpm: dbl(r, "resp_rate_bpm") ?? dbl(r, "respRateBpm"))
        }
    }

    private func getSleep(date: String) async -> [CachedSleepSession]? {
        let path = "/v1/sleep?device=\(deviceId)&date=\(date)"
        guard let body = await get(path: path),
              let obj = try? JSONSerialization.jsonObject(with: body) else {
            return nil
        }
        // Accept either a single session object or an array of sessions.
        let dicts: [[String: Any]]
        if let arr = obj as? [[String: Any]] { dicts = arr }
        else if let d = obj as? [String: Any], !d.isEmpty { dicts = [d] }
        else { dicts = [] }

        let int = ServerSync.int
        let dbl = ServerSync.dbl
        func epoch(_ r: [String: Any], _ k: String) -> Int? {
            if let s = r[k] as? String { return ServerSync.parseEpoch(s) }
            return int(r, k)
        }
        return dicts.compactMap { r in
            guard let start = epoch(r, "start_ts") ?? epoch(r, "startTs"),
                  let end = epoch(r, "end_ts") ?? epoch(r, "endTs") else { return nil }
            var stagesJSON: String? = nil
            if let stages = r["stages"],
               let data = try? JSONSerialization.data(withJSONObject: stages) {
                stagesJSON = String(decoding: data, as: UTF8.self)
            }
            return CachedSleepSession(startTs: start, endTs: end,
                                      efficiency: dbl(r, "efficiency"),
                                      restingHr: int(r, "resting_hr") ?? int(r, "restingHr"),
                                      avgHrv: dbl(r, "avg_hrv") ?? dbl(r, "avgHrv"),
                                      stagesJSON: stagesJSON)
        }
    }

    // MARK: - Workout model

    /// GET /v1/workouts?device=<deviceId>&from=<from>&to=<to>
    /// Returns decoded Workout array, newest-first (server returns ascending; we reverse).
    /// Returns [] on any network/parse error — callers treat this as "no data, try again later".
    func getWorkouts(from: String, to: String) async -> [Workout] {
        let path = "/v1/workouts?device=\(deviceId)&from=\(from)&to=\(to)"
        guard let body = await get(path: path),
              let arr = (try? JSONSerialization.jsonObject(with: body)) as? [[String: Any]] else {
            return []
        }
        let int = ServerSync.int
        let dbl = ServerSync.dbl
        func epoch(_ r: [String: Any], _ k: String) -> Int? {
            if let s = r[k] as? String { return ServerSync.parseEpoch(s) }
            return int(r, k)
        }
        let workouts: [Workout] = arr.compactMap { r in
            guard let start = epoch(r, "start_ts") ?? epoch(r, "startTs"),
                  let end   = epoch(r, "end_ts")   ?? epoch(r, "endTs"),
                  let avgHr  = dbl(r, "avg_hr")    ?? dbl(r, "avgHr"),
                  let peakHr = int(r, "peak_hr")   ?? int(r, "peakHr"),
                  let durS   = int(r, "duration_s") ?? int(r, "durationS") else { return nil }
            // Parse zone_time_pct: keys are strings "0"–"5"
            var zones: [Int: Double] = [:]
            if let zObj = r["zone_time_pct"] as? [String: Any] {
                for (k, v) in zObj {
                    if let zone = Int(k), let pct = (v as? NSNumber)?.doubleValue ?? (v as? Double) {
                        zones[zone] = pct
                    }
                }
            }
            let deviceId = (r["device_id"] as? String) ?? self.deviceId
            return Workout(
                id: "\(deviceId)|\(start)",
                deviceId: deviceId,
                startTs: start,
                endTs: end,
                avgHr: avgHr,
                peakHr: peakHr,
                strain: dbl(r, "strain"),
                kind: r["kind"] as? String,
                durationS: durS,
                zoneTimePct: zones,
                avgHrrPct: dbl(r, "avg_hrr_pct") ?? dbl(r, "avgHrrPct"),
                hrmax: dbl(r, "hrmax"),
                hrmaxSource: (r["hrmax_source"] as? String) ?? (r["hrmaxSource"] as? String) ?? "",
                caloriesKcal: dbl(r, "calories_kcal") ?? dbl(r, "caloriesKcal"),
                caloriesKj: dbl(r, "calories_kj") ?? dbl(r, "caloriesKj")
            )
        }
        // Server returns ascending; we reverse so newest is first (list view shows newest at top).
        return workouts.reversed()
    }

    // MARK: - ts parsing

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parse a server ISO-8601 timestamp ("2026-05-23T21:08:28+00:00", optionally with fractional
    /// seconds and/or 'Z') to unix epoch seconds. Tries fractional first, then plain.
    static func parseEpoch(_ iso: String) -> Int? {
        if let d = isoFractional.date(from: iso) { return Int(d.timeIntervalSince1970) }
        if let d = isoPlain.date(from: iso) { return Int(d.timeIntervalSince1970) }
        return nil
    }

    // MARK: - Profile

    /// GET /v1/profile?device=<deviceId> → decoded Profile, or nil on error / empty body.
    func getProfile() async -> Profile? {
        let path = "/v1/profile?device=\(deviceId)"
        guard let data = await get(path: path) else { return nil }
        // Server returns `{}` when no profile is stored yet — treat that as nil.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj.isEmpty {
            return nil
        }
        return try? JSONDecoder().decode(Profile.self, from: data)
    }

    /// POST /v1/profile with JSON body {device, height_cm, weight_kg, age, sex}.
    /// Returns true on 2xx, false on network error or non-2xx.
    func putProfile(_ profile: Profile) async -> Bool {
        let path = "/v1/profile"
        var body: [String: Any] = ["device": deviceId]
        if let h = profile.heightCm  { body["height_cm"]  = h }
        if let w = profile.weightKg  { body["weight_kg"]  = w }
        if let a = profile.age       { body["age"]         = a }
        if let s = profile.sex       { body["sex"]         = s }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return false }
        return await post(path: path, body: bodyData)
    }

    // MARK: - Raw HR series (downsampled, single request)

    /// GET /v1/streams/hr?device=<deviceId>&from=<from>&to=<to>&max_points=<N>
    /// Returns an array of (ts: epoch Int, bpm: Int) tuples, ascending by ts.
    /// Uses the server's `max_points` downsampling — NOT the heavy incremental pager.
    /// Returns [] on any network or parse error.
    func getHRSeries(fromEpoch: Int, toEpoch: Int, maxPoints: Int) async -> [(ts: Int, bpm: Int)] {
        let path = "/v1/streams/hr?device=\(deviceId)&from=\(fromEpoch)&to=\(toEpoch)&max_points=\(maxPoints)"
        guard let body = await get(path: path),
              let arr = (try? JSONSerialization.jsonObject(with: body)) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { r -> (ts: Int, bpm: Int)? in
            let ts: Int?
            if let tsStr = r["ts"] as? String {
                ts = ServerSync.parseEpoch(tsStr)
            } else if let n = r["ts"] as? NSNumber {
                ts = n.intValue
            } else {
                ts = nil
            }
            guard let t = ts, let b = ServerSync.int(r, "bpm") else { return nil }
            return (ts: t, bpm: b)
        }
    }

    // MARK: - Workout calorie backfill

    /// POST /v1/backfill-workouts {device, from, to} (YYYY-MM-DD UTC).
    /// Asks the server to recompute exercise sessions + calorie estimates over the given date range.
    /// Returns true on 2xx, false on any network or server error — callers treat this as best-effort.
    func backfillWorkouts(from: String, to: String) async -> Bool {
        let body: [String: Any] = ["device": deviceId, "from": from, "to": to]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return false }
        return await post(path: "/v1/backfill-workouts", body: bodyData)
    }

    // MARK: - HTTP helpers

    /// Perform a GET with the Bearer header. Returns the body Data only on 2xx; nil otherwise.
    private func get(path: String) async -> Data? {
        guard let url = URL(string: path, relativeTo: config.baseURL)
                     ?? URL(string: config.baseURL.absoluteString + path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    /// Perform a POST with Bearer auth + JSON body. Returns true on 2xx, false otherwise.
    private func post(path: String, body: Data) async -> Bool {
        guard let url = URL(string: path, relativeTo: config.baseURL)
                     ?? URL(string: config.baseURL.absoluteString + path) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return false }
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Workout model

struct Workout: Identifiable, Equatable {
    let id: String          // "\(deviceId)|\(startTs)"
    let deviceId: String
    let startTs: Int        // epoch seconds
    let endTs: Int          // epoch seconds
    let avgHr: Double
    let peakHr: Int
    let strain: Double?
    let kind: String?
    let durationS: Int
    let zoneTimePct: [Int: Double]   // zone 0–5 → % of bout (0.0–100.0)
    let avgHrrPct: Double?
    let hrmax: Double?
    let hrmaxSource: String
    let caloriesKcal: Double?
    let caloriesKj: Double?
}
