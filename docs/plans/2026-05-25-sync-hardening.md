# Sync Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended)
> or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`)
> syntax. Commit after every task. Co-author trailer:
> `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.

**Goal:** Harden the WHOOP sync flow so it never loses biometric data and doesn't drain the strap
battery — by adopting what WHOOP's own app does: offload via plain `SEND_HISTORICAL_DATA` (no
high-freq-sync), detect/recover a stuck strap, set the clock only when drifted, sync on a 15-min floor +
strap-pushed events, and nudge the user to reopen the app when sync goes stale.

**Architecture:** Design spec → `docs/specs/2026-05-25-sync-hardening-design.md` (read it first). Three
phases: **P0** removes the data-loss root cause (high-freq-sync) + adds a stuck-strap safety net; **P1**
fixes the clock policy and adds WHOOP's cadence (rate-limiter + 15-min floor + strap-as-clock event
triggers) + background resilience; **P2** adds the force-quit staleness nudge + an in-app sync tile.
Pure decision logic is extracted into testable helpers (`BackfillPolicy`, `StuckStrapDetector`,
`ClockPolicy`, `StalenessPolicy`); CoreBluetooth glue is verified by build + the existing suite +
on-device checks (it has no unit seam).

**Tech Stack:** Swift 6.3 / SwiftUI / CoreBluetooth (`ios/OpenWhoop/`), WhoopStore (GRDB,
`Packages/WhoopStore/`). Tests: XCTest via `xcodebuild` on the iPhone 17 simulator; WhoopStore via
`swift test`. On-device checks use the runbook (`docs/specs/2026-05-25-debugging-runbook.md`).

**Verified pre-work:** `re/test_offload_without_highfreq.py` proved on-device that plain
`SEND_HISTORICAL_DATA` returns type-47 with NO high-freq-sync (Phase A: 40 records; Phase B with
high-freq: none). Pillar 1 is therefore a confirmed change, not a hypothesis.

---

## File structure

**Create:**
- `ios/OpenWhoop/BLE/BackfillPolicy.swift` — `BackfillTrigger` enum + pure `BackfillPolicy` rate-limiter.
- `ios/OpenWhoop/BLE/StuckStrapDetector.swift` — pure "data frontier hasn't advanced" detector.
- `ios/OpenWhoop/Collect/ClockPolicy.swift` — pure "should we SET_CLOCK?" drift decision.
- `ios/OpenWhoop/Sync/StalenessPolicy.swift` — pure last-synced→staleness/tile-state decision.
- `ios/OpenWhoop/Sync/SyncNudge.swift` — local schedule-ahead notification scheduler.
- `ios/OpenWhoopTests/BackfillPolicyTests.swift`, `StuckStrapDetectorTests.swift`,
  `ClockPolicyTests.swift`, `StalenessPolicyTests.swift`.
- `Packages/WhoopStore/Tests/WhoopStoreTests/LatestSampleTests.swift`.

**Modify:**
- `ios/OpenWhoop/BLE/Commands.swift` — add `exitHighFreqSync = 97`.
- `ios/OpenWhoop/BLE/BLEManager.swift` — handshake (remove high-freq, defensive exit, conditional
  clock), `requestSync(_:)` + watermark, periodic interval 300→900, watchdog wiring.
- `ios/OpenWhoop/BLE/FrameRouter.swift` — EVENT → strap-as-clock sync trigger callback.
- `ios/OpenWhoop/Live/LiveState.swift` — `strapNeedsReboot` + `lastSyncedAt` published state.
- `ios/OpenWhoop/Live/LiveViewModel.swift` — `enterForeground()`, `syncNow()`, nudge wiring.
- `ios/OpenWhoop/Live/LiveView.swift` — scenePhase `.active` trigger, "Sync now" button, sync tile,
  "needs reboot" banner.
- `Packages/WhoopStore/Sources/WhoopStore/Reads.swift` — `latestHRSampleTs(deviceId:)`.
- `docs/specs/2026-05-25-debugging-runbook.md` — document the new model.

---

# PHASE P0 — Stop the data loss

## Task 1: Add `EXIT_HIGH_FREQ_SYNC` (97) to the command set

**Files:**
- Modify: `ios/OpenWhoop/BLE/Commands.swift`
- Test: `ios/OpenWhoopTests/CommandsTests.swift` (create if absent; else append)

- [ ] **Step 1: Write the failing test**

Create/append `ios/OpenWhoopTests/CommandsTests.swift`:

```swift
import XCTest
@testable import OpenWhoop

final class CommandsTests: XCTestCase {
    func testExitHighFreqSyncCommandExists() {
        XCTAssertEqual(WhoopCommand.exitHighFreqSync.rawValue, 97)
        XCTAssertEqual(WhoopCommand.exitHighFreqSync.label, "Exit High-Freq Sync")
    }
    // The framed packet for EXIT (cmd 97, payload [0x00]) is well-formed: 0xAA SOF, type=35.
    func testExitHighFreqSyncFrames() {
        let frame = WhoopCommand.exitHighFreqSync.frame(seq: 1, payload: [0x00])
        XCTAssertEqual(frame.first, 0xAA)
        XCTAssertEqual(frame[4], WhoopCommand.commandType) // inner type byte = 35 (COMMAND)
        XCTAssertEqual(frame[6], 97)                       // inner cmd byte
    }
}
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OpenWhoopTests/CommandsTests 2>&1 | tail -15`
Expected: FAIL — `type 'WhoopCommand' has no member 'exitHighFreqSync'`.

- [ ] **Step 3: Add the case + label**

In `ios/OpenWhoop/BLE/Commands.swift`, add the case next to `enterHighFreqSync = 96`:

```swift
    case enterHighFreqSync     = 96
    /// Leave high-frequency-sync mode. Sent defensively on connect to release a strap left parked in
    /// high-freq by an older app build (we no longer ENTER it — see the sync-hardening design). Payload
    /// [0x00]. Safe/reversible.
    case exitHighFreqSync      = 97
```

And add its label in the `label` switch (next to `enterHighFreqSync`):

```swift
        case .enterHighFreqSync:     return "Enter High-Freq Sync"
        case .exitHighFreqSync:      return "Exit High-Freq Sync"
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OpenWhoopTests/CommandsTests 2>&1 | tail -8`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add ios/OpenWhoop/BLE/Commands.swift ios/OpenWhoopTests/CommandsTests.swift
git commit -m "feat(ios): add EXIT_HIGH_FREQ_SYNC(97) command"
```

---

## Task 2: Remove high-freq-sync from the connect handshake; add defensive EXIT

**Files:**
- Modify: `ios/OpenWhoop/BLE/BLEManager.swift` (handshake ~620–647; stale comments ~51–55, ~393–396)

**Context:** The bond block at `BLEManager.swift:620` currently sends `ENTER_HIGH_FREQ_SYNC` (empty
payload, never exited) — the data-loss root cause (a stranded strap stops 1 Hz logging). Verified
on-device that plain `SEND_HISTORICAL_DATA` returns type-47 without it. We remove the ENTER and add a
one-shot defensive EXIT to release a strap stranded by the currently-shipped build.

- [ ] **Step 1: Replace the handshake sends**

In `ios/OpenWhoop/BLE/BLEManager.swift`, find (inside `if !backfillStarted {`):

```swift
            send(.setClock, payload: BLEManager.setClockPayload())
            send(.sendR10R11Realtime, payload: [0x00])   // stop the realtime-raw flood (the real fix)
            send(.enterHighFreqSync, payload: [])
            send(.getDataRange)
            beginBackfill()
```
Replace with:

```swift
            // Defensive: release a strap left parked in high-freq-sync by an OLDER app build. We no
            // longer ENTER high-freq — verified on-device (re/test_offload_without_highfreq.py) that
            // plain SEND_HISTORICAL_DATA returns the type-47 store; high-freq-sync only SUPPRESSED the
            // strap's 1 Hz logging when we got stranded in it (the data-loss bug). See the sync-hardening
            // design + [[whoop-offload-no-highfreq]].
            send(.exitHighFreqSync, payload: [0x00])
            send(.sendR10R11Realtime, payload: [0x00])   // stop the realtime-raw flood (the real fix)
            send(.setClock, payload: BLEManager.setClockPayload())  // becomes conditional in Task 8
            send(.getDataRange)
            beginBackfill()
```

(`SET_CLOCK` stays unconditional here for now — Task 8 makes it drift-gated. `getDataRange` stays; Task 5
uses its result. `enterHighFreqSync` remains in the enum, just unused by the offload path.)

- [ ] **Step 2: Fix the now-stale comments**

In `ios/OpenWhoop/BLE/BLEManager.swift`, the `backfillTimer` doc (~line 51–55) and
`triggerPeriodicBackfill` doc (~line 393–396) claim "ENTER_HIGH_FREQ_SYNC was sent once at connect and
stays active." Replace both mentions so they read (match the surrounding comment style):

```swift
    // ... the strap's 14-day biometric store is re-offloaded every `backfillIntervalSeconds` while
    // connected+bonded. Plain SEND_HISTORICAL_DATA returns the type-47 store (no high-freq-sync), so
    // each tick only needs to re-run beginBackfill() (SEND_HISTORICAL_DATA + watchdog).
```
and (in `triggerPeriodicBackfill`'s doc):
```swift
    /// Periodic-timer callback: re-run the historical offload if the gate allows. beginBackfill()
    /// (SEND_HISTORICAL_DATA + arms the watchdog) is all that's needed — no high-freq-sync handshake.
```

- [ ] **Step 3: Build + run the full iOS suite**

Run: `cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -8`
Expected: `** TEST SUCCEEDED **` (no regressions; ~95 existing + the Task 1 tests).

- [ ] **Step 4: On-device verification (manual — the BLE glue has no unit seam)**

With the strap worn and the app installed (phone BT on, no Mac BLE session):
1. Launch the app, let it connect/bond and run one offload.
2. Confirm the server frontier advances: per the runbook, `curl … /v1/streams/hr?device=my-whoop…` newest
   ts should climb to ~now over a few minutes.
3. **Reinstall the app while connected** (the original data-loss trigger) and confirm the server frontier
   keeps advancing afterward (no permanent gap) — the strap must keep logging because we never strand it
   in high-freq. Record the before/after newest-ts in the commit message.

- [ ] **Step 5: Commit**

```bash
git add ios/OpenWhoop/BLE/BLEManager.swift
git commit -m "fix(ble): drop ENTER_HIGH_FREQ_SYNC offload primitive (data-loss root cause); defensive EXIT on connect"
```

---

## Task 3: Pure `StuckStrapDetector`

**Files:**
- Create: `ios/OpenWhoop/BLE/StuckStrapDetector.swift`
- Test: `ios/OpenWhoopTests/StuckStrapDetectorTests.swift`

**Context:** A stuck strap (rare after Task 2 — only a truly frozen RTC / firmware glitch) is "connected,
the strap *has* records newer than ours, but our *data* frontier isn't advancing." Two signals are
needed: our frontier = **max persisted HR sample ts** (NOT `strap_trim`, which keeps climbing on empty
ENDs while stuck), and the strap's **reported newest record** (from `GET_DATA_RANGE`). Comparing them is
what distinguishes genuinely stuck from merely off-wrist / caught-up (where the strap isn't ahead of us,
so no new data is *expected* — that must NOT flag "needs reboot"). This pure detector takes both.

- [ ] **Step 1: Write the failing test**

Create `ios/OpenWhoopTests/StuckStrapDetectorTests.swift`:

```swift
import XCTest
@testable import OpenWhoop

final class StuckStrapDetectorTests: XCTestCase {
    private func make() -> StuckStrapDetector { StuckStrapDetector(stuckAfterSeconds: 600, behindGapSeconds: 300) }

    // First observation seeds, never stuck.
    func testFirstObservationNotStuck() {
        var d = make()
        XCTAssertFalse(d.observe(strapNewestTs: 9000, ourFrontierTs: 1000, now: 5000))
    }
    // Caught up / off-wrist (strap not ahead of us) → never stuck, even after a long time.
    func testCaughtUpNotStuck() {
        var d = make()
        _ = d.observe(strapNewestTs: 1050, ourFrontierTs: 1000, now: 5000) // 50s behind < 300 gap
        XCTAssertFalse(d.observe(strapNewestTs: 1050, ourFrontierTs: 1000, now: 9000))
    }
    // Behind + frontier advancing → catching up, not stuck.
    func testCatchingUpNotStuck() {
        var d = make()
        _ = d.observe(strapNewestTs: 9000, ourFrontierTs: 1000, now: 5000)
        XCTAssertFalse(d.observe(strapNewestTs: 9000, ourFrontierTs: 4000, now: 5300)) // advanced
        XCTAssertFalse(d.observe(strapNewestTs: 9000, ourFrontierTs: 7000, now: 5600)) // advanced
    }
    // Behind + frontier frozen past the window → stuck.
    func testBehindAndFrozenIsStuck() {
        var d = make()
        _ = d.observe(strapNewestTs: 9000, ourFrontierTs: 1000, now: 5000)
        XCTAssertFalse(d.observe(strapNewestTs: 9000, ourFrontierTs: 1000, now: 5500)) // 500s < 600
        XCTAssertTrue(d.observe(strapNewestTs: 9000, ourFrontierTs: 1000, now: 5601))  // 601s → stuck
    }
    // Recovery: stuck, then frontier advances → clears.
    func testRecoveryClears() {
        var d = make()
        _ = d.observe(strapNewestTs: 9000, ourFrontierTs: 1000, now: 5000)
        XCTAssertTrue(d.observe(strapNewestTs: 9000, ourFrontierTs: 1000, now: 5601))
        XCTAssertFalse(d.observe(strapNewestTs: 9000, ourFrontierTs: 3000, now: 5700)) // advanced → clear
    }
    // nil inputs (no range / no data yet) → not stuck.
    func testNilNotStuck() {
        var d = make()
        XCTAssertFalse(d.observe(strapNewestTs: nil, ourFrontierTs: 1000, now: 9999))
        XCTAssertFalse(d.observe(strapNewestTs: 9000, ourFrontierTs: nil, now: 9999))
    }
}
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OpenWhoopTests/StuckStrapDetectorTests 2>&1 | tail -15`
Expected: FAIL — `cannot find 'StuckStrapDetector' in scope`.

- [ ] **Step 3: Implement**

Create `ios/OpenWhoop/BLE/StuckStrapDetector.swift`:

```swift
import Foundation

/// Detects a "stuck strap": the strap reports records newer than ours (`strapNewestTs` from
/// GET_DATA_RANGE) AND our biometric data frontier (`ourFrontierTs` = max persisted HR ts; NOT the
/// strap_trim cursor, which climbs on empty ENDs while stuck) hasn't advanced for `stuckAfterSeconds`.
/// Comparing the two is what separates genuinely stuck from off-wrist / caught-up (strap not ahead of
/// us → no new data expected → never stuck). Pure + value-typed so it's trivially testable.
struct StuckStrapDetector {
    let stuckAfterSeconds: TimeInterval
    /// How far ahead the strap must be (seconds) before "frozen frontier" counts as behind, not noise.
    let behindGapSeconds: Int
    private var lastFrontierTs: Int?
    private var lastAdvanceWall: TimeInterval?

    init(stuckAfterSeconds: TimeInterval, behindGapSeconds: Int = 300) {
        self.stuckAfterSeconds = stuckAfterSeconds
        self.behindGapSeconds = behindGapSeconds
    }

    /// `strapNewestTs` = newest record the strap reports having (GET_DATA_RANGE). `ourFrontierTs` =
    /// newest record we've persisted. Stuck = behind (strap ahead by > behindGapSeconds) AND our
    /// frontier hasn't advanced for >= stuckAfterSeconds. Advancing → healthy; not-behind → caught up.
    mutating func observe(strapNewestTs: Int?, ourFrontierTs: Int?, now: TimeInterval) -> Bool {
        guard let strapNewest = strapNewestTs, let frontier = ourFrontierTs else { return false }
        guard let last = lastFrontierTs else {           // first observation: seed, not stuck
            lastFrontierTs = frontier; lastAdvanceWall = now; return false
        }
        if frontier > last {                              // progressing → healthy, reset the clock
            lastFrontierTs = frontier; lastAdvanceWall = now; return false
        }
        let behind = (strapNewest - frontier) > behindGapSeconds
        if !behind {                                      // caught up / off-wrist → not stuck
            lastAdvanceWall = now; return false
        }
        return (now - (lastAdvanceWall ?? now)) >= stuckAfterSeconds  // behind AND frozen → stuck
    }
}
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OpenWhoopTests/StuckStrapDetectorTests 2>&1 | tail -8`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add ios/OpenWhoop/BLE/StuckStrapDetector.swift ios/OpenWhoopTests/StuckStrapDetectorTests.swift
git commit -m "feat(ios): pure StuckStrapDetector (data-frontier liveness)"
```

---

## Task 4: `WhoopStore.latestHRSampleTs(deviceId:)`

**Files:**
- Modify: `Packages/WhoopStore/Sources/WhoopStore/Reads.swift`
- Test: `Packages/WhoopStore/Tests/WhoopStoreTests/LatestSampleTests.swift`

**Context:** The watchdog needs the data frontier = max HR sample ts. No such query exists (`Reads.swift`
has range reads; `Cursors.swift` has the trim cursor, which is the wrong signal). Add a focused query.

- [ ] **Step 1: Write the failing test**

Create `Packages/WhoopStore/Tests/WhoopStoreTests/LatestSampleTests.swift`:

```swift
import XCTest
@testable import WhoopStore

final class LatestSampleTests: XCTestCase {
    func testLatestHRSampleTs() async throws {
        let store = try await WhoopStore(path: ":memory:")
        try await store.upsertDevice(id: "d", mac: nil, name: nil)
        // No rows yet → nil.
        let empty = try await store.latestHRSampleTs(deviceId: "d")
        XCTAssertNil(empty)
        // Insert HR rows at ts 100 and 250; latest = 250.
        var s = Streams(); s.hr = [HRSample(deviceId: "d", ts: 100, bpm: 60),
                                   HRSample(deviceId: "d", ts: 250, bpm: 61)]
        try await store.insert(s, deviceId: "d")
        let latest = try await store.latestHRSampleTs(deviceId: "d")
        XCTAssertEqual(latest, 250)
    }
}
```

(If `Streams`/`HRSample` initializer shapes differ, mirror the construction used in the existing
`StreamStore`/insert tests in `Packages/WhoopStore/Tests/WhoopStoreTests/` — match those exactly.)

- [ ] **Step 2: Run it to confirm it fails**

Run: `swift test --package-path Packages/WhoopStore --filter LatestSampleTests 2>&1 | tail -15`
Expected: FAIL — `value of type 'WhoopStore' has no member 'latestHRSampleTs'`.

- [ ] **Step 3: Implement**

In `Packages/WhoopStore/Sources/WhoopStore/Reads.swift`, add (match the existing `hrSamples` query
style + the actual HR table/column names used there):

```swift
    /// Max HR sample timestamp for a device, or nil if there are none. The biometric "data frontier"
    /// used by the stuck-strap watchdog (advances iff the strap is actually logging + offloading).
    public func latestHRSampleTs(deviceId: String) async throws -> Int? {
        try await dbQueue.read { db in
            try Int.fetchOne(db,
                sql: "SELECT MAX(ts) FROM hrSample WHERE deviceId = ?", arguments: [deviceId])
        }
    }
```

(Confirm the table name `hrSample` + column `ts`/`deviceId` against the existing `hrSamples` read in this
file and `Database.swift`; use whatever those use.)

- [ ] **Step 4: Run the test to confirm it passes**

Run: `swift test --package-path Packages/WhoopStore --filter LatestSampleTests 2>&1 | tail -8`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/WhoopStore/Sources/WhoopStore/Reads.swift Packages/WhoopStore/Tests/WhoopStoreTests/LatestSampleTests.swift
git commit -m "feat(store): latestHRSampleTs query (data frontier for the watchdog)"
```

---

## Task 5: Wire the watchdog into BLEManager + add the `strapNeedsReboot` surface

**Files:**
- Modify: `ios/OpenWhoop/Live/LiveState.swift` (add `strapNeedsReboot`)
- Modify: `ios/OpenWhoop/BLE/BLEManager.swift` (detector + liveness check on offload exit)

**Context:** After each offload completes (`exitBackfilling`), compare the strap's reported newest record
(`strapNewestTs`, parsed from `GET_DATA_RANGE`) against our data frontier (`latestHRSampleTs`) via
`StuckStrapDetector`. On stuck: attempt recovery (defensive high-freq EXIT + SET_CLOCK) and raise
`strapNeedsReboot`; otherwise clear it. Frequency expected ~never after Task 2 — this is insurance.

- [ ] **Step 1: Add the published surface to LiveState**

In `ios/OpenWhoop/Live/LiveState.swift`, add alongside the other `@Published` properties:

```swift
    /// True when the stuck-strap watchdog finds the strap has newer records than us but our frontier
    /// won't advance (likely needs a manual reboot; ~never after high-freq-sync removal). Banner-only.
    @Published public var strapNeedsReboot = false
```

- [ ] **Step 2: Add the detector, the strap-newest capture, and the liveness check to BLEManager**

In `ios/OpenWhoop/BLE/BLEManager.swift`, add properties near the other backfill state (~line 45):

```swift
    /// Safety-net detector: strap reports newer data than us AND our frontier frozen 10 min ⇒ flag for
    /// reboot. behindGapSeconds avoids false positives when off-wrist / caught up. Insurance only.
    private var stuckDetector = StuckStrapDetector(stuckAfterSeconds: 600, behindGapSeconds: 300)
    /// Newest record unix the strap reports having (from the GET_DATA_RANGE response); refreshed each
    /// offload. Compared against our frontier to tell "stuck" from "off-wrist/caught-up".
    private var strapNewestTs: Int?
```

Add this parser (next to `setClockPayload`):

```swift
    /// Newest plausible-unix marker in a GET_DATA_RANGE COMMAND_RESPONSE = the strap's newest stored
    /// record. Mirrors re/diagnose_biometrics.py: scan u32 LE words in the response body (data starts at
    /// frame[7], after [type,seq,cmd]), keep those in the unix range, return the max. nil if none.
    static func dataRangeNewestUnix(from frame: [UInt8]) -> Int? {
        guard frame.count > 7 else { return nil }
        let body = Array(frame[7...]); var newest: Int? = nil; var i = 0
        while i + 4 <= body.count {
            let w = Int(body[i]) | Int(body[i+1]) << 8 | Int(body[i+2]) << 16 | Int(body[i+3]) << 24
            if w >= 1_700_000_000 && w <= 1_900_000_000 { newest = max(newest ?? 0, w) }
            i += 4
        }
        return newest
    }
```

Capture it in `didUpdateValueFor`, inside the `for frame in reassembler.feed(bytes)` loop, right after
`router.handle(frame: frame)`:

```swift
                if frame.count > 6, frame[6] == WhoopCommand.getDataRange.rawValue,
                   let newest = BLEManager.dataRangeNewestUnix(from: frame) {
                    strapNewestTs = newest
                }
```

Refresh strap-newest each offload — in `beginBackfill()`, send `getDataRange` before `sendHistoricalData`:

```swift
        backfiller.begin()
        backfilling = true
        send(.getDataRange)   // refresh strapNewestTs so the liveness watchdog can judge "stuck"
        send(.sendHistoricalData, payload: [0x00], writeType: .withResponse)
        armBackfillTimeout()
```

Add the liveness check (next to `exitBackfilling`):

```swift
    /// After an offload, judge liveness: stuck = strap reports records newer than our frontier AND our
    /// frontier (max persisted HR ts) hasn't advanced for the detector window. Off-wrist / caught up
    /// (strap not ahead) is NOT stuck. On stuck: attempt recovery (defensive EXIT + SET_CLOCK) and raise
    /// the surface. Best-effort; runs off the WhoopStore actor.
    private func checkStrapLiveness() {
        guard let store = collector?.store else { return }
        let strapNewest = strapNewestTs
        Task { @MainActor in
            let frontier = try? await store.latestHRSampleTs(deviceId: deviceId)
            let stuck = stuckDetector.observe(strapNewestTs: strapNewest,
                                              ourFrontierTs: frontier ?? nil,
                                              now: Date().timeIntervalSince1970)
            state.strapNeedsReboot = stuck
            if stuck {
                log("Watchdog: behind + frontier frozen — recovery (exit high-freq + SET_CLOCK)")
                send(.exitHighFreqSync, payload: [0x00])
                send(.setClock, payload: BLEManager.setClockPayload())
            }
        }
    }
```

(If `Collector` does not expose its `store`, add a `func latestHRSampleTs() async -> Int?` passthrough on
`Collector` that forwards to its store and call that — keep the call site shape identical. Confirm by
reading `ios/OpenWhoop/Collect/Collector.swift`.)

Call it at the end of `exitBackfilling(reason:)`, after `pullFromServer()`:

```swift
        restoreFromServerIfNeeded()
        pullFromServer()
        checkStrapLiveness()   // safety-net: strap ahead of us AND our frontier frozen ⇒ stuck?
```

- [ ] **Step 3: Build + run the full iOS suite**

Run: `cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -8`
Expected: `** TEST SUCCEEDED **` (no regressions).

- [ ] **Step 4: Commit**

```bash
git add ios/OpenWhoop/Live/LiveState.swift ios/OpenWhoop/BLE/BLEManager.swift
git commit -m "feat(ble): stuck-strap watchdog → recovery + strapNeedsReboot surface"
```

---

## Task 6: Surface "needs reboot" in LiveView

**Files:**
- Modify: `ios/OpenWhoop/Live/LiveView.swift`

- [ ] **Step 1: Add a banner shown only when stuck**

In `ios/OpenWhoop/Live/LiveView.swift`, inside `LiveContentView`'s `body` VStack, add right after
`chips` (line ~50):

```swift
                if state.strapNeedsReboot {
                    Text("⚠️ WHOOP may need a reboot — it's connected but not logging new data. "
                         + "Put it on the charger briefly to reboot it.")
                        .font(.caption).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
```

- [ ] **Step 2: Build the app (UI-only change)**

Run: `cd ios && xcodegen generate && xcodebuild build -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add ios/OpenWhoop/Live/LiveView.swift
git commit -m "feat(ios): 'WHOOP may need a reboot' banner when the watchdog flags a stuck strap"
```

---

# PHASE P1 — Correctness + battery

## Task 7: Pure `ClockPolicy` (drift-gated SET_CLOCK)

**Files:**
- Create: `ios/OpenWhoop/Collect/ClockPolicy.swift`
- Test: `ios/OpenWhoopTests/ClockPolicyTests.swift`

**Context:** WHOOP sets the clock reactively (≥2 s drift / RtcLost), not every connect. Gratuitous
`SET_CLOCK` risks a discontinuity in derived historical timestamps. Pure decision helper.

- [ ] **Step 1: Write the failing test**

Create `ios/OpenWhoopTests/ClockPolicyTests.swift`:

```swift
import XCTest
@testable import OpenWhoop

final class ClockPolicyTests: XCTestCase {
    // In-sync clock (within threshold) → don't set.
    func testInSyncDoesNotSet() {
        XCTAssertFalse(ClockPolicy.shouldSetClock(deviceClock: 1_000_000, wallNow: 1_000_001,
                                                  driftThreshold: 2))
    }
    // Drifted beyond threshold → set.
    func testDriftedSets() {
        XCTAssertTrue(ClockPolicy.shouldSetClock(deviceClock: 1_000_000, wallNow: 1_000_010,
                                                 driftThreshold: 2))
    }
    // Frozen RTC (way off, e.g. Jan-2025 vs now) → set.
    func testFrozenRtcSets() {
        XCTAssertTrue(ClockPolicy.shouldSetClock(deviceClock: 1_736_000_000, wallNow: 1_779_000_000,
                                                 driftThreshold: 2))
    }
    // Negative drift (device ahead) beyond threshold → set.
    func testDeviceAheadSets() {
        XCTAssertTrue(ClockPolicy.shouldSetClock(deviceClock: 1_000_010, wallNow: 1_000_000,
                                                 driftThreshold: 2))
    }
}
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OpenWhoopTests/ClockPolicyTests 2>&1 | tail -15`
Expected: FAIL — `cannot find 'ClockPolicy' in scope`.

- [ ] **Step 3: Implement**

Create `ios/OpenWhoop/Collect/ClockPolicy.swift`:

```swift
import Foundation

/// Pure decision: should we SET_CLOCK on this connect? Mirrors WHOOP — set only when the strap's RTC
/// has drifted beyond a small threshold (or is frozen/way off), not blindly every connect. Avoids
/// gratuitous clock resets that could introduce discontinuities in derived historical timestamps.
enum ClockPolicy {
    /// `deviceClock` = the strap's current RTC reading (unix seconds, from GET_CLOCK). `wallNow` =
    /// phone wall time (unix seconds). Returns true if |drift| >= threshold.
    static func shouldSetClock(deviceClock: Int, wallNow: Int, driftThreshold: Int = 2) -> Bool {
        abs(wallNow - deviceClock) >= driftThreshold
    }
}
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OpenWhoopTests/ClockPolicyTests 2>&1 | tail -8`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add ios/OpenWhoop/Collect/ClockPolicy.swift ios/OpenWhoopTests/ClockPolicyTests.swift
git commit -m "feat(ios): pure ClockPolicy (drift-gated SET_CLOCK)"
```

---

## Task 8: Make SET_CLOCK conditional (defer to GET_CLOCK response)

**Files:**
- Modify: `ios/OpenWhoop/BLE/BLEManager.swift` (handshake + clock-correlation block in `didUpdateValueFor`)

**Context:** Currently the handshake sends `SET_CLOCK` unconditionally (Task 2 left it there) before the
`GET_CLOCK` response arrives. Move the decision to *after* the response: parse the device clock, and
`SET_CLOCK` only if `ClockPolicy.shouldSetClock`. `GET_CLOCK` is already sent (~line 613) and parsed for
correlation (~line 677–684); the device clock value is `parsed.parsed["clock"]?.intValue` (see
`ClockCorrelation`).

- [ ] **Step 1: Remove the unconditional SET_CLOCK from the handshake**

In the bond block, delete this line added in Task 2:

```swift
            send(.setClock, payload: BLEManager.setClockPayload())  // becomes conditional in Task 8
```

- [ ] **Step 2: Evaluate drift when the clock response lands**

In `didUpdateValueFor`, the clock-correlation block currently sets `clockRef` (~line 677–684). Extend it
so that when we capture the device clock we also apply the policy. Replace:

```swift
                if clockRef == nil {
                    let parsed = parseFrame(frame)
                    if let ref = ClockCorrelation.clockRef(from: parsed, wall: Int(Date().timeIntervalSince1970)) {
                        clockRef = ref
                        collector?.clockRef = ref
                        backfiller?.clockRef = ref
                        log("Clock correlated: device=\(ref.device) wall=\(ref.wall)")
                    }
                }
```
with:

```swift
                if clockRef == nil {
                    let parsed = parseFrame(frame)
                    if let ref = ClockCorrelation.clockRef(from: parsed, wall: Int(Date().timeIntervalSince1970)) {
                        clockRef = ref
                        collector?.clockRef = ref
                        backfiller?.clockRef = ref
                        log("Clock correlated: device=\(ref.device) wall=\(ref.wall)")
                        // Conditional SET_CLOCK (mirrors WHOOP): only when the strap RTC has drifted /
                        // is frozen — not blindly every connect. Offload doesn't depend on this (it uses
                        // clockRef for decoding); SET_CLOCK only keeps FUTURE logging timestamps sane.
                        if ClockPolicy.shouldSetClock(deviceClock: ref.device, wallNow: ref.wall) {
                            log("Clock drift detected — issuing SET_CLOCK")
                            send(.setClock, payload: BLEManager.setClockPayload())
                        }
                    }
                }
```

- [ ] **Step 3: Build + run the full iOS suite**

Run: `cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -8`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: On-device sanity**

Launch on-device; confirm in the log that on a normal reconnect (RTC already sane) NO `SET_CLOCK` is
issued ("Clock correlated" with no following "issuing SET_CLOCK"), and the offload still runs. The
server frontier still advances.

- [ ] **Step 5: Commit**

```bash
git add ios/OpenWhoop/BLE/BLEManager.swift
git commit -m "feat(ble): conditional drift-gated SET_CLOCK (only when the strap RTC drifted)"
```

---

## Task 9: Pure `BackfillPolicy` rate-limiter (incl. `.strap` trigger)

**Files:**
- Create: `ios/OpenWhoop/BLE/BackfillPolicy.swift`
- Test: `ios/OpenWhoopTests/BackfillPolicyTests.swift`

**Context:** WHOOP's cadence = 15-min periodic floor + event-triggered syncs + a rate-limiter. This is
the pure limiter (from the prior `whoop-sync-model.md` plan, extended with a `.strap` trigger for the
strap-as-clock event path in Task 12).

- [ ] **Step 1: Write the failing test**

Create `ios/OpenWhoopTests/BackfillPolicyTests.swift`:

```swift
import XCTest
@testable import OpenWhoop

final class BackfillPolicyTests: XCTestCase {
    func testNeverSyncedAlwaysRuns() {
        for t in [BackfillTrigger.periodic, .connect, .foreground, .manual, .strap] {
            XCTAssertTrue(BackfillPolicy.shouldRun(trigger: t, now: 1000, lastBackfillAt: nil))
        }
    }
    func testPeriodicFloor() {
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .periodic, now: 1000, lastBackfillAt: 200)) // 800s
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .periodic, now: 1000, lastBackfillAt: 100))  // 900s
    }
    func testEventFloor() {
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .connect, now: 1000, lastBackfillAt: 950))    // 50s
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .connect, now: 1000, lastBackfillAt: 910))     // 90s
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .strap, now: 1000, lastBackfillAt: 950))      // 50s
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .strap, now: 1000, lastBackfillAt: 905))       // 95s
    }
    func testManualAlwaysRuns() {
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .manual, now: 1000, lastBackfillAt: 999))
    }
}
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OpenWhoopTests/BackfillPolicyTests 2>&1 | tail -15`
Expected: FAIL — `cannot find 'BackfillPolicy'`/`'BackfillTrigger' in scope`.

- [ ] **Step 3: Implement**

Create `ios/OpenWhoop/BLE/BackfillPolicy.swift`:

```swift
import Foundation

/// What prompted a sync attempt. Mirrors WHOOP (15-min periodic floor + event-triggered "process now"
/// syncs + the strap's own prompt events + manual), adapted to iOS.
enum BackfillTrigger {
    case periodic    // the repeating timer while connected+bonded
    case connect     // a (re)connect / bond confirmation
    case foreground  // the app became active (scenePhase .active)
    case manual      // the user tapped "Sync now"
    case strap       // an incoming strap EVENT packet (WHOOP's HighFreqSyncPrompt analog)
}

/// Pure rate-limiter for historical-offload kicks. No BLE/store deps. Floors match WHOOP
/// (observed: ~15-min periodic + expedited event syncs).
enum BackfillPolicy {
    static let periodicFloorSeconds: TimeInterval = 900   // 15 min
    static let eventFloorSeconds: TimeInterval = 90       // absorbs reconnect-flaps / event bursts

    static func shouldRun(trigger: BackfillTrigger, now: TimeInterval,
                          lastBackfillAt: TimeInterval?) -> Bool {
        guard let last = lastBackfillAt else { return true }
        let elapsed = now - last
        switch trigger {
        case .manual:                        return true
        case .connect, .foreground, .strap:  return elapsed >= eventFloorSeconds
        case .periodic:                      return elapsed >= periodicFloorSeconds
        }
    }
}
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OpenWhoopTests/BackfillPolicyTests 2>&1 | tail -8`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add ios/OpenWhoop/BLE/BackfillPolicy.swift ios/OpenWhoopTests/BackfillPolicyTests.swift
git commit -m "feat(ios): pure BackfillPolicy rate-limiter (15-min floor + event/strap triggers)"
```

---

## Task 10: Route all offload kicks through `requestSync(_:)`; periodic floor 300→900

**Files:**
- Modify: `ios/OpenWhoop/BLE/BLEManager.swift`

**Context:** Funnel every offload kick through one rate-limited entry point keyed by trigger, backed by a
persisted watermark (UserDefaults, survives relaunch — like WHOOP's `DATA_SYNC_WORKER_LAST_WORK_TIME`).

- [ ] **Step 1: Add the watermark key + `requestSync(_:)`**

In `ios/OpenWhoop/BLE/BLEManager.swift`, add near the interval constants:

```swift
    /// Last-offload-attempt time (unix seconds), persisted so the rate limiter survives relaunch
    /// (matches WHOOP's DATA_SYNC_WORKER_LAST_WORK_TIME watermark).
    static let backfillLastAtKey = "backfillLastAt"
```

Add next to `triggerPeriodicBackfill()`:

```swift
    /// The single gated entry point for every historical-offload kick. Applies the connection/state
    /// gate AND the BackfillPolicy rate-limiter for the trigger. On a go: records the attempt time
    /// (persisted) and starts the offload.
    func requestSync(_ trigger: BackfillTrigger) {
        guard BLEManager.shouldRunPeriodicBackfill(
            connected: state.connected, bonded: state.bonded, backfilling: backfilling) else { return }
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.object(forKey: BLEManager.backfillLastAtKey) as? Double
        guard BackfillPolicy.shouldRun(trigger: trigger, now: now, lastBackfillAt: last) else {
            log("Backfill: \(trigger) skipped (rate-limited; last \(last.map { Int(now - $0) } ?? -1)s ago)")
            return
        }
        UserDefaults.standard.set(now, forKey: BLEManager.backfillLastAtKey)
        beginBackfill()
    }
```

- [ ] **Step 2: Bump the periodic interval + route the periodic timer through `requestSync`**

Change `static let backfillIntervalSeconds = 300` to:

```swift
    // The timer fires this often, but BackfillPolicy.periodicFloorSeconds is the real floor (a recent
    // event-triggered sync defers the next periodic tick). 900s = 15 min, matching WHOOP.
    static let backfillIntervalSeconds = 900
```

Replace the body of `triggerPeriodicBackfill()` with:

```swift
    private func triggerPeriodicBackfill() {
        requestSync(.periodic)
    }
```

- [ ] **Step 3: Route the connect kick through `requestSync(.connect)`**

In the bond block, replace `beginBackfill()` (the one after the handshake sends) with:

```swift
            requestSync(.connect)   // rate-limited; first connect always runs (no watermark yet)
```

- [ ] **Step 4: Build + run the full iOS suite**

Run: `cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -8`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ios/OpenWhoop/BLE/BLEManager.swift
git commit -m "feat(ble): rate-limited requestSync entry point; periodic floor 5->15min"
```

---

## Task 11: Foreground + manual sync triggers

**Files:**
- Modify: `ios/OpenWhoop/Live/LiveViewModel.swift`, `ios/OpenWhoop/Live/LiveView.swift`

- [ ] **Step 1: Add intents to LiveViewModel**

In `ios/OpenWhoop/Live/LiveViewModel.swift`, add next to `onEnterBackground()`:

```swift
    /// App became active — opportunistically sync (rate-limited; won't hammer on rapid toggles).
    public func enterForeground() { ble.requestSync(.foreground) }
    /// User tapped "Sync now" — force an offload regardless of the periodic floor.
    public func syncNow() { ble.requestSync(.manual) }
```

- [ ] **Step 2: Trigger on scenePhase `.active` + add a "Sync now" button**

In `ios/OpenWhoop/Live/LiveView.swift`, change the `onChange(of: scenePhase)` handler:

```swift
            .onChange(of: scenePhase) { phase in
                if phase == .background { model.onEnterBackground() }
                if phase == .active { model.enterForeground() }
            }
```

And in `LiveContentView.controls`, add a "Sync now" button to the second HStack:

```swift
                Button("Sync now") { model.syncNow() }.buttonStyle(.bordered)
```

- [ ] **Step 3: Build + run the full iOS suite**

Run: `cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -8`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add ios/OpenWhoop/Live/LiveViewModel.swift ios/OpenWhoop/Live/LiveView.swift
git commit -m "feat(ios): foreground + manual ('Sync now') sync triggers"
```

---

## Task 12: Strap-as-clock — EVENT packets trigger a sync

**Files:**
- Modify: `ios/OpenWhoop/BLE/FrameRouter.swift` (add a sync-trigger callback)
- Modify: `ios/OpenWhoop/BLE/BLEManager.swift` (set the callback → `requestSync(.strap)`)
- Test: `ios/OpenWhoopTests/FrameRouterSyncTriggerTests.swift`

**Context:** WHOOP's strap pushes event packets (`HighFreqSyncPromptEventPacket`, condition-report) that
drive catch-up. Today `FrameRouter` handles `EVENT` (type-48) only to set `state.lastEvent`. Wire those
events to a rate-limited `requestSync(.strap)`. The `.strap` 90 s floor (Task 9) prevents event storms
from hammering the radio, so triggering on any non-bond EVENT is safe.

- [ ] **Step 1: Write the failing test**

Create `ios/OpenWhoopTests/FrameRouterSyncTriggerTests.swift`:

```swift
import XCTest
@testable import OpenWhoop
@testable import WhoopProtocol

final class FrameRouterSyncTriggerTests: XCTestCase {
    @MainActor
    func testEventFrameFiresSyncTrigger() {
        let state = LiveState()
        let router = FrameRouter(state: state)
        var fired = 0
        router.onSyncTrigger = { fired += 1 }
        // Feed a real EVENT (type-48) fixture frame (reuse one from the existing FrameRouter tests /
        // fixtures — the same frame those tests use to assert state.lastEvent is set).
        router.handle(frame: Fixtures.eventFrame)
        XCTAssertEqual(fired, 1)
    }
}
```

(Use whatever EVENT fixture the existing `FrameRouter` tests use; if they inline bytes, inline the same
bytes here. The assertion is just that the callback fired on an EVENT frame.)

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OpenWhoopTests/FrameRouterSyncTriggerTests 2>&1 | tail -15`
Expected: FAIL — `value of type 'FrameRouter' has no member 'onSyncTrigger'`.

- [ ] **Step 3: Add the callback to FrameRouter**

In `ios/OpenWhoop/BLE/FrameRouter.swift`, add a property + fire it from the EVENT case:

```swift
    /// Called when the strap pushes an EVENT packet (WHOOP's strap-as-clock catch-up signal). The
    /// BLEManager wires this to a rate-limited requestSync(.strap). nil in pure/unit contexts.
    var onSyncTrigger: (() -> Void)?
```

In the `case "EVENT":` branch, after setting `state.lastEvent`, add:

```swift
                // Strap-pushed event = "I may have new data" → kick a (rate-limited) sync.
                onSyncTrigger?()
```

- [ ] **Step 4: Wire it in BLEManager**

In `ios/OpenWhoop/BLE/BLEManager.swift` `init` (both inits, after `self.router = FrameRouter(state:)`),
set the callback. Since `self` isn't fully initialized at the stored-property line, set it at the end of
`init` (after `super.init()` and the `central = …` assignment):

```swift
        router.onSyncTrigger = { [weak self] in self?.requestSync(.strap) }
```

- [ ] **Step 5: Run the test + full suite**

Run: `cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -8`
Expected: `** TEST SUCCEEDED **` (the new trigger test + no regressions).

- [ ] **Step 6: Commit**

```bash
git add ios/OpenWhoop/BLE/FrameRouter.swift ios/OpenWhoop/BLE/BLEManager.swift ios/OpenWhoopTests/FrameRouterSyncTriggerTests.swift
git commit -m "feat(ble): strap-as-clock — EVENT packets trigger a rate-limited sync"
```

---

## Task 13: Background-relaunch drain robustness

**Files:**
- Modify: `ios/OpenWhoop/BLE/BLEManager.swift` (`willRestoreState` ~513)

**Context:** On a CoreBluetooth state-restoration relaunch, `willRestoreState` re-discovers services, but
`bootstrapStore()` runs from `centralManagerDidUpdateState` (async). If the restored peripheral is
already connected, the first restored BLE data can arrive before the store is ready. Ensure the store is
bootstrapped from `willRestoreState` too (idempotent — `bootstrapStore` early-returns if the collector
exists).

- [ ] **Step 1: Bootstrap the store on restore**

In `willRestoreState`, right after `self.peripheral = p` / before the `p.state == .connected` branch,
add:

```swift
        // Ensure the store is ready before restored BLE data arrives (idempotent; no-op if already built).
        Task { @MainActor in await bootstrapStore() }
```

- [ ] **Step 2: Build + run the full iOS suite**

Run: `cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -8`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add ios/OpenWhoop/BLE/BLEManager.swift
git commit -m "fix(ble): bootstrap the store on state-restoration relaunch (avoid first-data race)"
```

---

# PHASE P2 — Freshness / UX (force-quit nudge + tile)

## Task 14: Pure `StalenessPolicy` + a persisted last-synced watermark

**Files:**
- Create: `ios/OpenWhoop/Sync/StalenessPolicy.swift`
- Test: `ios/OpenWhoopTests/StalenessPolicyTests.swift`
- Modify: `ios/OpenWhoop/Live/LiveState.swift` (add `lastSyncedAt`), `ios/OpenWhoop/BLE/BLEManager.swift`
  (stamp it on a successful offload)

**Context:** "Caught up / catching up" mirrors WHOOP's tile (>1 h behind ⇒ catching up). Staleness also
drives the local nudge (Task 16). Pure mapping from (lastSyncedAt, now) → tile state.

- [ ] **Step 1: Write the failing test**

Create `ios/OpenWhoopTests/StalenessPolicyTests.swift`:

```swift
import XCTest
@testable import OpenWhoop

final class StalenessPolicyTests: XCTestCase {
    func testNeverSynced() {
        XCTAssertEqual(StalenessPolicy.state(lastSyncedAt: nil, now: 10_000), .neverSynced)
    }
    func testCaughtUpWithinOneHour() {
        XCTAssertEqual(StalenessPolicy.state(lastSyncedAt: 10_000 - 1800, now: 10_000), .caughtUp) // 30m
    }
    func testCatchingUpPastOneHour() {
        XCTAssertEqual(StalenessPolicy.state(lastSyncedAt: 10_000 - 4000, now: 10_000), .catchingUp) // 66m
    }
    func testStalePastNudgeThreshold() {
        // 6h = 21600s. WHOOP tile would say catching-up; our nudge threshold = .stale.
        XCTAssertEqual(StalenessPolicy.state(lastSyncedAt: 10_000 - 22_000, now: 10_000), .stale)
    }
}
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OpenWhoopTests/StalenessPolicyTests 2>&1 | tail -15`
Expected: FAIL — `cannot find 'StalenessPolicy' in scope`.

- [ ] **Step 3: Implement**

Create `ios/OpenWhoop/Sync/StalenessPolicy.swift`:

```swift
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
```

- [ ] **Step 4: Persist `lastSyncedAt` + expose on LiveState**

In `ios/OpenWhoop/Live/LiveState.swift` add:

```swift
    /// Wall time (unix seconds) of the last successfully-completed offload (a sync, even if nothing new
    /// came — i.e. caught up). Drives the sync tile + the staleness nudge.
    @Published public var lastSyncedAt: TimeInterval?
```

In `ios/OpenWhoop/BLE/BLEManager.swift`, stamp it in `exitBackfilling(reason:)` on a clean drain
(`reason == "HISTORY_COMPLETE"`, NOT a timeout — a timeout means we did NOT catch up), right before the
`checkStrapLiveness()` call added in Task 5:

```swift
        if reason == "HISTORY_COMPLETE" {
            state.lastSyncedAt = Date().timeIntervalSince1970
            UserDefaults.standard.set(state.lastSyncedAt, forKey: "lastSyncedAt")
        }
        checkStrapLiveness()
```

Load the persisted value on init (after `super.init()`):

```swift
        state.lastSyncedAt = UserDefaults.standard.object(forKey: "lastSyncedAt") as? Double
```

- [ ] **Step 5: Run the test + full suite**

Run: `cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -8`
Expected: `** TEST SUCCEEDED **` (4 new + no regressions).

- [ ] **Step 6: Commit**

```bash
git add ios/OpenWhoop/Sync/StalenessPolicy.swift ios/OpenWhoopTests/StalenessPolicyTests.swift ios/OpenWhoop/Live/LiveState.swift ios/OpenWhoop/BLE/BLEManager.swift
git commit -m "feat(ios): StalenessPolicy + persisted lastSyncedAt watermark"
```

---

## Task 15: Sync-status tile in LiveView

**Files:**
- Modify: `ios/OpenWhoop/Live/LiveView.swift`

- [ ] **Step 1: Add a tile driven by StalenessPolicy**

In `LiveContentView`, add a computed view and render it after `chips`:

```swift
    private var syncTile: some View {
        let s = StalenessPolicy.state(lastSyncedAt: state.lastSyncedAt, now: Date().timeIntervalSince1970)
        let (text, color): (String, Color) = {
            switch s {
            case .neverSynced: return ("Never synced", .gray)
            case .caughtUp:    return ("Caught up", .green)
            case .catchingUp:  return ("Catching up…", .orange)
            case .stale:       return ("Sync stale — open kept the app foregrounded to catch up", .red)
            }
        }()
        return Text(state.lastSyncedAt.map { ts in
            "\(text) · synced \(Int((Date().timeIntervalSince1970 - ts) / 60))m ago"
        } ?? text)
            .font(.caption).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
```

Render it (after `chips`, before the storage summary):

```swift
                chips
                syncTile
```

- [ ] **Step 2: Build the app**

Run: `cd ios && xcodegen generate && xcodebuild build -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add ios/OpenWhoop/Live/LiveView.swift
git commit -m "feat(ios): sync-status tile (caught up / catching up · synced Xm ago)"
```

---

## Task 16: Local schedule-ahead "tap to sync" nudge

**Files:**
- Create: `ios/OpenWhoop/Sync/SyncNudge.swift`
- Modify: `ios/OpenWhoop/Live/LiveViewModel.swift` (schedule on background; cancel on sync)

**Context:** The only thing that defeats iOS's force-quit wall is a notification the user taps. Schedule
one local notification for `staleAfterSeconds` (6 h) out whenever we background or sync; reschedule on
every successful sync so it only fires after a real stall; tapping it relaunches the app (clears the
force-quit flag) → catch-up runs. Single notification id → no 64-notification-limit concern. Reuses
`UserNotifications` (cf. `BatteryAlertMonitor`).

- [ ] **Step 1: Implement the scheduler**

Create `ios/OpenWhoop/Sync/SyncNudge.swift`:

```swift
import Foundation
import UserNotifications

/// Local "tap to sync" nudge using the schedule-ahead-then-cancel pattern. iOS won't background-launch a
/// force-quit app, and a silent push can't wake one either — only a user tap clears the force-quit flag.
/// So we keep one pending local notification ~`afterSeconds` in the future; every successful sync pushes
/// it forward, so it fires ONLY after a genuine stall (force-quit / away / stuck).
enum SyncNudge {
    static let id = "sync-stale-nudge"

    /// Request permission (call when enabling; safe to call repeatedly). Mirrors BatteryAlertMonitor.
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// (Re)schedule the single nudge `afterSeconds` from now, replacing any pending one.
    static func reschedule(afterSeconds: TimeInterval = StalenessPolicy.staleAfterSeconds) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        let content = UNMutableNotificationContent()
        content.title = "OpenWhoop hasn't synced in a while"
        content.body = "Open OpenWhoop to catch up your WHOOP data."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: afterSeconds, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    /// Cancel the pending nudge (e.g. on a fresh successful sync, before re-scheduling).
    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
}
```

- [ ] **Step 2: Wire scheduling into the lifecycle**

In `ios/OpenWhoop/Live/LiveViewModel.swift`:
- In `init`, request authorization once: `SyncNudge.requestAuthorization()`.
- In `onEnterBackground()`, (re)schedule so a force-quit-from-background still fires later:

```swift
    public func onEnterBackground() {
        ble.pruneRaw()
        SyncNudge.reschedule()
    }
```

- Add an observer so a successful sync pushes the nudge forward. The simplest seam: have the VM observe
  `state.$lastSyncedAt` (Combine) and reschedule on change. In `init`, after `state` is set:

```swift
        s.$lastSyncedAt
            .compactMap { $0 }
            .sink { _ in SyncNudge.reschedule() }
            .store(in: &cancellables)
```

Add the store: `private var cancellables = Set<AnyCancellable>()` (import Combine is already present).

- [ ] **Step 3: Build + run the full iOS suite**

Run: `cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -8`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: On-device verification**

Foreground the app and sync (tile shows "Caught up · synced 0m ago"). Background it; force-quit it; after
the (test-shortened, e.g. 120 s) interval, confirm the "hasn't synced" notification fires and tapping it
relaunches the app → it reconnects + catches up. (Use a short `afterSeconds` for the test, then restore
6 h.)

- [ ] **Step 5: Commit**

```bash
git add ios/OpenWhoop/Sync/SyncNudge.swift ios/OpenWhoop/Live/LiveViewModel.swift
git commit -m "feat(ios): local schedule-ahead 'tap to sync' nudge (defeats the force-quit wall)"
```

---

## Task 17: Update the debugging runbook

**Files:**
- Modify: `docs/specs/2026-05-25-debugging-runbook.md`

- [ ] **Step 1: Document the new model**

Update the backfill-cadence + handshake notes: offload uses plain `SEND_HISTORICAL_DATA` (no
high-freq-sync; `EXIT_HIGH_FREQ_SYNC` sent defensively on connect); 15-min periodic floor +
connect/foreground/manual/strap triggers via `BackfillPolicy` + `requestSync(_:)`; conditional
drift-gated `SET_CLOCK`; the stuck-strap watchdog (`StuckStrapDetector` → `strapNeedsReboot`); the
staleness tile + local nudge. Note `re/test_offload_without_highfreq.py` as the validator. Mark gotcha #1
(high-freq-sync interrupts logging) as RESOLVED in-app (we no longer enter it).

- [ ] **Step 2: Commit**

```bash
git add docs/specs/2026-05-25-debugging-runbook.md
git commit -m "docs(runbook): sync-hardening model (no high-freq-sync, watchdog, cadence, nudge)"
```

---

## Self-review (done while writing)

- **Spec coverage:** Pillar 1 = Tasks 1–2 ✓; Pillar 2 = Tasks 3–6 ✓; Pillar 3 = Tasks 7–8 ✓; Pillar 4 =
  Tasks 9–12 (rate-limiter, requestSync+floor, foreground/manual, strap-as-clock) ✓; Pillar 5 = Task 13 ✓;
  Pillar 6 = Tasks 14–16 (StalenessPolicy+watermark, tile, local nudge) ✓; runbook = Task 17 ✓. APNs
  server-push intentionally OUT (deferred, per the resolved decisions). No `BGProcessingTask` (resolved).
- **Type consistency:** `BackfillTrigger` (periodic/connect/foreground/manual/strap) defined in Task 9,
  consumed by `requestSync` (Task 10) + `LiveViewModel` (Task 11) + `FrameRouter` callback (Task 12);
  `StuckStrapDetector.observe` (Task 3) consumed in Task 5; `latestHRSampleTs` (Task 4) consumed in
  Tasks 5 + 14; `ClockPolicy.shouldSetClock` (Task 7) consumed in Task 8; `StalenessPolicy.state` /
  `SyncFreshness` (Task 14) consumed in Tasks 15–16; `state.strapNeedsReboot` (Task 5) consumed in Task 6;
  `state.lastSyncedAt` (Task 14) consumed in Tasks 15–16.
- **Verification honesty:** pure logic is TDD'd (Tasks 1,3,4,7,9,12,14); CoreBluetooth-glue tasks
  (2,5,8,10,13) verify by build + full suite + explicit on-device steps — no fabricated unit tests for an
  untestable seam (the repo's established pattern).
- **Assumptions to confirm at execution time (named, not placeholders):** the exact `hrSample` table/
  column names (Task 4 — mirror the existing `hrSamples` read), `Collector.store` exposure (Task 5 —
  add a passthrough if absent), the EVENT fixture frame (Task 12 — reuse the existing FrameRouter test
  fixture), and `Streams`/`HRSample` init shapes (Task 4 — mirror existing store tests). Each task says
  exactly what to check and what to write.
