import SwiftUI
import Charts

// MARK: - TrendPoint
// Shared model used by TrendChartCard and MetricChart.
// id = YYYY-MM-DD, unique per day.

struct TrendPoint: Identifiable, Equatable {
    let id: String   // YYYY-MM-DD
    let date: Date
    let value: Double
}

// MARK: - TrendChartCard
// A titled card containing a MetricChart for a single metric.
// Header is tappable (chevron) → MetricDetailView for full history.
// Tapping a chart point → onSelectDay callback (DayDetailView sheet).

struct TrendChartCard: View {

    let kind: MetricKind
    let points: [TrendPoint]
    let latestLabel: String     // pre-formatted display string for latest value
    let onSelectDay: (String) -> Void

    @State private var selected: TrendPoint? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: WH.Spacing.sm) {

            // Header: tappable → MetricDetailView
            NavigationLink(destination: MetricDetailView(kind: kind)) {
                HStack(alignment: .lastTextBaseline) {
                    Text(kind.title.uppercased())
                        .font(WH.Font.cardTitle)
                        .foregroundStyle(WH.Color.textSecondary)
                        .tracking(1.2)
                    Spacer()
                    HStack(alignment: .lastTextBaseline, spacing: 3) {
                        Text(latestLabel)
                            .font(WH.Font.metricMedium(size: 22))
                            .foregroundStyle(kind.color)
                            .monospacedDigit()
                        Text(kind.unit)
                            .font(WH.Font.caption)
                            .foregroundStyle(WH.Color.textSecondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(WH.Color.textSecondary.opacity(0.5))
                        .padding(.leading, WH.Spacing.xs)
                }
            }
            .buttonStyle(.plain)

            // Chart (compact: no axes, with day-tap selection)
            MetricChart(
                series: points,
                kind: kind,
                showAxes: true,
                showSelection: true,
                yDomain: kind.fixedYDomain,
                selected: $selected
            )
            .frame(height: 140)
            .onChange(of: selected) { pt in
                if let pt = pt { onSelectDay(pt.id) }
            }
        }
        .padding(WH.Spacing.md)
        .background(WH.Color.surface,
                    in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
    }
}
