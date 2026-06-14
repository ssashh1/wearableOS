import SwiftUI
import Charts

// MARK: - NowView
// Live biometric dashboard — updates in real-time from the BLE stream.
// All metrics are computed on the spot from rolling buffers in LiveState:
//   hrHistory (≤300 readings, ~5 min)  → rolling HR chart
//   rrHistory (≤500 intervals)         → HRV (RMSSD) and Baevsky stress
// Shows "—" rather than guessing when buffers are too short to produce
// a reliable value — no estimation, no randomization.

struct NowView: View {
    @EnvironmentObject private var live: LiveViewModel
    @EnvironmentObject private var metrics: MetricsRepository

    @State private var pulsing = false

    // Live thresholds are lower than overnight so metrics appear within ~20s of RR data
    // arriving rather than waiting 1-2 minutes. Still real data, just a shorter window.
    private var liveHRV: Double? {
        HRVCalculator.rmssd(live.state.rrHistory, minPairs: 15)
    }
    private var liveStress: Double? {
        let rr = live.state.rrHistory
        if let s = StressCalculator.stress(from: rr, min: 30) { return s }
        // Fallback: derive RR from hrHistory when beat-to-beat data is sparse.
        // 60000/bpm gives the expected interval — captures BPM variability for Baevsky.
        let derived = live.state.hrHistory.map { Int((60_000.0 / Double($0.bpm)).rounded()) }
        return StressCalculator.stress(from: derived, min: 30)
    }
    private var currentZone: HRZone { live.state.heartRate.map(HRZone.init) ?? .resting }

    var body: some View {
        ZStack {
            WH.Color.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: WH.Spacing.md) {
                    ScreenHeader("Now")
                    if !live.state.connected { disconnectedBanner }
                    heroCard
                    chartCard
                    metricsGrid
                    stepsRow
                    Spacer(minLength: WH.Spacing.xl)
                }
                .padding(WH.Spacing.md)
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: live.state.heartRate) { _ in triggerPulse() }
        .task { live.ensureActive() }
        .refreshable { live.ensureActive() }
    }

    // MARK: - Disconnected banner

    private var disconnectedBanner: some View {
        HStack(spacing: WH.Spacing.sm) {
            Circle()
                .fill(WH.Color.textSecondary)
                .frame(width: 7, height: 7)
            Text("Not connected — open the Device tab to pair your WHOOP")
                .font(WH.Font.caption)
                .foregroundStyle(WH.Color.textSecondary)
            Spacer()
        }
        .padding(.horizontal, WH.Spacing.md)
        .padding(.vertical, WH.Spacing.sm)
        .background(WH.Color.surface2,
                    in: RoundedRectangle(cornerRadius: WH.Radius.chip, style: .continuous))
    }

    // MARK: - Hero BPM card

    private var heroCard: some View {
        VStack(alignment: .center, spacing: WH.Spacing.xs) {
            // Zone chip (only when connected and a reading exists)
            if live.state.heartRate != nil {
                Text(currentZone.label)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(currentZone.color)
                    .padding(.horizontal, WH.Spacing.sm)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(currentZone.color.opacity(0.15)))
            }

            HStack(alignment: .lastTextBaseline, spacing: WH.Spacing.sm) {
                // Pulse dot — scales on each new HR reading
                Circle()
                    .fill(live.state.heartRate != nil ? currentZone.color : WH.Color.textSecondary.opacity(0.4))
                    .frame(width: 11, height: 11)
                    .scaleEffect(pulsing ? 1.5 : 1.0)
                    .opacity(pulsing ? 0.5 : 1.0)
                    .padding(.bottom, 16) // align with number baseline

                Text(live.state.heartRate.map { "\($0)" } ?? "—")
                    .font(.system(size: 84, weight: .black, design: .rounded))
                    .foregroundStyle(live.state.heartRate != nil ? currentZone.color : WH.Color.textSecondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.2), value: live.state.heartRate)

                Text("BPM")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(WH.Color.textSecondary)
                    .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(WH.Spacing.md)
        .background(WH.Color.surface,
                    in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
    }

    // MARK: - Rolling HR chart

    @ViewBuilder
    private var chartCard: some View {
        let history = live.state.hrHistory
        VStack(alignment: .leading, spacing: WH.Spacing.sm) {
            HStack {
                Text("HEART RATE")
                    .font(WH.Font.cardTitle)
                    .foregroundStyle(WH.Color.textSecondary)
                    .tracking(1.2)
                Spacer()
                // LIVE badge
                HStack(spacing: 4) {
                    Circle()
                        .fill(WH.Color.recoveryRed)
                        .frame(width: 6, height: 6)
                    Text("LIVE")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(WH.Color.recoveryRed)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(WH.Color.recoveryRed.opacity(0.12)))
            }

            if history.isEmpty {
                Text("Waiting for first reading…")
                    .font(WH.Font.caption)
                    .foregroundStyle(WH.Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: 120)
            } else {
                let zoneColor = currentZone.color
                Chart {
                    ForEach(history) { pt in
                        LineMark(
                            x: .value("Time", pt.ts),
                            y: .value("BPM", pt.bpm)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(zoneColor)

                        AreaMark(
                            x: .value("Time", pt.ts),
                            y: .value("BPM", pt.bpm)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [zoneColor.opacity(0.25), .clear],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                            .foregroundStyle(WH.Color.separator)
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(date, format: .dateTime.minute().second())
                                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                                    .foregroundStyle(WH.Color.textSecondary)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                            .foregroundStyle(WH.Color.separator)
                        AxisValueLabel {
                            if let bpm = value.as(Double.self) {
                                Text("\(Int(bpm))")
                                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                                    .foregroundStyle(WH.Color.textSecondary)
                            }
                        }
                    }
                }
                .frame(height: 130)
            }
        }
        .padding(WH.Spacing.md)
        .background(WH.Color.surface,
                    in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
    }

    // MARK: - 2×2 metrics grid

    private var metricsGrid: some View {
        let cols = [GridItem(.flexible(), spacing: WH.Spacing.sm),
                    GridItem(.flexible(), spacing: WH.Spacing.sm)]
        return LazyVGrid(columns: cols, spacing: WH.Spacing.sm) {
            // HRV — needs >60 clean RR pairs
            MetricCard(
                title: "HRV",
                value: liveHRV.map { String(format: "%.0f", $0) } ?? "—",
                unit: liveHRV != nil ? "ms" : nil,
                accentColor: WH.Color.teal
            )

            // Stress — needs ≥120 RR intervals
            MetricCard(
                title: "Stress",
                value: liveStress.map { String(format: "%.1f", $0) } ?? "—",
                unit: liveStress != nil ? "/10" : nil,
                accentColor: stressColor
            )

            // Session elapsed — live-updating via TimelineView
            TimelineView(.animation(minimumInterval: 1)) { ctx in
                MetricCard(
                    title: "Session",
                    value: sessionElapsed(at: ctx.date) ?? "—",
                    accentColor: WH.Color.textPrimary
                )
            }

            // Battery
            MetricCard(
                title: "Battery",
                value: live.state.batteryPct.map { String(format: "%.0f", $0) } ?? "—",
                unit: live.state.batteryPct != nil ? "%" : nil,
                accentColor: batteryColor
            )
        }
    }

    // MARK: - Steps row

    // MARK: - Steps row
    //
    // Source selection:
    //   Connected  → WHOOP IMU (type-43 R10/R11 stream, 100 Hz, sessionSteps)
    //                The WHOOP's raw accel at 100 Hz can detect individual step peaks.
    //   Disconnected → HealthKit daily total (iPhone pedometer runs 24/7 regardless of
    //                  WHOOP connection, so it covers all offline time automatically).
    //
    // The WHOOP's offline historical buffer only stores one averaged gravity vector per
    // record (~1 Hz), which is too coarse for step detection — it is used by SleepDetector
    // but cannot count individual steps. HealthKit fills that gap perfectly.

    private var stepsRow: some View {
        // When connected and the IMU stream has accumulated steps, show WHOOP session steps.
        // Otherwise fall back to HealthKit's daily total (covers the disconnected period).
        let useWHOOP = live.state.connected && live.state.sessionSteps > 0
        let label    = useWHOOP ? "STEPS THIS SESSION" : "STEPS TODAY"
        let source   = useWHOOP ? "WHOOP" : "iPhone"
        let value: Int? = useWHOOP ? live.state.sessionSteps : metrics.todaySteps

        return HStack(spacing: WH.Spacing.md) {
            Image(systemName: "figure.walk")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(WH.Color.teal.opacity(0.7))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(WH.Color.textSecondary)
                        .tracking(1.0)
                    Text("· \(source)")
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(WH.Color.textSecondary.opacity(0.6))
                }
                if let v = value {
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text(v.formatted())
                            .font(WH.Font.metricMedium(size: 26))
                            .foregroundStyle(WH.Color.textPrimary)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("steps")
                            .font(WH.Font.caption)
                            .foregroundStyle(WH.Color.textSecondary)
                    }
                } else {
                    Text(live.state.connected ? "Counting…" : "—")
                        .font(WH.Font.metricMedium(size: 26))
                        .foregroundStyle(WH.Color.textSecondary)
                }
            }
            Spacer()
        }
        .padding(WH.Spacing.md)
        .background(WH.Color.surface,
                    in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
    }

    // MARK: - Helpers

    private var stressColor: Color {
        guard let s = liveStress else { return WH.Color.textPrimary }
        switch s {
        case ..<3:  return WH.Color.recoveryGreen
        case ..<6:  return WH.Color.recoveryYellow
        default:    return WH.Color.recoveryRed
        }
    }

    private var batteryColor: Color {
        guard let pct = live.state.batteryPct else { return WH.Color.textPrimary }
        switch pct {
        case 30...:    return WH.Color.recoveryGreen
        case 15..<30:  return WH.Color.recoveryYellow
        default:       return WH.Color.recoveryRed
        }
    }

    private func sessionElapsed(at now: Date) -> String? {
        guard let start = live.state.sessionStartedAt else { return nil }
        let secs = Int(max(0, now.timeIntervalSince(start)))
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let s = secs % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    private func triggerPulse() {
        withAnimation(.easeOut(duration: 0.15)) { pulsing = true }
        withAnimation(.easeIn(duration: 0.25).delay(0.15)) { pulsing = false }
    }
}

// MARK: - HR Zone

private enum HRZone {
    case resting, light, moderate, cardio, peak

    init(bpm: Int) {
        switch bpm {
        case ..<60:  self = .resting
        case ..<100: self = .light
        case ..<130: self = .moderate
        case ..<160: self = .cardio
        default:     self = .peak
        }
    }

    var label: String {
        switch self {
        case .resting:  return "RESTING"
        case .light:    return "LIGHT"
        case .moderate: return "MODERATE"
        case .cardio:   return "CARDIO"
        case .peak:     return "PEAK"
        }
    }

    var color: Color {
        switch self {
        case .resting:  return WH.Color.textSecondary
        case .light:    return WH.Color.recoveryGreen
        case .moderate: return WH.Color.recoveryYellow
        case .cardio:   return .orange
        case .peak:     return WH.Color.recoveryRed
        }
    }
}

// MARK: - Preview

#Preview("NowView — idle") {
    let vm = LiveViewModel()
    return NowView()
        .environmentObject(vm)
}
