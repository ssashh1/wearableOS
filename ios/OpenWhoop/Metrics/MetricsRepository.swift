import Foundation
import SwiftUI
import WhoopStore
import WhoopProtocol

// MARK: - MetricsRepository
//
// View-facing read facade over the local MetricsCache (WhoopStore tables dailyMetric +
// sleepSession). The phone does NO metric computation: all values are server-computed and
// cached locally by ServerSync.pullDerived(). MetricsRepository only reads the cache and
// delegates network refreshes to ServerSync.
//
// LAZY-OPEN DESIGN: The synchronous init() does NOT open the on-disk store (WhoopStore.init
// is async). Instead, ensureOpen() is called at the top of every async method and opens the
// store + builds ServerSync on the first call. This lets AppRoot create the repo synchronously
// (as a @StateObject) and always inject a non-nil env object — eliminating the brief window
// where RootTabView rendered without the env object and would crash any @EnvironmentObject read.

@MainActor
final class MetricsRepository: ObservableObject {
    @Published private(set) var today: DailyMetric?            // most-recent cached daily row
    @Published private(set) var lastNight: CachedSleepSession? // most-recent cached sleep session
    @Published private(set) var localHRV: Double?              // locally-computed overnight RMSSD (ms)
    @Published private(set) var localRHR: Double?              // locally-computed overnight min 5-min avg HR
    @Published private(set) var todayStats: TodayHRStats?      // today's HR summary (avg, peak, elevated)
    @Published private(set) var localHRVHistory: [Double] = [] // 7-night RMSSD history, oldest→newest
    @Published private(set) var localRHRHistory: [Double] = [] // 7-night RHR history, oldest→newest
    @Published private(set) var localSleepEstimate: LocalSleepEstimate? // overnight strap data (no staging)
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefreshedAt: Date?

    // Injected directly (test path): store + sync are ready immediately; skip ensureOpen.
    private var store: WhoopStore?
    private var serverSync: ServerSync?
    private let deviceId: String

    // Lazy-open state (app path).
    private var _alreadyOpen = false
    private var _openTask: Task<Void, Never>?

    // MARK: - Synchronous init (app path — store not yet open)

    /// Creates a repository without opening the on-disk store. The store is opened lazily on the
    /// first async call to load()/refresh()/daily()/sleepSessions(). AppRoot uses this init so it
    /// can always provide a non-nil MetricsRepository env object from the very first frame.
    init(deviceId: String = "my-whoop") {
        self.deviceId = deviceId
        self.store = nil
        self.serverSync = nil
        self._alreadyOpen = false
    }

    // MARK: - Designated init (test path — store + sync injected)

    /// Designated initializer for tests: store and sync are ready immediately; ensureOpen() is
    /// a no-op. Keeps all existing MetricsRepository tests passing without modification.
    init(store: WhoopStore, serverSync: ServerSync?, deviceId: String) {
        self.store = store
        self.serverSync = serverSync
        self.deviceId = deviceId
        self._alreadyOpen = true   // already wired — no lazy open needed
    }

    // MARK: - Lazy open (app path)

    /// Idempotent: opens the on-disk store and builds ServerSync exactly once.
    /// All async public methods call this first so the first real operation bootstraps the stack.
    ///
    /// Concurrency contract: all callers on @MainActor await the SAME Task so no second caller
    /// can observe store == nil after ensureOpen() returns. The guard+assign block has no await
    /// between check and assign, so it is atomic on the single MainActor executor.
    private func ensureOpen() async {
        // Test path (store injected) or a previously-completed open: nothing to do.
        if _alreadyOpen, store != nil { return }
        // An open is already in flight — await the SAME task so we don't double-open.
        if let openTask = _openTask { await openTask.value; return }
        let task = Task { @MainActor [self] in
            guard let path = try? StorePaths.defaultDatabasePath(),
                  let openedStore = try? await WhoopStore(path: path) else {
                lastError = "Could not open local database"
                // Allow a retry on a future call.
                _openTask = nil
                return
            }
            store = openedStore
            serverSync = AppConfig.uploaderConfig(deviceId: deviceId)
                .map { ServerSync(config: $0, store: openedStore, deviceId: deviceId) }
            _alreadyOpen = true
        }
        _openTask = task
        await task.value
    }

    // MARK: - App factory (kept for backward-compat; AppRoot now prefers init())

    /// Opens the shared on-disk store and builds ServerSync from AppConfig.
    /// Returns nil if the store can't be opened (e.g. sandbox unavailable).
    static func makeDefault(deviceId: String = "my-whoop") async -> MetricsRepository? {
        guard let path = try? StorePaths.defaultDatabasePath(),
              let store = try? await WhoopStore(path: path) else { return nil }
        let sync = AppConfig.uploaderConfig(deviceId: deviceId)
            .map { ServerSync(config: $0, store: store, deviceId: deviceId) }
        return MetricsRepository(store: store, serverSync: sync, deviceId: deviceId)
    }

    // MARK: - Load from cache (no network)

    /// Populate `today`/`lastNight` from the local cache. No network call.
    func load() async {
        await ensureOpen()
        guard let store else { return }

        let now = Date()
        let cal = Calendar(identifier: .gregorian)
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd"

        // Fetch last 14 days of daily metrics; take the most-recent (last) row.
        if let start = cal.date(byAdding: .day, value: -14, to: now) {
            let fromDay = fmt.string(from: start)
            let toDay = fmt.string(from: now)
            today = (try? await store.dailyMetrics(deviceId: deviceId, from: fromDay, to: toDay))?.last
        }

        // Fetch last 14 days of sleep sessions; take the most-recent (last) row.
        let windowStart = Int(now.timeIntervalSince1970) - 14 * 86_400
        let windowEnd   = Int(now.timeIntervalSince1970) + 86_400   // +1 day buffer
        lastNight = (try? await store.sleepSessions(deviceId: deviceId,
                                                    from: windowStart,
                                                    to: windowEnd,
                                                    limit: 50))?.last

        // Local metrics — all computed from raw sensor data, no server required.
        let startOfToday     = cal.startOfDay(for: now)
        let startOfTodayEpoch = Int(startOfToday.timeIntervalSince1970)

        // Overnight window: yesterday 8 PM → today 10 AM (covers most sleep schedules)
        let overnightFrom = startOfTodayEpoch - 4 * 3600
        let overnightTo   = startOfTodayEpoch + 10 * 3600
        let todayFrom     = startOfTodayEpoch
        let todayTo       = Int(now.timeIntervalSince1970)

        // Overnight R-R → current HRV
        let overnightRR = (try? await store.rrIntervals(
            deviceId: deviceId, from: overnightFrom, to: overnightTo, limit: 100_000
        )) ?? []
        localHRV = HRVCalculator.overnightRMSSD(from: overnightRR)

        // Overnight HR → current RHR + local sleep estimate
        let overnightHR = (try? await store.hrSamples(
            deviceId: deviceId, from: overnightFrom, to: overnightTo, limit: 100_000
        )) ?? []
        localRHR = LocalMetrics.rhr(from: overnightHR)

        if let first = overnightHR.first, let last = overnightHR.last {
            let durMin = Double(last.ts - first.ts) / 60.0
            if durMin >= 30 {
                let avgBPM = Int((Double(overnightHR.map(\.bpm).reduce(0, +)) / Double(overnightHR.count)).rounded())
                localSleepEstimate = LocalSleepEstimate(
                    wristOnTs: first.ts, wristOffTs: last.ts,
                    durationMinutes: durMin, avgBPM: avgBPM,
                    rhr: localRHR, hrv: localHRV)
            } else {
                localSleepEstimate = nil
            }
        } else {
            localSleepEstimate = nil
        }

        // Today HR → summary stats
        let todayHR = (try? await store.hrSamples(
            deviceId: deviceId, from: todayFrom, to: todayTo, limit: 100_000
        )) ?? []
        todayStats = LocalMetrics.todayStats(from: todayHR)

        // 7-night sparkline history: one wide query per sensor, filtered in-memory per night.
        // histFrom covers oldest night (7 nights ago at 8 PM) to tonight's window end.
        let histFrom = startOfTodayEpoch - 7 * 86_400 - 4 * 3600
        let histTo   = overnightTo

        let histRR = (try? await store.rrIntervals(
            deviceId: deviceId, from: histFrom, to: histTo, limit: 500_000
        )) ?? []
        let histHR = (try? await store.hrSamples(
            deviceId: deviceId, from: histFrom, to: histTo, limit: 500_000
        )) ?? []

        // i=6 → oldest night (6 days ago), i=0 → current overnight; append oldest first
        var hrvHist: [Double] = []
        var rhrHist: [Double] = []
        for i in stride(from: 6, through: 0, by: -1) {
            let nFrom = startOfTodayEpoch - i * 86_400 - 4 * 3600
            let nTo   = startOfTodayEpoch - i * 86_400 + 10 * 3600
            let nRR   = histRR.filter { $0.ts >= nFrom && $0.ts <= nTo }
            let nHR   = histHR.filter { $0.ts >= nFrom && $0.ts <= nTo }
            if let h = HRVCalculator.rmssd(nRR.map(\.rrMs)) { hrvHist.append(h) }
            if let r = LocalMetrics.rhr(from: nHR)           { rhrHist.append(r) }
        }
        localHRVHistory = hrvHist
        localRHRHistory = rhrHist
    }

    // MARK: - Refresh from server then reload

    /// Pull derived metrics from the server (if configured) then reload from cache.
    /// Uses pullDerived() — NOT the heavy full-stream pull() — to keep the UI refresh fast.
    /// Safe when serverSync == nil (just reloads). Never throws.
    func refresh() async {
        await ensureOpen()
        isRefreshing = true
        lastError = nil
        await serverSync?.pullDerived()
        await load()
        isRefreshing = false
        lastRefreshedAt = Date()

        // Morning recovery notification: fire once per calendar day when recovery is available.
        if let metric = today, let recovery = metric.recovery {
            RecoveryNotifier.notify(recovery: recovery, forDay: metric.day)
        }
    }

    // MARK: - Range reads for Trends/Sleep tabs

    /// Daily metrics for a day range (YYYY-MM-DD bounds, inclusive). Reads straight from cache.
    func daily(fromDay: String, toDay: String) async -> [DailyMetric] {
        await ensureOpen()
        guard let store else { return [] }
        return (try? await store.dailyMetrics(deviceId: deviceId, from: fromDay, to: toDay)) ?? []
    }

    /// Sleep sessions overlapping [from, to] (epoch seconds). Reads straight from cache.
    func sleepSessions(from: Int, to: Int, limit: Int) async -> [CachedSleepSession] {
        await ensureOpen()
        guard let store else { return [] }
        return (try? await store.sleepSessions(deviceId: deviceId, from: from, to: to, limit: limit)) ?? []
    }

    // MARK: - Profile (M0.5)

    /// Best-effort GET /v1/profile. Returns nil when unconfigured or on error.
    func getProfile() async -> Profile? {
        await ensureOpen()
        return await serverSync?.getProfile()
    }

    /// Best-effort POST /v1/profile. Returns true on 2xx, false when unconfigured or on error.
    func putProfile(_ profile: Profile) async -> Bool {
        await ensureOpen()
        return await serverSync?.putProfile(profile) ?? false
    }

    // MARK: - Sleep tab reads (M2)

    /// Returns the most-recent sleep session paired with the `DailyMetric` for the day its
    /// `endTs` falls on (UTC date), or nil when there are no cached sessions.
    ///
    /// The session carries stagesJSON / efficiency / RHR / HRV; the daily row carries stage
    /// minutes, disturbances, total_sleep_min, and the new in-sleep signals (spo2/skin-temp/resp).
    /// The Sleep tab reads both from this single call to avoid two separate async round-trips.
    func sleepDetail() async -> (session: CachedSleepSession, daily: DailyMetric?)? {
        await ensureOpen()
        guard let store else { return nil }

        // Fetch the most-recent session from the last 14 days.
        let now = Int(Date().timeIntervalSince1970)
        let windowStart = now - 14 * 86_400
        let windowEnd   = now + 86_400
        guard let session = (try? await store.sleepSessions(deviceId: deviceId,
                                                            from: windowStart,
                                                            to: windowEnd,
                                                            limit: 50))?.last else { return nil }

        // Derive the YYYY-MM-DD day that the session's endTs falls on (UTC).
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd"
        let endDate = Date(timeIntervalSince1970: TimeInterval(session.endTs))
        let day = fmt.string(from: endDate)

        // Look up the daily row for that exact day.
        let daily = (try? await store.dailyMetrics(deviceId: deviceId, from: day, to: day))?.first

        return (session: session, daily: daily)
    }

    /// Returns up to `nights` most-recent sleep sessions, ordered oldest→newest, for the
    /// fall-asleep(startTs)/wake(endTs) trend chart on the Sleep tab.
    ///
    /// Fetches a slightly wider window (`nights + 2` days) so a session that started just before
    /// the window boundary is still included, then trims to the last `nights` entries.
    func sevenNightSleepWake(nights: Int = 7) async -> [CachedSleepSession] {
        await ensureOpen()
        guard let store else { return [] }

        let now = Int(Date().timeIntervalSince1970)
        let windowStart = now - (nights + 2) * 86_400
        let windowEnd   = now + 86_400
        let sessions = (try? await store.sleepSessions(deviceId: deviceId,
                                                       from: windowStart,
                                                       to: windowEnd,
                                                       limit: nights + 2)) ?? []
        // sleepSessions returns ASC by startTs; take the last `nights` (most-recent), keep ASC order.
        return Array(sessions.suffix(nights))
    }

    // MARK: - Local HR series (Trends tab, no server required)

    /// Read HR samples from the local store, bin into time buckets, and return the
    /// average BPM per bucket as TrendPoints. Gaps in coverage produce no point —
    /// the chart shows real discontinuities rather than a misleading flat line.
    func localHRSeries(fromEpoch: Int, toEpoch: Int, maxPoints: Int = 300) async -> [TrendPoint] {
        await ensureOpen()
        guard let store, toEpoch > fromEpoch else { return [] }
        let samples = (try? await store.hrSamples(
            deviceId: deviceId, from: fromEpoch, to: toEpoch, limit: 50_000
        )) ?? []
        guard !samples.isEmpty else { return [] }
        let bucketSeconds = max(1, (toEpoch - fromEpoch) / maxPoints)
        var buckets: [Int: [Int]] = [:]
        for s in samples {
            buckets[(s.ts - fromEpoch) / bucketSeconds, default: []].append(s.bpm)
        }
        return buckets.sorted { $0.key < $1.key }.map { bucket, bpms in
            TrendPoint(
                id: "\(fromEpoch + bucket * bucketSeconds)",
                date: Date(timeIntervalSince1970: TimeInterval(fromEpoch + bucket * bucketSeconds)),
                value: Double(bpms.reduce(0, +)) / Double(bpms.count)
            )
        }
    }

    // MARK: - Raw HR series (server, kept for compatibility when a server is configured)

    /// Fetch a downsampled raw HR series from the server for a given epoch-second window.
    /// Returns [] when unconfigured — callers should prefer localHRSeries for offline use.
    func hrSeries(fromEpoch: Int, toEpoch: Int, maxPoints: Int) async -> [TrendPoint] {
        await ensureOpen()
        guard let serverSync else { return [] }
        let raw = await serverSync.getHRSeries(fromEpoch: fromEpoch, toEpoch: toEpoch, maxPoints: maxPoints)
        return raw.map { pair in
            TrendPoint(
                id: "\(pair.ts)",
                date: Date(timeIntervalSince1970: TimeInterval(pair.ts)),
                value: Double(pair.bpm)
            )
        }
    }

    // MARK: - Workouts (M5)

    /// Fetches auto-detected workout bouts from the server for the given date range.
    /// Calls ensureOpen() to initialise the store/sync stack, then delegates to ServerSync.
    /// Returns [] when unconfigured (no API key), offline, or on parse error — never throws.
    func workouts(from: String, to: String) async -> [Workout] {
        await ensureOpen()
        return await serverSync?.getWorkouts(from: from, to: to) ?? []
    }

    // MARK: - Workout calorie backfill (M7)

    /// Asks the server to recompute calorie estimates for workouts in [from, to] (YYYY-MM-DD UTC).
    /// Fire-and-forget: the caller should not await a meaningful result; returns false silently if
    /// unconfigured or the request fails. Never throws.
    @discardableResult
    func backfillWorkouts(from: String, to: String) async -> Bool {
        await ensureOpen()
        return await serverSync?.backfillWorkouts(from: from, to: to) ?? false
    }

    // MARK: - Local activity detection (no server)

    /// Detect elevated-HR activity bouts from the local hr_samples store.
    /// Uses WorkoutDetector (≥10 min sustained >100 BPM). Returns newest-first.
    /// Returns [] when there is no local data — never returns guessed results.
    func localActivities(lastDays: Int = 30) async -> [DetectedActivity] {
        await ensureOpen()
        guard let store else { return [] }
        let now  = Int(Date().timeIntervalSince1970)
        let from = now - lastDays * 86_400
        let samples = (try? await store.hrSamples(
            deviceId: deviceId, from: from, to: now, limit: 200_000
        )) ?? []
        return WorkoutDetector.detect(from: samples)
    }
}
