import SwiftUI
import WhoopStore

// MARK: - Stage segment model

struct StageSegment {
    let start: Double   // epoch seconds
    let end: Double     // epoch seconds
    let stage: String   // "wake" | "light" | "deep" | "rem"
}

// MARK: - Stage helpers

func parseStages(_ json: String?) -> [StageSegment]? {
    guard let json, !json.isEmpty,
          let data = json.data(using: .utf8),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        return nil
    }
    let segments = arr.compactMap { dict -> StageSegment? in
        guard let start = dict["start"] as? Double ?? (dict["start"] as? Int).map(Double.init),
              let end   = dict["end"]   as? Double ?? (dict["end"]   as? Int).map(Double.init),
              let stage = dict["stage"] as? String else { return nil }
        return StageSegment(start: start, end: end, stage: stage)
    }
    return segments.isEmpty ? nil : segments
}

func stageColor(_ stage: String) -> Color {
    switch stage {
    case "deep":  return WH.Color.stageDeep
    case "rem":   return WH.Color.stageRem
    case "light": return WH.Color.stageLight
    default:      return WH.Color.stageWake   // "wake"
    }
}

// MARK: - HypnogramView

struct HypnogramView: View {
    let session: CachedSleepSession

    private let laneOrder = ["wake", "rem", "light", "deep"]

    // Static formatter — allocated once, reused across renders.
    private static let axisFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        fmt.amSymbol = "AM"
        fmt.pmSymbol = "PM"
        return fmt
    }()

    var body: some View {
        let stages = parseStages(session.stagesJSON)
        let nightStart = Double(session.startTs)
        let nightEnd   = Double(session.endTs)
        let nightDuration = nightEnd - nightStart

        VStack(alignment: .leading, spacing: WH.Spacing.sm) {
            Text("SLEEP STAGES")
                .font(WH.Font.cardTitle)
                .foregroundStyle(WH.Color.textSecondary)
                .tracking(1.5)
                .padding(.top, WH.Spacing.xs)

            if let stages, nightDuration > 0 {
                VStack(spacing: 0) {
                    // Label sidebar + track columns
                    HStack(alignment: .top, spacing: WH.Spacing.sm) {
                        // Fixed-width label column
                        VStack(alignment: .trailing, spacing: 3) {
                            ForEach(laneOrder, id: \.self) { lane in
                                Text(laneLabel(lane))
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(stageColor(lane).opacity(0.85))
                                    .frame(height: 28)
                            }
                        }
                        .frame(width: 36)

                        // Track area
                        VStack(spacing: 3) {
                            ForEach(laneOrder, id: \.self) { lane in
                                laneTrack(
                                    lane: lane,
                                    stages: stages,
                                    nightStart: nightStart,
                                    nightDuration: nightDuration
                                )
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: WH.Radius.small, style: .continuous))
                    }

                    // Time axis (inset to align with track area)
                    HStack(spacing: WH.Spacing.sm) {
                        Spacer().frame(width: 36 + WH.Spacing.sm)
                        timeAxis(
                            nightStart: nightStart,
                            nightEnd: nightEnd,
                            nightDuration: nightDuration
                        )
                    }
                }
                .padding(WH.Spacing.md)
                .background(WH.Color.surface,
                            in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))

                // Legend
                hypnogramLegend

            } else {
                Text("No stage data for last night")
                    .font(WH.Font.caption)
                    .foregroundStyle(WH.Color.textSecondary)
                    .padding(WH.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(WH.Color.surface,
                                in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
            }
        }
    }

    // MARK: - Lane label helper

    private func laneLabel(_ lane: String) -> String {
        switch lane {
        case "wake":  return "AWAKE"
        case "rem":   return "REM"
        case "light": return "LIGHT"
        case "deep":  return "DEEP"
        default:      return lane.uppercased()
        }
    }

    // MARK: - Lane track (brick area only — no label)

    private func laneTrack(
        lane: String,
        stages: [StageSegment],
        nightStart: Double,
        nightDuration: Double
    ) -> some View {
        let laneHeight: CGFloat = 28

        return GeometryReader { geo in
            let totalWidth = geo.size.width

            ZStack(alignment: .leading) {
                // Track background
                Rectangle()
                    .fill(WH.Color.surface2)
                    .frame(height: laneHeight)

                // Stage bricks for this lane
                ForEach(Array(stages.filter { $0.stage == lane }.enumerated()), id: \.offset) { _, seg in
                    let xFrac  = (seg.start - nightStart) / nightDuration
                    let wFrac  = (seg.end   - seg.start)  / nightDuration
                    let xPos   = totalWidth * CGFloat(max(0, xFrac))
                    let bWidth = totalWidth * CGFloat(min(1 - max(0, xFrac), max(0, wFrac)))

                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(stageColor(lane))
                        .frame(width: max(bWidth, 2), height: laneHeight - 4)
                        .offset(x: xPos)
                }
            }
            .frame(height: laneHeight)
        }
        .frame(height: laneHeight)
    }

    // MARK: - Time axis

    private func timeAxis(nightStart: Double, nightEnd: Double, nightDuration: Double) -> some View {
        // Show bedtime, midpoint, and wake time
        let midpoint = nightStart + nightDuration / 2

        return GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                // Left: bedtime
                Text(formatAxisTime(nightStart))
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(WH.Color.textSecondary)
                    .frame(width: w, alignment: .leading)

                // Center: midpoint
                Text(formatAxisTime(midpoint))
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(WH.Color.textSecondary)
                    .frame(width: w, alignment: .center)

                // Right: wake time
                Text(formatAxisTime(nightEnd))
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(WH.Color.textSecondary)
                    .frame(width: w, alignment: .trailing)
            }
        }
        .frame(height: 20)
        .padding(.top, WH.Spacing.xs)
    }

    // MARK: - Legend

    private var hypnogramLegend: some View {
        HStack(spacing: WH.Spacing.md) {
            ForEach([("DEEP", WH.Color.stageDeep),
                     ("REM", WH.Color.stageRem),
                     ("LIGHT", WH.Color.stageLight),
                     ("AWAKE", WH.Color.stageWake)], id: \.0) { label, color in
                HStack(spacing: WH.Spacing.xs) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: 12, height: 8)
                    Text(label)
                        .font(.system(size: 10, weight: .medium, design: .default))
                        .foregroundStyle(WH.Color.textSecondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, WH.Spacing.xs)
    }

    // MARK: - Helpers

    private func formatAxisTime(_ epochSeconds: Double) -> String {
        HypnogramView.axisFormatter.string(from: Date(timeIntervalSince1970: epochSeconds))
    }
}
