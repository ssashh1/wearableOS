import Foundation
import HealthKit
import WhoopStore
import WhoopProtocol

// Writes locally-collected WHOOP biometrics to Apple HealthKit.
// Authorization is requested once at app launch via the static requestAuthorization().
// sync() is called after each successful historical backfill; it pages through any new
// HR samples since a UserDefaults watermark and writes them as HKQuantitySamples.
@MainActor
final class HealthKitSyncer {
    private let hkStore = HKHealthStore()
    private let whoopStore: WhoopStore
    private let deviceId: String

    private static let hrWatermarkKey  = "hk_hr_highwater"
    private static let hrvDayWatermarkKey = "hk_hrv_day_watermark"
    private static let pageSize = 500

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    private static let writeTypes: Set<HKSampleType> = [
        HKQuantityType(.heartRate),
        HKQuantityType(.heartRateVariabilitySDNN),
    ]

    // The WHOOP 4.0 represented as an HKDevice so Health app shows the correct source.
    private static let whoopDevice = HKDevice(
        name: "WHOOP 4.0",
        manufacturer: "WHOOP",
        model: "WHOOP 4.0",
        hardwareVersion: nil,
        firmwareVersion: nil,
        softwareVersion: nil,
        localIdentifier: nil,
        udiDeviceIdentifier: nil
    )

    init(whoopStore: WhoopStore, deviceId: String) {
        self.whoopStore = whoopStore
        self.deviceId = deviceId
    }

    // MARK: - Authorization

    // Call once at app launch (from LiveViewModel.init). HealthKit shows the system
    // permission sheet on the first call; subsequent calls are no-ops.
    static func requestAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        Task {
            try? await HKHealthStore().requestAuthorization(toShare: writeTypes, read: [])
        }
    }

    // MARK: - Sync

    // Page through HR samples written since the last HealthKit sync and save them.
    // Safe to call repeatedly — the watermark ensures no sample is written twice.
    func sync() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        await syncHeartRate()
        await syncHRV()
    }

    private func syncHeartRate() async {
        let watermark = UserDefaults.standard.integer(forKey: Self.hrWatermarkKey)
        let now = Int(Date().timeIntervalSince1970)
        var from = watermark

        while true {
            let samples: [HRSample]
            do {
                samples = try await whoopStore.hrSamples(
                    deviceId: deviceId,
                    from: from + 1,
                    to: now,
                    limit: Self.pageSize
                )
            } catch { break }

            guard !samples.isEmpty else { break }

            let hkSamples = samples.compactMap { makeHRSample($0) }
            if !hkSamples.isEmpty {
                do {
                    try await hkSave(hkSamples)
                } catch { break }
            }

            let newWatermark = samples.map(\.ts).max() ?? from
            UserDefaults.standard.set(newWatermark, forKey: Self.hrWatermarkKey)

            if samples.count < Self.pageSize { break }
            from = newWatermark
        }
    }

    // Writes one heartRateVariabilitySDNN sample per night (overnight RMSSD).
    // Skips if we've already written a sample for today's overnight window.
    private func syncHRV() async {
        let todayStr = Self.dayFormatter.string(from: Date())
        let lastSynced = UserDefaults.standard.string(forKey: Self.hrvDayWatermarkKey) ?? ""
        guard lastSynced != todayStr else { return }

        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        let from = Int(startOfToday.addingTimeInterval(-4 * 3600).timeIntervalSince1970)  // yesterday 8 PM
        let to   = Int(startOfToday.addingTimeInterval(10 * 3600).timeIntervalSince1970)  // today 10 AM

        guard let intervals = try? await whoopStore.rrIntervals(
            deviceId: deviceId, from: from, to: to, limit: 100_000
        ) else { return }

        guard let hrv = HRVCalculator.overnightSDNN(from: intervals) else { return }

        let sampleDate = HRVCalculator.overnightSampleDate(calendar: cal)
        let quantity = HKQuantity(unit: HKUnit.secondUnit(with: .milli), doubleValue: hrv)
        let sample = HKQuantitySample(
            type: HKQuantityType(.heartRateVariabilitySDNN),
            quantity: quantity,
            start: sampleDate,
            end: sampleDate,
            device: Self.whoopDevice,
            metadata: nil
        )

        do {
            try await hkSave([sample])
            UserDefaults.standard.set(todayStr, forKey: Self.hrvDayWatermarkKey)
        } catch {}
    }

    // MARK: - Helpers

    private func makeHRSample(_ sample: HRSample) -> HKQuantitySample? {
        let quantity = HKQuantity(
            unit: HKUnit.count().unitDivided(by: .minute()),
            doubleValue: Double(sample.bpm)
        )
        let date = Date(timeIntervalSince1970: TimeInterval(sample.ts))
        return HKQuantitySample(
            type: HKQuantityType(.heartRate),
            quantity: quantity,
            start: date,
            end: date,
            device: Self.whoopDevice,
            metadata: [
                HKMetadataKeyHeartRateSensorLocation:
                    NSNumber(value: HKHeartRateSensorLocation.wrist.rawValue)
            ]
        )
    }

    private func hkSave(_ samples: [HKObject]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            hkStore.save(samples) { _, error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }
}
