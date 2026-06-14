# WHOOP-Style Sync Cadence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended)
> or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`)
> syntax. Commit after every task. Co-author trailer:
> `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.

**Goal:** Replace our fixed 5-minute historical-offload poll with WHOOP's model — a 15-minute periodic
floor + event-triggered syncs (connect / foreground / manual) + a rate-limiter — to cut strap-radio
wake-ups ~3× and match WHOOP's battery profile, without losing freshness when it matters.

**Architecture:** Today `BLEManager` kicks `beginBackfill()` on connect and again every
`backfillIntervalSeconds = 300`s via a repeating timer, gated only by `shouldRunPeriodicBackfill`
(connected+bonded+not-already-backfilling). We add a pure **`BackfillPolicy`** rate-limiter keyed by a
**trigger** (`periodic`/`connect`/`foreground`/`manual`) and a persisted **last-sync watermark**
(UserDefaults, survives relaunch). All offload kicks route through one `requestSync(trigger)` method
that consults the policy. Periodic ticks are floored at 15 min (matching an observed ~15-min periodic sync); connect/foreground/manual may sync sooner but are
floored at 90 s to absorb reconnect-flaps; manual always runs.

**Tech Stack:** Swift 6.3 / SwiftUI / CoreBluetooth (iOS app, `ios/OpenWhoop/`). Tests: XCTest via
`xcodebuild` on the iPhone 17 simulator.

**Reference (the behavior we're mirroring):** the official app's observed sync cadence —
a ~15-min periodic sync with ~5-min flex, plus expedited one-time syncs on triggers, and a
rate-limited last-work-time watermark. See `docs/specs/2026-05-25-debugging-runbook.md` §
backfill-cadence.

**iOS adaptation / scope:** iOS has no WorkManager. We map WHOOP's pieces to iOS primitives:
- *15-min periodic* → our repeating `DispatchSourceTimer` while connected, floored by the policy.
- *event-triggered "process now"* → `connect` (bond) + `foreground` (scenePhase `.active`) + `manual`
  (a "Sync now" button) triggers.
- *rate-limiting watermark* → a persisted `backfillLastAt` UserDefaults key.
- *foreground continuous service* → not applicable on iOS (CoreBluetooth runs backgrounded); the
  connect/foreground triggers + periodic floor cover it.
- **PHASE 2 (brainstorm at execution time — NOT pre-decided):** APNs/server "sync now" push,
  `BGTaskScheduler` periodic for the fully-killed app, and server-tunable floors. These have real
  design forks, so the plan stops at a **brainstorming gate** for each (Tasks 5–7) rather than
  deferring or guessing — the implementer runs `superpowers:brainstorming` with the user to settle
  intent + tradeoffs, then writes and executes the concrete steps from that outcome.

---

## File structure

- Create `ios/OpenWhoop/BLE/BackfillPolicy.swift` — the `BackfillTrigger` enum + pure `BackfillPolicy`
  rate-limiter (no BLE/store deps; trivially unit-testable).
- Modify `ios/OpenWhoop/BLE/BLEManager.swift` — add `requestSync(_:)` (the single gated entry point) +
  the persisted watermark; route the periodic timer + connect through it; bump the periodic interval to
  15 min.
- Modify `ios/OpenWhoop/Live/LiveViewModel.swift` — `enterForeground()` + `syncNow()` that call
  `ble.requestSync(...)`.
- Modify `ios/OpenWhoop/Live/LiveView.swift` — call `model.enterForeground()` on scenePhase `.active`;
  add a "Sync now" button wired to `model.syncNow()`.
- Create `ios/OpenWhoopTests/BackfillPolicyTests.swift` — pure policy tests.

---

## Task 1: Pure `BackfillPolicy` rate-limiter

**Files:**
- Create: `ios/OpenWhoop/BLE/BackfillPolicy.swift`
- Test: `ios/OpenWhoopTests/BackfillPolicyTests.swift`

- [ ] **Step 1: Write the failing test**

Create `ios/OpenWhoopTests/BackfillPolicyTests.swift`:

```swift
import XCTest
@testable import OpenWhoop

final class BackfillPolicyTests: XCTestCase {
    // Never synced this launch → any trigger runs.
    func testNeverSyncedAlwaysRuns() {
        for t in [BackfillTrigger.periodic, .connect, .foreground, .manual] {
            XCTAssertTrue(BackfillPolicy.shouldRun(trigger: t, now: 1000, lastBackfillAt: nil))
        }
    }
    // Periodic respects the 15-min (900s) floor.
    func testPeriodicFloor() {
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .periodic, now: 1000, lastBackfillAt: 200)) // 800s
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .periodic, now: 1000, lastBackfillAt: 100))  // 900s
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .periodic, now: 1000, lastBackfillAt: 50))   // 950s
    }
    // Connect/foreground use the short 90s event floor.
    func testEventFloor() {
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .connect, now: 1000, lastBackfillAt: 950))    // 50s
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .connect, now: 1000, lastBackfillAt: 910))     // 90s
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .foreground, now: 1000, lastBackfillAt: 950)) // 50s
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .foreground, now: 1000, lastBackfillAt: 900))  // 100s
    }
    // Manual always runs (user explicitly asked).
    func testManualAlwaysRuns() {
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .manual, now: 1000, lastBackfillAt: 999))
    }
}
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OpenWhoopTests/BackfillPolicyTests 2>&1 | tail -15`
Expected: FAIL — `cannot find 'BackfillPolicy'`/`'BackfillTrigger' in scope`.

- [ ] **Step 3: Implement `BackfillPolicy`**

Create `ios/OpenWhoop/BLE/BackfillPolicy.swift`:

```swift
import Foundation

/// What prompted a sync attempt. Mirrors WHOOP's model (a 15-min periodic floor + event-triggered
/// "process now" syncs + manual), adapted to iOS: a rate-limiter decides whether the historical
/// offload actually runs for a given trigger.
enum BackfillTrigger {
    case periodic    // the repeating timer while connected+bonded
    case connect     // a (re)connect / bond confirmation
    case foreground  // the app became active (scenePhase .active)
    case manual      // the user tapped "Sync now"
}

/// Pure rate-limiter for historical-offload kicks. No BLE/store deps so it's trivially testable.
/// Floors chosen to match the observed app cadence (~15-min periodic; expedited event syncs).
enum BackfillPolicy {
    /// Periodic floor — matches WHOOP's 15-min PeriodicWorkRequest. The dominant battery lever:
    /// ~3× fewer strap-radio wake-ups than our old 5-min poll.
    static let periodicFloorSeconds: TimeInterval = 900
    /// Event-trigger floor — connect/foreground may sync sooner than the periodic floor, but not
    /// within this window, so a reconnect-flap or rapid foreground/background toggle can't hammer
    /// the strap radio.
    static let eventFloorSeconds: TimeInterval = 90

    /// Should a backfill run now, given the trigger and the last successful-attempt time?
    /// `lastBackfillAt`/`now` are unix seconds; `nil` last means "never synced" → always run.
    static func shouldRun(trigger: BackfillTrigger, now: TimeInterval,
                          lastBackfillAt: TimeInterval?) -> Bool {
        guard let last = lastBackfillAt else { return true }
        let elapsed = now - last
        switch trigger {
        case .manual:               return true
        case .connect, .foreground: return elapsed >= eventFloorSeconds
        case .periodic:             return elapsed >= periodicFloorSeconds
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
git commit -m "feat(ios): pure BackfillPolicy rate-limiter (15-min periodic floor + event triggers)"
```

---

## Task 2: Route all offload kicks through a rate-limited `requestSync(_:)`

**Files:**
- Modify: `ios/OpenWhoop/BLE/BLEManager.swift` (add `requestSync`, watermark; change the periodic
  timer interval + handler; change the connect kick)

**Context:** Currently the periodic `DispatchSourceTimer` fires every `backfillIntervalSeconds=300`s →
`triggerPeriodicBackfill()` → (gate) → `beginBackfill()`; and the bond block calls `beginBackfill()`
once per connect (guarded by `backfillStarted`). `BLEManager` is `@MainActor`. It does NOT hold the
`WhoopStore` directly, so the watermark is persisted in **UserDefaults** (same pattern as the existing
`enableRawCapture` key) — which also survives app relaunch, giving true cross-launch rate-limiting like
WHOOP's `DATA_SYNC_WORKER_LAST_WORK_TIME`. Keep `shouldRunPeriodicBackfill` (the connection/state gate);
the policy is layered on top of it.

- [ ] **Step 1: Add the watermark key + `requestSync(_:)`**

In `ios/OpenWhoop/BLE/BLEManager.swift`, add near the other `static let` interval constants
(around `uploadIntervalSeconds` / `backfillIntervalSeconds`):

```swift
    /// UserDefaults key for the last-offload-attempt time (unix seconds). Persisted so the rate
    /// limiter survives app relaunches (matches WHOOP's DATA_SYNC_WORKER_LAST_WORK_TIME watermark).
    static let backfillLastAtKey = "backfillLastAt"
```

Add this method next to `triggerPeriodicBackfill()`:

```swift
    /// The single gated entry point for every historical-offload kick. Applies the connection/state
    /// gate (shouldRunPeriodicBackfill) AND the BackfillPolicy rate-limiter for the given trigger.
    /// On a go: records the attempt time (persisted) and starts the offload. Replaces direct
    /// beginBackfill() calls so periodic/connect/foreground/manual all share one rate limiter.
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

- [ ] **Step 2: Point the periodic timer at the 15-min floor + route through `requestSync`**

Change the interval constant — find:

```swift
    static let backfillIntervalSeconds = 300
```
Replace with:
```swift
    // Periodic offload cadence — the timer fires this often, but BackfillPolicy.periodicFloorSeconds
    // is the real floor (a recent event-triggered sync defers the next periodic tick). 900s = 15 min,
    // matching WHOOP's PeriodicWorkRequest(15, MINUTES).
    static let backfillIntervalSeconds = 900
```

Then change `triggerPeriodicBackfill()` to delegate to the rate limiter. Replace the whole body of
`triggerPeriodicBackfill()` with:

```swift
    private func triggerPeriodicBackfill() {
        requestSync(.periodic)
    }
```

(The connection/state gate now lives inside `requestSync`, so the old inline
`shouldRunPeriodicBackfill` check in this method is removed — `requestSync` performs it.)

- [ ] **Step 3: Route the connect kick through `requestSync(.connect)`**

In the bond block (the `if !backfillStarted { … }` section, ~line 620), find the call to
`beginBackfill()` (it sits after the handshake sends — `setClock`, `sendR10R11Realtime`,
`enterHighFreqSync`) and replace just that one call:

```swift
            beginBackfill()
```
with:
```swift
            requestSync(.connect)   // rate-limited; first connect always runs (no watermark yet)
```

Leave the handshake sends, `startUploadTimer()`, and `startBackfillTimer()` as-is. (`beginBackfill()`
remains a private method — it's now only called by `requestSync`.)

- [ ] **Step 4: Build + run the full iOS suite**

Run: `cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -8`
Expected: `** TEST SUCCEEDED **`, all tests pass (the BackfillPolicy suite + the existing ~95; no regressions). The SourceKit "No such module" diagnostics outside an xcodebuild context are noise — the xcodebuild result is the source of truth.

- [ ] **Step 5: Commit**

```bash
git add ios/OpenWhoop/BLE/BLEManager.swift
git commit -m "feat(ios): route offload kicks through rate-limited requestSync; periodic floor 5->15min"
```

---

## Task 3: Foreground + manual sync triggers

**Files:**
- Modify: `ios/OpenWhoop/Live/LiveViewModel.swift` (expose `enterForeground()` + `syncNow()`)
- Modify: `ios/OpenWhoop/Live/LiveView.swift` (call `enterForeground()` on scenePhase `.active`; add a
  "Sync now" button)

**Context:** `LiveViewModel` owns the `BLEManager` (`private let ble: BLEManager` — used by
`captureActivitySample` which calls `ble.captureRawAccel`). `LiveView` already observes `scenePhase`
(`.onChange(of: scenePhase)`: `.background → model.onEnterBackground()`, active → `model.refreshStorage()`).
`requestSync` is internal (no access modifier), callable from `LiveViewModel` in the same module.

- [ ] **Step 1: Add `enterForeground()` + `syncNow()` to `LiveViewModel`**

In `ios/OpenWhoop/Live/LiveViewModel.swift`, add (next to `captureActivitySample`):

```swift
    /// App became active — opportunistically sync (rate-limited; won't hammer on rapid toggles).
    func enterForeground() { ble.requestSync(.foreground) }

    /// User tapped "Sync now" — force an offload regardless of the periodic floor.
    func syncNow() { ble.requestSync(.manual) }
```

- [ ] **Step 2: Call `enterForeground()` when the app becomes active**

In `ios/OpenWhoop/Live/LiveView.swift`, in the `.onChange(of: scenePhase)` handler, find the active
branch (the one that calls `model.refreshStorage()`) and add the foreground sync alongside it:

```swift
                if phase == .active {
                    model.refreshStorage()
                    model.enterForeground()
                }
```
(Match the existing structure — if the active branch isn't an explicit `if phase == .active`, add one;
keep the existing `.background → model.onEnterBackground()` branch unchanged.)

- [ ] **Step 3: Add a "Sync now" button**

In `ios/OpenWhoop/Live/LiveView.swift`, add a button in a visible control area (e.g. near the existing
storage summary / research section — match the surrounding SwiftUI style):

```swift
            Button("Sync now") { model.syncNow() }
                .buttonStyle(.bordered)
```

- [ ] **Step 4: Build + run the full iOS suite**

Run: `cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -8`
Expected: `** TEST SUCCEEDED **`, all pass.

- [ ] **Step 5: Commit**

```bash
git add ios/OpenWhoop/Live/LiveViewModel.swift ios/OpenWhoop/Live/LiveView.swift
git commit -m "feat(ios): foreground + manual ('Sync now') backfill triggers"
```

---

## Task 4: Update the debugging runbook (cadence section)

**Files:**
- Modify: `docs/specs/2026-05-25-debugging-runbook.md`

- [ ] **Step 1: Document the new cadence**

Update the backfill-cadence note to: periodic floor 15 min (`BackfillPolicy.periodicFloorSeconds`),
event triggers (connect/foreground/manual) floored at 90 s (`eventFloorSeconds`), watermark in
UserDefaults `backfillLastAt`. Note it mirrors the app's observed ~15-min periodic cadence +
expedited event syncs, and that `BLEManager.requestSync(_:)` is the single gated entry point.

- [ ] **Step 2: Commit**

```bash
git add docs/specs/2026-05-25-debugging-runbook.md
git commit -m "docs: runbook — new WHOOP-style sync cadence (15-min floor + event triggers)"
```

---

## Phase 2 — brainstorm, then build (each task opens with a design session)

These complete WHOOP parity but each has genuine design forks, so **do NOT implement before
brainstorming.** Each task STARTS with **REQUIRED SUB-SKILL: superpowers:brainstorming** with the user
to settle intent + tradeoffs; the open questions listed are the *starting agenda*, not decisions. Only
after the brainstorm does the implementer write the concrete bite-sized steps (and run them TDD). These
build on Tasks 1–3 (the rate-limiter, `requestSync(_:)`, the floors) and should reuse them — e.g. a new
background trigger calls `requestSync(.periodic)` so it shares the same rate limiter.

### Task 5: Background sync for the fully-killed app (`BGTaskScheduler`)

- [ ] **Step 1: Brainstorm** (superpowers:brainstorming). Agenda / open questions:
  - Do we even need killed-app sync, or does CoreBluetooth **state restoration** (iOS already relaunches
    us on the strap's BLE events) cover it well enough in practice? Quantify the gap first.
  - `BGAppRefreshTask` vs `BGProcessingTask` (the latter allows longer/while-charging work).
  - Acceptance that iOS controls the cadence (often hours, throttled by app usage) — is a best-effort
    supplement worth the wiring?
  - How it composes with the 15-min periodic floor + the rate-limiter (it should just call
    `requestSync(.periodic)`, sharing the watermark).
  - Entitlements + `Info.plist` (`BGTaskSchedulerPermittedIdentifiers`), and how to *test* it (Xcode
    debugger `_simulateLaunchForTaskWithIdentifier` / simulate-background-fetch).
- [ ] **Step 2:** From the brainstorm outcome, write the concrete tasks (register the task identifier,
  schedule on background-entry, handler → `requestSync(.periodic)` + re-schedule) and implement TDD.
- [ ] **Step 3:** Build + full iOS suite green. Commit.

### Task 6: Server-triggered "sync now" push (APNs)

- [ ] **Step 1: Brainstorm** (superpowers:brainstorming). Agenda / open questions:
  - Is a *remote* "sync now" actually wanted for a personal single-strap setup, or do
    connect/foreground/manual already cover "sync when I pick up my phone"? (WHOOP needs it at fleet
    scale; we may not.)
  - APNs setup cost: auth key/cert, device-token registration, and the **home-server** side that sends
    the push. Worth it?
  - Mechanism: a **silent** (`content-available`) push → wake → `requestSync(.manual)`. Token
    storage/security; how it interacts with the rate-limiter.
- [ ] **Step 2:** From the outcome, write the concrete tasks (iOS: register for remote notifications +
  handle silent push → `requestSync`; server: a push-send path + APNs creds) and implement.
- [ ] **Step 3:** Build + suites (iOS + ingest) green. Commit.

### Task 7: Server-tunable rate-limit floors

- [ ] **Step 1: Brainstorm** (superpowers:brainstorming). Agenda / open questions:
  - Do we want remote tuning for one device, or is editing the `BackfillPolicy` constant + rebuild fine?
    (WHOOP gates this behind the `strap-sync-rate-limiting` feature flag for live, fleet-wide control.)
  - Where the floors live if we do it: `AppConfig` (xcconfig/Info.plist), a small server config endpoint
    the app fetches, or the existing config mechanism — and how/when the app refreshes them.
  - Safe defaults + fallback when the config source is unreachable (must never disable rate-limiting).
- [ ] **Step 2:** From the outcome, move `periodicFloorSeconds`/`eventFloorSeconds` out of the
  `BackfillPolicy` constants into the chosen source (keeping the pure `shouldRun` signature) and implement.
- [ ] **Step 3:** Build + suites green. Commit.

---

## Self-review (done while writing)
- **Spec coverage:** 15-min periodic floor (Task 2) ✓; event-triggered connect (Task 2) + foreground +
  manual (Task 3) ✓; rate-limiter + persisted watermark (Tasks 1–2) ✓; runbook (Task 4) ✓;
  push/BGTask/server-tunable are **brainstorm-gated Phase-2 tasks (5–7)**, not silently deferred —
  each opens with a superpowers:brainstorming session before any build ✓.
- **Type consistency:** `BackfillTrigger` (periodic/connect/foreground/manual) + `BackfillPolicy.shouldRun`
  defined in Task 1, consumed by `requestSync` (Task 2) and `LiveViewModel` (Task 3); `requestSync(_:)`
  is internal (callable from LiveViewModel same-module); `backfillLastAtKey`/`backfillIntervalSeconds`
  used consistently.
- **Behavior preserved:** `beginBackfill()`, the connect handshake, `startUploadTimer`,
  `shouldRunPeriodicBackfill`, the offload watchdog, and ServerSync-defer-until-after-offload are all
  unchanged; only WHAT triggers a backfill and HOW OFTEN changes.
- **No placeholders:** every code step shows complete code; commands have expected output.
