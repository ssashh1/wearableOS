import Foundation

/// Pure mapping from "when did we last successfully sync?" to a user-facing state. Thresholds mimic
/// WHOOP (caught-up < 1 h behind; catching-up beyond) plus a `.stale` step that drives the local nudge.
enum SyncFreshness: Equatable { case neverSynced, caughtUp, catchingUp, stale }

enum StalenessPolicy {
    static let catchingUpAfterSeconds: TimeInterval = 3600    // 1 h — WHOOP's DataCatchingUpHelper number
    static let staleAfterSeconds: TimeInterval = 6 * 3600     // 6 h — our local-nudge threshold

    static func state(lastSyncedAt: TimeInterval?, now: TimeInterval) -> SyncFreshness {
        guard let last = lastSyncedAt else { return .neverSynced }
        let elapsed = now - last
        if elapsed >= staleAfterSeconds { return .stale }
        if elapsed >= catchingUpAfterSeconds { return .catchingUp }
        return .caughtUp
    }
}
