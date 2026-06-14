import SwiftUI

// MARK: - RecoveryRing
// Circular progress ring showing a recovery percentage.
// Ring stroke is colored by the recovery band (green/yellow/red).
// The integer % is rendered large+bold in the center with a caption label below.

struct RecoveryRing: View {

    /// Recovery percentage 0–100
    var percent: Double
    var size: CGFloat = 180
    var strokeWidth: CGFloat = 14

    // Clamp to valid range
    private var clamped: Double { min(100, max(0, percent)) }
    private var progress: Double { clamped / 100 }
    private var bandColor: Color { WH.Color.recoveryColor(forPercent: clamped) }

    var body: some View {
        ZStack {
            // --- Track (faint ring) ---
            Circle()
                .stroke(WH.Color.ringTrack, lineWidth: strokeWidth)

            // --- Filled arc ---
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    bandColor,
                    style: StrokeStyle(
                        lineWidth: strokeWidth,
                        lineCap: .round
                    )
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: progress)

            // --- Glow effect (subtle) ---
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    bandColor.opacity(0.25),
                    style: StrokeStyle(lineWidth: strokeWidth + 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .blur(radius: 6)
                .animation(.easeInOut(duration: 0.6), value: progress)

            // --- Center content ---
            VStack(spacing: 2) {
                Text("\(Int(clamped.rounded()))")
                    .font(WH.Font.metricHero(size: size * 0.32))
                    .foregroundStyle(WH.Color.textPrimary)
                    .monospacedDigit()

                Text("RECOVERY")
                    .font(WH.Font.cardTitle)
                    .foregroundStyle(WH.Color.textSecondary)
                    .tracking(1.5)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Preview

#Preview("Recovery Ring — all bands") {
    HStack(spacing: WH.Spacing.xl) {
        RecoveryRing(percent: 82, size: 140)
        RecoveryRing(percent: 51, size: 140)
        RecoveryRing(percent: 18, size: 140)
    }
    .padding(WH.Spacing.xl)
    .background(WH.Color.background)
}
