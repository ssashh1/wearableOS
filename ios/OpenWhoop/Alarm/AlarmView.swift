import SwiftUI

// MARK: - AlarmView
// Alarm configuration screen (M6).
// Presents: a wake-by time picker, a smart-wake toggle + lead-time stepper,
// an enable/disable toggle, and Set/Turn-off actions.
// Settings are persisted to UserDefaults (keys: AlarmKeys.*).
// On enable: computes next occurrence of the wake-by time and calls BLEManager.armStrapAlarm(at:).
// On disable: calls BLEManager.disableStrapAlarm().
//
// NOTE: Haptic/firmware firing cannot be verified in the simulator (no strap).
// The "Alarm set" status line and all UI controls are sim-verifiable.

// MARK: - UserDefaults keys

enum AlarmKeys {
    static let enabled          = "alarmEnabled"
    static let wakeByHour       = "alarmWakeByHour"
    static let wakeByMinute     = "alarmWakeByMinute"
    static let smartWakeEnabled = "alarmSmartWakeEnabled"
    static let smartWakeLeadMin = "alarmSmartWakeLeadMin"
    /// Epoch seconds of the last successfully armed firmware alarm, for the status line.
    static let armedEpoch       = "alarmArmedEpoch"
}

// MARK: - AlarmView

struct AlarmView: View {
    @Environment(\.dismiss) private var dismiss

    // The shared LiveViewModel (and its single BLEManager) is injected via the environment
    // from AppRoot → TodayView sheet → AlarmView. Alarm commands call through passthroughs
    // on LiveViewModel so AlarmView never needs a raw BLEManager reference.
    @EnvironmentObject var live: LiveViewModel

    // Persisted alarm settings
    @AppStorage(AlarmKeys.enabled)          private var alarmEnabled   = false
    @AppStorage(AlarmKeys.wakeByHour)       private var wakeByHour     = 7
    @AppStorage(AlarmKeys.wakeByMinute)     private var wakeByMinute   = 0
    @AppStorage(AlarmKeys.smartWakeEnabled) private var smartWakeEnabled = false
    @AppStorage(AlarmKeys.smartWakeLeadMin) private var smartWakeLeadMin = 20
    @AppStorage(AlarmKeys.armedEpoch)       private var armedEpoch: Double = 0

    // Transient state for the DatePicker binding
    @State private var wakeByDate: Date = AlarmView.todayAt(hour: 7, minute: 0)

    var body: some View {
        NavigationStack {
            ZStack {
                WH.Color.background.ignoresSafeArea()
                Form {
                    alarmTimeSection
                    smartWakeSection
                    enableSection
                    statusSection
                    notesSection
                }
                .scrollContentBackground(.hidden)
                .background(WH.Color.background)
            }
            .navigationTitle("Alarm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .preferredColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(WH.Color.strainBlue)
                }
            }
            .onAppear { syncPickerFromStorage() }
            .onChange(of: wakeByDate) { date in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                wakeByHour   = comps.hour   ?? wakeByHour
                wakeByMinute = comps.minute ?? wakeByMinute
            }
        }
    }

    // MARK: - Sections

    private var alarmTimeSection: some View {
        Section {
            DatePicker(
                "Wake by",
                selection: $wakeByDate,
                displayedComponents: .hourAndMinute
            )
            .datePickerStyle(.compact)
            .tint(WH.Color.strainBlue)
            .foregroundStyle(WH.Color.textPrimary)
            .listRowBackground(WH.Color.surface)
        } header: {
            sectionHeader("Wake-by Time")
        }
    }

    private var smartWakeSection: some View {
        Section {
            Toggle("Smart wake", isOn: $smartWakeEnabled)
                .tint(WH.Color.sleepPurple)
                .foregroundStyle(WH.Color.textPrimary)
                .listRowBackground(WH.Color.surface)

            if smartWakeEnabled {
                Stepper(
                    "Up to \(smartWakeLeadMin) min early",
                    value: $smartWakeLeadMin,
                    in: 5...30,
                    step: 5
                )
                .foregroundStyle(WH.Color.textPrimary)
                .listRowBackground(WH.Color.surface)
            }
        } header: {
            sectionHeader("Smart Wake")
        } footer: {
            Text("Smart wake monitors your HR and movement to find a light-sleep moment "
                 + "within the lead window, then buzzes the strap at the optimal moment. "
                 + "Best-effort — requires the strap to be worn and connected. "
                 + "The fixed-time alarm above always fires as a safety net.")
                .font(WH.Font.caption)
                .foregroundStyle(WH.Color.textSecondary)
        }
    }

    private var enableSection: some View {
        Section {
            HStack(spacing: WH.Spacing.sm) {
                Button {
                    setAlarm()
                } label: {
                    Label("Set alarm", systemImage: "alarm")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, WH.Spacing.xs)
                }
                .buttonStyle(.borderedProminent)
                .tint(WH.Color.strainBlue)

                Button(role: .destructive) {
                    disableAlarm()
                } label: {
                    Label("Turn off", systemImage: "alarm.slash")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, WH.Spacing.xs)
                }
                .buttonStyle(.bordered)
                .tint(WH.Color.recoveryRed)
            }
            .listRowBackground(WH.Color.surface)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
    }

    private var statusSection: some View {
        Section {
            VStack(alignment: .leading, spacing: WH.Spacing.xs) {
                if alarmEnabled, armedEpoch > 0 {
                    let fireDate = Date(timeIntervalSince1970: armedEpoch)
                    HStack(spacing: WH.Spacing.xs) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(WH.Color.recoveryGreen)
                            .font(.system(size: 14))
                        Text("Alarm set for \(formattedTime(fireDate))")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(WH.Color.textPrimary)
                    }
                    Text("Your strap will buzz at \(formattedTime(fireDate)).")
                        .font(WH.Font.caption)
                        .foregroundStyle(WH.Color.textSecondary)
                    if smartWakeEnabled {
                        Text("Smart wake: watches for a light-sleep window up to "
                             + "\(smartWakeLeadMin) min before that time.")
                            .font(WH.Font.caption)
                            .foregroundStyle(WH.Color.textSecondary)
                    }
                } else {
                    HStack(spacing: WH.Spacing.xs) {
                        Image(systemName: "alarm.slash")
                            .foregroundStyle(WH.Color.textSecondary)
                            .font(.system(size: 14))
                        Text("No alarm set")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(WH.Color.textSecondary)
                    }
                }
            }
            .padding(.vertical, WH.Spacing.xs)
            .listRowBackground(WH.Color.surface)
        } header: {
            sectionHeader("Status")
        }
    }

    private var notesSection: some View {
        Section {
            VStack(alignment: .leading, spacing: WH.Spacing.sm) {
                noteRow(icon: "wave.3.right",
                        text: "Strap must be connected and worn at alarm time for the buzz to fire.")
                noteRow(icon: "iphone.slash",
                        text: "Fixed-time firmware alarm fires even if the app is force-quit or the phone is locked.")
                noteRow(icon: "exclamationmark.triangle",
                        text: "Smart-wake background BLE and actual firing require on-device testing — "
                            + "cannot be fully verified in the simulator.")
            }
            .padding(.vertical, WH.Spacing.xs)
            .listRowBackground(WH.Color.surface)
        } header: {
            sectionHeader("Notes")
        }
    }

    // MARK: - Row helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(WH.Font.cardTitle)
            .foregroundStyle(WH.Color.textSecondary)
            .tracking(1.2)
    }

    private func noteRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: WH.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(WH.Color.textSecondary.opacity(0.7))
                .frame(width: 16)
            Text(text)
                .font(WH.Font.caption)
                .foregroundStyle(WH.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private func setAlarm() {
        let fireDate = nextOccurrence(hour: wakeByHour, minute: wakeByMinute)
        alarmEnabled = true
        armedEpoch   = fireDate.timeIntervalSince1970
        // armStrapAlarm returns the shared BLEManager so SmartAlarmController can hold it weakly.
        let ble = live.armStrapAlarm(at: fireDate)
        // Wire up smart-wake if enabled (SmartAlarmController arms itself in the window)
        if smartWakeEnabled {
            SmartAlarmController.shared.schedule(
                wakeBy: fireDate,
                leadMinutes: smartWakeLeadMin,
                ble: ble
            )
        }
    }

    private func disableAlarm() {
        alarmEnabled = false
        armedEpoch   = 0
        live.disableStrapAlarm()
        SmartAlarmController.shared.cancel()
    }

    // MARK: - Helpers

    private func syncPickerFromStorage() {
        wakeByDate = AlarmView.todayAt(hour: wakeByHour, minute: wakeByMinute)
    }

    /// Returns a `Date` for today at `hour:minute` (local time).
    static func todayAt(hour: Int, minute: Int) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour   = hour
        comps.minute = minute
        comps.second = 0
        return Calendar.current.date(from: comps) ?? Date()
    }

    /// Next occurrence of `hour:minute` — today if still in the future, tomorrow otherwise.
    private func nextOccurrence(hour: Int, minute: Int) -> Date {
        let candidate = AlarmView.todayAt(hour: hour, minute: minute)
        if candidate > Date() { return candidate }
        return Calendar.current.date(byAdding: .day, value: 1, to: candidate) ?? candidate
    }

    private func formattedTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle  = .short
        f.timeStyle  = .short
        return f.string(from: date)
    }
}

// MARK: - Preview

#Preview("Alarm — no alarm set") {
    AlarmView()
        .environmentObject(LiveViewModel())
}
