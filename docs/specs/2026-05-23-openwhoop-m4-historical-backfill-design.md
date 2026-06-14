# OpenWhoop iOS — M4 + M5 write-path: Historical Backfill + Decoded Upload (Design)

**Date:** 2026-05-23
**Status:** Approved (brainstorm) — pending spec review → implementation plan
**Builds on:** M1 (connect/bond/live HR), M2 (Swift decoder + parity), M3 (local store + background collection). Umbrella spec: `docs/specs/2026-05-23-openwhoop-ios-app-design.md`; M3 plan: `docs/plans/2026-05-23-openwhoop-m3-local-store.md`.

## Scope

This milestone fuses **M4 (historical backfill)** with the **write-path half of M5 (upload to the server)**, because they are tightly coupled: backfill produces large writes (→ move the store off the main actor) and the data it captures only becomes durable once uploaded. Deferred to the **next** plan (M5 read-path): pulling decoded streams back, History = union(phone, server), fresh-reinstall cloud restore, and adding read-auth to the server's read endpoints.

Phases: **F** historical decode (RE-first, parity-tested) · **G** Backfiller + BLE wiring + auto-enable · **H** WhoopStore off the main actor · **I** decoded upload to the server + tunnel route.

## Goal

On every (re)connect, drain the WHOOP strap's onboard **history buffer** into the local store (the mechanism by which WHOOP gets 24/7 coverage — the strap logs to flash, the phone drains it in bursts), then push the resulting **decoded** streams to the server. Capture is **decoded-only**: the phone is the decoder, so the server receives decoded values, never raw bytes.

## Architecture principle: the phone is the decoding middle-man

The strap never talks to the server; the phone is always in between and always decodes. Sending raw to the server just makes the server re-decode the same bytes with a parity-copy of the same decoder. So: **the phone decodes once and uploads decoded; the server stores decoded.** No raw on the wire, no server-side decode, no raw archive for this milestone's data.

Two definitions that this rests on:
- **Decoded** = we know what every byte *means* (lossless structural parse into fields/values). Emitting summaries vs. full samples is an extraction choice, not a knowledge gap.
- **Analysis** = deriving metrics (HRV / SpO2 / skin-temp / strain) from decoded values — a separate concern (server-side sub-project B), not part of "decoding."

## Guiding decisions (settled during brainstorming)

1. **Trigger:** automatic on every (re)connect (foreground or background). Resumable across BLE windows via the persisted `trim` cursor.
2. **Decode it all (RE-first):** the offload *loop* is already proven in RE; the *payload body* has never been parsed and is the real unknown. M4 opens by capturing a real historical chunk and reverse-engineering it, **accounting for every field** (HR/R‑R confirmed; the user recalls gap-fill including step/activity-type data — inventory it all).
3. **Decoded-only upload:** push decoded stream rows to the server; never upload raw bytes for this milestone's data. Simpler than the M3 raw-batch path (no zlib blobs, no `batch_id` archive).
4. **Safe-trim invariant ("don't pretend"):** the `trim` ack is **destructive** on the strap (it may forget/overwrite the chunk). So a chunk's `trim` is acked **only after** its decoded streams are durably stored **and** the decoder fully accounts for the chunk's bytes. **If a chunk contains bytes we can't map, we do NOT trim it** — leave it on the strap and surface it for RE. This replaces "preserve raw as insurance" with "never destroy what we didn't decode," which makes decoded-only safe by construction.
5. **Dedicated `Backfiller`:** isolate the offload as its own testable state machine rather than overloading the live `Collector`, so the decoded-then-trim ordering stays airtight and chunk/trim boundaries never tangle with the live 64-frame/30 s cadence.
6. **Off-main store:** backfill dumps large writes; move `WhoopStore` off the main actor (the M3-flagged concurrency item) so the UI never janks.

## What is already known (from RE — `re/hist_raw_test.py`, `re/re_harness.py`, `FINDINGS.md`)

The offload is a **request → ack loop**, proven end-to-end:
1. Client sends `SEND_HISTORICAL_DATA` (cmd 22), confirmed write (`.withResponse`).
2. Strap streams, on data-notify char `61080005`: `METADATA HISTORY_START` → payload packets → `METADATA HISTORY_END`, repeating per chunk, ending with `METADATA HISTORY_COMPLETE`.
3. `HISTORY_END` payload = `<LHLL>` = `(unix u32, subsec u16, unk0 u32, trim u32)`.
4. Client acks each `HISTORY_END` with `HISTORICAL_DATA_RESULT` (cmd 23) carrying `<BLL>` = `[0x01, trim, 0x00000000]`, confirmed write.
5. Loop until `HISTORY_COMPLETE`.

`GET_DATA_RANGE` (cmd 34) returns the strap's stored-history extent (oldest/newest unix) for the Device-tab display. Commands already exist in `ios/OpenWhoop/BLE/Commands.swift`: `sendHistoricalData=22`, `historicalDataResult=23`, `getDataRange=34`, `toggleRealtimeHR=3`, `stopRawData=82`.

**Unverified (M4 settles it in Phase F):** the historical payload's exact byte layout, its per-record timestamp scheme (self-timestamped vs derived from `HISTORY_END` unix + offsets), and the full field inventory beyond HR/R‑R.

**Type‑43 note (context, not this milestone):** the canonical schema (`protocol/whoop_protocol.json`) already specifies the IMU variant fully (`1917`: 100 samples/axis @52 Hz, int16 LE, exact offsets) — IMU bytes are *known*. The optical variant (`1921`) is only partially specified (`~4 channels, 24-bit interleaved`, no exact per-channel offsets) — genuine unknowns remain there. Both are **live `START_RAW_DATA` bursts = M6**, out of scope here; noted so the spec's terminology is accurate.

## Components

**Phase F — Historical decode (`WhoopProtocol`).** A new `extractHistoricalStreams` (sibling to `extractStreams`, since historical uses a raw-shaped frame type the live extractor deliberately skips). Decodes **all identified fields** into stream rows with wall-clock timestamps, and exposes a **"fully accounted" signal** (were all the chunk's bytes mapped to known fields?) that the `Backfiller` uses to gate trim. Built after the Phase‑0 RE capture; **Python-parity tested** over a captured historical golden, same discipline as the live decoder (`StreamsParityTests` / `gen_golden.py`).

**Phase G — `Backfiller` (`@MainActor`, `ios/OpenWhoop/Collect/Backfiller.swift`).** The offload state machine: modes `idle` / `backfilling`. Buffers a chunk's payload between `HISTORY_START` and `HISTORY_END`; on `HISTORY_END`, decodes → persists decoded → **if fully accounted, persists the `strap_trim` cursor and acks `trim`; otherwise does NOT ack** (leaves it on the strap, logs it for RE); on `HISTORY_COMPLETE`, exits. Per-chunk timeout. Reuses the (now async) store. Unit-testable with scripted frame sequences + a `SpyStore`.

**Phase G — `BLEManager` changes.**
- `send()` gains a `writeType:` parameter (default `.withoutResponse`); `HISTORICAL_DATA_RESULT` uses `.withResponse` (resolves the existing `TODO(M4)`).
- A `backfilling` flag routes custom-char notify frames to the `Backfiller` while backfilling, else to the live `Collector` + `FrameRouter` (M3 path). Clock capture still runs so historical→wall timestamps resolve.
- Connect orchestration (see data flow), including auto `Stop Raw` and post-backfill `Start HR`.

**Phase H — `WhoopStore` off the main actor.** Convert `WhoopStore` to an `actor` (methods become `async`; internally still uses GRDB's thread-safe `DatabaseQueue`). The `StoreWriting` seam and callers (`Collector`, `Backfiller`) become `await`-based; decoded-then-trim and decoded-before-raw orderings are preserved by sequential `await`s. A small `cursors` table holds `strap_trim`, the last `GET_DATA_RANGE` extent, and per-stream **sync highwaters** (for Phase I). The store gains **room for new historical-metric streams** (e.g. an `activitySample`/steps table) added via migration as the RE identifies fields. Existing WhoopStore tests carry over (now async).

**Phase I — Decoded upload (`Uploader`) + server.**
- **`Uploader` (app):** reads decoded rows newer than each stream's sync highwater, POSTs them to a new server endpoint, advances the highwater on 2xx. Idempotent (server upserts on natural key), so retries/overlap are safe. Runs opportunistically when connected + network reachable (after backfill on connect), with retry/offline handling.
- **Server (`home-server` `stacks/whoop`):** a small new **`POST /v1/ingest-decoded`** (Bearer `WHOOP_API_KEY`) accepting `{device, streams:{hr:[{ts,bpm}], rr:[{ts,rr_ms}], events:[…], battery:[…], …}}` and upserting into the existing hypertables (reuses the existing upsert; just skips the decode step). No change to `/v1/ingest`.
- **Reachability:** a **Cloudflare tunnel route** exposes the ingest path so the phone reaches the server over the internet.
- **Secret/config:** the app reads `WHOOP_API_KEY` + server base URL from a **gitignored xcconfig** (never committed — the repo is destined to go public; stays alongside the device-ID redaction TODO).

**The M3 raw outbox** is **not** exercised by this milestone (decoded-only upload). It remains in place for the future live-raw-burst case (M6, where optical has unmapped bytes). The live `Collector`'s existing raw-enqueue is left as-is (bounded by the M3 prune, harmless) — not uploaded.

## Data flow

**Connect (orchestrated in `BLEManager`):**
```
bond confirmed
  → send(.stopRawData)                                   // quiet type-43 flood
  → (existing clock capture)                             // device↔wall ref
  → send(.getDataRange)                                  // → Device-tab history range
  → send(.sendHistoricalData)            [enter backfilling]
       repeat per chunk:
         HISTORY_START
         payload packets …               → Backfiller buffers
         HISTORY_END(unix, trim)
           → extractHistoricalStreams(payloads)  (decoded + "fully accounted?")
           → await store.insert(decoded)                 // durable, idempotent
           → if fullyAccounted:
                await store.setCursor(strap_trim = trim)
                send(.historicalDataResult, [1,trim,0], writeType:.withResponse)  // ACK
             else:
                log/flag chunk for RE; DO NOT ack (strap keeps it)
       HISTORY_COMPLETE                   [exit backfilling]
  → send(.toggleRealtimeHR, [0x01])                      // Start HR → live Collector resumes
```

**Upload (opportunistic, when connected + reachable):**
```
for each stream in [hr, rr, events, battery, activity?]:
  rows = store.rows(stream, after: highwater[stream])
  POST /v1/ingest-decoded { device, streams:{ stream: rows } }   (Bearer)
  on 2xx → store.setHighwater(stream, lastTs)
  on failure/offline → keep highwater, retry later
```

## Trim-safety & failure handling

**Invariant:** per chunk — **decoded persisted → (fully-accounted check) → trim cursor saved → ack `trim` (`.withResponse`).** A chunk is forgotten by the strap only after it is durably stored *and* we have accounted for all its bytes *and* the ack is link-layer confirmed.

- **Unaccounted bytes in a chunk:** do **not** ack → strap keeps it → no data loss; the chunk is logged for RE so we can extend the decoder and re-offload later.
- **Disconnect / per-chunk timeout (~20 s):** stop, ack nothing for the unfinished chunk → strap retains it → resume next connect.
- **Crash between persist and ack:** chunk stored but not acked → strap re-sends → idempotent `insert` dedupes → harmless.
- **Resumable across background windows:** auto-on-connect + retained un-acked data + persisted `trim` + idempotent inserts make overlap a non-issue.
- **Backfill never blocks live:** if `HISTORY_COMPLETE` never arrives (timeout), exit `backfilling` and still `Start HR`.
- **Upload is decoupled from trim:** trim depends only on *local* durability + full accounting, never on the server having the data. Upload retries independently.

## Testing & build sequence

0. **Capture + RE a real historical chunk on-device** (drain the current buffer, save the bytes like RE's `whoop_hist.bin`). Inventory fields, confirm compact-vs-raw, locate HR/R‑R and any aggregates (steps/activity), and identify whether all bytes are accounted for. Produces the field map + golden fixture. *(Manual/RE; feeds the TDD below.)*
1. **`extractHistoricalStreams` parity** (`WhoopProtocol`): extend `scripts/gen_golden.py` to emit `historical_golden.json`; Swift asserts byte-identical decode vs Python field-by-field over **every** identified field; assert the "fully accounted" signal matches.
2. **`Backfiller` unit tests** (with a `SpyStore`): scripted `HISTORY_START → payloads → HISTORY_END(trim) ×N → HISTORY_COMPLETE` → N decoded persists then N trim-acks in order; **safe-trim** (a chunk with unaccounted bytes persists decoded but is NOT acked); **ordering** (store throw → no trim ack); **resume/idempotency** (overlapping chunk → no dup rows); **timeout/disconnect** (no ack, backfilling exits so live starts).
3. **`WhoopStore` async** (Phase H): existing tests ported to `await`; a concurrency smoke test (no main-thread blocking).
4. **`BLEManager.send(writeType:)`**: `HISTORICAL_DATA_RESULT` writes `.withResponse`; others stay `.withoutResponse`.
5. **`Uploader`** (Phase I): with a stub server, decoded rows POST once, highwater advances, retry on failure leaves highwater, idempotent re-POST is a no-op. **Server:** a test for `POST /v1/ingest-decoded` upsert + dedupe (mirrors the existing ingest tests).
6. **On-device acceptance:** with a known phone-off gap, reconnect → gap fills with decoded rows (verified by pulling the SQLite via `devicectl … copy from`) → `strap_trim` advances → decoded rows appear on the server (`/v1/streams` via the dashboard) → `Stop Raw` / `Start HR` sequencing works → field inventory + any unaccounted-chunk flags reported.

CoreBluetooth wiring and the tunnel are build-verify; the offload *logic* lives in the testable `Backfiller`, the decode in the parity-tested `WhoopProtocol`, the upload in the testable `Uploader`.

## Scope boundaries

- **In:** historical offload loop, payload RE + decode + parity + "fully accounted" gating, decoded local persistence, safe-trim cursor management, `GET_DATA_RANGE` display, auto `Stop Raw` / `Start HR`, `send(writeType:)`, `WhoopStore` → actor + sync highwaters, decoded `Uploader`, the new `POST /v1/ingest-decoded` endpoint, the Cloudflare tunnel route, gitignored secret config, on-device verification.
- **Next plan (M5 read-path):** pull decoded streams back, History = union(phone, server), fresh-reinstall cloud restore, read-auth on the server's read endpoints.
- **Future (not scheduled):** emit full type‑43 IMU samples (layout already known) and nail down the optical channel layout; the HRV/SpO2/skin-temp/strain **analysis** (server-side, sub-project B); live raw-burst capture/upload (M6).

## Success criteria

- After a phone-off gap, reconnecting backfills it: decoded HR/R‑R **and every other field the RE identified** appear in the local store with correct wall-clock timestamps, verified on-device.
- The historical payload's field inventory is known and documented; any chunk with unaccounted bytes is **never trimmed** and is flagged for RE.
- The `strap_trim` cursor advances only after durable storage + full accounting; an interrupted backfill resumes losslessly (idempotent).
- Decoded streams (historical + live) reach the server via `POST /v1/ingest-decoded` and are visible in the dashboard; uploads are idempotent and retried; trim never depends on the server.
- Live HR/R‑R persists automatically after backfill (no manual "Start HR"); the type‑43 raw flood is stopped on connect.
- `WhoopStore` runs off the main actor; all package + app + server suites green; the historical decoder is Python-parity-proven.

## Open questions (to settle in the Phase‑0 RE step)

- Exact historical payload byte layout and per-record timestamp scheme.
- Full field inventory beyond HR/R‑R (steps/activity/kcal/strain inputs?) and which warrant their own store tables vs. events.
- Whether any historical chunk carries bytes we cannot account for (→ those chunks are not trimmed).
