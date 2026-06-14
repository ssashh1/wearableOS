# Derived-Metrics Accuracy Overhaul — Autonomous Plan (2026-05-26)

> **You are picking up an open-ended quality task: make EVERY derived health metric accurate and
> meaningful, validated against real WHOOP ground truth.** Work autonomously and exhaustively. Use
> **deep research via subagents**, lean on **established libraries + published prior art** for the math
> (don't hand-roll what neurokit2/scipy/peer-reviewed algorithms already do well), and validate every
> number against the user's real WHOOP data. Use **superpowers:subagent-driven-development** (fresh
> subagent per task + two-stage review) and **superpowers:systematic-debugging** when a metric is off.
> The previous pipeline work made raw data flow reliably; this plan makes the *insights* trustworthy.

---

## 0. MISSION & DEFINITION OF DONE

**Mission:** Every derived metric the product exposes is **accurate** (matches real WHOOP within a
stated tolerance, on the same underlying data) and **meaningful** (physiologically correct,
baseline-normalized where WHOOP normalizes, with honest units and documented methodology).

**Definition of done:**
1. A **validation harness** compares each metric to real WHOOP values over an overlapping period and
   reports error vs. explicit per-metric targets (§3). All targets met or the residual gap explained.
2. Raw sensor signals (SpO2 red/IR, skin temp, respiratory) are **calibrated to physical units** and
   validated against WHOOP's reported SpO2 %, skin-temp °C, and respiratory rate.
3. Each metric uses a **vetted algorithm/library** with **personal baselines** where WHOOP uses them
   (HRV, RHR, recovery, skin-temp deviation), not hard-coded population constants.
4. Recomputed over existing history, deployed to the server, surfaced with correct units on the
   dashboard, and documented in a methodology doc (algorithm + library + validation result per metric).

**Out of scope:** consumer UX polish (separate plan); new BLE/protocol work (the pipeline is fixed).

---

## 1. WHERE THINGS LIVE (verified 2026-05-26 — the prior survey conflated layers; trust this)

- **Production insights layer (the code you change):** `~/Developer/home-server/stacks/whoop/ingest`
  — Python / FastAPI / **TimescaleDB**. venv `~/Developer/home-server/venv`. Tests:
  `cd ~/Developer/home-server/stacks/whoop/ingest && ~/Developer/home-server/venv/bin/python -m pytest -q`
  (needs Docker). **READ THIS DIRECTORY FIRST** — `app/analysis/` (hrv/sleep/recovery/strain/activity/
  exercise/daily) is the Python port you are improving. Deploy: `ssh jpserver 'cd ~/home-server && git
  pull && docker compose -f stacks/whoop/docker-compose.yml up -d --build'`.
- **Method references (published):** HRV — Task Force 1996 / neurokit2; sleep — Cole–Kripke 1992,
  te Lindert 2013, Walch 2019; strain — Karvonen 1957, Edwards 1993, Banister 1991; energy —
  Keytel et al. 2005. Implement from these primary sources; the earlier naive formulas are being replaced.
- **iOS-side derived metrics (keep parity / or treat server as source of truth):**
  `Packages/WhoopStore/Sources/WhoopStore/DerivedMetrics.swift`; phone DB tables `sleepSession`,
  `dailyMetric`. Decide explicitly whether the phone recomputes or just mirrors the server.
- **Server read API (already live):** `https://whoop.example.com` — `/v1/daily`, `/v1/sleep`,
  `/v1/compute-daily`, `/v1/streams/{hr,rr,spo2,skin_temp,resp,gravity}`, `/v1/summary`. Bearer
  `WHOOP_API_KEY` (in `~/Developer/whoop/re/device_local.py` / Secrets; the live key in earlier docs is
  `<WHOOP_API_KEY>`). Device id `my-whoop`. **Cloudflare WAF 403s
  default UAs — use `curl`.**
- **Schema:** `protocol/whoop_protocol.json` (3 synced copies; `scripts/sync-schema.sh`).
- **Context docs:** `docs/plans/2026-05-24-whoop-insights-megaplan.md` (how the layer was built),
  `docs/specs/2026-05-25-strap-serving-ROOT-CAUSE-and-fix.md` (the pipeline fix).

---

## 2. SIGNALS WE ACTUALLY HAVE (decoded + persisted; correct the stale "not on the wire" claim)

`extractHistoricalStreams`/`extract_historical_streams` decode type-47 V24 at ~1 Hz and the server
persists all of these (server holds ~76k rows each; this session watched them insert):

| Signal | Table | Unit/state | Notes |
|---|---|---|---|
| Heart rate | `hr` | bpm | clean, 1 Hz |
| RR intervals | `rr` | ms | beat-to-beat; **the HRV source** |
| SpO2 | `spo2` | **raw red + IR ADC** | UNCALIBRATED → needs ratio-of-ratios → SpO2 % |
| Skin temp | `skin_temp` | **raw ADC** | UNCALIBRATED → thermistor curve → °C |
| Respiratory | `resp` | **raw** | UNCALIBRATED → breaths/min (or derive from PPG/accel) |
| Gravity (accel) | `gravity` | x,y,z in g | on-device calibrated; movement/sleep source |
| Events | `event` | — | strap events |
| Battery | `battery` | % / mV | — |

High-rate raw IMU/PPG is NOT routinely kept (opt-in on-demand only) — assume you work from the 1 Hz
streams above. **Do NOT trust the old `FINDINGS.md` line that says SpO2/skin-temp aren't on the wire —
that predates the finished decode; the raw values ARE present and persisted.**

### Current algorithms (what you're replacing — all naive / unvalidated)
- **Strain:** Edwards zone TRIMP → `21·ln(TRIMP+1)/ln(7201)`; assumes fixed max/resting HR, no personalization.
- **HRV:** rolling 300-sample RMSSD, integer-truncated (loses sub-ms).
- **Sleep "staging":** gravity still/active threshold only → **NOT real wake/light/deep/REM**; sleep
  score = naive `duration/8h`.
- **Recovery:** present but thin / under-defined; not baseline-normalized.
- **Stress:** Baevsky index (50 ms bins).
- **Activity/Exercise:** gravity-threshold detection; exercise = duration stats only (no intensity).
- **SpO2/skin-temp/resp units:** approximate/guessed conversions ("APPROX").

---

## 3. METRICS IN SCOPE + ACCURACY TARGETS

Targets are vs. real WHOOP on the SAME underlying data (§4). Tune targets in Phase 0 once you see the
ground-truth spread, but start here:

| Metric | Target vs WHOOP | Meaningful means |
|---|---|---|
| **Resting HR** | ±2 bpm | nightly low, sleep-derived |
| **HRV (RMSSD)** | ±5 ms or ±10% | sleep-window RMSSD, float precision, WHOOP's during-sleep convention |
| **SpO2 %** | ±2% | calibrated ratio-of-ratios, sleep-sampled |
| **Skin temp** | ±0.3 °C (and matching deviation-from-baseline) | calibrated + baseline-relative |
| **Respiratory rate** | ±1 breath/min | sleep respiratory rate |
| **Sleep duration / efficiency** | ±10 min / ±5% | from real staging, not duration heuristic |
| **Sleep stages (wake/light/deep/REM)** | ≥70% epoch agreement (stretch: WHOOP-comparable stage %) | multi-signal staging, not still/active |
| **Recovery %** | ±7% | baseline-normalized HRV+RHR+sleep+resp, 0–100 |
| **Strain** | ±1.5 (0–21) | personalized HRR zones, log-scaled, day-cycle aligned to WHOOP |
| **Stress / other** | qualitative match (trend correlation) | physiologically sane |

---

## 4. THE GROUND-TRUTH STRATEGY (this is the linchpin — without it "accuracy" is unverifiable)

There is currently **no real-WHOOP reference data** in the system. You cannot claim accuracy without it.
Key enabler: **it's one physical strap with a 14-day flash buffer**, so the *same raw signal* can be
scored by BOTH WHOOP's cloud and our pipeline for overlapping days.

**Establish ground truth (pick whichever the user can provide — REQUIRES the user; flag immediately if
unavailable and proceed with the weaker fallback):**

1. **WHOOP official API (best).** `developer.whoop.com` OAuth2. Build a small read-only client to pull
   the user's: **recovery** (`hrv_rmssd_milli`, `resting_heart_rate`, `spo2_percentage`,
   `skin_temp_celsius`), **sleep** (stage durations, efficiency, `respiratory_rate`, disturbances,
   start/end), **cycle/workout** (`strain`, avg/max HR, `kilojoule`). Needs the user to register an app
   + authorize (give you a token/refresh token). This is the richest, per-metric ground truth.
2. **WHOOP data export (fallback).** The user exports CSV/JSON from the WHOOP app/account.
3. **Concurrency note:** the strap can't be bonded to the WHOOP app and OpenWhoop simultaneously. To get
   a fresh overlap: user wears the strap on the **official WHOOP app for a validation window (≥5 nights
   incl. a workout)** → WHOOP cloud computes its metrics → user re-pairs to OpenWhoop and **offloads
   those same days from the 14-day flash** → you compute ours over the identical raw data → compare.
   If the user switched to OpenWhoop <14 days after last using the WHOOP app, an overlap may already
   exist — check first.

**Build a validation dataset:** align WHOOP's per-day/per-night values with our streams for the same
timestamps, stored as fixtures the harness reads. **Crucially, WHOOP's reported SpO2 %, skin-temp °C,
and respiratory rate become the calibration targets for our raw sensor conversions (Phase 1).**

If NO ground truth is obtainable: fall back to (a) reference-implementation agreement (our HRV ==
neurokit2 on the same RR), (b) physiological plausibility bounds, (c) internal consistency — and
clearly mark those metrics "plausible, not validated."

---

## 5. EXECUTION PHASES

### Phase 0 — Ground truth + deep research (do before touching algorithms)
- **0a. Locate + honestly survey** the real Python `ingest/app/analysis/` (NOT the Rust clone). Document
  each metric's current formula, inputs, and gaps.
- **0b. Obtain ground truth** (§4). If it needs the user (API auth / export / a validation-wear window),
  surface that as the first blocking ask and set up the rest meanwhile.
- **0c. Deep research via subagents — one per topic, in parallel.** Each returns: WHOOP's *published*
  methodology + the best open library/algorithm + exact formulas/citations:
  - HRV (RMSSD during sleep; WHOOP's last-SWS/weighted convention) — neurokit2 / hrv-analysis / pyHRV.
  - Sleep staging from HR + HRV + accel + respiratory (wearable, no EEG) — e.g. Walch et al. 2019
    (open code/data), `sleepecg`, Cole-Kripke/Sadeh actigraphy for sleep-wake; pick the best fit.
  - Recovery model (WHOOP: weighted HRV-vs-baseline + RHR-vs-baseline + sleep performance + respiratory).
  - Strain (0–21 log scale; cardiovascular load via HRR zones; personalized HRmax/RHR; day-cycle defn).
  - SpO2 from red/IR PPG (ratio-of-ratios calibration), skin-temp thermistor curve, respiratory rate
    from PPG/accel (neurokit2 RSP / heartpy).
  - Personal-baseline methodology (rolling 30-day, robust to outliers/missing nights).
- **0d. Decide library stack** (add to ingest deps): start with **neurokit2** (HRV, RSP, PPG),
  **scipy/numpy** (already available), **hrv-analysis**/**pyHRV** as cross-check, a sleep-staging lib if
  one fits. Prefer well-maintained, documented libraries over bespoke math.

### Phase 1 — Signal calibration (units first; metrics depend on them)
- Fit **raw SpO2 (red/IR) → SpO2 %** (ratio-of-ratios `R=(AC/DC)_red/(AC/DC)_ir`, linear calib
  `SpO2=a−b·R`) with `a,b` fit to match WHOOP's reported SpO2 over the overlap.
- Fit **raw skin-temp ADC → °C** (thermistor/Steinhart-Hart or empirical fit) to match WHOOP skin-temp;
  also produce the **deviation-from-baseline** WHOOP reports.
- **Respiratory rate**: either calibrate the raw field or derive from PPG/accel via neurokit2; validate
  vs WHOOP `respiratory_rate`.
- Gate: each calibrated signal within §3 target before building metrics on it.

### Phase 2 — Per-metric rebuild (vetted math + personal baselines)
Rebuild each module in `ingest/app/analysis/` using the Phase-0 algorithms/libraries:
- **RHR**, **HRV (RMSSD, sleep-window, float)**, **respiratory** (calibrated).
- **Sleep**: real staging (wake/light/deep/REM) from HR+HRV+accel+resp; efficiency, latency, WASO,
  disturbances, duration from staging.
- **Recovery**: baseline-normalized weighted composite (HRV, RHR, sleep, respiratory) → 0–100.
- **Strain**: personalized HRmax (and RHR from our RHR), HRR zones, TRIMP → log 0–21, aligned to WHOOP's
  day-cycle definition.
- **Activity/Exercise**: detection + per-bout intensity (HR-zone load), not just duration.
- Keep **stress** if useful; validate trend.
- Maintain Swift/Python parity or designate the server as source of truth (update `DerivedMetrics.swift`
  accordingly). Update `whoop_protocol.json` + run `scripts/sync-schema.sh` if any shared shape changes.

### Phase 3 — Validation harness + iterate (systematic-debugging per miss)
- Build `ingest/.../validation/` that loads the WHOOP ground truth + our recomputed metrics over the
  overlap and reports per-metric error vs §3 targets (table + plots).
- For each metric that misses: use **superpowers:systematic-debugging** — find root cause (calibration?
  baseline window? algorithm choice? day-boundary/timezone?), fix, re-validate. Don't thrash >3 fixes
  without stepping back to question the approach.
- Add regression tests asserting accuracy on the fixture set (not just "runs").

### Phase 4 — Integrate, recompute, deploy, document
- Recompute all history (`/v1/compute-daily` or a backfill script) with the new algorithms.
- Surface correct units + new metrics on the dashboard.
- **Methodology doc** (`docs/specs/2026-05-26-metrics-methodology.md`): per metric — algorithm, library,
  formula, baseline definition, validation result (error vs WHOOP), and honest caveats.
- Deploy (ssh jpserver + docker compose). Keep all suites green (WhoopProtocol/WhoopStore/iOS/ingest).
- Commit per task to `main` in each repo. Co-author trailer:
  `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.

---

## 6. PRIOR ART & LIBRARY POINTERS (start here; deep-research to refine)
- **HRV:** neurokit2 (`nk.hrv_time` RMSSD/SDNN/pNN50), hrv-analysis, pyHRV; Task Force 1996 standard.
  WHOOP HRV = RMSSD measured during sleep (weighted toward deep sleep).
- **Respiratory / PPG / SpO2:** neurokit2 (`nk.rsp_*`, `nk.ppg_*`), heartpy; ratio-of-ratios for SpO2.
- **Sleep staging (wearable):** Walch et al. 2019 "Sleep stage prediction with raw accel + PPG"
  (open dataset/code); `sleepecg`; Cole-Kripke / Sadeh for sleep-wake actigraphy.
- **Strain / cardiovascular load:** Banister/Edwards TRIMP; WHOOP strain = 0–21 logarithmic from
  HR-zone load (HRR-based). WHOOP "Locker"/support docs describe recovery/strain/sleep qualitatively.
- **Baselines:** rolling 30-day robust baseline (median/trimmed), as WHOOP does for HRV/RHR/skin-temp.
- **Method references:** neurokit2 (HRV); the published primary sources above for sleep/strain/energy.

---

## 7. PREREQUISITES & RISKS
- **Ground truth needs the user** (WHOOP API auth or export or a validation-wear window). This is the #1
  prerequisite — without it, accuracy is unprovable. Surface it first.
- **Same-strap concurrency**: can't run WHOOP app + OpenWhoop at once; use the 14-day-flash overlap method.
- **Sleep staging is the hardest** metric and may not hit WHOOP-level agreement without EEG-grade signals;
  set a realistic bar (epoch agreement %) and be honest about the ceiling.
- **SpO2/skin-temp/resp calibration** is sensor-specific; the WHOOP-reported values are your only
  calibration reference — guard against overfitting (hold out nights).
- Don't churn the strap; the pipeline is fixed — this plan is mostly server-side compute + validation.

---

## 8. DELIVERABLES
1. Calibrated SpO2/skin-temp/resp conversions (validated).
2. Rebuilt, library-backed, baseline-normalized metric modules in `ingest/app/analysis/`.
3. A validation harness + fixtures + regression tests proving each metric vs WHOOP within target.
4. Recomputed history, deployed server, dashboard with correct units.
5. `docs/specs/2026-05-26-metrics-methodology.md` documenting algorithm + library + accuracy per metric.
6. A short results summary: which metrics hit target, which didn't, and why.
