import Foundation
import WhoopProtocol
import WhoopStore

/// Pure decode→state router. Takes a COMPLETE (already reassembled) frame, decodes it with
/// WhoopProtocol.parseFrame, and updates LiveState. No CoreBluetooth — fully unit-testable.
@MainActor
public final class FrameRouter {
    private let state: LiveState
    /// Called when the strap pushes an EVENT packet (WHOOP's strap-as-clock catch-up signal). The
    /// BLEManager wires this to a rate-limited requestSync(.strap). nil in pure/unit contexts.
    var onSyncTrigger: (() -> Void)?

    // Realtime persistence — wired by BLEManager after bootstrapStore() completes.
    // HR/RR samples are batched and flushed to SQLite every ~5 seconds so MetricsRepository
    // can compute local metrics (todayStats, localStrain, etc.) without a full historical sync.
    var persistStore: WhoopStore?
    var persistDeviceId: String = ""
    private var pendingHR: [HRSample] = []
    private var pendingRR: [RRInterval] = []
    private var lastPersistFlush: Date = .distantPast

    public init(state: LiveState) {
        self.state = state
    }

    /// Flush any pending HR/RR samples to SQLite. Called on disconnect to avoid data loss.
    func flushPendingPersist() {
        guard let store = persistStore, !persistDeviceId.isEmpty,
              !pendingHR.isEmpty || !pendingRR.isEmpty else { return }
        let hr = pendingHR; let rr = pendingRR
        pendingHR = []; pendingRR = []
        lastPersistFlush = Date()
        let deviceId = persistDeviceId
        Task { try? await store.insert(Streams(hr: hr, rr: rr), deviceId: deviceId) }
    }

    /// Handle one complete frame (bytes including 0xAA SOF and the crc32 trailer).
    public func handle(frame: [UInt8]) {
        let parsed = parseFrame(frame)
        guard parsed.ok else { return }
        // Reject frames that failed their checksum — never let bad bytes drive state.
        if parsed.crcOK == false { return }

        state.lastFrameType = parsed.typeName

        switch parsed.typeName {
        case "REALTIME_DATA":
            let nowTs = Int(Date().timeIntervalSince1970)
            if let hr = parsed.parsed["heart_rate"]?.intValue {
                state.heartRate = hr
                if state.sessionStartedAt == nil { state.sessionStartedAt = Date() }
                state.hrHistory.append(LiveHRPoint(bpm: hr))
                if state.hrHistory.count > 300 { state.hrHistory.removeFirst() }
                // Accumulate for SQLite batch-write
                pendingHR.append(HRSample(ts: nowTs, bpm: hr))
            }
            // The realtime stream usually reports rr_count=0; only update R-R when this frame
            // actually carries intervals, so we don't wipe R-R sourced from the 0x2A37 profile.
            if let rr = parsed.parsed["rr_intervals"]?.intArrayValue, !rr.isEmpty {
                state.rr = rr
                state.rrHistory.append(contentsOf: rr)
                if state.rrHistory.count > 500 { state.rrHistory.removeFirst(state.rrHistory.count - 500) }
                pendingRR.append(contentsOf: rr.map { RRInterval(ts: nowTs, rrMs: $0) })
            }
            // Flush accumulated HR/RR to SQLite every 5 seconds (fire-and-forget Task).
            // The ON CONFLICT DO NOTHING upsert in WhoopStore makes this safe to call repeatedly.
            if let store = persistStore, !persistDeviceId.isEmpty,
               Date().timeIntervalSince(lastPersistFlush) >= 5,
               !pendingHR.isEmpty {
                let hr = pendingHR; let rr = pendingRR
                pendingHR = []; pendingRR = []
                lastPersistFlush = Date()
                let deviceId = persistDeviceId
                Task { try? await store.insert(Streams(hr: hr, rr: rr), deviceId: deviceId) }
            }

        case "REALTIME_RAW_DATA":
            // IMU variant (1928-byte frame): count steps from raw accel block.
            let steps = WhoopPedometer.countSteps(frame: frame)
            if steps > 0 {
                if state.sessionStartedAt == nil { state.sessionStartedAt = Date() }
                state.sessionSteps += steps
            }

        case "COMMAND_RESPONSE":
            if let pct = parsed.parsed["battery_pct"]?.doubleValue {
                state.setBattery(pct)
            }

        case "EVENT":
            if let ev = parsed.parsed["event"]?.stringValue {
                state.lastEvent = ev
                // Strap-pushed event = "I may have new data" → kick a (rate-limited) sync.
                onSyncTrigger?()
                // Belt-and-suspenders: a BLE_BONDED event confirms the link is bonded.
                // (BLEManager also sets bonded=true when the confirmed write succeeds.)
                if ev.hasPrefix("BLE_BONDED") {
                    state.bonded = true
                }
            }

        default:
            break
        }
    }
}
