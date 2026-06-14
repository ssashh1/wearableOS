import SwiftUI

// MARK: - DesignGallery
// Living reference view: shows all 3 recovery bands, sample metric cards,
// and a sparkline. Use as a visual regression tool during development.
// Wired into the Today tab TEMPORARILY during M0.2 visual verification;
// must be reverted to TodayView() before committing.

struct DesignGallery: View {

    private let hrvSeries: [Double] = [58, 62, 55, 70, 66, 74, 68, 72, 65, 78, 71, 69]
    private let rhrSeries: [Double] = [52, 50, 51, 49, 48, 50, 47, 49, 48, 46, 48, 47]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WH.Spacing.lg) {

                // Section: Recovery rings — all 3 bands
                sectionHeader("Recovery Rings")

                HStack(spacing: WH.Spacing.md) {
                    VStack(spacing: WH.Spacing.xs) {
                        RecoveryRing(percent: 82, size: 100, strokeWidth: 10)
                        Text("Green (82%)")
                            .font(WH.Font.caption)
                            .foregroundStyle(WH.Color.textSecondary)
                    }
                    Spacer()
                    VStack(spacing: WH.Spacing.xs) {
                        RecoveryRing(percent: 51, size: 100, strokeWidth: 10)
                        Text("Yellow (51%)")
                            .font(WH.Font.caption)
                            .foregroundStyle(WH.Color.textSecondary)
                    }
                    Spacer()
                    VStack(spacing: WH.Spacing.xs) {
                        RecoveryRing(percent: 18, size: 100, strokeWidth: 10)
                        Text("Red (18%)")
                            .font(WH.Font.caption)
                            .foregroundStyle(WH.Color.textSecondary)
                    }
                }
                .padding(.horizontal, WH.Spacing.xs)

                Divider().background(WH.Color.separator)

                // Section: Hero ring
                sectionHeader("Hero Ring")
                HStack {
                    Spacer()
                    RecoveryRing(percent: 74, size: 200, strokeWidth: 16)
                    Spacer()
                }

                Divider().background(WH.Color.separator)

                // Section: Metric cards (plain)
                sectionHeader("Metric Cards")

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: WH.Spacing.sm) {
                    MetricCard(title: "Strain", value: "14.2", accentColor: WH.Color.strainBlue)
                    MetricCard(title: "Recovery", value: "74", unit: "%", accentColor: WH.Color.recoveryGreen)
                    MetricCard(title: "Sleep", value: "7h 23m")
                    MetricCard(title: "HRV", value: "68", unit: "ms", accentColor: WH.Color.recoveryGreen)
                    MetricCard(title: "Resting HR", value: "48", unit: "bpm")
                    MetricCard(title: "SpO2", value: "97", unit: "%")
                    MetricCard(title: "Skin Temp", value: "+0.3", unit: "°C")
                    MetricCard(title: "Resp Rate", value: "16.2", unit: "/min")
                }

                Divider().background(WH.Color.separator)

                // Section: Metric card with sparkline accessory
                sectionHeader("Cards with Sparkline")

                MetricCard(title: "HRV Trend", value: "68", unit: "ms", accentColor: WH.Color.recoveryGreen) {
                    Sparkline(data: hrvSeries, color: WH.Color.recoveryGreen)
                        .frame(height: 48)
                        .padding(.top, WH.Spacing.xs)
                }

                MetricCard(title: "Resting HR Trend", value: "48", unit: "bpm", accentColor: WH.Color.strainBlue) {
                    Sparkline(data: rhrSeries, color: WH.Color.strainBlue)
                        .frame(height: 48)
                        .padding(.top, WH.Spacing.xs)
                }

                Divider().background(WH.Color.separator)

                // Section: Standalone sparklines
                sectionHeader("Sparklines (standalone)")

                VStack(spacing: WH.Spacing.sm) {
                    Sparkline(data: hrvSeries, color: WH.Color.recoveryGreen, showArea: true)
                        .frame(height: 64)
                        .padding(WH.Spacing.sm)
                        .background(WH.Color.surface, in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))

                    Sparkline(data: rhrSeries, color: WH.Color.strainBlue, showArea: false)
                        .frame(height: 64)
                        .padding(WH.Spacing.sm)
                        .background(WH.Color.surface, in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
                }

                Divider().background(WH.Color.separator)

                // Section: Color palette swatches
                sectionHeader("Color Palette")
                colorPalette

                Spacer(minLength: WH.Spacing.xl)
            }
            .padding(WH.Spacing.md)
        }
        .background(WH.Color.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(WH.Font.cardTitle)
            .foregroundStyle(WH.Color.textSecondary)
            .tracking(1.5)
            .padding(.top, WH.Spacing.xs)
    }

    private var colorPalette: some View {
        let swatches: [(String, Color)] = [
            ("Background",    WH.Color.background),
            ("Surface",       WH.Color.surface),
            ("Surface 2",     WH.Color.surface2),
            ("Text Primary",  WH.Color.textPrimary),
            ("Text Secondary",WH.Color.textSecondary),
            ("Separator",     WH.Color.separator),
            ("Green",         WH.Color.recoveryGreen),
            ("Yellow",        WH.Color.recoveryYellow),
            ("Red",           WH.Color.recoveryRed),
            ("Strain Blue",   WH.Color.strainBlue),
        ]
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: WH.Spacing.xs) {
            ForEach(swatches, id: \.0) { name, color in
                HStack(spacing: WH.Spacing.sm) {
                    RoundedRectangle(cornerRadius: WH.Radius.small)
                        .fill(color)
                        .frame(width: 28, height: 28)
                        .overlay(
                            RoundedRectangle(cornerRadius: WH.Radius.small)
                                .strokeBorder(WH.Color.separator, lineWidth: 1)
                        )
                    Text(name)
                        .font(WH.Font.caption)
                        .foregroundStyle(WH.Color.textPrimary)
                    Spacer()
                }
                .padding(WH.Spacing.xs)
            }
        }
    }
}

// MARK: - Preview

#Preview("Design Gallery") {
    DesignGallery()
}
