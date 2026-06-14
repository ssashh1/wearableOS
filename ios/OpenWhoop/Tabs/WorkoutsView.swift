import SwiftUI

// MARK: - WorkoutsView
// Shows auto-detected workout bouts. Prefers server workouts when available;
// falls back to locally-detected activity bouts (≥10 min sustained >100 BPM) otherwise.

struct WorkoutsView: View {
    @EnvironmentObject private var metrics: MetricsRepository

    // MARK: - State

    @State private var workouts: [Workout] = []
    @State private var localActivities: [DetectedActivity] = []
    @State private var isLoading = true
    @State private var errorMessage: String? = nil

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                WH.Color.background.ignoresSafeArea()

                if isLoading {
                    loadingView
                } else {
                    listContent
                }
            }
            // Hide the system nav bar on the root; pushed detail views manage their own bars.
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .task {
            await reload()
        }
        .refreshable {
            await reload()
        }
    }

    // MARK: - Loading view

    private var loadingView: some View {
        VStack(spacing: WH.Spacing.md) {
            ProgressView()
                .tint(WH.Color.textSecondary)
            Text("Loading workouts…")
                .font(WH.Font.caption)
                .foregroundStyle(WH.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List / empty content

    private var listContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {

                // Custom tight header (replaces the hidden system large-title nav bar)
                ScreenHeader("Workouts")

                if let err = errorMessage {
                    errorBanner(err)
                        .padding(.horizontal, WH.Spacing.md)
                        .padding(.top, WH.Spacing.sm)
                }

                if !workouts.isEmpty {
                    workoutList
                } else if !localActivities.isEmpty {
                    localActivityBanner
                    localActivityList
                } else {
                    emptyState
                }
            }
        }
        .background(WH.Color.background)
    }

    // MARK: - Workout list

    private var workoutList: some View {
        VStack(spacing: 1) {
            ForEach(workouts) { workout in
                NavigationLink(destination: WorkoutDetailView(workout: workout)) {
                    workoutRow(workout)
                }
                .buttonStyle(.plain)
            }
        }
        .background(WH.Color.surface,
                    in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
        .padding(WH.Spacing.md)
    }

    private func workoutRow(_ w: Workout) -> some View {
        HStack(spacing: WH.Spacing.sm) {

            // Date + time column
            VStack(alignment: .leading, spacing: 2) {
                Text(rowDate(w.startTs))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(WH.Color.textPrimary)
                Text(rowTime(w.startTs))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(WH.Color.textSecondary)
            }
            .frame(width: 72, alignment: .leading)

            // Duration
            Text(formatDuration(w.durationS))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(WH.Color.textSecondary)
                .frame(width: 44, alignment: .leading)

            Spacer()

            // Avg HR
            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "%.0f", w.avgHr))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(WH.Color.textPrimary)
                    .monospacedDigit()
                Text("bpm")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(WH.Color.textSecondary)
            }
            .frame(width: 44, alignment: .trailing)

            // Strain badge
            strainBadge(w.strain)

            // Calories
            VStack(alignment: .trailing, spacing: 1) {
                Text(w.caloriesKcal.map { String(format: "%.0f", $0) } ?? "—")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(w.caloriesKcal != nil ? WH.Color.recoveryYellow : WH.Color.textSecondary)
                    .monospacedDigit()
                Text(w.caloriesKcal != nil ? "kcal" : "")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(WH.Color.textSecondary)
            }
            .frame(width: 40, alignment: .trailing)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WH.Color.textSecondary.opacity(0.5))
        }
        .padding(.horizontal, WH.Spacing.md)
        .padding(.vertical, WH.Spacing.sm)
    }

    private func strainBadge(_ strain: Double?) -> some View {
        Group {
            if let s = strain {
                Text(String(format: "%.1f", s))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(WH.Color.strainBlue)
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(WH.Color.strainBlue.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: WH.Radius.small, style: .continuous))
            } else {
                Text("—")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(WH.Color.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(WH.Color.surface2,
                                in: RoundedRectangle(cornerRadius: WH.Radius.small, style: .continuous))
            }
        }
        .frame(width: 52, alignment: .center)
    }

    // MARK: - Local activity banner

    private var localActivityBanner: some View {
        HStack(spacing: WH.Spacing.xs) {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(WH.Color.textSecondary)
            Text("Locally detected · periods ≥10 min sustained >100 bpm")
                .font(WH.Font.caption)
                .foregroundStyle(WH.Color.textSecondary)
            Spacer()
        }
        .padding(.horizontal, WH.Spacing.md)
        .padding(.top, WH.Spacing.xs)
    }

    // MARK: - Local activity list

    private var localActivityList: some View {
        VStack(spacing: 1) {
            ForEach(localActivities) { activity in
                localActivityRow(activity)
            }
        }
        .background(WH.Color.surface,
                    in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
        .padding(WH.Spacing.md)
    }

    private func localActivityRow(_ a: DetectedActivity) -> some View {
        HStack(spacing: WH.Spacing.sm) {

            VStack(alignment: .leading, spacing: 2) {
                Text(rowDate(a.startTs))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(WH.Color.textPrimary)
                Text(rowTime(a.startTs))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(WH.Color.textSecondary)
            }
            .frame(width: 72, alignment: .leading)

            Text(formatDuration(a.durationSeconds))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(WH.Color.textSecondary)
                .frame(width: 44, alignment: .leading)

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(a.avgBPM)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(WH.Color.textPrimary)
                    .monospacedDigit()
                Text("avg bpm")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(WH.Color.textSecondary)
            }
            .frame(width: 52, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(a.peakBPM)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(WH.Color.strainBlue)
                    .monospacedDigit()
                Text("peak")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(WH.Color.textSecondary)
            }
            .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, WH.Spacing.md)
        .padding(.vertical, WH.Spacing.sm)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: WH.Spacing.sm) {
            Image(systemName: "figure.run.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(WH.Color.textSecondary)
            Text("No activity detected")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(WH.Color.textPrimary)
            Text("Activity bouts (≥10 min >100 bpm) from the last 30 days will appear here once heart rate data has been collected.")
                .font(WH.Font.caption)
                .foregroundStyle(WH.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, WH.Spacing.xl)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, WH.Spacing.xxl)
    }

    // MARK: - Error banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: WH.Spacing.sm) {
            Image(systemName: "wifi.slash")
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

    // MARK: - Data loading

    private func reload() async {
        errorMessage = nil
        let (from, to) = dateRange()
        workouts = await metrics.workouts(from: from, to: to)
        // Fall back to local threshold-based detection when no server workouts available
        localActivities = workouts.isEmpty ? await metrics.localActivities() : []
        if isLoading { isLoading = false }
    }

    private func dateRange() -> (from: String, to: String) {
        let cal = Calendar(identifier: .gregorian)
        let utc = TimeZone(identifier: "UTC")!
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.timeZone = utc
        fmt.dateFormat = "yyyy-MM-dd"
        let today = Date()
        let from = cal.date(byAdding: .day, value: -30, to: today) ?? today
        return (fmt.string(from: from), fmt.string(from: today))
    }

    // MARK: - Formatting

    private func rowDate(_ ts: Int) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ts))
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE M/d"
        return fmt.string(from: d)
    }

    private func rowTime(_ ts: Int) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ts))
        let fmt = DateFormatter()
        fmt.dateStyle = .none
        fmt.timeStyle = .short
        return fmt.string(from: d)
    }

    private func formatDuration(_ seconds: Int) -> String {
        let totalMin = seconds / 60
        let h = totalMin / 60
        let m = totalMin % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0           { return "\(h)h" }
        return "\(m)m"
    }
}

// MARK: - Preview

#Preview("Workouts — empty") {
    WorkoutsView()
        .environmentObject(MetricsRepository(deviceId: "preview"))
}
