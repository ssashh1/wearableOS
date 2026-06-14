# WHOOP — Debugging & Operations Runbook (2026-05-25)

Operational reference for debugging the pipeline (strap → phone → server → dashboard). Written after a
long debugging session; **read §3 (gotchas) before touching the strap or diagnosing "missing data."**

---

## 1. Reaching the data (for diagnosis)

### Live server (PREFERRED — clean reads, reflects the full pipeline, no mid-write races)
- URL: `https://whoop.example.com` · device id: `my-whoop`
- Auth: `Authorization: Bearer <WHOOP_API_KEY>`
  (the real key lives only in the gitignored `Secrets.xcconfig` / server env — never committed.)
- **Cloudflare WAF 403s the default urllib User-Agent → use `curl`** (or set a UA). Same for scripting.
- Endpoints (all Bearer):
  - `GET /v1/streams/{kind}?device=&from=&to=&limit=&max_points=` — kinds: `hr`(bpm), `rr`(rr_ms),
    `spo2`(red,ir,value,unit), `skin_temp`(raw,value,unit), `resp`(raw,value,unit), `gravity`(x,y,z),
    `battery`(soc,mv), `events`(kind,payload). `from`/`to` = unix seconds. `max_points` → server
    time-bucket downsamples (avg) to ~N points spanning the data; omit for raw rows (capped by `limit`).
  - `GET /v1/daily?device=&from=&to=` (from/to = `YYYY-MM-DD`) — daily_metrics rows.
  - `GET /v1/sleep?device=&date=` (`YYYY-MM-DD`) — sleep_sessions (start_ts,end_ts,efficiency,
    resting_hr,avg_hrv,stages:[{start,end,stage}]).
  - `GET /v1/summary?device=&from=&to=` — exact COUNT per stream (no limit). `GET /v1/devices`.
- Quick coverage/gap check (find where HR has gaps + the live frontier):
  ```bash
  curl -s -H "Authorization: Bearer $KEY" \
    "https://whoop.example.com/v1/streams/hr?device=my-whoop&from=0&to=2000000000&limit=200000" \
   | python3 -c "import sys,json,datetime as D; d=json.load(sys.stdin); ts=[D.datetime.fromisoformat(r['ts']).timestamp() for r in d]; print('span',D.datetime.utcfromtimestamp(ts[0]),'->',D.datetime.utcfromtimestamp(ts[-1])); [print('GAP %dmin %s'%((ts[i+1]-ts[i])/60, D.datetime.utcfromtimestamp(ts[i]))) for i in range(len(ts)-1) if ts[i+1]-ts[i]>180]"
  ```

### Local Postgres on the server (TimescaleDB, in docker on jpserver)
```bash
ssh jpserver
cd /home/jp/home-server && set -a && . hosts/jpserver.env && set +a
docker exec -i whoop-db sh -c 'psql -U $POSTGRES_USER -d $POSTGRES_DB'
```
Tables: `hr_samples, rr_intervals, events, battery, spo2_samples, skin_temp_samples, resp_samples,
gravity_samples` (raw streams, hypertables) + `sleep_sessions, exercise_sessions, daily_metrics`
(derived) + `devices, raw_batches`. `ts` is TIMESTAMPTZ.

### The phone's local SQLite (GRDB) — when you need on-device state
```bash
xcrun devicectl device copy from --device <DEVICE_UDID> \
  --domain-type appDataContainer --domain-identifier com.openwhoop.OpenWhoop \
  --source "Library/Application Support/OpenWhoop/whoop.sqlite" --destination /tmp/x.sqlite
```
- Tables: `hrSample, rrInterval, event, battery, spo2Sample, skinTempSample, respSample,
  gravitySample` (ts = unix-seconds INT; `synced` flag), `cursors` (`strap_trim` = offload frontier;
  `highwater:*` upload, `read:*` pull), `rawBatch`, `sleepSession`, `dailyMetric`.
- ⚠️ **WAL GOTCHA:** if the app is actively writing (offloading), a copy of just `whoop.sqlite` comes
  back **"database disk image is malformed."** Either copy `whoop.sqlite-wal` + `whoop.sqlite-shm`
  too (same command, append `-wal`/`-shm`), **or just use the live server** (it has the same decoded
  data and no copy race). The "No provider was found" line from devicectl is benign noise.

### Re-running the analysis / detector
- Pure modules: `home-server/stacks/whoop/ingest/app/analysis/` (`sleep.py` `detect_sleep(streams)`,
  `daily.py` `compute_day(conn, device_id, date)`, `hrv/recovery/strain/activity/exercise.py`).
- Input shape: `streams = {"hr":[{ts,bpm}], "rr":[{ts,rr_ms}], "resp":[{ts,raw}],
  "gravity":[{ts,x,y,z}], "skin_temp":[{ts,raw}]}`, ts epoch-seconds (datetimes coerced via
  `analysis/_utils.to_epoch`). Pure → run locally on pulled rows OR in the container.
- Force a recompute server-side: `POST /v1/compute-daily {device, date}` (Bearer). Recompute is
  idempotent (delete-then-insert per day). venvs: ingest tests = `~/Developer/home-server/venv`
  (py3.11, needs Docker); re/ scripts + goldens = `whoop-reader/.venv` (py3.14).

---

## 2. Sleep-detection diagnosis

Detector = gravity-stillness sleep/wake DETECTION (te Lindert 2013) + a heuristic STAGING layer (all in
`analysis/sleep.py`), flagged **APPROXIMATE**. Detection (gravity-stillness): still `<0.01 g`, 15-min
rolling window, ≥0.70 still-fraction → asleep, break runs on >20-min gaps, merge <15-min periods,
session must be >60 min; HR-baseline refinement on top.

**#1 thing to check FIRST: gaps in the input streams.** This pipeline's data routinely has gaps
(offload lag + the strap not logging during disconnects/reboots — see §3). The detector's `>20-min
gap` rule **breaks a night into multiple sessions** and its bounds shift if the night's gravity/HR
stream is gappy. So before blaming the algorithm: pull last night's `gravity` + `hr` streams for the
window, and look for gaps (use the curl snippet in §1). A "much shorter total" or "split into several
sessions" almost always traces to missing input data, not the thresholds. Only after confirming the
input is continuous should you tune detection thresholds (60-min min, 0.70 still-fraction, 15-min merge).
Re-run `detect_sleep` over the pulled streams and compare its session bounds to the user's recollection.

### Diagnosed + fixed 2026-05-25 (first real overnight: night of 5/24→5/25, `my-whoop`)
First full overnight wear+sync. **Detection was fine** — one continuous session 09:41→19:01 UTC
(02:41am→12:01pm PDT, vs the wearer's "≈2am→11:50am": onset ~40 min late = sleep latency, wake ~11 min
late), no gaps (38k samples ≈ 1 Hz, dense), NOT fragmented. **The STAGING was the problem:** it reported
`deep 15m, rem 0m, light 445m, 16 disturbances` — REM=0 is physiologically impossible and the
disturbance count was wildly inflated. Two root causes in the old `_classify_window`:
1. **REM was structurally unreachable.** `wake` was checked before `rem` and stole every movement
   window; the only other REM path required a 5-min-window *mean* HR ≥ `session_max − 6` (≈86 bpm),
   which never happens in sleep.
2. **Absolute bands didn't fit the signal.** Overnight HR sits in a narrow few-bpm band over the
   resting floor and per-window mean movement is tiny, so the fixed `min+4`/`min+6` bpm bands and
   `0.02 g` mean-movement "burst" threshold mis-binned everything (tiny deep, no REM, every position
   change → a 5-min wake block).

**Fix:** stage RELATIVE to each night's own distribution. HR_LOW (p20) / HR_HIGH (p72) percentile bands
of per-window mean HR; "moving" = fraction of a window's per-sample gravity deltas over the still
threshold (≥0.15 of the window = arousal). deep = still + low-HR + regular resp; rem = still + high-HR;
wake = moving + high-HR; light = default. **HRV is deliberately NOT a staging input** — per-window RMSSD
is too noisy at 5-min granularity (gating deep on it swung deep between 7% and 30%); avg HRV is still
reported separately for recovery. Result on the same night: `deep 90m (17%), rem 115m (21%),
light 330m (62%), ~6 disturbances, 95% eff` — coherent. Percentiles/thresholds are named constants at
the top of `sleep.py`; re-tune against `diag` (pull streams → `detect_sleep` → print the stage split).

---

## 3. Hard-won operational gotchas (READ THIS before debugging "missing data")

1. **Driving the strap from the Mac INTERRUPTS its normal logging.** Reboots (`REBOOT_STRAP`) and
   repeated high-freq-sync sessions (no-ack peeks, `ENTER_HIGH_FREQ_SYNC`) tie the strap up so it
   isn't free-running its 1 Hz biometric logging → **creates gaps**. During this session, ~90 min of
   Mac-driven RE produced a 90-min HR gap. **Minimize Mac/BLE sessions during normal wear; every
   reboot/peek risks a logging gap.**

   **RESOLVED IN-APP (sync-hardening branch):** The phone no longer sends `ENTER_HIGH_FREQ_SYNC`.
   Plain `SEND_HISTORICAL_DATA`(22) returns the full type-47 biometric store — high-freq-sync was
   unnecessary and was the primary data-loss root cause (a strap stranded in high-freq mode stops its
   1 Hz logging). The iOS connect handshake now sends `EXIT_HIGH_FREQ_SYNC`(97) **defensively on every
   connect** to release any strap stranded by an older build. Verified by `re/test_offload_without_highfreq.py`
   (Phase A: no high-freq-sync → 40 type-47 records returned; Phase B: with high-freq-sync → 0 records).
   The phone's periodic backfill uses plain `SEND_HISTORICAL_DATA` and does NOT interrupt logging.

2. **"Samples not going up" usually = offload LAG, not broken logging.** The strap logs ~1 Hz when
   worn; the offload drains oldest→newest from `strap_trim` and can be hours behind. The recent data
   is on the strap, not yet pulled. **Don't misdiagnose offload-lag as off-wrist or a logging failure**
   (it was misdiagnosed twice this session). Verify on the server: is the frontier (max ts) advancing
   toward now? Confirm wear via the **events stream `WRIST_ON`/`WRIST_OFF`** — don't guess.

3. **type-47 is VERSION-keyed — never hand-roll V24 offsets in ad-hoc scripts.** A naive decoder that
   forces the V24 byte layout produces **garbage HR/skin_contact on non-V24 records** (this caused a
   false "biometrics are corrupt" alarm). Use the real version-aware `whoop_protocol.parse_frame` /
   `extract_historical_streams`, not inline `struct.unpack` offsets.

4. **The raw "flood" = R10/R11 realtime, controlled by `SEND_R10_R11_REALTIME(63)` payload
   `[0x01]`on/`[0x00]`off — NOT `STOP_RAW_DATA(82)`** (which never affected it). `[0x00]` stops the
   ~2/s type-43 flood and persists across reconnect; the iOS connect handshake sends it. Identified
   while studying the official app for interoperability. The sigproc feature-flags (`sigproc_10_sec_dp`,
   `enable_r19_packets`, …) do **NOT** control the flood and turning them off did **NOT** break
   biometrics (despite an in-session false alarm). `re/device_config.py` holds `DEVICE_UUID`
   (gitignored `re/device_local.py`).

5. **Cloudflare in front of the tunnel:** WAF 403s default UAs (use curl); `/static/*` is
   path-cached, so after a dashboard deploy verify via the container
   (`ssh jpserver 'docker exec whoop-ingest grep -c <token> /app/app/static/app.js'`) or a
   `?v=<timestamp>` query — a plain `curl` of `/static/app.js` can return a stale copy. The browser
   gets the new file via the bumped `app.js?v=` cache-buster in index.html.

6. **Dashboard:** charts share one x-axis and anchor the right edge to live "now" (gap from last point
   → right edge = sync lag). Stream charts downsample via `max_points`. Bump `app.js?v=` on any static
   change. Sleep-history panel needs real overnight data to populate.

---

## 4. Key facts & access

- Device: iPhone udid `<DEVICE_UDID>`, team `<TEAM_ID>`, bundle `com.openwhoop.OpenWhoop`.
  Strap CB UUID `<STRAP_UUID>…` (in `re/device_config.py`). Build+install:
  `cd ios && xcodegen generate && xcodebuild -project OpenWhoop.xcodeproj -scheme OpenWhoop
  -destination 'id=<DEVICE_UDID>' -derivedDataPath build/dd -allowProvisioningUpdates
  DEVELOPMENT_TEAM=<TEAM_ID> CODE_SIGN_STYLE=Automatic build` →
  `xcrun devicectl device install app --device <DEVICE_UDID> build/dd/Build/Products/Debug-iphoneos/OpenWhoop.app`.
- Server deploy: push home-server `main` → `ssh jpserver 'cd /home/jp/home-server && git pull && set -a
  && . hosts/jpserver.env && set +a && docker compose -f stacks/whoop/docker-compose.yml up -d --build'`.
  init.sql is re-applied idempotently on startup (new tables auto-create).
- Read-only strap diagnostics (BT off, phone app quit): `re/diagnose_biometrics.py` (flags + is-logging
  + decode newest records), `re/diag_logging.py`, `re/verify_r10r11_off.py`, `re/stop_r10r11.py`,
  `re/enum_config_v4.py` (config/flag dump). All connect via `re/device_config.py`. `GET_DATA_RANGE`:
  the newest-unix word advancing ~1/s ⇒ logging now; cursor words ≈ write vs read(trim) pointers.
- iOS connect handshake (sync-hardening model): `EXIT_HIGH_FREQ_SYNC(97)` [defensive, releases any
  stranded strap] → `SEND_R10_R11_REALTIME[0x00]` [flood off] → conditional `SET_CLOCK` (only if
  `ClockPolicy.shouldSetClock` — drift ≥2 s, evaluated after GET_CLOCK response) → `requestSync(.connect)`
  → plain `SEND_HISTORICAL_DATA(22)` → type-47 records. No `ENTER_HIGH_FREQ_SYNC`. Backfill watchdog 60 s.
- **Sync cadence (WHOOP-style):** 15-min periodic floor (`BLEManager.backfillIntervalSeconds = 900`,
  matching WHOOP's `PeriodicWorkRequest(15, MINUTES)`) plus event triggers: `connect` / `foreground`
  (scenePhase `.active`) / `manual` ("Sync now" button) / `strap` (incoming EVENT packets). All route
  through `BLEManager.requestSync(_:)`, gated by the pure `BackfillPolicy` (periodic floor 900 s;
  event floor 90 s; manual always runs). Persisted watermark: `UserDefaults` key `backfillLastAt`
  (survives relaunch, giving cross-launch rate-limiting like WHOOP's `DATA_SYNC_WORKER_LAST_WORK_TIME`).
- **Stuck-strap watchdog (`StuckStrapDetector`):** after each offload, compares the local data frontier
  (`WhoopStore.latestHRSampleTs`) against the strap's newest-record timestamp (from GET_DATA_RANGE).
  "Strap ahead AND our frontier frozen ≥10 min" → `state.strapNeedsReboot` (LiveView banner) + defensive
  EXIT + SET_CLOCK recovery. Expected to fire rarely now that high-freq-sync stranding is gone — insurance.
- **Freshness / sync tile:** `StalenessPolicy` maps `lastSyncedAt` → `caughtUp` (<1 h) / `catchingUp`
  (≥1 h) / `stale` (≥6 h). `lastSyncedAt` stamped on each clean drain (`HISTORY_COMPLETE`), persisted
  in UserDefaults. A local `SyncNudge` notification (6 h, rescheduled on every successful sync) is the
  only mechanism that defeats iOS's force-quit wall (tap → relaunch → catch-up).
- **BLE state-restoration:** `bootstrapStore()` is also called from `willRestoreState` (idempotent) so
  the store is ready before restored BLE data arrives on a state-restoration relaunch.
- ServerSync pull/restore runs AFTER the offload (deferred, so it doesn't starve the trim-ack). Decoded
  upload uses a per-row `synced` flag (WhoopStore v5), not a forward highwater (which stranded backfilled
  older-ts rows).

## 5. What shipped this session (2026-05-25)
R10/R11 flood fix (cmd 63); per-row synced upload (WhoopStore v5); offload watchdog 20→60s +
don't-drain-the-live-flood + defer ServerSync pull until after offload; trimmed handshake; dashboard
(sleep-history drill-down, shared time axis, x-axis time ticks, server-side `max_points` downsampling,
live-"now" right edge). Repo now on private GitHub. See `MEMORY.md` / `whoop-productionization.md`.

### Sync-hardening (branch `sync-hardening`, 2026-05-25)
- **No high-freq-sync:** `ENTER_HIGH_FREQ_SYNC` removed from the handshake; `EXIT_HIGH_FREQ_SYNC(97)`
  sent defensively on every connect instead. Offload uses plain `SEND_HISTORICAL_DATA(22)`. Validated by
  `re/test_offload_without_highfreq.py` (Phase A no-high-freq: 40 type-47 records; Phase B with: 0).
- **WHOOP-style cadence:** `BackfillPolicy` (pure, unit-tested) gates all offload kicks via
  `BLEManager.requestSync(_:)` — 15-min periodic floor, 90-s event floor, manual always runs. Persisted
  `backfillLastAt` watermark survives relaunch. Triggers: `connect` / `foreground` / `manual` / `strap`.
- **Drift-gated clock:** `ClockPolicy.shouldSetClock` — SET_CLOCK only when drift ≥2 s (evaluated after
  GET_CLOCK response); watchdog recovery also issues it.
- **Stuck-strap watchdog:** `StuckStrapDetector` — after each offload, compares local data frontier vs
  strap's newest record; flags `strapNeedsReboot` if strap is ahead AND frontier frozen ≥10 min.
- **Freshness UX:** `StalenessPolicy` (caughtUp / catchingUp / stale) → sync tile in LiveView;
  `lastSyncedAt` persisted watermark; `SyncNudge` local notification (6 h) defeats the iOS force-quit wall.
- **State restoration:** `bootstrapStore()` called from `willRestoreState` so the store is ready before
  restored BLE data arrives on a CoreBluetooth state-restoration relaunch.

### Later 2026-05-25 (first overnight → dashboard + sleep-staging pass, home-server repo)
- **Sleep staging rewrite** (`analysis/sleep.py`) — percentile-relative bands, REM reachable, realistic
  disturbances (see §2). Tests: ingest suite 175 passed.
- **Dashboard** (`ingest/app/static/`): bed/wake clock times on the DAILY card + each sleep-history
  night (new `daily_metrics.sleep_start`/`sleep_end` cols → `/v1/daily`; idempotent `ALTER … IF NOT
  EXISTS` migrates the live DB on bootstrap); all timestamps now 12-hour AM/PM in the **viewer's** local
  tz (`fmtClock`/`fmtFull`/x-ticks, was `hour12:false`); **chart height-growth bug fixed** (`sizeCanvas`
  caches logical height in `dataset.h` so the dpr-scaled `cv.height` no longer compounds the reflected
  `height` attr on each ⟳ reload, + pins CSS display height); **two-column layout** (left = DAILY +
  SLEEP HISTORY, right = SIGNALS; collapses <1000px). Bumped `app.js?v=16`.
- Deploy these via the §4 server-deploy steps; verify `/static` past Cloudflare with the `?v=` bump.
