import SwiftUI
import WhoopStore

// MARK: - SevenNightChart
// Gantt-style 7-night sleep/wake timeline.
//
// Layout: each night is ONE row — day label (fixed left column) + a bar drawn
// on a shared time-of-day GeometryReader track + bed/wake clock labels flanking
// the bar's ends. A single shared axis ruler at the bottom is aligned to the
// same track width, so every element is pixel-perfectly registered.
//
// Time axis: "hours since the 6 PM preceding each night's bedtime."
// A typical 11 PM → 7 AM session maps to 5.0 → 13.0.
// One shared [xMin, xMax] domain with small padding covers all nights.

struct SevenNightChart: View {
    let sessions: [CachedSleepSession]

    // MARK: - Static formatters (allocated once, never in body)

    private static let nightLabelFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE M/d"
        return fmt
    }()

    private static let clockFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        fmt.amSymbol = "AM"
        fmt.pmSymbol = "PM"
        return fmt
    }()

    // MARK: - Layout constants

    private let labelColumnWidth: CGFloat = 54   // day-label column
    private let rowHeight:        CGFloat = 44   // height of each night row
    private let barHeight:        CGFloat = 14   // the sleep bar itself
    private let axisHeight:       CGFloat = 28   // bottom axis ruler row

    // MARK: - Row model

    struct NightRow: Identifiable {
        let id: Int          // session.startTs — unique natural key
        let label: String    // e.g. "Mon 5/26"
        let bedtime: String  // e.g. "11:42 PM"
        let waketime: String // e.g. "6:46 AM"
        let xStart: Double   // hours from reference 6 PM
        let xEnd:   Double
    }

    // MARK: - Time helpers (same logic as the old implementation, kept intact)

    /// Hours from the most-recent 6 PM that preceded the session's startTs.
    private func hoursFromBaseline(_ epochSeconds: Int, referenceSixPm: Date) -> Double {
        let target = Date(timeIntervalSince1970: TimeInterval(epochSeconds))
        return target.timeIntervalSince(referenceSixPm) / 3600
    }

    /// Returns the most-recent 18:00 local time strictly before session.startTs.
    private func referenceSixPm(for session: CachedSleepSession) -> Date {
        let cal = Calendar.current
        let startDate = Date(timeIntervalSince1970: TimeInterval(session.startTs))
        var comps = cal.dateComponents([.year, .month, .day], from: startDate)
        comps.hour = 18; comps.minute = 0; comps.second = 0
        guard let sameDaySixPm = cal.date(from: comps) else { return startDate }
        if startDate < sameDaySixPm {
            return cal.date(byAdding: .day, value: -1, to: sameDaySixPm) ?? sameDaySixPm
        }
        return sameDaySixPm
    }

    private func nightLabel(_ session: CachedSleepSession) -> String {
        SevenNightChart.nightLabelFormatter.string(
            from: Date(timeIntervalSince1970: TimeInterval(session.endTs))
        )
    }

    private func clockTime(_ epochSeconds: Int) -> String {
        SevenNightChart.clockFormatter.string(
            from: Date(timeIntervalSince1970: TimeInterval(epochSeconds))
        )
    }

    // MARK: - Body

    var body: some View {
        // Build row models
        let rows: [NightRow] = sessions.map { s in
            let sixPm = referenceSixPm(for: s)
            return NightRow(
                id:       s.startTs,
                label:    nightLabel(s),
                bedtime:  clockTime(s.startTs),
                waketime: clockTime(s.endTs),
                xStart:   hoursFromBaseline(s.startTs, referenceSixPm: sixPm),
                xEnd:     hoursFromBaseline(s.endTs,   referenceSixPm: sixPm)
            )
        }

        // Shared domain across all nights, with padding
        let allX = rows.flatMap { [$0.xStart, $0.xEnd] }
        let xMin = (allX.min() ?? 4.0) - 0.5
        let xMax = (allX.max() ?? 14.0) + 0.75

        // Axis ticks at clean clock hours that fall inside the domain
        let candidates: [Double] = [3.0, 6.0, 9.0, 12.0, 15.0, 18.0]
        let axisTicks = candidates.filter { $0 >= xMin && $0 <= xMax }

        VStack(alignment: .leading, spacing: 0) {
            if rows.count < 2 {
                // Graceful fallback for 0-1 nights
                HStack {
                    Image(systemName: "moon.zzz")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(WH.Color.textSecondary)
                    Text(rows.isEmpty
                         ? "No nights recorded yet"
                         : "One night recorded — collect more for the trend view")
                        .font(WH.Font.caption)
                        .foregroundStyle(WH.Color.textSecondary)
                    Spacer()
                }
                .padding(WH.Spacing.md)
            } else {
                GanttCanvas(
                    rows: rows,
                    xMin: xMin,
                    xMax: xMax,
                    axisTicks: axisTicks,
                    labelColumnWidth: labelColumnWidth,
                    rowHeight: rowHeight,
                    barHeight: barHeight,
                    axisHeight: axisHeight
                )
            }
        }
        .padding(WH.Spacing.md)
        .background(WH.Color.surface,
                    in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
    }
}

// MARK: - GanttCanvas
// The actual positioned drawing — a separate View so GeometryReader's
// closure gets a proper non-ViewBuilder context for local let-bindings.

private struct GanttCanvas: View {
    let rows:             [SevenNightChart.NightRow]
    let xMin:             Double
    let xMax:             Double
    let axisTicks:        [Double]
    let labelColumnWidth: CGFloat
    let rowHeight:        CGFloat
    let barHeight:        CGFloat
    let axisHeight:       CGFloat

    /// Converts "hours since 18:00" to a short axis label: 3→"9p" 6→"12a" 9→"3a" 12→"6a"
    private func axisLabel(hoursFromSixPm: Double) -> String {
        let totalHour = Int(18 + hoursFromSixPm) % 24
        let isPm      = totalHour >= 12
        let display   = totalHour % 12 == 0 ? 12 : totalHour % 12
        return "\(display)\(isPm ? "p" : "a")"
    }

    var body: some View {
        GeometryReader { geo in
            canvasContent(totalWidth: geo.size.width)
        }
        .frame(height: CGFloat(rows.count) * rowHeight + axisHeight)
    }

    // Extracted so we can use local `let` freely (plain function, not ViewBuilder)
    @ViewBuilder
    private func canvasContent(totalWidth: CGFloat) -> some View {
        let trackWidth = totalWidth - labelColumnWidth
        let totalHeight = CGFloat(rows.count) * rowHeight + axisHeight

        // Helper: domain value → track-pixel offset
        let scale = { (v: Double) -> CGFloat in
            CGFloat((v - xMin) / (xMax - xMin)) * trackWidth
        }

        ZStack(alignment: .topLeading) {

            // ── Background gridlines ──────────────────────────────────────
            ForEach(axisTicks, id: \.self) { tick in
                Rectangle()
                    .fill(WH.Color.separator.opacity(0.4))
                    .frame(width: 1, height: CGFloat(rows.count) * rowHeight)
                    .offset(x: labelColumnWidth + scale(tick), y: 0)
            }

            // ── Night rows ────────────────────────────────────────────────
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                NightRowView(
                    row: row,
                    index: idx,
                    labelColumnWidth: labelColumnWidth,
                    rowHeight: rowHeight,
                    barHeight: barHeight,
                    trackWidth: trackWidth,
                    xScale: scale
                )
            }

            // ── Axis ruler ────────────────────────────────────────────────
            let axisY = CGFloat(rows.count) * rowHeight

            // Top hairline spanning the track
            Rectangle()
                .fill(WH.Color.separator)
                .frame(width: trackWidth, height: 1)
                .offset(x: labelColumnWidth, y: axisY)

            ForEach(axisTicks, id: \.self) { tick in
                AxisTickView(
                    tick: tick,
                    label: axisLabel(hoursFromSixPm: tick),
                    axisY: axisY,
                    labelColumnWidth: labelColumnWidth,
                    totalWidth: totalWidth,
                    xScale: scale
                )
            }

            // Invisible spacer so the ZStack is fully tall
            Color.clear.frame(width: totalWidth, height: totalHeight)
        }
    }
}

// MARK: - NightRowView
// One Gantt row: day label + faint track + sleep bar + bed/wake time labels.

private struct NightRowView: View {
    let row:              SevenNightChart.NightRow
    let index:            Int
    let labelColumnWidth: CGFloat
    let rowHeight:        CGFloat
    let barHeight:        CGFloat
    let trackWidth:       CGFloat
    let xScale:           (Double) -> CGFloat

    var body: some View {
        let yTop   = CGFloat(index) * rowHeight
        let barY   = yTop + (rowHeight - barHeight) / 2
        let barX0  = labelColumnWidth + xScale(row.xStart)
        let barX1  = labelColumnWidth + xScale(row.xEnd)
        let barW   = max(barX1 - barX0, 4)
        // Vertical centre for the day label (single line, ~14 pt cap height)
        let labelY = yTop + (rowHeight - 14) / 2

        ZStack(alignment: .topLeading) {

            // Day label
            Text(row.label)
                .font(.system(size: 11, weight: .regular, design: .default))
                .foregroundStyle(WH.Color.textSecondary)
                .frame(width: labelColumnWidth, alignment: .leading)
                .offset(x: 0, y: labelY)

            // Full-width faint track (shows the full possible span)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(WH.Color.surface2)
                .frame(width: trackWidth, height: barHeight)
                .offset(x: labelColumnWidth, y: barY)

            // Sleep bar
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [WH.Color.sleepPurple, WH.Color.stageLight],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: barW, height: barHeight)
                .offset(x: barX0, y: barY)

            // Bedtime label — just above the bar's left end
            Text(row.bedtime)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(WH.Color.sleepPurple)
                .frame(width: 60, alignment: .leading)
                .offset(x: barX0, y: barY - 12)

            // Wake label — just above the bar's right end, right-aligned so it
            // doesn't overshoot the card edge when the bar ends near the right
            Text(row.waketime)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(WH.Color.stageLight)
                .frame(width: 60, alignment: .trailing)
                .offset(x: barX1 - 60, y: barY - 12)
        }
    }
}

// MARK: - AxisTickView
// One axis tick mark + label. Clamps near the right edge to avoid clipping.

private struct AxisTickView: View {
    let tick:             Double
    let label:            String
    let axisY:            CGFloat
    let labelColumnWidth: CGFloat
    let totalWidth:       CGFloat
    let xScale:           (Double) -> CGFloat

    var body: some View {
        let x          = labelColumnWidth + xScale(tick)
        let labelWidth: CGFloat = 28
        // Clamp so the rightmost label stays inside the card
        let clampedX   = min(x, totalWidth - labelWidth / 2)

        ZStack(alignment: .topLeading) {
            // Tick mark
            Rectangle()
                .fill(WH.Color.separator)
                .frame(width: 1, height: 5)
                .offset(x: x, y: axisY + 1)

            // Tick label
            Text(label)
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundStyle(WH.Color.textSecondary)
                .frame(width: labelWidth, alignment: .center)
                .offset(x: clampedX - labelWidth / 2, y: axisY + 7)
        }
    }
}
