import SwiftUI
import Charts

// MARK: - Sparkline
// Lightweight, label-free line chart for a [Double] data series.
// Renders a smooth line + optional area fill, tinted by a passed-in color.
// Handles empty and single-point series gracefully.

struct Sparkline: View {

    var data: [Double]
    var color: Color = WH.Color.strainBlue
    var showArea: Bool = true
    var lineWidth: CGFloat = 2

    // Normalised series for display (fallback to flat if empty/1-point)
    private var displayData: [Double] {
        guard data.count >= 2 else {
            return data.isEmpty ? [0, 0] : [data[0], data[0]]
        }
        return data
    }

    var body: some View {
        Chart {
            ForEach(Array(displayData.enumerated()), id: \.offset) { idx, value in
                if showArea {
                    AreaMark(
                        x: .value("index", idx),
                        y: .value("value", value)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [color.opacity(0.35), color.opacity(0.0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                }

                LineMark(
                    x: .value("index", idx),
                    y: .value("value", value)
                )
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.catmullRom)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { content in
            content.background(Color.clear)
        }
    }
}

// MARK: - Preview

#Preview("Sparkline") {
    let hrv: [Double] = [58, 62, 55, 70, 66, 74, 68, 72, 65, 78, 71, 69]
    let rhr: [Double] = [52, 50, 51, 49, 48, 50, 47, 49, 48, 46, 48, 47]

    VStack(spacing: WH.Spacing.lg) {
        Sparkline(data: hrv, color: WH.Color.recoveryGreen)
            .frame(height: 60)

        Sparkline(data: rhr, color: WH.Color.strainBlue)
            .frame(height: 60)

        // Edge cases
        Sparkline(data: [], color: WH.Color.recoveryYellow)
            .frame(height: 40)

        Sparkline(data: [65], color: WH.Color.recoveryRed)
            .frame(height: 40)
    }
    .padding(WH.Spacing.md)
    .background(WH.Color.background)
}
