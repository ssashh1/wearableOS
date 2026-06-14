# Sync Hardening — Design Spec (2026-05-25)

**Status:** design, pending user review → implementation plan (superpowers:writing-plans).
**Supersedes the scope of** `docs/plans/2026-05-25-whoop-sync-model.md` (its Tasks 1–4 are folded in as
Pillar 4; its Phase-2 brainstorm gates are resolved here).

**Goals (user's words):** (1) **never lose biometric data**, (2) **don't drain the strap battery too
fast**, (3) **mimic WHOOP** — bias hard toward what WHOOP's own app does, since they've solved this.

This spec is grounded in three research streams (all 2026-05-25): the sync-stall investigation
(`docs/specs/2026-05-25-sync-stall-frozen-strap-investigation.md`), a reverse-engineering pass over the
WHOOP Android APK (`apk/`), and an iOS background-execution constraints review. Where a claim was
verified on-device it is marked **[verified]**.

---

## 1. Findings that drive the design

**F1 — WHOOP's Gen4 offload never enters high-freq-sync; we shouldn't either. [verified]**
WHOOP's app offloads the 14-day biometric history with plain `SEND_HISTORICAL_DATA`(22) +
`GET_DATA_RANGE`(34) + per-chunk `HISTORICAL_DATA_RESULT`(23) acks over a persistent connection.
`ENTER/EXIT_HIGH_FREQ_SYNC`(96/97) exist **only** for the Smart-Alarm wake window, and there WHOOP
sends ENTER with a **bounded `duration` (≤7200 s)** so the strap auto-exits. Strap generation only
selects GATT UUIDs — it does not change the offload mechanism. (APK: zero `EnterHighFreqSyncPacket`
constructions in any offload path; the only two ENTER call sites are Smart-Alarm.)
On-device A/B test (`re/test_offload_without_highfreq.py`): **Phase A (no high-freq) returned 40
type-47 records + types 48/49/50; Phase B (high-freq) returned none.** Our `protocol-complete` doc's
"type-47 requires the high-freq-sync handshake" was a **frozen-RTC artifact** — biometric logging is
default-on once the RTC is valid (that doc, line 236, agrees).

**F2 — Our `ENTER_HIGH_FREQ_SYNC`-then-never-exit is the data-loss root cause.**
The app sends `ENTER_HIGH_FREQ_SYNC` with an **empty payload** (no auto-expiry) on every connect
(`BLEManager.swift:636`) and has **no `EXIT_HIGH_FREQ_SYNC`** (not in `Commands.swift`). High-freq-sync
suppresses the strap's free-running 1 Hz logging; a strap stranded in it (e.g. after an abrupt
app-kill that skips the implicit exit) **stops recording** — that data is never logged and is therefore
unrecoverable, not merely delayed. This produced the observed 65-min gap.

**F3 — WHOOP's sync cadence: periodic floor + strap-pushed events + rate limiter.**
A 15-min `PeriodicWorkRequest` floor; expedited "process-now" syncs on triggers; and — the part we're
missing — the **strap pushes BLE event packets** (`HighFreqSyncPromptEventPacket` → "Triggering 1 minute
sync", plus double-tap / condition-report) that drive catch-up. The strap is the clock. A 15-min
Room-backed dedup rate-limiter (hardcoded, not server-tunable) gates re-syncs. Persistent connection,
short drains throttled to **≥5 s** between `SEND_HISTORICAL_DATA`.

**F4 — Catch-up is ack-driven; the 14-day store is the backstop.**
The strap holds its own record cursor; the phone drains until an **empty `HISTORY_END`** ("caught up")
and advances the strap's frontier only via the per-chunk ack. No phone-side record IDs. Missed data
(phone & strap apart) syncs automatically on reconnect, as long as the gap < ~14 days.

**F5 — iOS force-quit is a hard wall; the nudge is the only key.**
A user force-quit sets one OS flag that disables **CoreBluetooth restoration, BGTaskScheduler, and silent
push** together; it clears only on manual relaunch, a *tapped* notification, or reboot. iOS gives **no
force-quit callback** (unlike Android's `onTaskRemoved`), so we don't detect force-quit — we track
**last-successful-sync** and treat *staleness* as the signal (it's the superset). WHOOP's "keep the app
open to sync" nudge is a **server-sent push** (copy is server-side), reinforced by an in-app
"catching-up / caught-up" tile (>1 h behind ⇒ catching up).

**F6 — Current app: the machinery exists; the primitive and the safety nets don't.**
CoreBluetooth state restoration is fully wired (`restoreID`, `willRestoreState`, `bluetooth-central`);
the decode/drain/per-row-`synced` upload pipeline works; local notifications exist (battery only).
Missing: the corrected offload primitive, an explicit EXIT, a stuck-strap watchdog, conditional clock,
the rate-limiter/event triggers, foreground-resync, and any staleness nudge.

---

## 2. Architecture — six pillars

Each pillar lists **what / why / WHOOP parallel / files / key decisions.** Priority tags: **P0**
(data-loss, do first), **P1**, **P2**.

### Pillar 1 — Correct the offload primitive (remove high-freq-sync) · **P0**
- **What:** Remove `ENTER_HIGH_FREQ_SYNC` from the connect handshake. Add `EXIT_HIGH_FREQ_SYNC = 97` to
  `WhoopCommand` and send it **once, defensively, early in every connect** to release a strap left
  parked in high-freq by an older build of our app or by WHOOP's Smart-Alarm. Keep the rest of the
  handshake (`GET_CLOCK`, flood-stop `SEND_R10_R11_REALTIME[0x00]`, `GET_DATA_RANGE`, `beginBackfill` =
  `SEND_HISTORICAL_DATA`).
- **Why:** F1 + F2 — this is the data-loss root cause; plain `SEND_HISTORICAL_DATA` is sufficient
  **[verified]**. The defensive EXIT recovers any strap already stranded by the current shipped build.
- **WHOOP parallel:** WHOOP's exact Gen4 offload (no high-freq for history; bounded-duration high-freq
  reserved for Smart-Alarm).
- **Files:** `BLEManager.swift` (handshake ~620–647), `Commands.swift` (add `exitHighFreqSync = 97`).
- **Decisions:** (a) Keep `enterHighFreqSync` in the enum (harmless; reserved for a future Smart-Alarm
  feature) but never call it in the offload path. (b) The defensive EXIT is one tiny command per connect
  — negligible battery cost, high safety; the stuck-watchdog (Pillar 2) re-sends it on escalation.

### Pillar 2 — Liveness / stuck-strap detection + recovery · **P0**
- **What:** Detect "connected+bonded but the data frontier (`max(ts)` / `strap_trim`) hasn't advanced
  in N min while the strap *has* newer data," and escalate on a ladder:
  1. abort + **retry** `SEND_HISTORICAL_DATA` (re-kick the drain);
  2. still stuck → re-issue conditional `SET_CLOCK` (drift) + defensive `EXIT_HIGH_FREQ_SYNC`;
  3. still stuck → surface a **user-visible "strap may need a reboot"** state (do **not** auto-reboot).
  Use `GET_DATA_RANGE` to distinguish **caught-up** (strap newest ≈ our frontier ⇒ healthy, idle) from
  **stuck** (strap newest ≫ frontier but frozen ⇒ escalate). (Investigation rec #3, #5.)
- **Why:** Today there is *no* detection — the strap logged nothing for 65 min in silence. We must own
  "the strap is healthy and advancing" as observable state.
- **WHOOP parallel:** WHOOP's 5 s watchdog → abort → retry, plus reactive `SET_CLOCK` on RTC-lost — and
  notably WHOOP does **not** auto-reboot to recover, so neither do we.
- **Files:** `BLEManager.swift` (extend `armBackfillTimeout`/`exitBackfilling` ~298–326; add a
  frontier-liveness check on the periodic tick), `LiveState`/`LiveView` (the "needs reboot" surface),
  `Backfiller.swift` (expose the local frontier).
- **Decisions:** N ≈ 10 min for the "frozen-while-data-available" threshold (tune later). The existing
  60 s idle watchdog stays as the fast path; this is the slow, semantic path. **Expected frequency after Pillar 1: ~never** — the high-freq-sync stranding (the only stuck cause we've actually seen) is gone; this watchdog is insurance for rare residual causes (a truly frozen RTC after long disuse, a firmware glitch), not an expected path.

### Pillar 3 — Conditional, drift-aware clock policy · **P1**
- **What:** `GET_CLOCK` → compute drift → `SET_CLOCK` **only** when the RTC is invalid or drifted beyond
  a threshold (or on an RTC-lost signal). Stop resetting the clock every connect. Keep clock correlation
  for type-47 timestamp derivation, and correlate consistently relative to any reset. (Investigation
  rec #6.)
- **Why:** Gratuitous `SET_CLOCK` risks a discontinuity in historical-record timestamps, and adds a
  command per connect. WHOOP sets the clock reactively (≥2 s drift / RtcLost), not blindly.
- **Observed parallel:** the app does a conditional SET_CLOCK + RTC-lost resync.
- **Files:** `BLEManager.swift` (handshake), `ClockCorrelation.swift`.
- **Decisions:** Drift threshold ≈ 2 s (match WHOOP). `REBOOT` stays excluded from the enum; frozen-RTC
  recovery (`SET_CLOCK`+`REBOOT`) remains a **manual** step surfaced via Pillar 2, not app-automated.

### Pillar 4 — WHOOP-style cadence + strap-as-clock (battery) · **P1**
- **What:** (a) The `BackfillPolicy` rate-limiter + **15-min periodic floor** + `connect` / `foreground`
  / `manual` triggers (the existing `whoop-sync-model.md` Tasks 1–4, reused). (b) **NEW: strap-as-clock**
  — react to incoming `EVENT` packets (the HighFreqSyncPrompt / condition-report equivalents) by calling
  `requestSync(.strap)`; today `FrameRouter.swift:39` ignores them. (c) Throttle drains to **≥5 s**
  between `SEND_HISTORICAL_DATA` (match WHOOP).
- **Why:** Battery. Fewer radio wake-ups (15-min floor ≈ 3× fewer than the old 5-min poll), event-driven
  rather than poll-driven, and no elevated high-freq mode. The strap-as-clock trigger pairs with
  CoreBluetooth restoration: a strap event both relaunches us *and* kicks a drain.
- **WHOOP parallel:** F3 in full.
- **Files:** new `BackfillPolicy.swift` + tests (per the existing plan), `BLEManager.swift`
  (`requestSync(_:)`, watermark, route periodic/connect through it; bump interval 300→900),
  `FrameRouter.swift` (EVENT → trigger), `LiveViewModel.swift`/`LiveView.swift` (foreground + "Sync now").
- **Decisions:** Floors as in the existing plan (`periodicFloorSeconds=900`, `eventFloorSeconds=90`);
  `manual` always runs. Keep the persistent connection (don't disconnect between drains) — WHOOP's model.

### Pillar 5 — Background resilience / missed-data catch-up · **P1**
- **What:** Ensure a clean full drain on background relaunch (fix the `bootstrapStore` race flagged in
  the iOS survey — the first restored BLE data can arrive before the store is ready). Make every connect
  **deterministically recover** from any mid-session strap state (the defensive EXIT in Pillar 1 + the
  watchdog in Pillar 2 cover this). Rely on CoreBluetooth state restoration (already wired) + the strap's
  14-day retention as the backstop for "phone & strap were apart." (Investigation rec #4.)
- **Why:** "Sync missed data when phone & device weren't connected" = the system-termination case, which
  CoreBluetooth restoration already handles once the offload is correct; we just harden the edges.
- **Files:** `BLEManager.swift` (`willRestoreState` ~513, `bootstrapStore` ordering), `Backfiller.swift`.
- **Decisions:** No `BGProcessingTask` initially — CoreBluetooth restoration covers the non-force-quit
  case; revisit only if a measured gap appears. (Resolves the existing plan's Task 5 brainstorm: defer.)

### Pillar 6 — Force-quit nudge + staleness surfacing · **P2**
- **What:** (a) **Local schedule-ahead notification** (server-free): on each sync/background, (re)schedule
  one local notification for T+N hours — "OpenWhoop hasn't synced in a while — tap to catch up";
  reschedule-on-sync so it fires only when sync genuinely stalls (force-quit / stuck / away). Tap →
  relaunch → flag clears → drain. (b) An in-app **"Caught up / Catching up · synced 5 m ago" tile** +
  a persisted **"last synced at"** watermark (mirrors WHOOP's connectivity tile, ~1 h threshold).
  (c) **Later sub-phase — server push (APNs):** the ingest server already knows each device's true
  last-upload time; add a push token + a staleness check + an APNs sender for a smarter, server-truth
  nudge.
- **Why:** F5 — the only way past iOS's force-quit wall is a notification the user taps. Local first
  (zero infra, already defeats the wall); server push as fidelity refinement.
- **WHOOP parallel:** server-staleness push + in-app catching-up tile.
- **Files:** new notification scheduler (reuse `UserNotifications`, cf. `BatteryAlertMonitor.swift`),
  `LiveState`/`LiveView` (tile + watermark); server side later (`ingest/`), `aps-environment` entitlement
  + remote-notification registration for the APNs sub-phase.
- **Decisions (confirmed 2026-05-25):** Local notification first; APNs server-push deferred to a later
  sub-phase (NOT in this plan). Tile flips at **~1 h** behind (WHOOP's `DataCatchingUpHelper` number);
  local nudge after **~6 h** of no successful sync (our default — WHOOP's nudge is server-decided, so no
  client constant to copy; tune in practice).

---

## 3. Sequencing

1. **P0 — data-loss fix:** Pillar 1 (remove high-freq-sync + defensive EXIT) → Pillar 2 (stuck watchdog).
   Ship first; this stops the bleeding.
2. **P1 — correctness + battery:** Pillar 3 (clock) → Pillar 4 (cadence/triggers) → Pillar 5 (background
   resilience).
3. **P2 — freshness/UX:** Pillar 6 (local nudge + tile first; APNs server push as a later sub-phase).

---

## 4. Testing strategy

- **Pillar 1 already validated** by `re/test_offload_without_highfreq.py` (read-only A/B) **[verified]**.
- **Pure logic via TDD:** `BackfillPolicy` (floors/triggers), the staleness/last-synced computation, the
  frontier-liveness predicate — all pure and unit-testable off-device (XCTest).
- **On-device / hardware checks** (Mac BLE with phone app quit; server frontier via the runbook):
  - After Pillar 1: confirm a normal wear session offloads type-47 with high-freq-sync removed, and that
    the server frontier advances continuously (no gaps) across an app reinstall (the original trigger).
  - After Pillar 2: simulate a stall (or observe one) and confirm the escalation ladder + the
    "needs reboot" surface fire.
- **Regression:** keep the existing suites green (WhoopProtocol / WhoopStore / iOS / ingest).

---

## 5. Risks & mitigations

- **R1 — removing high-freq-sync regresses some unforeseen strap state.** Mitigation: verified on-device;
  defensive EXIT on connect; staged P0 rollout with server-frontier monitoring across a reinstall.
- **R2 — the stuck-watchdog mis-fires "needs reboot" when merely caught-up.** Mitigation: gate strictly
  on `GET_DATA_RANGE` showing newer data than the local frontier; conservative N (~10 min).
- **R3 — conditional clock breaks type-47 timestamp mapping.** Mitigation: keep correlation logic; change
  only *when* we reset, not *how* we derive ts; verify newest-ts sanity after a session.
- **R4 — local nudge nags when nothing's wrong.** Mitigation: reschedule-on-sync means it only fires
  after N hours of *no* successful sync; pick N generously (strap retains 14 days, so no urgency).

---

## 6. Resolved decisions (2026-05-25 review)

1. **Thresholds — mimic WHOOP.** Tile flips at **~1 h** behind (WHOOP's `DataCatchingUpHelper` number);
   local nudge after **~6 h** of no successful sync (our default — WHOOP's nudge is server-decided, so
   there's no client constant to copy; tune in practice).
2. **APNs server-push — deferred.** Local notification is sufficient for now; the server-push sub-phase
   is explicitly NOT in this plan (revisit later).
3. **Stuck-watchdog "needs reboot" — quiet in-app tile state**, not a notification. Rationale: after
   Pillar 1 this state should fire ~never, and you don't build a loud alert for a should-never-happen
   condition; Pillar 6's staleness nudge already prompts opening the app, where the tile says "reboot."
4. **No `BGProcessingTask`.** WHOOP syncs in the background via Android's reliable primitive (WorkManager
   15-min + FG services); the faithful iOS translation is the 15-min floor (Pillar 4) running under
   CoreBluetooth state restoration (already wired) + strap-as-clock events — not the unreliable iOS
   `BGProcessingTask`. Skipping it is the *more* WHOOP-faithful choice. Revisit only if a measured gap
   appears.
