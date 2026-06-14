import SwiftUI
import WhoopStore

// MARK: - TrendsView
// M3 Trends tab — historical charts for Recovery / HRV / Resting HR / Strain / Sleep Duration,
// plus a raw Heart Rate card (downsampled 1 Hz stream from /v1/streams/hr).
// Data source: MetricsRepository.daily(fromDay:toDay:) for daily-aggregate cards (cached locally
// by ServerSync); MetricsRepository.hrSeries(fromEpoch:toEpoch:maxPoints:) for the HR card
// (live single-request fetch, downsampled by the server).
// Tapping a daily chart card header → MetricDetailView (full history, range selector).
// Tapping a chart point  → DayDetailView sheet (full day breakdown).
// Tapping the HR card → HeartRateDetailView (range selector, stats strip).

struct TrendsView: View {
    @EnvironmentObject private var metrics: MetricsRepository

    // MARK: - State

    enum Range: Int, CaseIterable, Identifiable {
        case week = 7, month = 30, quarter = 90
        var id: Int { rawValue }
        var label: String {
            switch self { case .week: return "7D"; case .month: return "30D"; case .quarter: return "90D" }
        }
    }

    @State private var selectedRange: Range = .month
    @State private var rows: [DailyMetric] = []
    @State private var isLoading = true
    @State private var selectedDay: SelectedDay?

    // MARK: - Raw HR card state (last 24h, loaded independently of the daily range)
    @State private var hrPoints: [TrendPoint] = []
    @State private var hrSelected: TrendPoint? = nil
    @State private var hrIsLoading = true

    // Local strain chart selection (not navigable — used only to satisfy MetricChart binding)
    @State private var localStrainSelected: TrendPoint? = nil

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                WH.Color.background.ignoresSafeArea()

                Group {
                    if isLoading {
                        loadingView
                    } else {
                        scrollContent
                    }
                }
            }
            // Hide the system nav bar on the root; pushed detail views manage their own bars.
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .task {
            // Refresh immediately, then every 60 s so live-persisted HR appears automatically.
            while !Task.isCancelled {
                await metrics.refresh()
                await reloadRows()
                if isLoading { isLoading = false }
                await reloadHR()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .refreshable {
            await metrics.refresh()
            await reloadRows()
            await reloadHR()
        }
        .onChange(of: selectedRange) { _ in
            Task {
                await reloadRows()
                await reloadHR()
            }
        }
        .sheet(item: $selectedDay) { day in
            DayDetailView(selected: day)
        }
    }

    // MARK: - Data loading

    /// Reload raw HR from the local store for the currently selected range.
    /// Reads directly from SQLite — no server required.
    private func reloadHR() async {
        hrIsLoading = true
        let now = Int(Date().timeIntervalSince1970)
        let from = now - selectedRange.rawValue * 86_400
        hrPoints = await metrics.localHRSeries(fromEpoch: from, toEpoch: now)
        hrIsLoading = false
    }

    private func reloadRows() async {
        let (from, to) = dayRange(for: selectedRange)
        rows = await metrics.daily(fromDay: from, toDay: to)
    }

    private func dayRange(for range: Range) -> (String, String) {
        let cal = Calendar(identifier: .gregorian)
        let utc = TimeZone(identifier: "UTC")!
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.timeZone = utc
        fmt.dateFormat = "yyyy-MM-dd"
        let today = Date()
        let from  = cal.date(byAdding: .day, value: -(range.rawValue - 1), to: today) ?? today
        return (fmt.string(from: from), fmt.string(from: today))
    }

    // MARK: - Derived chart data (kind-driven)

    private func points(for kind: MetricKind) -> [TrendPoint] {
        rows.compactMap { row -> TrendPoint? in
            guard let val = kind.value(from: row),
                  let date = isoDate(row.day) else { return nil }
            return TrendPoint(id: row.day, date: date, value: val)
        }
    }

    private func isoDate(_ day: String) -> Date? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.date(from: day)
    }

    // MARK: - Formatted latest values

    private func latestLabel(for kind: MetricKind, pts: [TrendPoint]) -> String {
        guard let last = pts.last else { return "—" }
        return kind.formatShort(last.value)
    }

    // MARK: - Day selection helper

    private func selectDay(_ dayString: String) {
        guard let row = rows.first(where: { $0.day == dayString }) else { return }
        selectedDay = SelectedDay(id: dayString, metric: row)
    }

    // MARK: - Loading view

    private var loadingView: some View {
        VStack(spacing: WH.Spacing.md) {
            ProgressView()
                .tint(WH.Color.textSecondary)
            Text("Loading trends…")
                .font(WH.Font.caption)
                .foregroundStyle(WH.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Scroll content

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WH.Spacing.lg) {

                // Custom tight header (replaces the hidden system large-title nav bar)
                ScreenHeader("Trends")

                rangePicker

                // Always show the HR chart — it reads from local SQLite and populates as soon
                // as the WHOOP streams realtime data (no server required).
                hrCard

                if rows.isEmpty && metrics.localStrainHistory.isEmpty && hrPoints.isEmpty {
                    emptyState
                } else if !rows.isEmpty || !metrics.localStrainHistory.isEmpty {
                    chartsStack
                }

                if let err = metrics.lastError {
                    errorBanner(err)
                }

                syncFooter

                if !rows.isEmpty {
                    dayListSection
                }

                Spacer(minLength: WH.Spacing.xl)
            }
            .padding(WH.Spacing.md)
        }
        .background(WH.Color.background)
    }

    // MARK: - Range picker

    private var rangePicker: some View {
        Picker("Range", selection: $selectedRange) {
            ForEach(Range.allCases) { r in
                Text(r.label).tag(r)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Charts stack

    private var chartsStack: some View {
        VStack(spacing: WH.Spacing.md) {
            // Daily-aggregate cards (server) — only when server data is present
            if !rows.isEmpty {
                ForEach(MetricKind.dailyCases, id: \.id) { kind in
                    let pts = points(for: kind)
                    TrendChartCard(
                        kind: kind,
                        points: pts,
                        latestLabel: latestLabel(for: kind, pts: pts),
                        onSelectDay: selectDay
                    )
                }
            }

            // Local strain chart — shown when no server data but local HR exists
            localStrainCard
        }
    }

    // MARK: - Local strain chart card

    @ViewBuilder
    private var localStrainCard: some View {
        let pts = metrics.localStrainHistory
        if !pts.isEmpty && rows.isEmpty {
            VStack(alignment: .leading, spacing: WH.Spacing.sm) {
                HStack(alignment: .lastTextBaseline) {
                    Text("LOCAL STRAIN (EST.)")
                        .font(WH.Font.cardTitle)
                        .foregroundStyle(WH.Color.textSecondary)
                        .tracking(1.2)
                    Spacer()
                    HStack(alignment: .lastTextBaseline, spacing: 3) {
                        Text(pts.last.map { MetricKind.strain.formatShort($0.value) } ?? "—")
                            .font(WH.Font.metricMedium(size: 22))
                            .foregroundStyle(WH.Color.strainBlue)
                            .monospacedDigit()
                        Text(MetricKind.strain.unit)
                            .font(WH.Font.caption)
                            .foregroundStyle(WH.Color.textSecondary)
                    }
                }
                MetricChart(
                    series: pts,
                    kind: .strain,
                    showAxes: true,
                    showSelection: false,
                    yDomain: MetricKind.strain.fixedYDomain,
                    selected: $localStrainSelected
                )
                .frame(height: 140)
                Text("Edwards TRIMP · \(metrics.maxHRIsUserSet ? "user-set" : "auto-detected") max HR · local resting HR")
                    .font(WH.Font.caption)
                    .foregroundStyle(WH.Color.textSecondary.opacity(0.7))
            }
            .padding(WH.Spacing.md)
            .background(WH.Color.surface,
                        in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
        }
    }

    // MARK: - Raw HR card

    private var hrCard: some View {
        NavigationLink(destination: HeartRateDetailView()) {
            VStack(alignment: .leading, spacing: WH.Spacing.sm) {
                // Header
                HStack(alignment: .lastTextBaseline) {
                    Text("HEART RATE")
                        .font(WH.Font.cardTitle)
                        .foregroundStyle(WH.Color.textSecondary)
                        .tracking(1.2)
                    Spacer()
                    HStack(alignment: .lastTextBaseline, spacing: 3) {
                        Text(hrLatestLabel)
                            .font(WH.Font.metricMedium(size: 22))
                            .foregroundStyle(MetricKind.rawHR.color)
                            .monospacedDigit()
                        if !hrPoints.isEmpty {
                            Text("bpm")
                                .font(WH.Font.caption)
                                .foregroundStyle(WH.Color.textSecondary)
                        }
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(WH.Color.textSecondary.opacity(0.5))
                        .padding(.leading, WH.Spacing.xs)
                }

                // Chart or skeleton
                if hrIsLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                            .tint(WH.Color.textSecondary)
                        Spacer()
                    }
                    .frame(height: 140)
                } else {
                    MetricChart(
                        series: hrPoints,
                        kind: .rawHR,
                        showAxes: true,
                        showSelection: true,
                        yDomain: nil,
                        selected: $hrSelected
                    )
                    .frame(height: 140)
                }
            }
            .padding(WH.Spacing.md)
            .background(WH.Color.surface,
                        in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var hrLatestLabel: String {
        guard let last = hrPoints.last else { return "—" }
        return String(Int(last.value.rounded()))
    }

    // MARK: - Day list section

    private var dayListSection: some View {
        VStack(alignment: .leading, spacing: WH.Spacing.sm) {
            Text("ALL DAYS")
                .font(WH.Font.cardTitle)
                .foregroundStyle(WH.Color.textSecondary)
                .tracking(1.5)
                .padding(.top, WH.Spacing.xs)

            VStack(spacing: 1) {
                ForEach(rows.reversed(), id: \.day) { row in
                    dayRow(row)
                }
            }
            .background(WH.Color.surface,
                        in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
        }
    }

    private func dayRow(_ row: DailyMetric) -> some View {
        Button {
            selectedDay = SelectedDay(id: row.day, metric: row)
        } label: {
            HStack(spacing: WH.Spacing.sm) {
                Text(formatDay(row.day))
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(WH.Color.textPrimary)
                    .frame(width: 80, alignment: .leading)

                Spacer()

                if let rec = row.recovery {
                    let pct = rec * 100
                    Circle()
                        .fill(WH.Color.recoveryColor(forPercent: pct))
                        .frame(width: 8, height: 8)
                    Text("\(Int(pct.rounded()))%")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(WH.Color.recoveryColor(forPercent: pct))
                        .frame(width: 38, alignment: .trailing)
                        .monospacedDigit()
                } else {
                    Text("—")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(WH.Color.textSecondary)
                        .frame(width: 46, alignment: .trailing)
                }

                if let strain = row.strain {
                    Text(String(format: "%.1f", strain))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(WH.Color.strainBlue)
                        .frame(width: 34, alignment: .trailing)
                        .monospacedDigit()
                } else {
                    Text("—")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(WH.Color.textSecondary)
                        .frame(width: 34, alignment: .trailing)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WH.Color.textSecondary.opacity(0.5))
            }
            .padding(.horizontal, WH.Spacing.md)
            .padding(.vertical, WH.Spacing.sm)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: WH.Spacing.sm) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(WH.Color.textSecondary)
                Text("No daily history yet")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(WH.Color.textPrimary)
                Text("Daily recovery, strain, and sleep trends require a server. Heart rate data populates in the chart above as your WHOOP streams — keep the Device tab connected.")
                    .font(WH.Font.caption)
                    .foregroundStyle(WH.Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, WH.Spacing.xl)
            }
            .padding(.vertical, WH.Spacing.xxl)
            Spacer()
        }
    }

    // MARK: - Error banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: WH.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(WH.Color.recoveryYellow)
            Text(message)
                .font(WH.Font.caption)
                .foregroundStyle(WH.Color.textSecondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(WH.Spacing.sm)
        .background(WH.Color.surface2,
                    in: RoundedRectangle(cornerRadius: WH.Radius.chip, style: .continuous))
    }

    // MARK: - Sync footer

    private var syncFooter: some View {
        HStack {
            if metrics.isRefreshing {
                HStack(spacing: WH.Spacing.xs) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(WH.Color.textSecondary)
                    Text("Updating…")
                        .font(WH.Font.caption)
                        .foregroundStyle(WH.Color.textSecondary)
                }
            } else if let at = metrics.lastRefreshedAt {
                Text("Updated \(relativeTime(from: at))")
                    .font(WH.Font.caption)
                    .foregroundStyle(WH.Color.textSecondary)
            }
            Spacer()
        }
    }

    // MARK: - Formatting helpers

    private func formatDay(_ day: String) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        guard let date = fmt.date(from: day) else { return day }
        let out = DateFormatter()
        out.dateFormat = "EEE M/d"
        return out.string(from: date)
    }

    private func relativeTime(from date: Date) -> String {
        let elapsed = Int(-date.timeIntervalSinceNow)
        switch elapsed {
        case ..<5:   return "just now"
        case ..<60:  return "\(elapsed)s ago"
        case ..<3600: return "\(elapsed / 60)m ago"
        default:     return "\(elapsed / 3600)h ago"
        }
    }
}

// MARK: - Preview

#Preview("Trends — empty") {
    TrendsView()
        .environmentObject(MetricsRepository(deviceId: "preview"))
}
