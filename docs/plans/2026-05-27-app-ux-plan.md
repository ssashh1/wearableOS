# OpenWhoop App UX — Autonomous Plan (2026-05-27)

> **You are building the consumer-facing iOS app on top of a working pipeline + server-computed
> metrics.** Work autonomously. Use **superpowers:subagent-driven-development** (fresh subagent per
> task + two-stage review: spec-compliance then code-quality), **superpowers:systematic-debugging**
> when something's off, and deep research via subagents for the hard parts (smart alarm, workout
> detection, WHOOP visual style). The data pipeline and the derived-metrics layer are DONE; this plan
> is about **rendering** those metrics beautifully on the phone + the two genuinely new device
> features (smart alarm, workout auto-detection).

---

## 0. MISSION & PRINCIPLES

**Mission:** A WHOOP-like iOS app with a **Today** view and **historical** views (mirroring the web
dashboard), a real **smart alarm**, **workout auto-detection**, and a powerful **Device/technical**
tab — with an original dark, high-contrast design and an original app icon.

**Core principles:**
- **Server is the single source of truth for all derived/daily metrics** (recovery, strain, sleep,
  HRV, RHR, workouts, trends). The metrics overhaul (#3) already made the server authoritative — do
  NOT recompute metrics on the phone. **Retire the phone-side `DerivedMetrics.swift`** and pull from
  the server read API instead.
- **One data contract, two renderers.** The iOS app and the web dashboard render the **same server
  read API**. If a view exists on the dashboard, the app shows the same numbers from the same endpoint.
  Solidify/extend that API as the shared contract; don't fork metric logic.
- **Phone keeps what only the phone can do:** raw 1 Hz collection, a **local cache** of the latest
  server metrics (so the app shows last-known data offline), live HR, the Device console, and the
  **BLE-dependent features (alarm haptics, on-demand raw capture, workout-window high-freq)**.
- **No onboarding.** Purely functional. A single small **Settings** screen lets the user set the few
  values that feed the algorithms (**height, weight**, plus whatever HRmax/age/sex the metrics layer
  actually needs) — pushed to the server so the analysis uses them.
- **No questions, make the obvious choice and note it.** Commit per task to `main` in each repo.

---

## 1. WHERE THINGS LIVE (verified)
- **iOS app:** `~/openwhoop/ios/OpenWhoop/` (SwiftUI / CoreBluetooth). Current UI is a
  single technical view (log list + command buttons + live HR) driven by `BLEManager`'s published
  `state` — **this becomes the Device tab.** Packages: `Packages/WhoopProtocol` (decode),
  `Packages/WhoopStore` (GRDB local store; **retire `Sources/WhoopStore/DerivedMetrics.swift`**),
  `ios/OpenWhoop/Upload/ServerSync.swift` (server client — extend with the read API + caching).
- **Server (source of truth):** `~/Developer/home-server/stacks/whoop/ingest` (Python/FastAPI/
  TimescaleDB). Analysis modules in `app/analysis/` (hrv/sleep/recovery/strain/activity/exercise/daily
  — rebuilt in #3). Read API: `/v1/daily`, `/v1/sleep`, `/v1/compute-daily`, `/v1/streams/*`,
  `/v1/summary` at `https://whoop.example.com` (Bearer key; device `my-whoop`; **use `curl`** —
  Cloudflare WAF 403s default UAs). Deploy: `ssh jpserver 'cd ~/home-server && git pull && docker
  compose -f stacks/whoop/docker-compose.yml up -d --build'`. venv `~/Developer/home-server/venv`.
- **Web dashboard (style + parity reference):** the dashboard under `home-server/stacks/whoop` (and the
  repo's `dashboard/`). **Study it** so the app's historical views match what's already there.
- **Visual language:** the app icon, color palette, fonts, and ring/card UI are **original
  creations** — a generic dark fitness-app aesthetic, not copied from any third party.
- **Alarm command format (interoperability):** the alarm command bytes were determined for
  interoperability so the app can set an alarm on the user's own device.
- **Schema:** `protocol/whoop_protocol.json` (3 synced copies; `scripts/sync-schema.sh`).
- **Build/install:** udid `<DEVICE_UDID>`, team `<TEAM_ID>`. `xcodegen generate` only
  when adding/removing files. Reference `docs/plans/2026-05-24-whoop-insights-megaplan.md` for patterns.

---

## 2. APP STRUCTURE (tab bar, WHOOP-style)

| Tab | Purpose |
|---|---|
| **Today** | The command center: recovery ring (green/yellow/red %), day strain (0–21), last-night sleep summary, current/live HR, sync + strap-battery status. |
| **Sleep** | Last-night detail (hypnogram + performance/need/debt/efficiency + HRV/RHR/respiratory/SpO2/skin-temp during sleep) **and** a 7-night sleep/wake-time trend. |
| **Trends** | Historical charts mirroring the dashboard — recovery, HRV, RHR, strain, sleep duration — over 7/30/90 days. |
| **Workouts** | Auto-detected activities list + per-workout detail (duration, HR zones, strain, avg/max HR). (Could merge into Today/Trends if you prefer 4 tabs.) |
| **Device** | The powerful technical console: live logs, command buttons, live HR, raw-capture toggle, connection/battery/data-range/cursor, sync controls, haptic/alarm test. |

Plus: a **Settings** screen (height/weight + algorithm values), and **Alarm** config (its own screen,
reachable from Today; the alarm itself is a background feature, M6).

**Design:** dark theme; generic recovery green/yellow/red and strain blue (standard traffic-light
health colors); original card + ring visual language. Use **Swift Charts** for all charts. The
**app icon is an original design** (a gradient ring on black) — not derived from any third party.

---

## 3. MILESTONES (each = several subagent-driven tasks; commit per task; keep suites green)

### M0 — Foundation (do first)
- Tab-bar scaffold (SwiftUI `TabView`) with the tabs above; move the existing technical UI under **Device**.
- **Design system**: an original color/typography/spacing token set + reusable components
  (recovery ring, metric card, sparkline).
- **App icon**: an original gradient-ring icon, added as the app icon set.
- **Shared server API client + cache**: extend `ServerSync.swift` into a read client for the metrics
  endpoints; cache responses in the local store (GRDB) keyed by day/range so the app renders offline
  from last-known data. **Remove `DerivedMetrics.swift`** + the phone-side daily/sleep compute; the
  app now displays server-computed metrics only.
- **Settings screen**: height + weight (+ any HRmax/age/sex the analysis needs); persist + push to the
  server (`/v1/profile` or equivalent — add the endpoint if missing) so analysis uses them.

### M1 — Today
- Recovery ring (% + color), day strain (0–21, vs. recommended), last-night sleep one-liner, live/last
  HR, **sync freshness + strap battery** (reuse the existing sync-status work). Pull-to-refresh =
  trigger a sync + re-fetch. All from the server read API (+ live HR locally).

### M2 — Sleep (directly serves the two explicit asks)
- **"How well did I sleep last night":** sleep performance score + a **hypnogram** (wake/light/deep/REM
  bands over the night), duration, efficiency, sleep need vs. got / debt, latency, disturbances, and
  the in-sleep signals (HRV, RHR, respiratory rate, SpO2, skin-temp). Headline answer up top.
- **7-night sleep/wake times:** a per-night chart of **bedtime (fall-asleep) and wake time** for the
  last ~7 nights (dots/bars on a time-of-day axis) so trends in sleep schedule are obvious.
- **Acceptance:** opening Sleep answers both "how did I sleep last night" and "when have I been
  falling asleep / waking up over the past 7 nights" at a glance.

### M3 — Trends (mirror the dashboard's historical view)
- Charts for recovery, HRV, RHR, strain, sleep duration over selectable 7/30/90-day ranges, from the
  same endpoints the dashboard uses. Tap a point → that day's detail. Match the dashboard's numbers.

### M4 — Device tab (make it feel powerful)
- Relocate + sharpen the current technical UI: live `[OW]`-style log stream, command buttons (the
  `WhoopCommand` set), live HR toggle, raw-capture toggle, connection/bond state, strap battery,
  GET_DATA_RANGE W/U/T + pending, sync controls (sync now / offload now), **haptic/alarm test buzz**.
  This is the developer console — dense, real-time, powerful.

### M5 — Workout auto-detection (backend + RE + app) — IN SCOPE
- **Research subagent:** how WHOOP auto-detects activities (sustained HR elevation relative to RHR/
  baseline + movement/accel; min duration; classification) and what the APK does (search
  `apk/` for activity/workout/auto-detect logic, thresholds, the "Activities" model). Survey open
  prior art (HR-zone effort detection).
- **Server-side detection module** (`ingest/app/analysis/`): detect workout bouts from the 1 Hz HR
  (+ gravity/accel; optionally trigger on-demand raw IMU for cadence) → per-bout duration, HR zones,
  strain, avg/max HR, calories/kJ (using height/weight). New endpoint `/v1/workouts`. Backfill history.
- **App Workouts tab:** detected-activities list + detail; optional manual confirm/relabel.
- **Acceptance:** a real workout you did shows up auto-detected with sane strain/HR-zone breakdown.

### M6 — Smart alarm (the hard one) — FULL scope
- **Research subagent first:** fully map the APK alarm path — `SET_ALARM_TIME(66)`, `GET_ALARM_TIME(67)`,
  `RUN_ALARM(68)`, `DISABLE_ALARM(69)`, `RUN_HAPTICS_PATTERN(79)`, and `SmartAlarmTriggerRepository`
  (the only place `ENTER_HIGH_FREQ_SYNC` is built). Determine: does the strap fire its own alarm at a
  set time (firmware), or does the app drive the haptic? What payloads do 66/68 take? How does WHOOP
  pick the wake moment within the window? Capture exact byte formats.
- **Implement:**
  - **Alarm config UI** (wake-by time + smart window, e.g. wake up to 30 min before).
  - **Fixed-time fallback (ship this first, guaranteed):** set the strap's native alarm via
    `SET_ALARM_TIME` so the strap buzzes at the latest acceptable time even with no app in foreground.
  - **Smart wake:** near the window, the app (via CB background + state restoration) enters
    `ENTER_HIGH_FREQ_SYNC` to get fine-grained recent HR/movement, detects light-sleep/near-wake, and
    fires `RUN_ALARM`/`RUN_HAPTICS` at the optimal moment — exactly the one legitimate use of
    high-freq-sync (so it won't strand the offload; EXIT after).
  - Add `setAlarmTime`/`runAlarm`/`disableAlarm`/`getAlarmTime` to the `WhoopCommand` set; expose a
    test buzz in the Device tab.
- **Risks/notes:** iOS background-BLE is constrained — lean on CoreBluetooth state restoration (already
  used) and a generous high-freq window; if smart timing proves unreliable in background, the fixed-
  time strap alarm still fires. **Always send `EXIT_HIGH_FREQ_SYNC` after** and never leave it parked.
- **Acceptance:** an alarm set tonight reliably buzzes the strap by the target time; smart version
  wakes within the window near a light-sleep point.

### M7 — Notifications + polish
- Morning **recovery push** (when today's recovery computes), **sync-stale alert** (no fresh data in N
  hours while worn), bedtime nudge (optional). Empty/loading/offline states everywhere. Final visual
  pass against the APK style.

---

## 4. ACCEPTANCE CRITERIA (the whole plan)
1. Today shows recovery + strain + last-night sleep + sync/battery, all from the server, cached for offline.
2. Sleep answers **"how well did I sleep last night"** (hypnogram + performance) and **"my fall-asleep/
   wake times over the last 7 nights."**
3. Trends mirror the web dashboard's historical numbers (same API).
4. Device tab is a powerful technical console (logs, commands, live HR, raw, cursors, sync, test buzz).
5. **Workout auto-detection** surfaces real workouts with strain/HR zones (server-detected).
6. **Smart alarm** reliably wakes via strap haptics (smart window + fixed-time fallback).
7. Metric generation is **unified** — server-computed, app + dashboard render the same contract,
   `DerivedMetrics.swift` retired.
8. Settings lets the user set height/weight (+ needed algorithm values) that the server analysis uses.
9. Original gradient-ring icon and original visual style throughout.
10. All suites green (WhoopProtocol/WhoopStore/iOS/ingest); built + installed on the phone; server deployed.

---

## 5. DELIVERABLES
- The tabbed app (Today / Sleep / Trends / Workouts / Device) + Settings + Alarm config, installed on the phone.
- Server: `/v1/workouts` + workout-detection analysis module + `/v1/profile` (height/weight) +
  whatever read endpoints the app needs (recovery/trends if not already exposed), deployed.
- `WhoopCommand` additions for the alarm; Device-tab test controls.
- A short doc (`docs/specs/2026-05-27-app-ux.md`): final tab/screen map, the API contract the app +
  dashboard share, the alarm design (+ APK findings), and the workout-detection method.
- Manual test steps (turn BT on → open app → expect X per tab; set an alarm → verify buzz).

---

## 6. RISKS
- **Smart alarm background BLE** is the biggest unknown (iOS limits) — fixed-time strap alarm de-risks it.
- **Workout detection accuracy** — start with HR-elevation + movement heuristics; validate against a
  workout you actually did; iterate (systematic-debugging).
- **Offline UX** — cache server metrics locally; degrade gracefully when the server/phone is offline.
- **Don't regress the pipeline** — the BLE/offload path is fixed and shipped; the alarm's high-freq use
  must EXIT cleanly so it never re-introduces the data-loss/stranding behavior.
