# Plan: Retire raw upload — biometric type-47 sync, decoded-only pipeline

_Status: COMPLETE 2026-05-24 — Phases 0–4 done, deployed, and VERIFIED END-TO-END on the real
device + server. Decisions confirmed by user: OFF-by-default research-raw toggle; SpO2/skin-temp/resp
uploaded as raw ADC._

## Phase 4 — on-device end-to-end (VERIFIED)
Server deployed to jpserver (4 new hypertables created live + ingest rebuilt; tunnel auth re-verified,
all /v1/* require Bearer). App built+signed+installed to the iPhone (CLI). On connect it ran the full
handshake → pulled type-47 V24 → decoded + stored 1522 samples → uploaded DECODED-ONLY. Server after:
hr 397→1090, rr 148→371, spo2/skin_temp/resp/gravity 644 each, raw batches unchanged (312 — zero raw
uploaded). **On-device bug found + fixed (`c6d02e0`):** the persistent ~2/s type-43 raw flood re-armed
the backfill idle-watchdog on every frame, so the session never completed/timed-out and the
post-backfill upload never fired; fix = re-arm the watchdog ONLY on offload frames (type 47/48/49/50)
via `BLEManager.isOffloadFrame`, never the live flood (40/43). App tests 67 green.
_Depends on: Task 1 decode library (DONE — type-47 V24 + biometric streams land with byte-parity)._

## Execution record
- Phase 0 (server): home-server `0880a13` — 4 hypertables + upsert + widened model, 28 tests green.
- Task A (WhoopStore): whoop `064b612` — v3 tables + insert + reads, 39 tests green.
- Task B (handshake + ack): whoop `362cc13` — SET_CLOCK + GET_HELLO_HARVARD + GET_ADVERTISING_NAME +
  ENTER_HIGH_FREQ_SYNC before SEND_HISTORICAL_DATA; ack fixed to `[0x01]+metadata.data[10:18]`.
- Task C (upload + retire raw): whoop `2dda010` — 4 new decoded drains; raw enqueue + auto-upload
  gated behind OFF-by-default `enableRawCapture`. App 66 tests green.
- Final cross-cutting review: clean (iOS↔server JSON contract verified, safe-trim preserved).

## Goal
Rework the iOS pipeline so the strap's 14-day biometric store (type-47 V24) is pulled via the
high-freq-sync handshake, decoded losslessly into named streams, and uploaded **decoded-only**.
Retire the default raw type-43 upload. Server persists the new biometric streams.

## Why this is the right change (grounded in the code map)
- The iOS `Backfiller` already decodes via `extractHistoricalStreams` and commits decoded→raw→ack.
  But `BLEManager` connect sends only `GET_CLOCK` + `STOP_RAW_DATA` + `GET_DATA_RANGE` +
  `SEND_HISTORICAL_DATA` — it never does `SET_CLOCK` or `ENTER_HIGH_FREQ_SYNC`. Per protocol §0-bis
  a plain offload yields type-43 live-contamination, NOT the type-47 V24 biometric records. So today's
  "historical" backfill is decoding the wrong source.
- `extractHistoricalStreams` (now, post-Task-1) emits hr/rr/spo2/skin_temp/resp/gravity from type-47.
  The server's Python `extract_historical_streams` does too — but `ingest.py` only upserts hr/rr/events/battery.
- Decoded rows are already committed before raw is queued, so removing raw is safe (decoded stays durable).

## Raw-optical (1921) policy — DECISION (my call, per mission; confirm please)
**Default app uploads DECODED ONLY.** Specifically:
- type-47 V24 biometric streams (hr, rr, spo2_raw, skin_temp_raw, resp_raw, gravity) — the real history.
- type-43 header HR/RR for any live view (already decoded).
- The green PPG waveform (s24 channel) is NOT uploaded by default (it's a research signal; red/IR/ambient
  aren't even in it). 
- Keep a **user-toggled "Research raw capture" switch, OFF by default**, that still writes raw type-43
  frames to the LOCAL store only (never auto-uploaded) so the remaining RE (optical config header,
  byte[3], IMU tail, gyro scale) can continue. Raw is uploaded only if the user explicitly exports.
This satisfies "default sends only decoded; raw retired/optional."

## Phases

### Phase 0 — Server: persist biometric streams (do first; backward-compatible)
- `home-server` `db/init.sql`: add hypertables `spo2_samples(ts, red, ir)`, `skin_temp_samples(ts, raw)`,
  `resp_samples(ts, raw)`, `gravity_samples(ts, x, y, z)` (raw ADC + g; document cloud-computes units).
- `store.py upsert_streams()`: insert the 4 new streams when present (idempotent, like existing).
- `DecodedStreams`/`DecodedBatch` Pydantic: accept optional spo2/skin_temp/resp/gravity arrays.
- `/v1/ingest-decoded` already routes to `upsert_streams` — just widen the model.
- Tests: extend the ingest test to POST a V24-derived decoded batch (use the real frame from
  `test_historical_v24.py`) and assert rows land in all streams.
- This is additive — existing clients keep working.

### Phase 1 — iOS: biometric sync handshake on connect
- `BLEManager` connect sequence: after bond + `GET_CLOCK`, add `SET_CLOCK(unix now, 5 pad)` (pre-authorized,
  reversible) → `GET_HELLO_HARVARD` → `GET_ADVERTISING_NAME_HARVARD` → `ENTER_HIGH_FREQ_SYNC(96, empty)`
  → `SEND_HISTORICAL_DATA(22, [0x00])`. (Mirror `re/sync_openwhoop.py`, which is verified.)
- Fix the `HISTORICAL_DATA_RESULT` ack to the openwhoop end_data form: `[0x01] + metadata.data[10:18]`
  (NOT `[0x01][trim][0]`). Confirm against the Backfiller's current ack and METADATA HISTORY_END parse.
- `Backfiller` already classifies METADATA + decodes via `extractHistoricalStreams`; verify it now sees
  type-47 V24 frames and persists the biometric streams.
- Keep the safe-trim order (decoded committed before ack). Save-every-frame still applies.

### Phase 2 — iOS: persist + upload the new decoded streams
- `WhoopStore`: add decoded tables/inserts for spo2/skin_temp/resp/gravity (mirror hr/rr schema; highwater
  pagination for upload).
- `Uploader.drainDecoded`: page + POST the new streams to `/v1/ingest-decoded`.
- `Collector` (live path): unchanged decoded HR/RR; no raw enqueue by default (see Phase 3).

### Phase 3 — Retire raw upload (default)
- `Collector.swift` + `Backfiller.swift`: gate `enqueueRawBatch(...)` behind the "Research raw capture"
  toggle (default OFF). When OFF, never enqueue raw.
- `Uploader.swift`: remove `drainRaw()` from the default `drain()` path; raw batches (only present when the
  toggle is on) are local-only unless explicitly exported.
- `RawOutbox`: keep the table + API for the research path; prune policy unchanged for local-only batches.
- Server `/v1/ingest` raw path: leave intact (for the optional research export) but it's no longer the
  primary path.

### Phase 4 — Verify end-to-end + docs/memory
- iOS unit tests: connect-sequence emits the handshake; Backfiller persists V24 streams; Uploader posts
  decoded streams and does NOT post raw when toggle is OFF.
- One on-device run (coordinate): connect → confirm type-47 V24 pulled + decoded streams uploaded +
  zero raw uploaded by default. Save the capture to a gitignored .bin.
- Update offline-first design doc + auto-memory (raw retired; biometric sync is the path).

## Execution
Subagent-driven, one phase at a time, TDD, tests green before moving on. Phase 0 (server) and Phase 1
(iOS handshake) are independent and can run in parallel. Commit per phase to `main` in each repo.

## Open question for you
1. OK to make the **default decoded-only with an OFF-by-default research-raw toggle** (vs dropping raw entirely)?
2. The biometric raw ADCs (SpO2/skin-temp/resp) have NO client-side unit conversion (WHOOP computes them
   in cloud). Upload them **raw** (recommended — lossless, convert later) — confirm that's fine.
