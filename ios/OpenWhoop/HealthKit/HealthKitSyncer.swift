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

    private static let hrWatermarkKey = "hk_hr_highwater"
    private static let pageSize = 500

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
