import SwiftUI

// MARK: - TodayView
// The command-centre "Today" tab. Renders server-cached recovery/strain/sleep/HRV/RHR
// metrics pulled from MetricsRepository.
// Tapping any metric card → MetricDetailView (full history, range selector).

struct TodayView: View {
    @EnvironmentObject private var metrics: MetricsRepository
    @EnvironmentObject private var live: LiveViewModel

    var body: some View {
        NavigationStack {
            ZStack {
                WH.Color.background.ignoresSafeArea()

                Group {
                    if metrics.isRefreshing && metrics.today == nil && metrics.lastNight == nil && metrics.todayStats == nil {
                        loadingView
                    } else {
                        scrollContent
                    }
                }
            }
            // Hide the system nav bar on the root so the custom ScreenHeader sits tight
            // below the status bar/Dynamic Island. Pushed detail views manage their own bars.
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .task { await metrics.refresh() }
        .refreshable { await metrics.refresh() }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: WH.Spacing.md) {
            ProgressView()
                .tint(WH.Color.textSecondary)
            Text("Loading metrics…")
                .font(WH.Font.caption)
                .foregroundStyle(WH.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Main scroll content

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WH.Spacing.lg) {

                ScreenHeader("Today")

                // Hero recovery ring — server-only; shows pending ring when unconfigured
                heroSection

                // HRV + RHR: locally computed, 7-day sparklines
                hrvAndRhrRow

                // Stress: Baevsky index from last 2 h of RR data (local, no server)
                stressCard

                // Today's HR summary — local, shown whenever HR data exists for today
                todayHRCard

                // Strain: local Edwards TRIMP when server unavailable
                NavigationLink(destination: MetricDetailView(kind: .strain)) {
                    strainCard
                }
                .buttonStyle(.plain)

                // Sleep — server only; shows raw duration from local timestamps if available
                NavigationLink(destination: MetricDetailView(kind: .sleepDuration)) {
                    sleepCard
                }
                .buttonStyle(.plain)

                if let err = metrics.lastError {
                    errorBanner(err)
                }

                if metrics.today == nil && metrics.lastNight == nil
                    && metrics.todayStats == nil && !metrics.isRefreshing {
                    emptyState
                }

                strapNote
                syncFooter

                Spacer(minLength: WH.Spacing.xl)
            }
            .padding(WH.Spacing.md)
        }
        .background(WH.Color.background)
    }

    // MARK: - Hero section (recovery ring → recovery history)

    private var heroSection: some View {
        HStack {
            Spacer()
            NavigationLink(destination: MetricDetailView(kind: .recovery)) {
                if let recovery = metrics.today?.recovery {
                    RecoveryRing(percent: recovery * 100, size: 200, strokeWidth: 16)
                } else {
                    pendingRecoveryRing
                }
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.top, WH.Spacing.sm)
    }

    private var pendingRecoveryRing: some View {
        ZStack {
            Circle()
                .stroke(WH.Color.ringTrack, lineWidth: 16)
            Circle()
                .stroke(WH.Color.ringTrack.opacity(0.5), lineWidth: 24)
                .blur(radius: 6)

            VStack(spacing: WH.Spacing.xs) {
                Text("—")
                    .font(WH.Font.metricHero(size: 64))
                    .foregroundStyle(WH.Color.textSecondary)
                    .monospacedDigit()
                Text("RECOVERY")
                    .font(WH.Font.cardTitle)
                    .foregroundStyle(WH.Color.textSecondary)
                    .tracking(1.5)
                Text("Pending")
                    .font(WH.Font.caption)
                    .foregroundStyle(WH.Color.textSecondary.opacity(0.7))
            }
        }
        .frame(width: 200, height: 200)
    }

    // MARK: - Stress card (Baevsky index, local)

    @ViewBuilder
    private var stressCard: some View {
        if let stress = metrics.localStress {
            VStack(alignment: .leading, spacing: WH.Spacing.sm) {
                HStack {
                    Text("STRESS INDEX")
                        .font(WH.Font.cardTitle)
                        .foregroundStyle(WH.Color.textSecondary)
                        .tracking(1.2)
                    Spacer()
                    Text("Last 2h · Baevsky")
                        .font(WH.Font.caption)
                        .foregroundStyle(WH.Color.textSecondary)
                }
                HStack(alignment: .lastTextBaseline, spacing: WH.Spacing.sm) {
                    Text(String(format: "%.1f", stress))
                        .font(WH.Font.metricMedium())
                        .foregroundStyle(stressColor(stress))
                        .monospacedDigit()
                    Text("/ 10")
                        .font(WH.Font.unit)
                        .foregroundStyle(WH.Color.textSecondary)
                    Spacer()
                    Text(stressLabel(stress))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(stressColor(stress))
                        .padding(.horizontal, WH.Spacing.sm)
                        .padding(.vertical, WH.Spacing.xs)
                        .background(stressColor(stress).opacity(0.15),
                                    in: Capsule())
                }
            }
            .padding(WH.Spacing.md)
            .background(WH.Color.surface,
                        in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
        }
    }

    private func stressColor(_ score: Double) -> Color {
        switch score {
        case ..<3:  return WH.Color.recoveryGreen
        case 3..<5: return WH.Color.recoveryYellow
        default:    return WH.Color.recoveryRed
        }
    }

    private func stressLabel(_ score: Double) -> String {
        switch score {
        case ..<3:  return "LOW"
        case 3..<5: return "MODERATE"
        case 5..<7: return "HIGH"
        default:    return "VERY HIGH"
        }
    }

    // MARK: - Strain card

    private var strainCard: some View {
        // Prefer server-computed strain; fall back to local Edwards TRIMP
        let strain    = metrics.today?.strain ?? metrics.localStrain
        let isLocal   = metrics.today?.strain == nil && metrics.localStrain != nil
        let value     = strain.map { String(format: "%.1f", $0) } ?? "—"
        let hasStrain = strain != nil
        return MetricCard(title: isLocal ? "Day Strain (Est.)" : "Day Strain",
                          value: value,
                          unit: hasStrain ? "/ 21" : nil,
                          accentColor: hasStrain ? WH.Color.strainBlue : WH.Color.textSecondary)
    }

    // MARK: - Sleep card

    private var sleepCard: some View {
        let sleepMin: Double? = {
            if let m = metrics.today?.totalSleepMin, m > 0 { return m }
            if let s = metrics.lastNight {
                let d = Double(s.endTs - s.startTs) / 60
                return d > 0 ? d : nil
            }
            return nil
        }()

        let efficiency: Double? = {
            guard sleepMin != nil else { return nil }
            if let e = metrics.today?.efficiency, e > 0 { return e }
            if let e = metrics.lastNight?.efficiency, e > 0 { return e }
            return nil
        }()

        return VStack(alignment: .leading, spacing: WH.Spacing.sm) {
            HStack {
                Text("LAST NIGHT")
                    .font(WH.Font.cardTitle)
                    .foregroundStyle(WH.Color.textSecondary)
                    .tracking(1.2)
                Spacer()
            }

            if let min = sleepMin {
                HStack(alignment: .lastTextBaseline, spacing: WH.Spacing.sm) {
                    Text(formatSleepMinutes(min))
                        .font(WH.Font.metricLarge())
                        .foregroundStyle(WH.Color.textPrimary)
                        .monospacedDigit()

                    if let eff = efficiency {
                        Text("·  \(Int((eff * 100).rounded()))% efficiency")
                            .font(WH.Font.unit)
                            .foregroundStyle(WH.Color.textSecondary)
                    }

                    Spacer(minLength: 0)
                }
            } else {
                Text("No sleep data")
                    .font(WH.Font.metricMedium())
                    .foregroundStyle(WH.Color.textSecondary)
            }
        }
        .padding(WH.Spacing.md)
        .background(WH.Color.surface,
                    in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
    }

    // MARK: - HRV + RHR row

    private var hrvAndRhrRow: some View {
        HStack(spacing: WH.Spacing.sm) {
            NavigationLink(destination: MetricDetailView(kind: .hrv)) {
                hrvCard.frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            NavigationLink(destination: MetricDetailView(kind: .rhr)) {
                rhrCard.frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        }
    }

    private var hrvCard: some View {
        let hrv     = metrics.localHRV ?? metrics.today?.avgHrv ?? metrics.lastNight?.avgHrv
        let value   = hrv.map { String(format: "%.0f", $0) } ?? "—"
        let accent: Color = hrv != nil ? WH.Color.recoveryGreen : WH.Color.textSecondary
        let history = metrics.localHRVHistory
        return MetricCard(title: "HRV", value: value, unit: hrv != nil ? "ms" : nil, accentColor: accent) {
            if history.count >= 2 {
                Sparkline(data: history, color: WH.Color.recoveryGreen, showArea: false)
                    .frame(height: 32)
            }
        }
    }

    private var rhrCard: some View {
        // Prefer locally-computed overnight min 5-min avg; fall back to server cache
        let rhrValue = metrics.localRHR.map { Int($0.rounded()) }
                       ?? metrics.today?.restingHr
                       ?? metrics.lastNight?.restingHr
        let value    = rhrValue.map { "\($0)" } ?? "—"
        let accent: Color = rhrValue != nil ? WH.Color.textPrimary : WH.Color.textSecondary
        let history  = metrics.localRHRHistory
        return MetricCard(title: "Resting HR", value: value, unit: rhrValue != nil ? "bpm" : nil, accentColor: accent) {
            if history.count >= 2 {
                Sparkline(data: history, color: WH.Color.strainBlue, showArea: false)
                    .frame(height: 32)
            }
        }
    }

    // MARK: - Today's HR card

    @ViewBuilder
    private var todayHRCard: some View {
        if let stats = metrics.todayStats {
            VStack(alignment: .leading, spacing: WH.Spacing.sm) {

                // Header row
                HStack {
                    Text("TODAY'S HEART RATE")
                        .font(WH.Font.cardTitle)
                        .foregroundStyle(WH.Color.textSecondary)
                        .tracking(1.2)
                    Spacer()
                    Text(formatDataCoverage(stats.dataMinutes))
                        .font(WH.Font.caption)
                        .foregroundStyle(WH.Color.textSecondary)
                }

                // Three-column stat row
                HStack(spacing: 0) {
                    hrStatColumn(label: "AVG",
                                 value: "\(stats.avgBPM)",
                                 unit: "bpm",
                                 color: WH.Color.textPrimary)

                    columnDivider

                    hrStatColumn(label: "PEAK",
                                 value: "\(stats.peakBPM)",
                                 unit: "bpm",
                                 color: peakHRColor(stats.peakBPM))

                    columnDivider

                    hrStatColumn(label: "ELEVATED",
                                 value: "\(stats.elevatedMinutes)",
                                 unit: "min >100",
                                 color: stats.elevatedMinutes > 0
                                    ? WH.Color.strainBlue
                                    : WH.Color.textSecondary)
                }
            }
            .padding(WH.Spacing.md)
            .background(WH.Color.surface,
                        in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
        }
    }

    private func hrStatColumn(label: String, value: String, unit: String, color: Color) -> some View {
        VStack(spacing: WH.Spacing.xs) {
            Text(label)
                .font(WH.Font.cardTitle)
                .foregroundStyle(WH.Color.textSecondary)
                .tracking(1.2)
            Text(value)
                .font(WH.Font.metricMedium())
                .foregroundStyle(color)
                .monospacedDigit()
            Text(unit)
                .font(WH.Font.caption)
                .foregroundStyle(WH.Color.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var columnDivider: some View {
        Rectangle()
            .fill(WH.Color.separator)
            .frame(width: 1)
            .padding(.vertical, WH.Spacing.sm)
    }

    private func peakHRColor(_ bpm: Int) -> Color {
        switch bpm {
        case ..<100: return WH.Color.textPrimary
        case 100..<140: return WH.Color.recoveryYellow
        default: return WH.Color.recoveryRed
        }
    }

    private func formatDataCoverage(_ minutes: Int) -> String {
        guard minutes > 0 else { return "no data" }
        if minutes >= 60 {
            let h = minutes / 60
            let m = minutes % 60
            return m > 0 ? "\(h)h \(m)m data" : "\(h)h data"
        }
        return "\(minutes)m data"
    }

    // MARK: - Empty state

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: WH.Spacing.sm) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(WH.Color.textSecondary)
                Text("No metrics yet")
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

    // MARK: - Live strap status row (HR + battery when connected; caption when not)

    /// Compact pill showing a single live reading (HR or battery).
    private func liveChip(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: WH.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(WH.Color.textPrimary)
                .monospacedDigit()
        }
        .padding(.horizontal, WH.Spacing.sm)
        .padding(.vertical, WH.Spacing.xs)
        .background(WH.Color.surface2,
                    in: Capsule())
    }

    /// Shows live HR + battery pills when connected; otherwise shows the connect caption.
    private var strapNote: some View {
        Group {
            if live.state.connected, let hr = live.state.heartRate {
                HStack(spacing: WH.Spacing.sm) {
                    liveChip(icon: "heart.fill",
                             label: "\(hr) BPM LIVE",
                             color: WH.Color.recoveryRed)
                    if let bat = live.state.batteryPct {
                        let pct = Int(bat.rounded())
                        let batColor: Color = pct > 30 ? WH.Color.recoveryGreen
                                                       : WH.Color.recoveryYellow
                        let batIcon = pct > 70 ? "battery.100" :
                                      pct > 30 ? "battery.50"  : "battery.25"
                        liveChip(icon: batIcon,
                                 label: "\(pct)%",
                                 color: batColor)
                    }
                    Spacer()
                }
            } else {
                HStack(spacing: WH.Spacing.xs) {
                    Image(systemName: "wave.3.right")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(WH.Color.textSecondary.opacity(0.5))
                    Text("Live HR & battery appear when your strap is connected (Device tab)")
                        .font(WH.Font.caption)
                        .foregroundStyle(WH.Color.textSecondary.opacity(0.5))
                        .lineLimit(2)
                }
            }
        }
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

    // MARK: - Formatting helpers

    private func formatSleepMinutes(_ totalMin: Double) -> String {
        guard totalMin > 0 else { return "—" }
        let hours = Int(totalMin) / 60
        let mins  = Int(totalMin) % 60
        if hours > 0 && mins > 0 { return "\(hours)h \(mins)m" }
        if hours > 0              { return "\(hours)h" }
        return "\(mins)m"
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

#Preview("Today — empty (cold start)") {
    TodayView()
        .environmentObject(MetricsRepository(deviceId: "preview"))
}

#Preview("Today — design gallery reference") {
    DesignGallery()
}
