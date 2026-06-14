import SwiftUI

public struct LiveView: View {
    // The single LiveViewModel (and its BLEManager) is owned by AppRoot and injected via
    // the environment so it is shared with the alarm sheet. No longer a @StateObject here.
    @EnvironmentObject var model: LiveViewModel
    /// MetricsRepository is injected here so we can pass it explicitly to the SettingsView
    /// sheet (iOS 16 sheets do not always inherit environment objects from the presenting view).
    @EnvironmentObject var metrics: MetricsRepository
    @Environment(\.scenePhase) private var scenePhase
    public init() {}
    public var body: some View {
        LiveContentView(state: model.state, model: model, metrics: metrics)
            // Hide the system nav bar on the root; the custom ScreenHeader is inside the ScrollView.
            .toolbar(.hidden, for: .navigationBar)
            // scenePhase is still observed here: the Device tab hosts the scenePhase
            // observation that drives background/foreground transitions for the BLE pipeline.
            .onChange(of: scenePhase) { phase in
                if phase == .background { model.onEnterBackground() }
                if phase == .active { model.enterForeground() }
            }
            // Poll the lightweight storage summary every 5s (cancel-safe). Full History is M7.
            .task {
                while !Task.isCancelled {
                    model.refreshStorage()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
    }
}

private struct LiveContentView: View {
    @ObservedObject var state: LiveState
    @ObservedObject var model: LiveViewModel
    var metrics: MetricsRepository

    @State private var showingSettings = false

    /// Research toggle, backed by the same UserDefaults key BLEManager.bootstrapStore() reads.
    /// Default false → decoded-only. bootstrapStore() reads this once when it builds the
    /// Collector/Backfiller (first Bluetooth poweredOn after launch, idempotent thereafter),
    /// so a change here applies on the next app launch.
    @AppStorage("enableRawCapture") private var enableRawCapture = false

    /// Haptics playground state. patternId indexes the device's preset patterns (the strap reports
    /// 7 via GET_ALL_HAPTICS_PATTERN); the official app fires id 2, so that's the default. loops = repeats.
    @State private var hapticPattern = 2
    @State private var hapticLoops = 0

    /// Battery-alert settings, persisted to the same UserDefaults keys BatteryAlertMonitor reads.
    /// Defaults: both alerts off, warn at 50%, low at 20%.
    @AppStorage(BatteryAlertKeys.warnEnabled)   private var warnEnabled = false
    @AppStorage(BatteryAlertKeys.warnThreshold) private var warnThreshold = BatteryAlertKeys.defaultWarnThreshold
    @AppStorage(BatteryAlertKeys.lowEnabled)    private var lowEnabled = false
    @AppStorage(BatteryAlertKeys.lowThreshold)  private var lowThreshold = BatteryAlertKeys.defaultLowThreshold

    var body: some View {
        ZStack {
            WH.Color.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: WH.Spacing.md) {
                    // Custom tight header (replaces the hidden system large-title nav bar)
                    ScreenHeader("Device")
                    settingsRow
                    connectionSection
                    liveSection
                    controlsSection
                    hapticsSection
                    batteryAlertsSection
                    researchSection
                    logSection
                }
                .padding(WH.Spacing.md)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingSettings) {
            // iOS 16: sheets don't reliably inherit environment objects — pass explicitly.
            SettingsView()
                .environmentObject(metrics)
        }
    }

    // MARK: - Settings entry row

    /// Tappable card at the top of the Device console that opens Body Profile & Settings.
    private var settingsRow: some View {
        Button {
            showingSettings = true
        } label: {
            HStack(spacing: WH.Spacing.sm) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(WH.Color.strainBlue)
                    .frame(width: 32, height: 32)
                    .background(WH.Color.strainBlue.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: WH.Radius.small, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Body Profile & Settings")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(WH.Color.textPrimary)
                    Text("Height, weight, age, sex — used for strain + calorie estimates")
                        .font(WH.Font.caption)
                        .foregroundStyle(WH.Color.textSecondary)
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

    // MARK: - Section container

    private func consoleCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(WH.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WH.Color.surface,
                        in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
    }

    private func sectionHeader(_ label: String) -> some View {
        Text(label.uppercased())
            .font(WH.Font.cardTitle)
            .foregroundStyle(WH.Color.textSecondary)
            .tracking(1.5)
    }

    // MARK: - 1. Connection

    private var connectionSection: some View {
        consoleCard {
            VStack(alignment: .leading, spacing: WH.Spacing.sm) {
                sectionHeader("Connection")

                // Status chips row
                HStack(spacing: WH.Spacing.sm) {
                    statusChip("LINK",
                               state.connected ? "Connected" : "Disconnected",
                               state.connected ? WH.Color.recoveryGreen : WH.Color.textSecondary)
                    statusChip("BOND",
                               state.bonded ? "Bonded" : "Unbonded",
                               state.bonded ? WH.Color.recoveryGreen : WH.Color.recoveryYellow)
                    statusChip("BATT",
                               state.batteryPct.map { String(format: "%.1f%%", $0) } ?? "—",
                               state.batteryPct.map { $0 < 20 ? WH.Color.recoveryRed : WH.Color.strainBlue }
                                   ?? WH.Color.textSecondary)
                }

                // Sync-freshness row
                syncFreshnessRow

                // Storage summary
                Text(model.storageSummary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(WH.Color.textSecondary)

                // Strap-reboot warning (conditional)
                if state.strapNeedsReboot {
                    HStack(spacing: WH.Spacing.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(WH.Color.recoveryYellow)
                        Text("WHOOP may need a reboot — connected but not logging new data. "
                             + "Put it on the charger briefly to reboot.")
                            .font(WH.Font.caption)
                            .foregroundStyle(WH.Color.recoveryYellow)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(WH.Spacing.sm)
                    .background(WH.Color.recoveryYellow.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: WH.Radius.chip, style: .continuous))
                }

            }
        }
    }

    private var syncFreshnessRow: some View {
        let s = StalenessPolicy.state(lastSyncedAt: state.lastSyncedAt, now: Date().timeIntervalSince1970)
        let (label, color): (String, Color) = {
            switch s {
            case .neverSynced: return ("Never synced", WH.Color.textSecondary)
            case .caughtUp:    return ("Caught up", WH.Color.recoveryGreen)
            case .catchingUp:  return ("Catching up…", WH.Color.recoveryYellow)
            case .stale:       return ("Sync stale — keep the app open", WH.Color.recoveryRed)
            }
        }()
        let text = state.lastSyncedAt.map { ts in
            "\(label) · \(Int((Date().timeIntervalSince1970 - ts) / 60))m ago"
        } ?? label
        return HStack(spacing: WH.Spacing.xs) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    private func statusChip(_ label: String, _ value: String, _ accent: Color) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(WH.Font.cardTitle)
                .foregroundStyle(WH.Color.textSecondary)
                .tracking(1.2)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(accent)
        }
        .padding(.vertical, WH.Spacing.xs)
        .padding(.horizontal, WH.Spacing.sm)
        .background(accent.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: WH.Radius.chip, style: .continuous))
    }

    // MARK: - 2. Live

    private var liveSection: some View {
        consoleCard {
            VStack(alignment: .leading, spacing: WH.Spacing.sm) {
                sectionHeader("Live")

                // Big HR readout
                HStack(alignment: .lastTextBaseline, spacing: WH.Spacing.xs) {
                    Text(state.heartRate.map(String.init) ?? "––")
                        .font(WH.Font.metricHero(size: 72))
                        .foregroundStyle(state.connected
                            ? WH.Color.recoveryRed
                            : WH.Color.textSecondary)
                        .monospacedDigit()
                    Text("BPM")
                        .font(WH.Font.unit)
                        .foregroundStyle(WH.Color.textSecondary)
                        .padding(.bottom, 6)
                }
                .frame(maxWidth: .infinity, alignment: .center)

                Divider()
                    .background(WH.Color.separator)

                // R-R intervals
                VStack(alignment: .leading, spacing: WH.Spacing.xs) {
                    Text("R-R INTERVALS")
                        .font(WH.Font.cardTitle)
                        .foregroundStyle(WH.Color.textSecondary)
                        .tracking(1.2)
                    if state.rr.isEmpty {
                        Text("—")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(WH.Color.textSecondary)
                    } else {
                        Text(state.rr.map(String.init).joined(separator: "  "))
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(WH.Color.textPrimary)
                        Text("ms")
                            .font(WH.Font.caption)
                            .foregroundStyle(WH.Color.textSecondary)
                    }
                }
            }
        }
    }

    // MARK: - 3. Controls

    private var controlsSection: some View {
        consoleCard {
            VStack(alignment: .leading, spacing: WH.Spacing.sm) {
                sectionHeader("Controls")

                // Connect / Disconnect
                HStack(spacing: WH.Spacing.sm) {
                    consoleButton("Connect", icon: "antenna.radiowaves.left.and.right",
                                  accent: WH.Color.strainBlue, prominent: true) {
                        model.connect()
                    }
                    consoleButton("Disconnect", icon: "xmark.circle",
                                  accent: WH.Color.textSecondary, prominent: false) {
                        model.disconnect()
                    }
                }

                // HR + Battery + Sync
                HStack(spacing: WH.Spacing.sm) {
                    consoleButton("Start HR", icon: "waveform.path.ecg",
                                  accent: WH.Color.recoveryRed, prominent: false) {
                        model.startRealtimeHR()
                    }
                    consoleButton("Stop HR", icon: "stop.circle",
                                  accent: WH.Color.textSecondary, prominent: false) {
                        model.stopRealtimeHR()
                    }
                    consoleButton("Battery", icon: "battery.100",
                                  accent: WH.Color.recoveryGreen, prominent: false) {
                        model.getBattery()
                    }
                    consoleButton("Sync", icon: "arrow.trianglehead.2.clockwise",
                                  accent: WH.Color.teal, prominent: false) {
                        model.syncNow()
                    }
                }
            }
        }
    }

    private func consoleButton(_ label: String, icon: String,
                               accent: Color, prominent: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                Text(label)
                    .font(.system(size: 10, weight: .semibold, design: .default))
            }
            .foregroundStyle(prominent ? WH.Color.background : accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, WH.Spacing.sm)
            .background(prominent ? accent : accent.opacity(0.15),
                        in: RoundedRectangle(cornerRadius: WH.Radius.small, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 4. Haptics

    private var hapticsSection: some View {
        consoleCard {
            VStack(alignment: .leading, spacing: WH.Spacing.sm) {
                sectionHeader("Haptics")

                HStack(spacing: WH.Spacing.md) {
                    Picker("Pattern", selection: $hapticPattern) {
                        ForEach(0...7, id: \.self) { Text("Pattern \($0)").tag($0) }
                    }
                    .pickerStyle(.menu)
                    .foregroundStyle(WH.Color.textPrimary)
                    .tint(WH.Color.strainBlue)

                    Stepper("Loops \(hapticLoops)", value: $hapticLoops, in: 0...5)
                        .fixedSize()
                        .foregroundStyle(WH.Color.textPrimary)
                }

                HStack(spacing: WH.Spacing.sm) {
                    consoleButton("Buzz", icon: "waveform",
                                  accent: WH.Color.sleepPurple, prominent: true) {
                        model.runHaptic(pattern: UInt8(hapticPattern), loops: UInt8(hapticLoops))
                    }
                    consoleButton("Stop", icon: "pause.circle",
                                  accent: WH.Color.textSecondary, prominent: false) {
                        model.stopHaptics()
                    }
                    // M6: Test alarm buzz — fires patternId=2 (3 loops) + RUN_ALARM.
                    // Haptic firing cannot be verified in the simulator; test on-device only.
                    consoleButton("Test Alarm", icon: "alarm",
                                  accent: WH.Color.recoveryYellow, prominent: false) {
                        model.testAlarmBuzz()
                    }
                }
            }
        }
    }

    // MARK: - 5. Battery Alerts

    private var batteryAlertsSection: some View {
        consoleCard {
            VStack(alignment: .leading, spacing: WH.Spacing.sm) {
                sectionHeader("Battery Alerts")

                alertRow(label: "Warn at", isOn: $warnEnabled, threshold: $warnThreshold)
                alertRow(label: "Low at",  isOn: $lowEnabled,  threshold: $lowThreshold)

                Text("Fires once when WHOOP drops to a threshold; re-arms after charging.")
                    .font(WH.Font.caption)
                    .foregroundStyle(WH.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func alertRow(label: String, isOn: Binding<Bool>, threshold: Binding<Int>) -> some View {
        HStack(spacing: WH.Spacing.md) {
            Toggle(label, isOn: isOn)
                .fixedSize()
                .tint(WH.Color.strainBlue)
                .foregroundStyle(WH.Color.textPrimary)
                // Ask for notification permission the first time an alert is switched on.
                .onChange(of: isOn.wrappedValue) { on in
                    if on { BatteryAlertMonitor.requestAuthorization() }
                }
            Stepper("\(threshold.wrappedValue)%", value: threshold, in: 5...95, step: 5)
                .fixedSize()
                .foregroundStyle(WH.Color.textPrimary)
                .disabled(!isOn.wrappedValue)
        }
    }

    // MARK: - 6. Research

    private var researchSection: some View {
        consoleCard {
            VStack(alignment: .leading, spacing: WH.Spacing.sm) {
                sectionHeader("Research")

                NavigationLink(destination: HRVDebugView(state: state)) {
                    HStack {
                        Image(systemName: "waveform.path.ecg.rectangle")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(WH.Color.teal)
                        Text("HRV Debug")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(WH.Color.teal)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(WH.Color.textSecondary.opacity(0.5))
                    }
                    .padding(.vertical, WH.Spacing.xs)
                }

                Divider().background(WH.Color.separator)

                Toggle("Capture raw frames", isOn: $enableRawCapture)
                    .tint(WH.Color.strainBlue)
                    .foregroundStyle(WH.Color.textPrimary)

                Text("Off = decoded-only (default). On captures raw frames locally for RE; "
                     + "takes effect on next launch.")
                    .font(WH.Font.caption)
                    .foregroundStyle(WH.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Raw-accelerometer capture is a RESEARCH lever for future step/cadence work — it is NOT
                // "start an activity". Workouts are detected automatically + retroactively server-side
                // (analysis/exercise.py) from the backfilled 1 Hz store, no manual start needed. So this
                // button only appears when the research toggle is on, to avoid implying you must start
                // activities manually.
                if enableRawCapture {
                    consoleButton("Capture raw accel (30s · research)",
                                  icon: "sensor.tag.radiowaves.forward",
                                  accent: WH.Color.teal, prominent: false) {
                        model.captureActivitySample(seconds: 30)
                    }
                    Text("Streams raw accelerometer for 30 s for future step/cadence work, "
                         + "then stops + uploads. Workouts auto-detected from the 1 Hz store.")
                        .font(WH.Font.caption)
                        .foregroundStyle(WH.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 7. Log

    private var logSection: some View {
        VStack(alignment: .leading, spacing: WH.Spacing.xs) {
            sectionHeader("Log")
                .padding(.horizontal, WH.Spacing.xs)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(state.log.suffix(30).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(WH.Color.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(WH.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WH.Color.surface2,
                        in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
        }
    }
}
