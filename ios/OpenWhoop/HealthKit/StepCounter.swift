import Foundation
import HealthKit

enum StepCounter {
    private static let store = HKHealthStore()

    static func requestAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        Task {
            try? await store.requestAuthorization(toShare: [], read: [HKQuantityType(.stepCount)])
        }
    }

    /// Cumulative step count from midnight today until now.
    /// Returns nil if HealthKit is unavailable or the user has not granted permission.
    static func todaySteps() async -> Int? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        let start = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(
            withStart: start, end: Date(), options: .strictStartDate
        )
        return await withCheckedContinuation { cont in
            let query = HKStatisticsQuery(
                quantityType: HKQuantityType(.stepCount),
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, stats, _ in
                guard let sum = stats?.sumQuantity() else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: Int(sum.doubleValue(for: .count()).rounded()))
            }
            store.execute(query)
        }
    }
}
