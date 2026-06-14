import SwiftUI
import WhoopStore

// MARK: - DayDetailView
// Full-detail sheet for one selected day's DailyMetric.
// Shown when the user taps a day row in the Trends tab.

struct SelectedDay: Identifiable {
    let id: String  // YYYY-MM-DD (unique per day)
    let metric: DailyMetric
}

struct DayDetailView: View {
    let selected: SelectedDay

    private var metric: DailyMetric { selected.metric }

    // Human-readable date from YYYY-MM-DD
    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        guard let date = formatter.date(from: metric.day) else { return metric.day }
        let out = DateFormatter()
        out.dateStyle = .full
        out.timeStyle = .none
        return out.string(from: date)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                WH.Color.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: WH.Spacing.lg) {

                        // Recovery + Strain row
                        HStack(spacing: WH.Spacing.sm) {
                            recoveryCard.frame(maxWidth: .infinity)
                            strainCard.frame(maxWidth: .infinity)
                        }

                        // Sleep section
                        sleepSection

                        // Body signals section
                        bodySignalsSection

                        Spacer(minLength: WH.Spacing.xl)
                    }
                    .padding(WH.Spacing.md)
                }
                .background(WH.Color.background)
            }
            .navigationTitle(formattedDate)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Recovery card

    private var recoveryCard: some View {
        let pct = metric.recovery.map { $0 * 100 }
        let color = pct.map { WH.Color.recoveryColor(forPercent: $0) } ?? WH.Color.textSecondary
        return MetricCard(
            title: "Recovery",
            value: pct.map { String(format: "%.0f", $0) } ?? "—",
            unit: pct != nil ? "%" : nil,
            accentColor: color
        )
    }

    // MARK: - Strain card

    private var strainCard: some View {
        MetricCard(
            title: "Day Strain",
            value: metric.strain.map { String(format: "%.1f", $0) } ?? "—",
            unit: metric.strain != nil ? "/ 21" : nil,
            accentColor: metric.strain != nil ? WH.Color.strainBlue : WH.Color.textSecondary
        )
    }

    // MARK: - Sleep section

    private var sleepSection: some View {
        VStack(alignment: .leading, spacing: WH.Spacing.sm) {
            sectionHeader("Sleep")

            // Total + efficiency
            VStack(alignment: .leading, spacing: WH.Spacing.xs) {
                HStack {
                    Text("TOTAL SLEEP")
                        .font(WH.Font.cardTitle)
                        .foregroundStyle(WH.Color.textSecondary)
                        .tracking(1.2)
                    Spacer()
                    if let eff = metric.efficiency {
                        Text("\(Int((eff * 100).rounded()))% efficiency")
                            .font(WH.Font.caption)
                            .foregroundStyle(WH.Color.textSecondary)
                    }
                }
                Text(metric.totalSleepMin.map { formatMinutes($0) } ?? "—")
                    .font(WH.Font.metricLarge())
                    .foregroundStyle(metric.totalSleepMin != nil ? WH.Color.textPrimary : WH.Color.textSecondary)
                    .monospacedDigit()
            }
            .padding(WH.Spacing.md)
            .background(WH.Color.surface,
                        in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))

            // Stage breakdown
            HStack(spacing: WH.Spacing.sm) {
                stageCell(label: "DEEP",  color: WH.Color.stageDeep,  minutes: metric.deepMin)
                stageCell(label: "REM",   color: WH.Color.stageRem,   minutes: metric.remMin)
                stageCell(label: "LIGHT", color: WH.Color.stageLight, minutes: metric.lightMin)
            }

            // Disturbances
            if let dist = metric.disturbances {
                HStack(spacing: WH.Spacing.sm) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(WH.Color.textSecondary)
                    Text("\(dist) disturbance\(dist == 1 ? "" : "s")")
                        .font(WH.Font.caption)
                        .foregroundStyle(WH.Color.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, WH.Spacing.xs)
            }
        }
    }

    private func stageCell(label: String, color: Color, minutes: Double?) -> some View {
        VStack(alignment: .leading, spacing: WH.Spacing.xs) {
            HStack(spacing: WH.Spacing.xs) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label)
                    .font(WH.Font.cardTitle)
                    .foregroundStyle(WH.Color.textSecondary)
                    .tracking(1.0)
            }
            Text(minutes.map { formatMinutes($0) } ?? "—")
                .font(WH.Font.metricMedium(size: 20))
                .foregroundStyle(minutes != nil ? color : WH.Color.textSecondary)
                .monospacedDigit()
        }
        .padding(WH.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WH.Color.surface,
                    in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
    }

    // MARK: - Body signals section

    private var bodySignalsSection: some View {
        VStack(alignment: .leading, spacing: WH.Spacing.sm) {
            sectionHeader("Body Signals")

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                      spacing: WH.Spacing.sm) {
                MetricCard(
                    title: "HRV",
                    value: metric.avgHrv.map { String(format: "%.0f", $0) } ?? "—",
                    unit: metric.avgHrv != nil ? "ms" : nil,
                    accentColor: metric.avgHrv != nil ? WH.Color.recoveryGreen : WH.Color.textSecondary
                )
                MetricCard(
                    title: "Resting HR",
                    value: metric.restingHr.map { "\($0)" } ?? "—",
                    unit: metric.restingHr != nil ? "bpm" : nil,
                    accentColor: metric.restingHr != nil ? WH.Color.textPrimary : WH.Color.textSecondary
                )
                MetricCard(
                    title: "SpO2",
                    value: metric.spo2Pct.map { String(format: "%.1f", $0) } ?? "—",
                    unit: metric.spo2Pct != nil ? "%" : nil,
                    accentColor: metric.spo2Pct != nil ? WH.Color.textPrimary : WH.Color.textSecondary
                )
                MetricCard(
                    title: "Resp Rate",
                    value: metric.respRateBpm.map { String(format: "%.1f", $0) } ?? "—",
                    unit: metric.respRateBpm != nil ? "/min" : nil,
                    accentColor: metric.respRateBpm != nil ? WH.Color.strainBlue : WH.Color.textSecondary
                )
                MetricCard(
                    title: "Skin Temp Dev",
                    value: {
                        guard let t = metric.skinTempDevC else { return "—" }
                        return String(format: "%+.1f", t)
                    }(),
                    unit: metric.skinTempDevC != nil ? "°C" : nil,
                    accentColor: metric.skinTempDevC != nil ? WH.Color.recoveryYellow : WH.Color.textSecondary
                )
                if let ex = metric.exerciseCount {
                    MetricCard(
                        title: "Workouts",
                        value: "\(ex)",
                        accentColor: WH.Color.strainBlue
                    )
                }
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(WH.Font.cardTitle)
            .foregroundStyle(WH.Color.textSecondary)
            .tracking(1.5)
            .padding(.top, WH.Spacing.xs)
    }

    private func formatMinutes(_ totalMin: Double) -> String {
        guard totalMin > 0 else { return "—" }
        let hours = Int(totalMin) / 60
        let mins  = Int(totalMin) % 60
        if hours > 0 && mins > 0 { return "\(hours)h \(mins)m" }
        if hours > 0              { return "\(hours)h" }
        return "\(mins)m"
    }
}
