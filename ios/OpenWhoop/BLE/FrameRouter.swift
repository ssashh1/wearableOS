import Foundation
import WhoopProtocol

/// Pure decode→state router. Takes a COMPLETE (already reassembled) frame, decodes it with
/// WhoopProtocol.parseFrame, and updates LiveState. No CoreBluetooth — fully unit-testable.
@MainActor
public final class FrameRouter {
    private let state: LiveState
    /// Called when the strap pushes an EVENT packet (WHOOP's strap-as-clock catch-up signal). The
    /// BLEManager wires this to a rate-limited requestSync(.strap). nil in pure/unit contexts.
    var onSyncTrigger: (() -> Void)?

    public init(state: LiveState) {
        self.state = state
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
            if let hr = parsed.parsed["heart_rate"]?.intValue {
                state.heartRate = hr
                if state.sessionStartedAt == nil { state.sessionStartedAt = Date() }
                state.hrHistory.append(LiveHRPoint(bpm: hr))
                if state.hrHistory.count > 300 { state.hrHistory.removeFirst() }
            }
            // The realtime stream usually reports rr_count=0; only update R-R when this frame
            // actually carries intervals, so we don't wipe R-R sourced from the 0x2A37 profile.
            if let rr = parsed.parsed["rr_intervals"]?.intArrayValue, !rr.isEmpty {
                state.rr = rr
                state.rrHistory.append(contentsOf: rr)
                if state.rrHistory.count > 500 { state.rrHistory.removeFirst(state.rrHistory.count - 500) }
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
