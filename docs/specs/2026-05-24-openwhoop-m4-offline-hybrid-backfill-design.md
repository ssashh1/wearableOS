# OpenWhoop iOS — M4 + M5 write-path: Offline-First Hybrid Backfill (Design)

**Date:** 2026-05-24
**Status:** Approved (brainstorm) — pending spec review → implementation plan
**Supersedes:** `docs/specs/2026-05-23-openwhoop-m4-historical-backfill-design.md` (its "novel type-47 payload" and "decoded-only, no raw on the wire" premises were invalidated by the F0 RE spike — see below).
**Builds on:** M1 (connect/bond/live HR), M2 (Swift decoder + parity), M3 (local store + background collection + `RawOutbox`). Umbrella spec: `docs/specs/2026-05-23-openwhoop-ios-app-design.md`; M3 plan: `docs/plans/2026-05-23-openwhoop-m3-local-store.md`.

## Why this supersedes the 2026-05-23 spec

The prior spec assumed the strap's history offload carried a **novel, compact `HISTORICAL_DATA` (type 47)** payload to be reverse-engineered and decoded in full, enabling a strict "every byte accounted → safe to trim" invariant and a **decoded-only** upload (no raw ever sent to the server).

The **F0 RE spike** (2026-05-24) captured a clean full chunk (`fixtures/historical_capture.bin`, 885 KB, 104 chunks, reached `HISTORY_COMPLETE`) and proved otherwise:

- **There is no type-47 payload.** The history buffer is the **recorded raw frame stream**, replayed in native packet types. Every reassembled frame passes CRC32.
- Per second the timeseries is a **pair of `REALTIME_RAW_DATA` (type 43)** frames: `cmd=41` (~1917 B: header + optical/PPG sample arrays) + `cmd=0` (~1921 B: IMU accel/gyro arrays). The buffer also carries `CONSOLE_LOGS` (type 50), `EVENT` (type 48), and `METADATA` (type 49) frames.
- **HR/R‑R are ~24 bytes of header** on top of ~3.8 KB/sec of **undecoded** IMU/PPG arrays (header layout already known from `re/decode_raw.py`; verified a clean 52–69 bpm sleeping curve at 1 record/sec).

Consequence: requiring a **full byte-level decode before trim** is no longer viable — ~99 % of each record is sensor arrays we are deliberately not decoding this milestone. The strict invariant would mean **nothing ever trims**. This spec resolves that, and folds in the user's offline-first requirement.

See memory: historical on-wire format, offline-first decode.

## Scope

Fuses **M4 (historical backfill)** with the **write-path half of M5 (upload)**. Phases: **F** decoder extension (type-43 historical header → known streams) · **G** Backfiller + BLE wiring + auto-enable · **H** `WhoopStore` off the main actor · **I** hybrid upload (decoded + raw) to the server + tunnel route.

**Deferred to the next plan (M5 read-path):** pull decoded streams back, History = union(phone, server), fresh-reinstall cloud restore, read-auth on the server's read endpoints.
**Deferred to a future milestone:** decode the IMU/PPG sample arrays on the phone, then **stop uploading raw** — the app sends only decoded. (This milestone's raw upload is the bridge until then.)

## Goal

On every (re)connect, drain the strap's onboard history buffer. For each chunk the phone **decodes the fields it knows** (HR/R‑R/events/battery) into local decoded streams **and** stores the **whole raw frames** locally; once both are durable on the phone it **trims** the chunk. Independently and opportunistically (when online) it **uploads both** the decoded streams and the raw batches to the server. End state: the server holds **decoded for known fields, raw for everything else** — with full 24/7 coverage and nothing lost.

## Architecture principle: offline-first, phone is the sole decoder

The phone↔strap path **must work fully offline**; the server may be unreachable for long stretches. Therefore:

1. **The phone decodes known fields locally.** It does not depend on the server to decode. There is exactly **one** decoder (Swift, on the phone) — the phone's local data and the server's decoded data are identical by construction, with no second (server) decoder to drift.
2. **Unknown bytes are preserved as raw, locally first.** The phone stores the whole raw frames in the existing `RawOutbox` (M3). This is the catch-all that makes trimming safe without decoding everything.
3. **Trim is gated on LOCAL persistence only** — decoded-known stored **and** raw stored on the phone. **Never** waits for the server. (Offline-first; the buffer must keep draining with no connectivity.)
4. **Upload is opportunistic and idempotent.** When online, push decoded streams (authoritative, "known") and raw batches (archive, "unknown") to the server. The server **does not re-decode** the phone-uploaded raw (Option A: no decoder drift).

Definitions:
- **Known field** = a value the phone's decoder fully parses today: **HR, R‑R, events, battery**.
- **Unknown bytes** = everything else in the historical frames (IMU accel/gyro, optical/PPG arrays, console logs) — kept raw, decoded in a future milestone.

## What is already known (RE)

Offload loop (proven end-to-end; `re/hist_capture.py`, `re/re_harness.py`):
1. `SEND_HISTORICAL_DATA` (cmd 22), confirmed write.
2. On data-notify char `61080005`, per chunk: `METADATA HISTORY_START` → frames → `METADATA HISTORY_END`, repeating, then `METADATA HISTORY_COMPLETE`.
3. `HISTORY_END` payload = `<LHLL>` = `(unix u32, subsec u16, unk0 u32, trim u32)`.
4. Ack each `HISTORY_END` with `HISTORICAL_DATA_RESULT` (cmd 23) carrying `<BLL>` = `[0x01, trim, 0x00000000]`, confirmed write. **This ack is destructive** (the strap may trim/forget the chunk).

Historical frame types per chunk (F0): `REALTIME_RAW_DATA` (43, the timeseries — `cmd=41`+`cmd=0` pairs/sec), `CONSOLE_LOGS` (50), `EVENT` (48), `METADATA` (49). **No type 47.**

Type-43 header (payload bytes after `[type,seq,cmd]`, from `re/decode_raw.py`, F0-verified):
`[4:8]` unix u32 (device clock) · `[8:10]` subsec u16 · `[10:14]` unk u32 · `[14]` heart u8 · `[15]` rrnum u8 · `[16:16+2*rrnum]` rr u16[]. Device-clock unix maps to wall-clock via the live `ClockRef(device, wall)` correlation (`GET_CLOCK` on connect), exactly as the live path.

Reassembly gotcha: historical frames are ~1920 B and fragment across ~244 B BLE notifications. Capture must log **every** data-char notification verbatim; the concatenation is the frame stream (`_split_frames` reassembles it). The original `re/hist_raw_test.py` only wrote single-notification frames → it trimmed history while saving almost nothing; replaced by `re/hist_capture.py`.

## Components

- **WhoopProtocol (Swift) — decoder extension.** Add extraction of HR/R‑R from the **type-43 historical header** (and confirm events/battery decode reuses the live `EVENT` path). Output the existing `Streams` (hr/rr/events/battery). No IMU/PPG/console decode. Byte-parity tested against a Python reference over the committed fixture (same discipline as M2's `StreamsParityTests` + `gen_golden.py`). The type-43→raw routing in `whoop_protocol.json` is left intact (it already aliases 47→raw); the new work is a historical **stream extractor**, not a new packet type.
- **`Backfiller` (`@MainActor` state machine).** Idle / backfilling. Per chunk: collect frames between `HISTORY_START`/`HISTORY_END`; **decode known → `store.insert(streams)`**; **`store.enqueueRawBatch(meta, frames)`** (whole chunk's raw); both must succeed (durable) → **persist `strap_trim` cursor → ack-trim**. On any local-store failure: do **not** ack (chunk re-offloads next connect — idempotent). Unit-tested with a spy store (mirrors `CollectorTests`); BLE wiring is build-verify.
- **`WhoopStore` → `actor` (Phase H).** Public API becomes `async`; GRDB work runs off the main thread so large backfill writes never jank the UI. `RawOutbox` (M3: `enqueueRawBatch`/`pendingRawBatches`/`markRawBatchSynced`/`pruneRaw`) is reused as-is for the raw half. Add a `cursors` table (`strap_trim` + per-stream upload highwaters). **`pruneRaw` policy change:** unsynced raw is **not** droppable (it is the only copy of unknown bytes after trim) — the byte-cap policy must never delete an unsynced batch; only synced batches age out.
- **`Uploader` (opportunistic).** Two drains, both idempotent, both advancing their cursor only on 2xx:
  - **decoded:** per stream, read rows newer than `highwater(stream)`, POST to the decoded endpoint, advance highwater.
  - **raw:** `pendingRawBatches(limit)` → POST each to the raw archive endpoint → `markRawBatchSynced`.
- **Server (home-server).**
  - **Decoded ingest** — `POST /v1/ingest-decoded` (auth): accept `{device, streams:{hr,rr,events,battery}}`, call `store.upsert_streams` (exists, idempotent). No decode.
  - **Raw archive ingest** — reuse `POST /v1/ingest` with an **archive-only** switch (`decode_streams: bool = True`; the phone sends `false`): archive the raw frames (exists) and **skip** `extract_streams` so the phone's decoded upload stays authoritative (no drift). Default stays `true` for back-compat.
  - **Tunnel:** Cloudflare ingress route `whoop.<domain>` → ingest service (covers all `/v1/...`).

## Data flow

1. **Connect** → `GET_CLOCK` (sets `ClockRef` on both `Collector` and `Backfiller`); stop the type-43 live flood for backfill; `SEND_HISTORICAL_DATA`.
2. **Per chunk** (`HISTORY_START`…`HISTORY_END`): `Backfiller` decodes known → `insert` decoded streams; `enqueueRawBatch` whole raw frames; on both-durable → save `strap_trim` → **ack-trim**.
3. **`HISTORY_COMPLETE`** → exit backfilling → resume live HR.
4. **Opportunistically (online):** `Uploader.drain()` pushes decoded streams + pending raw batches; advances highwaters / marks batches synced on 2xx. Runs on connect and post-backfill.

## Trim-safety & failure handling

- **Local-only trim gate:** ack the destructive `trim` **iff** the chunk's decoded streams **and** its raw batch are both durably stored on the phone. Independent of the server → works offline.
- **Interrupted backfill** resumes losslessly: an un-acked chunk is re-offloaded next connect; decoded upserts dedupe by `(device, ts)`, raw batches dedupe by `batch_id`.
- **Upload independence:** upload never gates trim. A 5xx/offline leaves highwaters/`syncedAt` unchanged → retried next opportunity.
- **Raw is not dropped while unsynced:** `pruneRaw` only ages out **synced** batches; unsynced raw is retained until uploaded (it is the sole copy of unknown bytes post-trim).

## Testing & build sequence

- **Parity (Python = source of truth):** Python reference extracts HR/R‑R from the type-43 historical header over `fixtures/historical_capture.bin`; `gen_golden.py` emits goldens; Swift matches byte-for-byte (`HistoricalStreamsParityTests`). Regression-gate the existing live `StreamsParityTests`.
- **`Backfiller` (TDD, spy store):** clean chunk → insert + enqueueRaw + cursor + ack-once; store-throw → no ack; multi-chunk acks in order; `HISTORY_COMPLETE` exits; timeout exits without ack; payload-before-START is a no-op.
- **`WhoopStore` actor:** port suites to `async`; `CursorTests`; `pruneRaw` never deletes unsynced.
- **`Uploader` (TDD, URLProtocol stub + in-memory store):** decoded drain idempotent + highwater on 2xx only; raw drain marks synced on 2xx only; 5xx retry-safe.
- **Server (TDD):** `/v1/ingest-decoded` 401/200/idempotent/partial-streams; `/v1/ingest` `decode_streams=false` archives without decoding.
- **CoreBluetooth + tunnel:** build-verify + on-device acceptance (pull SQLite, confirm a phone-off gap fills, `strap_trim` advances, decoded + raw both reach the server).

## Scope boundaries

- **In:** type-43 historical HR/R‑R/events/battery decode (phone); whole-raw local store + safe local-trim; off-main store; hybrid upload (decoded + raw); server decoded endpoint + archive-only raw; tunnel.
- **Out (future milestone):** decode IMU accel/gyro + optical/PPG arrays + console logs; then retire raw upload (app sends only decoded). HRV/SpO2/skin-temp/strain analysis (server sub-project B). Read-path (next plan).

## Success criteria

- **Decode:** Swift extracts HR/R‑R from real captured type-43 historical frames, Python-parity-proven; live decode unregressed.
- **Backfill:** on (re)connect the strap drains into the local store as decoded streams (correct wall-clock ts) **and** raw batches; a chunk trims only after both are locally durable; interrupted backfill resumes losslessly; live HR resumes after backfill; the type-43 flood is stopped during backfill. Verified on-device (SQLite pull: phone-off gap fills, `strap_trim` advances).
- **Offline:** with no server reachable, capture + decode + local store + trim all proceed; uploads catch up later.
- **Off-main:** `WhoopStore` is an `async actor`; suites green; UI doesn't jank during a large backfill.
- **Upload:** decoded streams + raw batches reach the server (decoded for known, raw for unknown), idempotent + retried; highwaters/`syncedAt` advance only on 2xx; the server does not re-decode phone raw; trim never depends on the server. Tunnel verified by curl.
- **Hygiene:** the real `Secrets.xcconfig` and generated `xcodeproj`/`Info.plist`/golden JSON are never committed; commits carry the `Co-Authored-By` trailer.
