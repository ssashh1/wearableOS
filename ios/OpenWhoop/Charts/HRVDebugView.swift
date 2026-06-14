import SwiftUI

// MARK: - HRVDebugView
// Live diagnostic screen for the HRV pipeline. Shows the raw RR stream, artifact
// rejection breakdown, and both RMSSD and SDNN values so you can verify correctness
// on-device before trusting any displayed HRV number.
struct HRVDebugView: View {
    @ObservedObject var state: LiveState

    var body: some View {
        ZStack {
            WH.Color.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: WH.Spacing.md) {
                    ScreenHeader("HRV Debug")
                    connectionRow
                    rrStreamCard
                    rejectionCard
                    valuesCard
                    windowCard
                    Spacer(minLength: WH.Spacing.xl)
                }
                .padding(WH.Spacing.md)
            }
        }
        .preferredColorScheme(.dark)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Connection row

    private var connectionRow: some View {
        HStack(spacing: WH.Spacing.sm) {
            Circle()
                .fill(state.connected ? WH.Color.recoveryGreen : WH.Color.textSecondary)
                .frame(width: 7, height: 7)
            Text(state.connected ? "Connected · live data" : "Not connected · data frozen")
                .font(WH.Font.caption)
                .foregroundStyle(WH.Color.textSecondary)
            Spacer()
            if let hr = state.heartRate {
                Text("\(hr) BPM (strap)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(WH.Color.recoveryRed)
            }
        }
        .padding(.horizontal, WH.Spacing.sm)
    }

    // MARK: - Raw RR stream (last 20 samples)

    private var rrStreamCard: some View {
        let samples = state.rrHistory
        let recent = Array(samples.suffix(20))
        return debugCard("RAW R-R STREAM (last 20)") {
            if recent.isEmpty {
                monoline("No R-R data yet")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    // Header
                    HStack {
                        monoHeader("   #")
                        monoHeader("   RR (ms)")
                        monoHeader("  HR (bpm)")
                        monoHeader("  TS")
                        Spacer()
                    }
                    ForEach(Array(recent.enumerated()), id: \.offset) { idx, s in
                        let derivedHR = s.rrMs > 0 ? Int((60_000.0 / Double(s.rrMs)).rounded()) : 0
                        let inRange = s.rrMs >= HRVCalculator.minRR && s.rrMs <= HRVCalculator.maxRR
                        HStack(spacing: 0) {
                            monoValue(String(format: "%4d", samples.count - recent.count + idx + 1),
                                      color: WH.Color.textSecondary)
                            monoValue(String(format: "%9d", s.rrMs),
                                      color: inRange ? WH.Color.textPrimary : WH.Color.recoveryRed)
                            monoValue(String(format: "%9d", derivedHR),
                                      color: WH.Color.textSecondary)
                            monoValue("  \(timeStr(s.ts))",
                                      color: WH.Color.textSecondary.opacity(0.7))
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Rejection breakdown

    private var rejectionCard: some View {
        let dbg = HRVCalculator.rmssdDebug(state.rrHistory, minPairs: 15)
        return debugCard("ARTIFACT REJECTION (minPairs=15)") {
            VStack(alignment: .leading, spacing: WH.Spacing.xs) {
                statRow("Total pairs evaluated", "\(dbg.totalPairs)")
                statRow("Valid pairs", "\(dbg.validPairs)", accent: WH.Color.recoveryGreen)
                statRow("Rejected — out of range", "\(dbg.rejectedByRange)",
                        accent: dbg.rejectedByRange > 0 ? WH.Color.recoveryRed : WH.Color.textSecondary)
                statRow("Rejected — session gap (>30s)", "\(dbg.rejectedByGap)",
                        accent: dbg.rejectedByGap > 0 ? WH.Color.recoveryYellow : WH.Color.textSecondary)
                statRow("Rejected — Malik (|diff|>200ms)", "\(dbg.rejectedByMalik)",
                        accent: dbg.rejectedByMalik > 0 ? WH.Color.recoveryYellow : WH.Color.textSecondary)
                let pct = dbg.totalPairs > 0
                    ? Int((Double(dbg.totalPairs - dbg.validPairs) / Double(dbg.totalPairs) * 100).rounded())
                    : 0
                statRow("Bad-pair ratio", "\(pct)%  (nil if >40%)",
                        accent: pct > 40 ? WH.Color.recoveryRed : WH.Color.recoveryGreen)
            }
        }
    }

    // MARK: - HRV values

    private var valuesCard: some View {
        let samples = state.rrHistory
        let dbg = HRVCalculator.rmssdDebug(samples, minPairs: 15)
        let sdnn = HRVCalculator.sdnn(samples.map(\.rrMs), minIntervals: 15)
        return debugCard("HRV VALUES") {
            VStack(alignment: .leading, spacing: WH.Spacing.xs) {
                statRow("RMSSD (live display)", fmt(dbg.value) + " ms",
                        accent: dbg.value != nil ? WH.Color.teal : WH.Color.textSecondary)
                statRow("SDNN (HealthKit write)", fmt(sdnn) + " ms",
                        accent: sdnn != nil ? WH.Color.strainBlue : WH.Color.textSecondary)
                Divider().background(WH.Color.separator).padding(.vertical, 2)
                Text("RMSSD = live display. SDNN = Apple Health writes only.")
                    .font(WH.Font.caption)
                    .foregroundStyle(WH.Color.textSecondary.opacity(0.7))
            }
        }
    }

    // MARK: - Window info

    private var windowCard: some View {
        let samples = state.rrHistory
        let clean = samples.filter { $0.rrMs >= HRVCalculator.minRR && $0.rrMs <= HRVCalculator.maxRR }
        let windowSec: Int? = samples.count >= 2
            ? Int(samples.last!.ts.timeIntervalSince(samples.first!.ts))
            : nil
        let sumMs = clean.reduce(0) { $0 + $1.rrMs }
        return debugCard("WINDOW") {
            VStack(alignment: .leading, spacing: WH.Spacing.xs) {
                statRow("Total RR samples buffered", "\(samples.count) / 500")
                statRow("In-range samples", "\(clean.count)  (\(HRVCalculator.minRR)–\(HRVCalculator.maxRR) ms)")
                statRow("Window length",
                        windowSec.map { "\($0) s" } ?? "—")
                statRow("Cumulative RR time (in-range)",
                        clean.isEmpty ? "—" : String(format: "%.1f s", Double(sumMs) / 1000.0))
            }
        }
    }

    // MARK: - Helpers

    private func debugCard<Content: View>(_ title: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: WH.Spacing.sm) {
            Text(title)
                .font(WH.Font.cardTitle)
                .foregroundStyle(WH.Color.textSecondary)
                .tracking(1.2)
            content()
        }
        .padding(WH.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WH.Color.surface,
                    in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
    }

    private func statRow(_ label: String, _ value: String,
                          accent: Color = WH.Color.textPrimary) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(WH.Color.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(accent)
        }
    }

    private func monoHeader(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(WH.Color.textSecondary.opacity(0.6))
    }

    private func monoValue(_ s: String, color: Color) -> some View {
        Text(s)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(color)
    }

    private func monoline(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(WH.Color.textSecondary)
    }

    private func fmt(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.1f", v)
    }

    private func timeStr(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}
