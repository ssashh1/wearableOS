import SwiftUI
import Charts
import WhoopStore

// MARK: - SleepView
// M2 Sleep tab — answers two questions at a glance:
//   (1) "How well did I sleep last night?"  → headline efficiency + duration + hypnogram
//   (2) "When have I been sleeping/waking over the past 7 nights?" → 7-night bar chart

struct SleepView: View {
    @EnvironmentObject private var metrics: MetricsRepository
    /// LiveViewModel injected so we can pass it to AlarmView's sheet (iOS 16 env-object safety).
    @EnvironmentObject private var live: LiveViewModel

    // Local async state
    @State private var detail: (session: CachedSleepSession, daily: DailyMetric?)?
    @State private var weekNights: [CachedSleepSession] = []
    @State private var showingAlarm = false

    // Alarm state read from UserDefaults for the summary card.
    @AppStorage(AlarmKeys.enabled)    private var alarmEnabled   = false
    @AppStorage(AlarmKeys.wakeByHour) private var wakeByHour     = 7
    @AppStorage(AlarmKeys.wakeByMinute) private var wakeByMinute = 0

    // Static formatter — allocated once, reused across renders.
    private static let timeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        fmt.amSymbol = "AM"
        fmt.pmSymbol = "PM"
        return fmt
    }()

    var body: some View {
        NavigationStack {
            ZStack {
                WH.Color.background.ignoresSafeArea()

                Group {
                    if metrics.isRefreshing && detail == nil && weekNights.isEmpty {
                        loadingView
                    } else {
                        scrollContent
                    }
                }
            }
            // Hide the system nav bar on the root; pushed detail views manage their own bars.
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingAlarm) {
                // iOS 16: sheets don't reliably inherit environment objects — pass explicitly.
                AlarmView()
                    .environmentObject(live)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await loadData()
        }
        .refreshable {
            await loadData()
        }
    }

    // MARK: - Data loading

    private func loadData() async {
        await metrics.refresh()
        detail = await metrics.sleepDetail()
        weekNights = await metrics.sevenNightSleepWake(nights: 7)
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: WH.Spacing.md) {
            ProgressView()
                .tint(WH.Color.textSecondary)
            Text("Loading sleep data…")
                .font(WH.Font.caption)
                .foregroundStyle(WH.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Main scroll content

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WH.Spacing.lg) {

                // Custom tight header (replaces the hidden system large-title nav bar)
                ScreenHeader("Sleep")

                // 1. Headline — server sleep data OR local strap estimate as fallback
                if detail != nil {
                    headlineSection
                } else if let estimate = metrics.localSleepEstimate {
                    localSleepSection(estimate)
                }

                // 2. Hypnogram (server only)
                if let session = detail?.session {
                    HypnogramView(session: session)
                }

                // 3. Stage breakdown (server only)
                if detail != nil {
                    stageBreakdownSection
                }

                // 4. In-sleep signals (server only)
                if detail != nil {
                    inSleepSignalsSection
                }

                // 5. 7-night sleep/wake chart
                sevenNightSection

                // 6. Smart alarm entry card
                alarmCard

                // Error banner (non-blocking)
                if let err = metrics.lastError {
                    errorBanner(err)
                }

                // Empty state only when neither server data nor local estimate is available
                if detail == nil && metrics.localSleepEstimate == nil && !metrics.isRefreshing {
                    emptyState
                }

                // Freshness footer
                syncFooter

                Spacer(minLength: WH.Spacing.xl)
            }
            .padding(WH.Spacing.md)
        }
        .background(WH.Color.background)
    }

    // MARK: - 1a. Local sleep estimate (shown when no server data)
    // Derived from overnight strap HR data only — not sleep-staged.

    private func localSleepSection(_ estimate: LocalSleepEstimate) -> some View {
        VStack(alignment: .leading, spacing: WH.Spacing.sm) {

            // Header with time span
            VStack(alignment: .leading, spacing: WH.Spacing.xs) {
                Text("LAST NIGHT · LOCAL DATA")
                    .font(WH.Font.cardTitle)
                    .foregroundStyle(WH.Color.textSecondary)
                    .tracking(1.2)

                HStack(alignment: .lastTextBaseline, spacing: WH.Spacing.xs) {
                    Text(formatMinutes(estimate.durationMinutes))
                        .font(WH.Font.metricLarge(size: 36))
                        .foregroundStyle(WH.Color.textPrimary)
                        .monospacedDigit()
                    Text("in strap")
                        .font(WH.Font.unit)
                        .foregroundStyle(WH.Color.textSecondary)
                }

                Text(formatTime(estimate.wristOnTs) + " → " + formatTime(estimate.wristOffTs))
                    .font(WH.Font.caption)
                    .foregroundStyle(WH.Color.textSecondary)
            }
            .padding(WH.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WH.Color.surface,
                        in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))

            // RHR + HRV tiles
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                      spacing: WH.Spacing.sm) {
                MetricCard(
                    title: "Resting HR",
                    value: estimate.rhr.map { "\(Int($0.rounded()))" } ?? "—",
                    unit: estimate.rhr != nil ? "bpm" : nil,
                    accentColor: estimate.rhr != nil ? WH.Color.textPrimary : WH.Color.textSecondary
                )
                MetricCard(
                    title: "HRV",
                    value: estimate.hrv.map { String(format: "%.0f", $0) } ?? "—",
                    unit: estimate.hrv != nil ? "ms" : nil,
                    accentColor: estimate.hrv != nil ? WH.Color.recoveryGreen : WH.Color.textSecondary
                )
            }

            // Disclaimer
            HStack(spacing: WH.Spacing.xs) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(WH.Color.textSecondary.opacity(0.6))
                Text("Strap-presence duration, not sleep duration. Sleep staging requires a server.")
                    .font(WH.Font.caption)
                    .foregroundStyle(WH.Color.textSecondary.opacity(0.6))
                    .lineLimit(2)
            }
            .padding(.horizontal, WH.Spacing.xs)
        }
    }

    // MARK: - 1. Headline section

    private var headlineSection: some View {
        // TODO: server-side sleep performance/need/debt — use efficiency as the headline for now
        let session = detail?.session
        let daily = detail?.daily

        let efficiencyPct: Int? = {
            if let e = session?.efficiency, e > 0 { return Int((e * 100).rounded()) }
            if let e = daily?.efficiency, e > 0 { return Int((e * 100).rounded()) }
            return nil
        }()

        let totalMinutes: Double? = {
            if let m = daily?.totalSleepMin, m > 0 { return m }
            if let s = session {
                let d = Double(s.endTs - s.startTs) / 60
                return d > 0 ? d : nil
            }
            return nil
        }()

        return VStack(spacing: WH.Spacing.sm) {
            HStack(alignment: .bottom, spacing: WH.Spacing.md) {
                // Big efficiency percentage
                VStack(alignment: .leading, spacing: WH.Spacing.xs) {
                    Text("SLEEP EFFICIENCY")
                        .font(WH.Font.cardTitle)
                        .foregroundStyle(WH.Color.textSecondary)
                        .tracking(1.2)

                    HStack(alignment: .lastTextBaseline, spacing: WH.Spacing.xs) {
                        Text(efficiencyPct.map { "\($0)" } ?? "—")
                            .font(WH.Font.metricHero(size: 64))
                            .foregroundStyle(efficiencyPct != nil ? WH.Color.textPrimary : WH.Color.textSecondary)
                            .monospacedDigit()
                        if efficiencyPct != nil {
                            Text("%")
                                .font(WH.Font.unit)
                                .foregroundStyle(WH.Color.textSecondary)
                        }
                    }
                }

                Spacer()

                // Total time asleep (right-aligned)
                VStack(alignment: .trailing, spacing: WH.Spacing.xs) {
                    Text("TIME ASLEEP")
                        .font(WH.Font.cardTitle)
                        .foregroundStyle(WH.Color.textSecondary)
                        .tracking(1.2)

                    Text(totalMinutes.map { formatMinutes($0) } ?? "—")
                        .font(WH.Font.metricLarge(size: 32))
                        .foregroundStyle(totalMinutes != nil ? WH.Color.textPrimary : WH.Color.textSecondary)
                        .monospacedDigit()
                }
            }
            .padding(WH.Spacing.md)
            .background(WH.Color.surface,
                        in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))

            // Bed/wake time subtitle
            if let session = session {
                HStack {
                    Text(formatTime(session.startTs) + " → " + formatTime(session.endTs))
                        .font(WH.Font.caption)
                        .foregroundStyle(WH.Color.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, WH.Spacing.xs)
            }
        }
    }

    // MARK: - 3. Stage breakdown + sleep stats

    private var stageBreakdownSection: some View {
        let session = detail?.session
        let daily = detail?.daily

        // Sleep latency: minutes from startTs to first non-wake stage
        let latencyMin: String = {
            guard let session = session,
                  let stages = parseStages(session.stagesJSON) else { return "—" }
            guard let firstNonWake = stages.first(where: { $0.stage != "wake" }) else { return "—" }
            let latency = (firstNonWake.start - Double(session.startTs)) / 60
            if latency < 0 { return "—" }
            return "\(Int(latency.rounded()))m"
        }()

        let timeInBed: String? = session.map {
            formatMinutes(Double($0.endTs - $0.startTs) / 60)
        }

        return VStack(alignment: .leading, spacing: WH.Spacing.sm) {
            sectionHeader("Stage Breakdown")

            // Deep / REM / Light row
            HStack(spacing: WH.Spacing.sm) {
                stageMinCard(
                    label: "DEEP",
                    color: WH.Color.stageDeep,
                    minutes: daily?.deepMin
                )
                stageMinCard(
                    label: "REM",
                    color: WH.Color.stageRem,
                    minutes: daily?.remMin
                )
                stageMinCard(
                    label: "LIGHT",
                    color: WH.Color.stageLight,
                    minutes: daily?.lightMin
                )
            }

            // Stats row
            HStack(spacing: WH.Spacing.sm) {
                smallStatTile(label: "TIME IN BED", value: timeInBed ?? "—")
                smallStatTile(label: "DISTURBANCES", value: daily?.disturbances.map { "\($0)" } ?? "—")
                smallStatTile(label: "LATENCY", value: latencyMin)
            }
        }
    }

    private func stageMinCard(label: String, color: Color, minutes: Double?) -> some View {
        VStack(alignment: .leading, spacing: WH.Spacing.xs) {
            HStack(spacing: WH.Spacing.xs) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(WH.Font.cardTitle)
                    .foregroundStyle(WH.Color.textSecondary)
                    .tracking(1.0)
            }
            Text(minutes.map { formatMinutes($0) } ?? "—")
                .font(WH.Font.metricMedium(size: 22))
                .foregroundStyle(minutes != nil ? color : WH.Color.textSecondary)
                .monospacedDigit()
        }
        .padding(WH.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WH.Color.surface,
                    in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
    }

    private func smallStatTile(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: WH.Spacing.xs) {
            Text(label)
                .font(WH.Font.cardTitle)
                .foregroundStyle(WH.Color.textSecondary)
                .tracking(1.0)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(value)
                .font(WH.Font.metricMedium(size: 20))
                .foregroundStyle(WH.Color.textPrimary)
                .monospacedDigit()
        }
        .padding(WH.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WH.Color.surface,
                    in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
    }

    // MARK: - 4. In-sleep signals
    // Note: SpO2, skin temp deviation, and respiratory rate are WHOOP-LIKE APPROXIMATIONS
    // derived from the optical + accelerometer sensors. They have not been clinically calibrated.

    private var inSleepSignalsSection: some View {
        let session = detail?.session
        let daily = detail?.daily

        return VStack(alignment: .leading, spacing: WH.Spacing.sm) {
            sectionHeader("In-Sleep Signals")

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                      spacing: WH.Spacing.sm) {

                MetricCard(
                    title: "Resting HR",
                    value: session?.restingHr.map { "\($0)" } ?? "—",
                    unit: session?.restingHr != nil ? "bpm" : nil,
                    accentColor: session?.restingHr != nil ? WH.Color.textPrimary : WH.Color.textSecondary
                )

                MetricCard(
                    title: "HRV",
                    value: session?.avgHrv.map { String(format: "%.0f", $0) } ?? "—",
                    unit: session?.avgHrv != nil ? "ms" : nil,
                    accentColor: session?.avgHrv != nil ? WH.Color.recoveryGreen : WH.Color.textSecondary
                )

                MetricCard(
                    title: "Resp Rate",
                    value: daily?.respRateBpm.map { String(format: "%.1f", $0) } ?? "—",
                    unit: daily?.respRateBpm != nil ? "/min" : nil,
                    accentColor: daily?.respRateBpm != nil ? WH.Color.strainBlue : WH.Color.textSecondary
                )

                MetricCard(
                    title: "SpO2",
                    value: daily?.spo2Pct.map { String(format: "%.1f", $0) } ?? "—",
                    unit: daily?.spo2Pct != nil ? "%" : nil,
                    accentColor: daily?.spo2Pct != nil ? WH.Color.textPrimary : WH.Color.textSecondary
                )

                MetricCard(
                    title: "Skin Temp Dev",
                    value: {
                        guard let t = daily?.skinTempDevC else { return "—" }
                        return String(format: "%+.1f", t)
                    }(),
                    unit: daily?.skinTempDevC != nil ? "°C" : nil,
                    accentColor: daily?.skinTempDevC != nil ? WH.Color.recoveryYellow : WH.Color.textSecondary
                )
            }
        }
    }

    // MARK: - 5. 7-night sleep/wake chart

    private var sevenNightSection: some View {
        VStack(alignment: .leading, spacing: WH.Spacing.sm) {
            sectionHeader("7-Night Sleep / Wake")

            if weekNights.count < 1 {
                noDataCard(icon: "chart.bar.xaxis", message: "Need more nights to show the trend")
            } else {
                SevenNightChart(sessions: weekNights)

                if weekNights.count < 2 {
                    Text("Collect more nights for a full trend view")
                        .font(WH.Font.caption)
                        .foregroundStyle(WH.Color.textSecondary)
                        .padding(.top, WH.Spacing.xs)
                }
            }
        }
    }

    // MARK: - 6. Smart alarm card

    /// Tappable alarm entry card. Shows the armed wake time (or "No alarm set") and
    /// opens AlarmView on tap. Lives on the Sleep tab — WHOOP-style: you set your wake
    /// alarm where you see your sleep data.
    private var alarmCard: some View {
        Button {
            showingAlarm = true
        } label: {
            HStack(spacing: WH.Spacing.sm) {
                Image(systemName: alarmEnabled ? "alarm.fill" : "alarm")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(alarmEnabled ? WH.Color.sleepPurple : WH.Color.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(
                        (alarmEnabled ? WH.Color.sleepPurple : WH.Color.textSecondary).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: WH.Radius.small, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("SMART ALARM")
                        .font(WH.Font.cardTitle)
                        .foregroundStyle(WH.Color.textSecondary)
                        .tracking(1.2)
                    if alarmEnabled {
                        Text("Wake alarm · \(alarmTimeString)")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(WH.Color.textPrimary)
                    } else {
                        Text("No alarm set")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(WH.Color.textSecondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WH.Color.textSecondary.opacity(0.5))
            }
            .padding(WH.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WH.Color.surface,
                        in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Formats the stored hour + minute into "6:45 AM" style.
    private var alarmTimeString: String {
        var comps = DateComponents()
        comps.hour   = wakeByHour
        comps.minute = wakeByMinute
        guard let date = Calendar.current.date(from: comps) else {
            return "\(wakeByHour):\(String(format: "%02d", wakeByMinute))"
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        fmt.amSymbol = "AM"
        fmt.pmSymbol = "PM"
        return fmt.string(from: date)
    }

    // MARK: - Helpers / sub-components

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(WH.Font.cardTitle)
            .foregroundStyle(WH.Color.textSecondary)
            .tracking(1.5)
            .padding(.top, WH.Spacing.xs)
    }

    private func noDataCard(icon: String, message: String) -> some View {
        HStack(spacing: WH.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(WH.Color.textSecondary)
            Text(message)
                .font(WH.Font.caption)
                .foregroundStyle(WH.Color.textSecondary)
            Spacer()
        }
        .padding(WH.Spacing.md)
        .background(WH.Color.surface,
                    in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
    }

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: WH.Spacing.sm) {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(WH.Color.textSecondary)
                Text("No sleep recorded yet")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(WH.Color.textPrimary)
                Text("Pull down to refresh")
                    .font(WH.Font.caption)
                    .foregroundStyle(WH.Color.textSecondary)
            }
            .padding(.vertical, WH.Spacing.xxl)
            Spacer()
        }
    }

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

    // MARK: - Formatting helpers

    private func formatMinutes(_ totalMin: Double) -> String {
        guard totalMin > 0 else { return "—" }
        let hours = Int(totalMin) / 60
        let mins  = Int(totalMin) % 60
        if hours > 0 && mins > 0 { return "\(hours)h \(mins)m" }
        if hours > 0              { return "\(hours)h" }
        return "\(mins)m"
    }

    private func formatTime(_ epochSeconds: Int) -> String {
        SleepView.timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(epochSeconds)))
    }

    private func relativeTime(from date: Date) -> String {
        let elapsed = Int(-date.timeIntervalSinceNow)
        switch elapsed {
        case ..<5:   return "just now"
        case ..<60:  return "\(elapsed)s ago"
        case ..<3600:
            let m = elapsed / 60
            return "\(m)m ago"
        default:
            let h = elapsed / 3600
            return "\(h)h ago"
        }
    }
}

// MARK: - Preview

#Preview("Sleep — empty (cold start)") {
    SleepView()
        .environmentObject(MetricsRepository(deviceId: "preview"))
        .environmentObject(LiveViewModel())
}
