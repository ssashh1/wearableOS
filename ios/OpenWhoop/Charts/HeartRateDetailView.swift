import SwiftUI
import Charts

// MARK: - HeartRateDetailView
// Full-page view for the raw 1 Hz HR stream. Distinct from MetricDetailView (which is for
// daily-aggregate metrics). Provides a time-window range selector (6H / 24H / 3D / 7D),
// stats strip (AVG / MIN / MAX / LATEST), and a tap-to-highlight MetricChart.
// Gaps in the data are fine — the strap isn't always streaming; we render whatever exists.
// iOS 16 safe.

struct HeartRateDetailView: View {

    @EnvironmentObject private var metrics: MetricsRepository

    // MARK: - Time window

    enum Window: String, CaseIterable, Identifiable {
        case sixHours  = "6H"
        case oneDay    = "24H"
        case threeDays = "3D"
        case sevenDays = "7D"

        var id: String { rawValue }
        var label: String { rawValue }

        /// Duration in seconds.
        var seconds: Int {
            switch self {
            case .sixHours:  return 6 * 3_600
            case .oneDay:    return 86_400
            case .threeDays: return 3 * 86_400
            case .sevenDays: return 7 * 86_400
            }
        }

        /// Max points to request from the server — larger windows use more points to preserve shape.
        var maxPoints: Int {
            switch self {
            case .sixHours:  return 300
            case .oneDay:    return 400
            case .threeDays: return 400
            case .sevenDays: return 500
            }
        }
    }

    @State private var selectedWindow: Window = .oneDay
    @State private var points: [TrendPoint] = []
    @State private var isLoading = true
    @State private var selected: TrendPoint? = nil

    // MARK: - Stats

    private struct Stats {
        let avg: Double; let min: Double; let max: Double; let latest: Double?
    }

    private var stats: Stats? {
        guard !points.isEmpty else { return nil }
        let vals = points.map(\.value)
        return Stats(
            avg:    vals.reduce(0, +) / Double(vals.count),
            min:    vals.min()!,
            max:    vals.max()!,
            latest: points.last?.value
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
        .navigationTitle("Heart Rate")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await reload() }
        .onChange(of: selectedWindow) { _ in
            selected = nil
            Task { await reload() }
        }
    }

    // MARK: - Loading view

    private var loadingView: some View {
        VStack(spacing: WH.Spacing.md) {
            ProgressView()
                .tint(WH.Color.textSecondary)
            Text("Loading heart rate…")
                .font(WH.Font.caption)
                .foregroundStyle(WH.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Scroll content

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WH.Spacing.lg) {
                windowPicker
                if let s = stats { statsStrip(s) }
                chartSection
                Spacer(minLength: WH.Spacing.xl)
            }
            .padding(WH.Spacing.md)
        }
        .background(WH.Color.background)
    }

    // MARK: - Window picker

    private var windowPicker: some View {
        Picker("Window", selection: $selectedWindow) {
            ForEach(Window.allCases) { w in
                Text(w.label).tag(w)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Stats strip

    private func statsStrip(_ s: Stats) -> some View {
        HStack(spacing: 0) {
            statCell(label: "AVG",    value: String(Int(s.avg.rounded())))
            Divider().frame(height: 32).background(WH.Color.separator)
            statCell(label: "MIN",    value: String(Int(s.min.rounded())))
            Divider().frame(height: 32).background(WH.Color.separator)
            statCell(label: "MAX",    value: String(Int(s.max.rounded())))
            Divider().frame(height: 32).background(WH.Color.separator)
            statCell(label: "LATEST", value: s.latest.map { String(Int($0.rounded())) } ?? "—")
        }
        .padding(WH.Spacing.md)
        .background(WH.Color.surface,
                    in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
    }

    private func statCell(label: String, value: String) -> some View {
        VStack(spacing: WH.Spacing.xs) {
            Text(label)
                .font(WH.Font.cardTitle)
                .foregroundStyle(WH.Color.textSecondary)
                .tracking(1.0)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(MetricKind.rawHR.color)
                    .monospacedDigit()
                if value != "—" {
                    Text("bpm")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(WH.Color.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Chart section

    private var chartSection: some View {
        VStack(spacing: WH.Spacing.sm) {
            // Window label
            HStack {
                Spacer()
                Text(windowLabel)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(WH.Color.textSecondary)
                Spacer()
            }

            MetricChart(
                series: points,
                kind: .rawHR,
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
        let now = Date()
        let start = Date(timeIntervalSince1970: now.timeIntervalSince1970 - TimeInterval(selectedWindow.seconds))
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, h:mm a"
        return "\(fmt.string(from: start)) – now"
    }

    // MARK: - Data loading

    private func reload() async {
        isLoading = true
        let now = Int(Date().timeIntervalSince1970)
        let from = now - selectedWindow.seconds
        points = await metrics.hrSeries(fromEpoch: from, toEpoch: now, maxPoints: selectedWindow.maxPoints)
        isLoading = false
    }
}

// MARK: - Preview

#Preview("HR Detail") {
    NavigationStack {
        HeartRateDetailView()
            .environmentObject(MetricsRepository(deviceId: "preview"))
    }
}
