# WHOOP Insights & Pipeline-Hardening — Mega Plan (Milestones A–D)

> **For agentic workers:** Use **superpowers:subagent-driven-development** to execute this task-by-task
> (fresh subagent per task + two-stage review: spec-compliance then code-quality). Steps use
> checkbox (`- [ ]`) syntax. This is a LARGE plan in an ESTABLISHED codebase — each task gives exact
> files, signatures, key code, test commands, and acceptance criteria; **read the cited existing files
> for surrounding patterns rather than expecting every line inlined.** Commit after every task.

**Goal:** Turn the working raw-decode pipeline into a WHOOP-like insights product: a **daily sleep
metric (phone + server)**, **real human units** on the dashboard, **all byte fields decoded** (+ an
on-demand raw-accel path for steps/exercise), **full bidirectional sync + cloud restore**, and a
**hardened, audited end-to-end data path** — leaving the polished in-app charts UX for a separate later plan.

**Architecture:** Phone is the always-present collector/decoder. The **type-47 V24 store, pulled by
periodic backfill, is the canonical 1 Hz metric source** (HR/RR/SpO2/skin-temp/resp/gravity). Derived
metrics (sleep, HRV, recovery, strain, activity, exercise) are computed by a **local-analysis layer
implementing published methods** (HRV: Task Force/neurokit2; sleep: Cole–Kripke; strain:
Karvonen/Edwards), run **server-side** over the durable streams (and surfaced to the
phone via the read API). Raw high-rate IMU/PPG is NOT routinely kept; an **opt-in on-demand raw
capture** provides accelerometer samples when we want step/cadence detail.

**Tech Stack:** Swift 6.3 / SwiftUI / CoreBluetooth / GRDB (iOS app + `WhoopProtocol` + `WhoopStore`
packages); Python / FastAPI / TimescaleDB (`home-server/stacks/whoop`); shared `whoop_protocol.json`
schema (3 synced copies). Reference: `research/openwhoop` (Rust). venv:
`~/openwhoop/whoop-reader/.venv/bin/python`. Device build: udid
`<DEVICE_UDID>`, team `<TEAM_ID>`. Server deploy: push → `ssh jpserver 'cd
/home/jp/home-server && git pull && docker compose -f stacks/whoop/docker-compose.yml up -d --build'`.
Tunnel: `https://whoop.example.com` (Bearer `WHOOP_API_KEY=<WHOOP_API_KEY>`;
device `my-whoop`). Cloudflare WAF 403s the default urllib UA — use `curl` (or set a UA) when scripting the tunnel.

---

## EXECUTION INSTRUCTIONS (the user will run this autonomously, NO questions)

- The user keeps the **strap worn + phone Bluetooth OFF** so YOU can drive the strap from the Mac via
  `bleak` (the `re/*.py` pattern) to capture/verify autonomously. Do not ask questions — make the
  obvious choice, note it, proceed.
- **Test as you go.** Every task ships with tests; keep all suites green:
  - `swift test --package-path Packages/WhoopProtocol` (62) · `--package-path Packages/WhoopStore` (39)
  - `cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17'` (71)
  - `cd ~/Developer/home-server/stacks/whoop/ingest && ~/Developer/home-server/venv/bin/python -m pytest -q` (31; needs Docker)
  - Schema parity after any schema change: `bash scripts/sync-schema.sh` + regen goldens `whoop-reader/.venv/bin/python scripts/gen_golden.py`.
- **Many review/test cycles + subagents** (two-stage review per task). Read-only device diagnostics
  are safe; **save every BLE notification to a gitignored `.bin` before any acking/trim**; never send
  FORCE_TRIM/REBOOT/POWER_CYCLE/SHIP_MODE/DFU.
- **Finish by:** building + installing the new app on the phone (`devicectl`), deploying the dashboard,
  and writing **manual test steps** (a `## Manual test steps` section appended to this file) the user
  runs when they return (turn phone BT on → open app → expect X).
- Commit to `main` in each repo as you go (solo repo convention). Co-author trailer:
  `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.

---

## CURRENT STATE (what's already done — do NOT redo)

- Decode library (schema + Python `whoop_protocol` + Swift `WhoopProtocol`) decodes type-47 V24
  biometric, type-43 IMU (accel ÷4096, gyro ×0.06104 deg/s), type-43 optical PPG (s24), with Swift==Python
  byte-parity. `extract_historical_streams`/`extractHistoricalStreams` emit hr/rr/spo2/skin_temp/resp/gravity.
- iOS pipeline: high-freq-sync handshake on connect; **periodic 5-min backfill** (the metric source) +
  background BLE wakes; **acks every HISTORY_END** (the fix); 30s periodic upload; decoded-only default;
  raw behind OFF-by-default `enableRawCapture`; live HR opt-in (manual button). `Backfiller`/`Collector`/
  `Uploader`/`BLEManager` in `ios/OpenWhoop/`.
- Server: `POST /v1/ingest-decoded` persists 8 streams (hr/rr/events/battery/spo2/skin_temp/resp/gravity);
  read API `/v1/streams/{kind}`, `/v1/summary`, `/v1/devices`, `/v1/batches[/frames]` (all Bearer-auth);
  dashboard charts the 8 streams; raw archive demoted/auto-hidden.
- VERIFIED: strap logs the type-47 store at 1 Hz when worn; acking advances trim ~34 rec/s; pipeline
  catches up to live across reconnects. Steps are NOT in V24. V24 has a 2nd gravity triplet @data 49/53/57.

---

## File map (what gets created/modified)

**New analysis layer (server-side compute over streams):**
- `home-server/stacks/whoop/ingest/app/analysis/` — `__init__.py`, `units.py` (raw→human), `hrv.py`,
  `sleep.py`, `recovery.py`, `strain.py`, `activity.py`, `exercise.py`, `daily.py` (orchestrator).
- `home-server/stacks/whoop/db/init.sql` — new tables: `sleep_sessions`, `daily_metrics`,
  `exercise_sessions` (+ hypertables where time-series).
- `home-server/stacks/whoop/ingest/app/main.py` + `store.py` + `read.py` — endpoints to compute/store/read
  derived metrics; widen read API.
- `home-server/stacks/whoop/ingest/app/static/{index.html,app.js,style.css}` — sleep/recovery/strain panel + real units.
- `home-server/stacks/whoop/ingest/tests/` — analysis + endpoint tests.

**Schema / decode completeness:**
- `protocol/whoop_protocol.json` (+ `scripts/sync-schema.sh` to the 2 copies) — add V24 `gravity2_x/y/z`
  (@49/53/57 f32) + label/flag the remaining fields; type-43 IMU tail annotation.
- Python `whoop_protocol/interpreter.py` + Swift `WhoopProtocol` — decode the added fields; regen goldens.

**iOS:**
- `Packages/WhoopStore/` — tables/reads for derived metrics pulled back from server; cursors for read-sync.
- `ios/OpenWhoop/` — read-path sync (pull decoded + derived back), cloud-restore, on-demand raw-accel
  capture command, minimal sleep-metric surface, audit fixes.

---

# PHASE 1 — Decode completeness + real units

### Task 1.1: Add the V24 second gravity/accel triplet to the schema + decoders
**Files:** `protocol/whoop_protocol.json` (HISTORICAL_DATA v24 fields), Python `interpreter.py` (none if
schema-driven), Swift mirror, `scripts/sync-schema.sh`, `scripts/gen_golden.py`, tests.
- [ ] Add three f32 fields to the V24 `versions["24"].fields`: `gravity2_x`@frame 56, `gravity2_y`@60,
  `gravity2_z`@64 (data offsets 49/53/57 + 7). cat `"accel"`, unit `"g"`, note "2nd accel/gravity triplet".
- [ ] `bash scripts/sync-schema.sh`; regen goldens `whoop-reader/.venv/bin/python scripts/gen_golden.py`.
- [ ] Extend the Python V24 test (`home-server/.../tests/test_historical_v24.py`) to assert the new
  fields decode and |gravity2|≈1g on the embedded real frame. Run Python suite.
- [ ] `swift test --package-path Packages/WhoopProtocol` (parity over the regenerated goldens).
- [ ] Commit (both repos: whoop schema/Swift + home-server schema/Python).
- **Accept:** both suites green; `gravity2_*` present in parsed output; |gravity2|∈(0.9,1.1).

### Task 1.2: Real-unit conversion module (server)
**Files:** Create `home-server/stacks/whoop/ingest/app/analysis/units.py`; test `tests/test_units.py`.
Reference: openwhoop has NO conversions (cloud-side); use standard approximations, flagged approximate.
- [ ] `spo2_percent(red, ir) -> float` — ratio-of-ratios: `R = (AC_red/DC_red)/(AC_ir/DC_ir)`; with only
  per-record red/ir ADC (no AC/DC split) use the empirical linear `SpO2 ≈ 110 - 25*R` clamped [70,100],
  computed over a short rolling window for AC/DC; document as APPROXIMATE. If a single-sample estimate is
  too noisy, expose `spo2_percent_window(reds, irs)` operating on a window.
- [ ] `skin_temp_celsius(raw) -> float` — thermistor/linear map. Calibrate against plausibility: resting
  on-wrist skin temp ~31–35 °C; fit `c*raw + b` so the median maps to ~33 °C (document the fit + that
  it's uncalibrated absolute, good for TREND).
- [ ] `resp_rate_bpm(raw) -> float` — map raw→breaths/min (resting 12–20). Document approximate.
- [ ] Tests assert monotonicity + plausible ranges on the real V24 values (red 587/ir 585→SpO2∈[90,100];
  skin_temp 930→°C∈[30,36]).
- [ ] Commit. **Accept:** `pytest tests/test_units.py` green; functions flagged APPROXIMATE in docstrings.

### Task 1.3: Surface real units in the read API + dashboard
**Files:** `read.py` (`/v1/streams/{kind}` add computed unit columns or a `?units=human` flag),
`static/app.js` + `index.html` (show °C / % / bpm with an "approx" tag), tests.
- [ ] `/v1/streams/spo2|skin_temp|resp` gains computed human-unit fields alongside the raw (e.g.
  `{ts, raw, value, unit}`), using `analysis/units.py`. Keep raw too.
- [ ] Dashboard charts show human units with an "≈ approx" label; gravity/HR unchanged.
- [ ] Endpoint test seeds raw rows, asserts human-unit fields present + plausible.
- [ ] Commit + (deploy happens in Phase 5). **Accept:** ingest tests green; `curl` returns human units.

### Task 1.4: On-demand raw-accel capture path (for steps/exercise when needed)
**Files:** `ios/OpenWhoop/BLE/BLEManager.swift` (+ `Commands.swift`), `Collect/` as needed; a manual
trigger (temporary: a function callable from the existing research toggle / a debug button).
- [ ] Add a bounded **"capture raw accel for N seconds"** path: when invoked, enable the raw stream
  (`enableOpticalData`/`toggleIMUMode`/`startRawData`) and persist the type-43 1917 IMU frames to the raw
  outbox for N seconds, then stop. This is the accelerometer-raw source for step/cadence detail. Gate it
  behind the existing `enableRawCapture` toggle OR a new explicit "capture activity sample" action.
- [ ] Server already archives raw via `/v1/ingest` (decode_streams=false). No server change needed; the
  raw frames upload through the existing raw drain when the toggle is on.
- [ ] Unit-test the bounded-capture decision logic (pure helper: should-capture / duration). Device-only
  parts validated in Phase 5.
- [ ] Commit. **Accept:** app tests green; a raw-accel sample can be captured + uploaded on demand.
- **Note:** This does NOT enable 24/7 raw. It's the "somehow get accelerometer raw" lever for step work.

---

# PHASE 2 — Insights / local-analysis layer (the core value)

> Implement the derived-metric algorithms from published methods in Python under
> `ingest/app/analysis/`. These run server-side over the durable 1 Hz streams. Each is a pure function
> over time-ordered samples → a metric; test against the real device streams already in the DB
> (`device my-whoop`) and against synthetic fixtures with known shapes.

### Task 2.1: HRV (RMSSD + SDNN) from RR intervals
**Files:** `analysis/hrv.py`; `tests/test_hrv.py`.
- [ ] `rmssd(rr_ms: list[int]) -> float`, `sdnn(...)`, plus a windowed `hrv_series(rr_rows, window_s)`.
  Filter physiologically-implausible RR (300–2000 ms) before computing.
- [ ] Tests: known RR arrays → known RMSSD; filtering drops outliers.
- [ ] Commit. **Accept:** `pytest tests/test_hrv.py` green.

### Task 2.2: Sleep detection + staging (PRIMARY deliverable)
**Files:** `analysis/sleep.py`; `tests/test_sleep.py`. References: Cole–Kripke 1992; te Lindert 2013; Walch 2019.
- [ ] `detect_sleep(streams) -> list[SleepSession]` where a session = {start, end, efficiency,
  stages:[{start,end,stage}]}. Inputs (1 Hz): HR, HRV(from RR), resp, movement (per-record L2 delta of
  the gravity vector), skin_temp. Algorithm: (1) **sleep/wake** = sustained low movement + HR below the
  day's active baseline + stable respiration → asleep; (2) **staging** (light/deep/REM) heuristic from
  HRV (high in deep), HR dips, movement bursts (REM/wake), respiration regularity — literature
  thresholds; mark APPROXIMATE. (3) Efficiency = asleep/in-bed.
- [ ] `daily_sleep_summary(sessions, date) -> {date, total_sleep_min, efficiency, deep_min, rem_min,
  light_min, disturbances, resting_hr, avg_hrv}` — the **daily sleep metric** the user wants.
- [ ] Tests: synthetic night (low-movement + HR-dip block) → detected session w/ plausible stages;
  an all-active stream → no session. Also a smoke test over the real `my-whoop` streams (assert it runs +
  returns plausible structure; don't assert exact stages).
- [ ] Commit. **Accept:** `pytest tests/test_sleep.py` green; runs over real data without error.

### Task 2.3: Recovery + resting HR + strain + activity
**Files:** `analysis/recovery.py`, `strain.py`, `activity.py`; tests for each. References: Karvonen 1957, Edwards 1993 (strain); te Lindert 2013 (activity).
- [ ] `resting_hr(streams, sleep_session) -> int` (min sustained HR during sleep).
- [ ] `recovery_score(hrv, resting_hr, resp, baseline) -> 0..100` (HRV-driven, literature-based; APPROX).
- [ ] `strain(hr_series, max_hr) -> 0..21` (cardiovascular load: time-in-HR-zones weighted, WHOOP 0–21
  scale; `max_hr` default `220 - age` with age configurable, default a constant + TODO).
- [ ] `activity_series(gravity_rows) -> motion intensity` (per-record L2 delta; the openwhoop "Activity"
  proxy) using BOTH gravity triplets for robustness.
- [ ] Tests with known inputs → known/plausible outputs.
- [ ] Commit. **Accept:** all three test files green.

### Task 2.4: Exercise / workout detection (the "did I go for a run" requirement)
**Files:** `analysis/exercise.py`; `tests/test_exercise.py`.
- [ ] `detect_exercises(streams) -> list[ExerciseSession]` = {start, end, avg_hr, peak_hr, kind?,
  strain}. A workout = a sustained window (≥ ~5 min) of **elevated HR (above resting + margin) AND
  sustained motion** (activity_series high). This works retroactively from the backfilled 1 Hz store —
  **no raw needed** (so a run done while the phone was disconnected is detected after the next sync).
- [ ] If a raw-accel sample exists for the window (Phase 1.4), optionally attach cadence/step estimate;
  otherwise omit (document that step COUNT needs the raw sample).
- [ ] Tests: synthetic elevated-HR+motion block → detected exercise; quiet stream → none.
- [ ] Commit. **Accept:** `pytest tests/test_exercise.py` green.

### Task 2.5: Daily orchestrator + persistence + endpoints
**Files:** `analysis/daily.py`, `db/init.sql` (`sleep_sessions`, `exercise_sessions`, `daily_metrics`),
`store.py`, `main.py`, `read.py`, tests.
- [ ] `compute_day(device_id, date) -> {sleep_summary, recovery, strain, exercises, hrv, resting_hr}`
  reading the streams from the DB, running 2.1–2.4, persisting to the new tables (idempotent upsert by
  (device_id, date) / (device_id, start)).
- [ ] `POST /v1/compute-daily {device, date}` (Bearer) → computes + stores + returns the summary. Plus a
  trigger to compute on ingest (e.g. recompute the affected day after each `/v1/ingest-decoded`), or a
  cron-ish endpoint — simplest: recompute the day(s) touched by an ingest batch.
- [ ] Read: `GET /v1/daily?device=&from=&to=` (Bearer) → daily_metrics rows; `GET /v1/sleep?device=&date=`.
- [ ] Tests: ingest a synthetic day → compute → read back the daily metric; idempotent recompute.
- [ ] Commit. **Accept:** ingest suite green; end-to-end ingest→compute→read works in tests.

### Task 2.6: Dashboard — sleep/recovery/strain panel
**Files:** `static/{index.html,app.js,style.css}`; bump `app.js?v`.
- [ ] Add a primary "DAILY" panel: latest sleep summary (total/efficiency/stages), recovery, strain,
  exercises list, resting HR, HRV — reading `/v1/daily` + `/v1/sleep`. Telemetry-console aesthetic; reuse
  chart helpers. Sleep stages as a hypnogram-style bar if feasible (else a stacked summary).
- [ ] Commit (deploy in Phase 5). **Accept:** `node --check app.js`; renders against seeded data (verify
  via headless screenshot if practical, else code-review).

---

# PHASE 3 — Full bidirectional sync + cloud restore

### Task 3.1: Pull decoded streams + derived metrics back to the phone
**Files:** `Packages/WhoopStore` (tables for derived metrics + a "server read highwater" cursor),
`ios/OpenWhoop/` (a `ServerSync`/reader that GETs `/v1/streams/*` + `/v1/daily` + `/v1/sleep`), tests.
- [ ] WhoopStore: add tables to cache pulled derived metrics (sleep_sessions, daily_metrics) +
  reads; a `read_highwater` cursor per stream so pull is incremental.
- [ ] iOS reader: on connect (and a periodic timer), GET new rows since the read-highwater from the
  server and upsert locally → **History = union(phone-collected, server)**.
- [ ] Tests (stubbed URLSession + in-memory store, mirror UploaderTests): pulls + upserts + advances
  read-highwater only on 2xx; dedup by natural key.
- [ ] Commit. **Accept:** app tests green; pull path covered.

### Task 3.2: Cloud restore (fresh reinstall rebuilds history)
**Files:** `ios/OpenWhoop/` (a one-time full backfill-from-server on empty store), tests.
- [ ] On first launch with an empty local store, page the FULL history from `/v1/streams/*` +
  `/v1/daily` (not just since-highwater) → rebuild local history; then resume incremental.
- [ ] Test: empty store + stubbed server with N rows → local store rebuilt to N.
- [ ] Commit. **Accept:** app tests green; restore path covered.

---

# PHASE 4 — Harden + audit the end-to-end path

### Task 4.1: End-to-end integration test harness
**Files:** `home-server/stacks/whoop/ingest/tests/test_e2e.py` (or a script) + a Mac-side replay.
- [ ] Build an e2e test: take real captured frames (`fixtures/hist_biometric.bin` via `re/verify_v24.py`
  reassembly) → POST through `/v1/ingest-decoded` → `/v1/compute-daily` → assert `/v1/daily` + `/v1/sleep`
  return coherent results, and stream counts reconcile (no dup, no drop).
- [ ] Commit. **Accept:** e2e test green against the Docker Timescale fixture.

### Task 4.2: Audit pass — idempotency, dedup, gaps, ordering, resilience
**Files:** across iOS + server; a written audit note `docs/specs/2026-05-24-pipeline-audit.md`.
- [ ] Audit + add tests for: idempotent re-ingest (no dup rows); highwater monotonicity (upload + read);
  backfill resume-from-trim after disconnect (already fixed — add a regression test if missing);
  clock-correlation edge cases; the safe-trim invariant (decoded durable before ack); stream-count
  reconciliation phone↔server; the BLE disconnect/reconnect loop doesn't thrash.
- [ ] Fix any gap found; document the audit findings + the guarantees in the audit note.
- [ ] Run ALL suites (Swift x2, iOS, ingest). Commit. **Accept:** all green; audit note committed.

### Task 4.3: BLE robustness (if disconnects are frequent)
**Files:** `ios/OpenWhoop/BLE/BLEManager.swift`.
- [ ] If the Mac-side soak (Phase 5 device test) shows frequent mid-drain disconnects, add: backoff on
  reconnect, and ensure the periodic-backfill timer + the drain queue can't double-fire. Add a pure-logic
  test for the reconnect/backoff decision. (Skip if disconnects are rare.)
- [ ] Commit. **Accept:** app tests green.

---

# PHASE 5 — Build, deploy, verify, hand off

### Task 5.1: Deploy server (analysis + units + dashboard)
- [ ] Push home-server `main` → `ssh jpserver 'cd /home/jp/home-server && git pull && set -a &&
  . hosts/jpserver.env && set +a && docker compose -f stacks/whoop/docker-compose.yml up -d --build'`.
- [ ] Create the new tables in the LIVE DB (init.sql only runs on fresh volume): pipe the new
  CREATE TABLE/create_hypertable statements via `docker exec -i whoop-db sh -c "psql -U $POSTGRES_USER
  -d $POSTGRES_DB"` (idempotent `IF NOT EXISTS`).
- [ ] Trigger `/v1/compute-daily` for `my-whoop` for the last few days; `curl` `/v1/daily` + `/v1/sleep`
  + the dashboard (200) to verify real units + a sleep metric appear.
- [ ] **Accept:** dashboard at `whoop.example.com` shows the DAILY panel with a sleep metric + real units.

### Task 5.2: Build + install the app on the phone
- [ ] `cd ios && xcodegen generate && xcodebuild -project OpenWhoop.xcodeproj -scheme OpenWhoop
  -destination 'id=<DEVICE_UDID>' -derivedDataPath build/dd -allowProvisioningUpdates
  DEVELOPMENT_TEAM=<TEAM_ID> CODE_SIGN_STYLE=Automatic build` → `xcrun devicectl device install app
  --device <DEVICE_UDID> build/dd/Build/Products/Debug-iphoneos/OpenWhoop.app`.
- [ ] **Accept:** BUILD SUCCEEDED + App installed.

### Task 5.3: Autonomous device verification (Mac BLE, strap worn, phone BT off)
- [ ] From the Mac (`re/` bleak pattern), run a read-only soak: confirm the strap logs the type-47 store
  (GET_DATA_RANGE count climbs), and that a `re/` script driving the SAME handshake + ack-every-END drains
  + that the decoded values are plausible. Save captures to gitignored `.bin`.
- [ ] Confirm the server-side compute produces a sleep metric for a night of `my-whoop` data (if a night
  isn't present, note it for the user's manual test).
- [ ] **Accept:** documented evidence that the loop works end-to-end.

### Task 5.4: Write manual test steps
- [ ] Append a `## Manual test steps` section to THIS file: the exact steps the user runs when back
  (turn phone BT on → open OpenWhoop → wait ~5 min for a backfill cycle → check the sleep metric on the
  dashboard + on the phone → toggle live HR → trigger an on-demand raw-accel sample → confirm an exercise
  was detected for any earlier elevated-HR window). Include what to expect at each step + how to read the
  dashboard.
- [ ] Final: update auto-memory (mark milestones A–D done; note any remaining gaps). Commit.

---

## Self-review (done while writing)
- **Spec coverage:** daily sleep metric (2.2, 2.5, 2.6 phone-surface via 3.1/5.4) ✓; full sync (Phase 3) ✓;
  hardened/audited path (Phase 4) ✓; all bytes decoded + raw-accel path (1.1, 1.4; remaining optical
  byte[3]/IMU-tail are completeness — see matrix, fold into 4.2 if cheap) ✓; real units (1.2, 1.3) ✓;
  exercise detection incl. phone-disconnected runs (2.4) ✓; build+deploy+manual steps (Phase 5) ✓.
- **App UX** (polished charts/tabs) intentionally EXCLUDED (separate later plan) — only the minimal
  sleep-metric surface is in scope.
- **Open approximations flagged:** SpO2/temp/resp units + sleep staging + recovery/strain are
  WHOOP-*like*, not bit-identical (documented per task). Step COUNT needs the on-demand raw-accel sample.

---

## Manual test steps (run these when you're back — phone BT was OFF during the autonomous build)

> **Status at hand-off (2026-05-24):** All 18 in-scope tasks done (4.3 BLE-robustness skipped — the
> Mac soak showed no frequent disconnects). Server is DEPLOYED at `https://whoop.example.com`
> (analysis layer + real units + DAILY dashboard panel, all 3 derived tables live). The new app build
> is INSTALLED on the phone (`com.openwhoop.OpenWhoop`). Test suites all green:
> WhoopProtocol 62 · WhoopStore 46 · iOS 95 · ingest 166. Audit note: `docs/specs/2026-05-24-pipeline-audit.md`.
>
> **One known gap, by design:** the live server only has gappy test-session data (≈3289 biometric
> samples in bursts, no continuous overnight 1 Hz wear), so **no real sleep session has been computed
> yet** — `/v1/daily` rows exist but `total_sleep_min=0`, `recovery=null`. The sleep metric will populate
> only after a real overnight wear + sync (steps 1–4 below). The *pipeline* is proven end-to-end by the
> e2e test (`tests/test_e2e.py`, real captured frames → ingest → compute → daily/sleep, reconciled) and
> by a live Mac-BLE soak (48 type-47 records decoded with HR 70–76, |gravity|≈1 g).

1. **Turn the phone's Bluetooth ON, then force-quit + reopen OpenWhoop.** Expect: it connects to the
   strap (LiveView shows the connection), runs the high-freq-sync handshake, and begins the periodic
   type-47 backfill. (If the Mac is still connected to the strap, disconnect it first — one central at a
   time. The autonomous run left the strap untrimmed/read-only, so nothing was lost.)
2. **Wait ~5 minutes** for at least one periodic backfill cycle + a 30 s upload tick. Expect: the phone
   uploads decoded streams; on connect it also runs `ServerSync` (pull decoded + derived back) and, on a
   truly empty store only, a one-time full cloud restore.
3. **Wear the strap overnight** (this is the part the autonomous run could not do). The strap logs the
   1 Hz type-47 store continuously; the next morning's sync uploads it. This is what gives a real
   **sleep session** (needs a sustained ≥60-min low-movement + HR-dip block — gappy daytime data won't
   qualify).
4. **Check the sleep metric on the dashboard:** open `https://whoop.example.com`, pick device
   `my-whoop`. Expect the **DAILY panel** (top) to show, for the latest day: **Recovery** (0–100, colour
   -coded, `≈ approx`), **Strain** (0–21), **Sleep** (total `h:mm` + efficiency % + a colored
   **hypnogram** bar of light/deep/REM/wake + per-stage minutes), resting HR, avg HRV, and an exercise
   count. If a day shows nothing, trigger compute:
   `curl -X POST -H "Authorization: Bearer <WHOOP_API_KEY>" -H "Content-Type: application/json" -d '{"device":"my-whoop","date":"YYYY-MM-DD"}' https://whoop.example.com/v1/compute-daily`
   (compute also auto-runs after every ingest). The biometric charts below show **real units** (°C, %,
   bpm) with an `≈ approx` tag.
5. **Toggle live HR:** in LiveView tap the manual **Start HR** button. Expect live heart-rate to stream
   (this is opt-in; the periodic type-47 backfill, not live HR, is the primary metric source).
6. **Trigger an on-demand raw-accel sample:** in LiveView's research section tap **"Capture activity
   sample (30 s)"**. Expect: the strap's raw type-43 IMU streams for ~30 s and uploads (even with the
   global "capture raw frames" toggle OFF). This is the accelerometer-raw lever for future step/cadence
   work — repeated taps within the window are ignored.
7. **Confirm exercise detection:** if you had any sustained elevated-HR + motion block (a walk/workout)
   while wearing the strap — even while the phone was disconnected — it is detected *retroactively* from
   the backfilled 1 Hz store after the next sync. After compute, `GET /v1/daily` shows
   `exercise_count > 0` for that day; the DAILY panel shows the count. (Per-exercise detail and step
   COUNT need the raw-accel sample from step 6 — documented as out of scope for the 1 Hz path.)

**How to read the DAILY panel:** Recovery green ≥67 / amber 34–66 / red <34 (HRV-driven, approximate).
Strain 0–21 (cardiovascular load). Sleep efficiency = asleep ÷ in-bed. All derived metrics are
WHOOP-*like* approximations (sleep staging, recovery, strain, SpO2/temp/resp units), not bit-identical
to WHOOP's cloud — see `docs/specs/2026-05-24-pipeline-audit.md` for the exact guarantees + the
deliberate decisions (gravity2 is bit-identical to gravity1 in data so it isn't persisted; 1 s-resolution
key collapse is an intended ≈1 Hz fidelity property).
