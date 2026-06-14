import SwiftUI

// MARK: - WorkoutDetailView
// Push destination for a single detected workout bout.
// Header → stats strip → HR-zone breakdown.

struct WorkoutDetailView: View {
    let workout: Workout

    // MARK: - Body

    var body: some View {
        ZStack {
            WH.Color.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: WH.Spacing.lg) {
                    headerSection
                    statsStrip
                    zoneSection
                    contextSection
                    Spacer(minLength: WH.Spacing.xl)
                }
                .padding(WH.Spacing.md)
            }
            .background(WH.Color.background)
        }
        .navigationTitle("Workout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: WH.Spacing.xs) {
            Text(formattedDate)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(WH.Color.textPrimary)
            HStack(spacing: WH.Spacing.sm) {
                Text(formattedTime)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(WH.Color.textSecondary)
                Text("·")
                    .foregroundStyle(WH.Color.textSecondary)
                Text(formattedDuration)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(WH.Color.strainBlue)
                if let kind = workout.kind {
                    Text("·")
                        .foregroundStyle(WH.Color.textSecondary)
                    Text(kind)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(WH.Color.textSecondary)
                }
            }
        }
        .padding(WH.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WH.Color.surface,
                    in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
    }

    // MARK: - Stats strip

    private var statsStrip: some View {
        HStack(spacing: 0) {
            statCell(label: "STRAIN",
                     value: workout.strain.map { String(format: "%.1f", $0) } ?? "—",
                     unit: workout.strain != nil ? "/ 21" : nil,
                     color: WH.Color.strainBlue)
            divider
            statCell(label: "AVG HR",
                     value: String(format: "%.0f", workout.avgHr),
                     unit: "bpm",
                     color: WH.Color.textPrimary)
            divider
            statCell(label: "PEAK HR",
                     value: "\(workout.peakHr)",
                     unit: "bpm",
                     color: WH.Color.recoveryRed)
            divider
            statCell(label: "CALORIES",
                     value: workout.caloriesKcal.map { String(format: "%.0f", $0) } ?? "—",
                     unit: workout.caloriesKcal != nil ? "kcal" : nil,
                     color: workout.caloriesKcal != nil ? WH.Color.recoveryYellow : WH.Color.textSecondary)
        }
        .padding(.vertical, WH.Spacing.sm)
        .background(WH.Color.surface,
                    in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
    }

    private var divider: some View {
        Rectangle()
            .fill(WH.Color.separator)
            .frame(width: 1, height: 40)
    }

    private func statCell(label: String, value: String, unit: String?, color: Color) -> some View {
        VStack(spacing: WH.Spacing.xs) {
            Text(label)
                .font(WH.Font.cardTitle)
                .foregroundStyle(WH.Color.textSecondary)
                .tracking(1.0)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(value == "—" ? WH.Color.textSecondary : color)
                    .monospacedDigit()
                if let u = unit, value != "—" {
                    Text(u)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(WH.Color.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Zone breakdown

    private var zoneSection: some View {
        VStack(alignment: .leading, spacing: WH.Spacing.sm) {
            sectionHeader("HR Zones")

            VStack(spacing: WH.Spacing.xs) {
                ForEach(0..<6, id: \.self) { zone in
                    zoneRow(zone: zone)
                }
            }
            .padding(WH.Spacing.md)
            .background(WH.Color.surface,
                        in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
        }
    }

    private func zoneRow(zone: Int) -> some View {
        let pct = workout.zoneTimePct[zone] ?? 0.0
        let mins = Double(workout.durationS) * pct / 100.0 / 60.0
        let color = zoneColor(zone)
        let label = zoneLabel(zone)

        return VStack(spacing: 4) {
            HStack {
                // Zone dot + label
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text("Z\(zone)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .frame(width: 22, alignment: .leading)
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(WH.Color.textSecondary)
                Spacer()
                // Minutes + percentage
                Text(formatZoneMins(mins))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(WH.Color.textSecondary)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
                Text(String(format: "%.0f%%", pct))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(pct > 0 ? color : WH.Color.textSecondary)
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
            // Horizontal bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color.opacity(0.12))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color)
                        .frame(width: max(2, geo.size.width * CGFloat(pct / 100.0)), height: 6)
                }
            }
            .frame(height: 6)
        }
    }

    // MARK: - Context section (HRmax + HRR)

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: WH.Spacing.sm) {
            sectionHeader("Context")
            HStack(spacing: WH.Spacing.sm) {
                if let hrmax = workout.hrmax {
                    contextCell(
                        label: "HR MAX",
                        value: String(format: "%.0f", hrmax),
                        unit: "bpm",
                        note: workout.hrmaxSource.isEmpty ? nil : "(\(workout.hrmaxSource))"
                    )
                }
                if let hrr = workout.avgHrrPct {
                    contextCell(
                        label: "AVG %HRR",
                        value: String(format: "%.0f", hrr),
                        unit: "%",
                        note: nil
                    )
                }
            }
        }
    }

    private func contextCell(label: String, value: String, unit: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: WH.Spacing.xs) {
            Text(label)
                .font(WH.Font.cardTitle)
                .foregroundStyle(WH.Color.textSecondary)
                .tracking(1.0)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(WH.Color.textPrimary)
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(WH.Color.textSecondary)
            }
            if let note {
                Text(note)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(WH.Color.textSecondary)
            }
        }
        .padding(WH.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WH.Color.surface,
                    in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(WH.Font.cardTitle)
            .foregroundStyle(WH.Color.textSecondary)
            .tracking(1.5)
            .padding(.top, WH.Spacing.xs)
    }

    private var formattedDate: String {
        let d = Date(timeIntervalSince1970: TimeInterval(workout.startTs))
        let fmt = DateFormatter()
        fmt.dateStyle = .full
        fmt.timeStyle = .none
        return fmt.string(from: d)
    }

    private var formattedTime: String {
        let d = Date(timeIntervalSince1970: TimeInterval(workout.startTs))
        let fmt = DateFormatter()
        fmt.dateStyle = .none
        fmt.timeStyle = .short
        return fmt.string(from: d)
    }

    private var formattedDuration: String {
        let totalMin = workout.durationS / 60
        let h = totalMin / 60
        let m = totalMin % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0           { return "\(h)h" }
        return "\(m)m"
    }

    private func formatZoneMins(_ mins: Double) -> String {
        if mins < 1.0 { return "<1m" }
        return "\(Int(mins.rounded()))m"
    }

    private func zoneColor(_ zone: Int) -> Color {
        switch zone {
        case 0: return WH.Color.textSecondary
        case 1: return WH.Color.teal
        case 2: return WH.Color.recoveryGreen
        case 3: return WH.Color.recoveryYellow
        case 4: return Color(hex: "#FF8C00")
        case 5: return WH.Color.recoveryRed
        default: return WH.Color.textSecondary
        }
    }

    private func zoneLabel(_ zone: Int) -> String {
        switch zone {
        case 0: return "Rest"
        case 1: return "Very Light"
        case 2: return "Light"
        case 3: return "Moderate"
        case 4: return "Hard"
        case 5: return "Max"
        default: return "Zone \(zone)"
        }
    }
}
