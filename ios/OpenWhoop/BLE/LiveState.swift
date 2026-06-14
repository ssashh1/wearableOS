import Foundation
import Combine

// MARK: - LiveHRPoint

/// A single live heart-rate reading with a wall-clock timestamp.
public struct LiveHRPoint: Identifiable, Equatable {
    public let id: UUID
    public let ts: Date
    public let bpm: Int
    public init(bpm: Int) {
        id  = UUID()
        ts  = Date()
        self.bpm = bpm
    }
}

// MARK: - LiveState

/// Observable snapshot of the live connection + biometric state, driven by FrameRouter
/// (from decoded frames) and BLEManager (from CoreBluetooth callbacks).
/// `@MainActor` so SwiftUI views observe it safely; mutators are called on the main queue.
@MainActor
public final class LiveState: ObservableObject {
    @Published public var connected: Bool = false
    @Published public var bonded: Bool = false
    @Published public var heartRate: Int? = nil
    @Published public var rr: [Int] = []
    @Published public var batteryPct: Double? = nil
    @Published public var lastFrameType: String? = nil
    @Published public var lastEvent: String? = nil

    // Rolling live buffers used by NowView — capped to avoid unbounded growth.
    // hrHistory: last 300 readings ≈ 5 minutes at 1 Hz.
    // rrHistory: last 500 RR intervals ≈ 6–8 minutes of beat-to-beat data.
    @Published public var hrHistory: [LiveHRPoint] = []
    @Published public var rrHistory: [Int] = []
    @Published public var sessionStartedAt: Date? = nil
    @Published public var sessionSteps: Int = 0      // steps counted from WHOOP IMU this session
    /// Rolling log of human-readable lines for the on-device verification checklist.
    @Published public var log: [String] = []

    /// True when the stuck-strap watchdog finds the strap has newer records than us but our frontier
    /// won't advance (likely needs a manual reboot; ~never after high-freq-sync removal). Banner-only.
    @Published public var strapNeedsReboot = false

    /// Wall time (unix seconds) of the last successfully-completed offload (a sync, even if nothing new
    /// came — i.e. caught up). Drives the sync tile + the staleness nudge.
    @Published public var lastSyncedAt: TimeInterval?

    /// Optional hook invoked on every battery update (wired by LiveViewModel to the alert monitor).
    /// Kept as a closure so LiveState stays a plain observable snapshot with no alert dependency.
    public var onBatteryUpdate: ((Double) -> Void)?

    public init() {}

    /// Single funnel for battery readings — updates the published value AND notifies the hook,
    /// so both write sites (FrameRouter, BLEManager) drive the alert monitor identically.
    public func setBattery(_ pct: Double) {
        batteryPct = pct
        onBatteryUpdate?(pct)
    }

    public func append(log line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}
