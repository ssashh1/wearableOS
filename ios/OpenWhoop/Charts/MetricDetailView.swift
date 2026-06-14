import SwiftUI
import WhoopStore

// MARK: - MetricDetailView
// Full-page detail for a single metric: range selector, stats strip, zoomable chart, prev/next paging.
// Pushed via NavigationLink — NOT a sheet. iOS 16 safe.

struct MetricDetailView: View {

    let kind: MetricKind

    @EnvironmentObject private var metrics: MetricsRepository

    // MARK: - State

    enum TimeRange: Int, CaseIterable, Identifiable {
        case week = 7, month = 30, quarter = 90, halfYear = 180
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .week:     return "1W"
            case .month:    return "1M"
            case .quarter:  return "3M"
            case .halfYear: return "6M"
            }
        }
    }

    @State private var selectedRange: TimeRange = .month
    @State private var allRows: [DailyMetric] = []
    @State private var isLoading = true
    @State private var selected: TrendPoint? = nil
    /// Paging: pageOffset shifts the visible window by half the range period.
    /// 0 = most-recent window (default). Positive = further into the past.
    @State private var pageOffset: Int = 0

    // MARK: - Derived

    /// All TrendPoints for the max window (180 days), filtered to the selected range + page offset.
    private var allPoints: [TrendPoint] {
        let fmt = isoFormatter()
        return allRows.compactMap { row -> TrendPoint? in
            guard let val = kind.value(from: row),
                  let date = fmt.date(from: row.day) else { return nil }
            return TrendPoint(id: row.day, date: date, value: val)
        }
    }

    private var visiblePoints: [TrendPoint] {
        let all = allPoints
        guard !all.isEmpty else { return [] }

        let cal = Calendar(identifier: .gregorian)
        let today = Date()
        let halfPeriod = selectedRange.rawValue / 2

        // Window end shifts earlier by (pageOffset * halfPeriod) days
        guard let windowEnd = cal.date(
            byAdding: .day,
            value: -(pageOffset * halfPeriod),
            to: today
        ) else { return all }

        guard let windowStart = cal.date(
            byAdding: .day,
            value: -(selectedRange.rawValue - 1),
            to: windowEnd
        ) else { return all }

        return all.filter { $0.date >= windowStart && $0.date <= windowEnd }
    }

    /// X-scale domain for the current window (ensures chart fills the axis even with sparse data).
    private var xScaleDomain: ClosedRange<Date> {
        let cal = Calendar(identifier: .gregorian)
        let today = Date()
        let halfPeriod = selectedRange.rawValue / 2
        let end   = cal.date(byAdding: .day, value: -(pageOffset * halfPeriod), to: today) ?? today
        let start = cal.date(byAdding: .day, value: -(selectedRange.rawValue - 1), to: end) ?? end
        return start...end
    }

    private var canPageBack: Bool {
        // Can go back if the earliest allPoints date is before our current window start
        guard let earliest = allPoints.first?.date else { return false }
        return earliest < xScaleDomain.lowerBound
    }

    private var canPageForward: Bool { pageOffset > 0 }

    // MARK: - Stats over visible range

    private struct Stats {
        let avg: Double; let min: Double; let max: Double; let latest: Double?
    }

    private var stats: Stats? {
        let pts = visiblePoints
        guard !pts.isEmpty else { return nil }
        let vals = pts.map(\.value)
        return Stats(
            avg:    vals.reduce(0, +) / Double(vals.count),
            min:    vals.min()!,
            max:    vals.max()!,
            latest: pts.last?.value
        )
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            WH.Color.background.ignoresSafeArea()
            if isLoading {
                loadingView
            } else {
                scrollContent
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await loadAll() }
        // Reset page when range changes
        .onChange(of: selectedRange) { _ in
            pageOffset = 0
            selected = nil
        }
    }

    // MARK: - Loading view

    private var loadingView: some View {
        VStack(spacing: WH.Spacing.md) {
            ProgressView()
                .tint(WH.Color.textSecondary)
            Text("Loading \(kind.title)…")
                .font(WH.Font.caption)
                .foregroundStyle(WH.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Scroll content

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WH.Spacing.lg) {

                // Range selector
                rangePicker

                // Stats strip
                if let s = stats {
                    statsStrip(s)
                }

                // Chart + paging controls
                chartSection

                Spacer(minLength: WH.Spacing.xl)
            }
            .padding(WH.Spacing.md)
        }
        .background(WH.Color.background)
    }

    // MARK: - Range picker

    private var rangePicker: some View {
        Picker("Range", selection: $selectedRange) {
            ForEach(TimeRange.allCases) { r in
                Text(r.label).tag(r)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Stats strip

    private func statsStrip(_ s: Stats) -> some View {
        HStack(spacing: 0) {
            statCell(label: "AVG",    value: kind.formatShort(s.avg),        unit: kind.unit)
            Divider().frame(height: 32).background(WH.Color.separator)
            statCell(label: "MIN",    value: kind.formatShort(s.min),        unit: kind.unit)
            Divider().frame(height: 32).background(WH.Color.separator)
            statCell(label: "MAX",    value: kind.formatShort(s.max),        unit: kind.unit)
            Divider().frame(height: 32).background(WH.Color.separator)
            statCell(label: "LATEST", value: s.latest.map { kind.formatShort($0) } ?? "—", unit: kind.unit)
        }
        .padding(WH.Spacing.md)
        .background(WH.Color.surface,
                    in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
    }

    private func statCell(label: String, value: String, unit: String) -> some View {
        VStack(spacing: WH.Spacing.xs) {
            Text(label)
                .font(WH.Font.cardTitle)
                .foregroundStyle(WH.Color.textSecondary)
                .tracking(1.0)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(kind.color)
                    .monospacedDigit()
                if value != "—" {
                    Text(unit)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(WH.Color.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Chart section (chart + paging chevrons)

    private var chartSection: some View {
        VStack(spacing: WH.Spacing.sm) {
            // Paging header
            HStack {
                Button {
                    pageOffset += 1
                    selected = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(canPageBack ? WH.Color.textSecondary : WH.Color.separator)
                }
                .disabled(!canPageBack)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())

                Spacer()

                // Window label
                Text(windowLabel)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(WH.Color.textSecondary)

                Spacer()

                Button {
                    pageOffset -= 1
                    selected = nil
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(canPageForward ? WH.Color.textSecondary : WH.Color.separator)
                }
                .disabled(!canPageForward)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
            }
            .padding(.horizontal, WH.Spacing.xs)

            // The unified chart component
            MetricChart(
                series: visiblePoints,
                kind: kind,
                showAxes: true,
                showSelection: true,
                yDomain: nil,
                selected: $selected
            )
            .frame(height: 260)
            .padding(WH.Spacing.xs)
            .background(WH.Color.surface,
                        in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
        }
    }

    private var windowLabel: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        let d = xScaleDomain
        return "\(fmt.string(from: d.lowerBound)) – \(fmt.string(from: d.upperBound))"
    }

    // MARK: - Data loading

    private func loadAll() async {
        let fmt = isoFormatter()
        let today = Date()
        let cal = Calendar(identifier: .gregorian)
        guard let from = cal.date(byAdding: .day, value: -179, to: today) else {
            isLoading = false; return
        }
        let fromDay = fmt.string(from: from)
        let toDay   = fmt.string(from: today)
        allRows = await metrics.daily(fromDay: fromDay, toDay: toDay)
        isLoading = false
    }

    // MARK: - Helpers

    private func isoFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }
}
