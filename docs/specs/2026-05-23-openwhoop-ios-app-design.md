# OpenWhoop iOS App — Design

- **Date:** 2026-05-23
- **Status:** Draft (design); implementation plan to follow
- **Author:** jp (with Claude)
- **Repos touched:** `openwhoop` (new public monorepo, from `~/Developer/whoop`) and `home-server` (the deployed backbone — read-auth addition only)

## Context

The WHOOP 4.0 band is fully reverse-engineered (`~/Developer/whoop/FINDINGS.md`):
bonding, the GATT command surface, and decode of HR/R-R, IMU (accel/gyro), and raw
optical/PPG. **Sub-project A** (the home-server backbone — TimescaleDB datastore, a
schema-as-data decoder `whoop_protocol.json` + Python interpreter, an idempotent
`POST /v1/ingest` API, read endpoints, and a stored-history dashboard) is **done and
deployed** on `jpserver` (dashboard at `http://jpserver:8770`).

The original decomposition split the iOS side into C (BLE engine), D (UI), and E (sync).
**This spec collapses C+D+E into one cohesive native iOS app** — they are one codebase on
one device and are tightly coupled. The app's spine is a **rock-solid data pipeline**; the
viewer is a friendly, charts-first surface over it.

Native **Swift / CoreBluetooth** (not React Native — `ble-plx` cannot bond peripherals,
and bonding is a CoreBluetooth behavior, so the Mac `bleak` prototype transfers directly).

## Goals

1. A native Swift/SwiftUI iOS app that connects to the user's WHOOP 4.0, **bonds**
   (one confirmed write), and streams + decodes live data **fully offline**.
2. A **strong data pipeline**: collect while paired → decode → keep **decoded streams**
   locally (durable, compact) while **raw is buffered and store-and-forwarded** to the
   deployed server (the single durable raw archive) and then **pruned** → **backfill on
   reconnect** (the historical-buffer offload) so nothing is missed.
3. **Bidirectional sync with the server**: push raw up; pull decoded history back so the
   app shows the **union of phone + server data**, and a **fresh reinstall fully recovers**
   the device's history from the server.
4. **See every metric the sensors report, fully decoded, with charts** — live and
   historical: HR, R-R/HRV, accelerometer, gyroscope, raw optical/PPG waveform, battery,
   events, device status. No hex required in the primary UX.
5. A **curated command sender** (safe commands only) and surfaced **device status**
   (battery, charging, on-wrist, firmware, serial, stored-history range, sync state).
6. A **schema-driven Swift decoder reading the same `whoop_protocol.json` as the server**,
   guaranteed by parity tests never to drift from the Python interpreter.
7. Clean up `~/Developer/whoop` into a public **`openwhoop` monorepo**.

## Non-Goals (explicitly deferred or out of scope)

- **SpO₂ / skin-temperature values** — not on the BLE wire; WHOOP computes them in their
  cloud from raw PPG. Not readable locally. Out of scope.
- **Full optical/PPG channel decode** (red/IR/ambient split, bit-scaling) — still open in
  RE. The app shows the located pulsatile (HR/green) channel as a raw waveform, clearly
  labeled "raw/experimental"; full decode and any DSP is deferred to server sub-project B.
- **On-device analytics** (HRV scoring beyond basic R-R, strain, recovery, sleep) — the
  band does no analytics; heavy analysis is server sub-project B.
- **Keeping raw on the phone long-term / bulk re-mirroring it on reinstall** — the server is
  the durable raw archive; the phone holds raw only transiently (outbox), pulls decoded
  streams back, and fetches raw on-demand per batch.
- **Multi-user** — single user; schema is keyed by `device_id` so multiple straps work.

## Architecture

Five layers, native Swift + SwiftUI:

```
            ┌──────────────────────────── OpenWhoop iOS app ────────────────────────────┐
 WHOOP 4.0  │  BLE engine        Protocol lib        Local store        Sync             │
   strap ───┼─▶ CBCentralManager ─▶ Reassembler ─▶ decode ─▶ GRDB/SQLite ──┬─ push ──────┼──▶ POST /v1/ingest
            │   connect+BOND        (framing.swift)  (interpreter.swift     │  (raw+clock) │     (server decodes,
            │   subscribe 03/04/05   reads            reads schema.json)    │              │      archives raw)
            │   + std 0x2A37/0x2A19  whoop_protocol.json                    └─ pull ◀──────┼──── GET /v1/streams/*,
            │                                                  ▲                           │     /v1/batches[/frames]
            │                              UI (SwiftUI + Swift Charts) ◀── reads local ────┘     (merged into local)
            └────────────────────────────────────────────────────────────────────────────┘
```

### 1. BLE engine
`CBCentralManager`: scan for the strap → connect → **issue one confirmed write
(`writeValue(..., type: .withResponse)`) to command char `61080002` to trigger silent
just-works bonding** (the key unlock; produces a `BLE_BONDED` event). Subscribe to custom
notify chars `61080003` (cmd responses), `61080004` (events), `61080005` (data), plus the
standard Heart Rate `0x2A37` (HR+R-R, works unbonded — a cross-check/fallback) and Battery
`0x2A19`. Holds the link, auto-reconnects, runs under the **`bluetooth-central` background
mode** with **`CBCentralManager` state restoration** so collection survives backgrounding
and relaunch. Owns the **`Reassembler`** (frames fragment across BLE notifications; only
the first fragment carries the `0xAA` SOF — accumulate by the length header).

GATT (authoritative, from FINDINGS):
```
Service 61080001-8d6d-82b8-614a-1c8cb0f8dcc6
  61080002 write          CMD → strap      61080003 notify  CMD responses ←
  61080004 notify events ←                 61080005 notify  data ← (realtime/raw/historical/logs)
Standard: 0x180D/0x2A37 (HR+RR), 0x180F/0x2A19 (battery), 0x180A (device info)
```

### 2. Protocol library (Swift) — the no-drift core
Two small files mirroring the Python package:
- **`framing.swift`** — CRC8 (poly 0x07 table, over the 2 length bytes), zlib CRC32
  (over the inner packet), `verifyFrame`, `frameFromPayload`, and the `Reassembler`.
  Procedural and stable; a direct port of `framing.py`.
- **`interpreter.swift`** — loads the bundled **`whoop_protocol.json`** and does the same
  generic field walk + per-type post-hooks as `interpreter.py`, emitting the same
  `{ok, type_name, seq, fields[], parsed{}, crc_ok}` shape. Decodes **all** packet types:
  REALTIME_DATA (HR/RR), REALTIME_RAW_DATA (IMU variant 1917 / optical variant 1921),
  EVENT, COMMAND_RESPONSE, METADATA, CONSOLE_LOGS.
- A curated **`CommandNumber`** table for *sending* (the full enum lives in
  `whoomp/scripts/packet.py`; the schema's `CommandNumber` is decode-only and omits send
  codes like `TOGGLE_IMU_MODE`=106, `ENABLE_OPTICAL_DATA`=107).

**Decode additions (also benefit the server, made in the canonical schema):**
- `GET_HELLO_HARVARD` (cmd 35) parse: byte 7 = charging flag, byte 116 = isWorn, plus
  serial — surfaced as device status. Add to the `command_response` post-hook.

### 3. Local store (GRDB / SQLite) — decoded is durable, raw is transient
Storage ownership splits cleanly between phone and server (the phone is the **collector**
and durable home for decoded; the **server** is the durable home for raw):
- **Decoded streams = durable on the phone** (also on the server; kept in sync). Tiny
  (HR ≈ a few MB/day), so they live on the phone indefinitely and are what the History
  charts read — the union of phone-decoded + server-pulled, deduped by `(device_id, ts)`.
- **Raw = durable on the server only.** The phone holds raw **transiently** in an outbox,
  uploads it, then prunes it. The server's zstd archive is the single durable home for raw.

Tables:
- `devices(device_id PK, mac, name, first_seen, last_seen)`
- Decoded streams (upsert by natural key, never pruned): `hr_samples(device_id, ts, bpm)`,
  `rr_intervals(device_id, ts, rr_ms)`, `events(device_id, ts, kind, payload)`,
  `battery(device_id, ts, soc, mv)`
- `raw_outbox(batch_id PK, device_id, captured_at, device_clock_ref, wall_clock_ref,
   start_ts, end_ts, packet_count, byte_size, synced_at NULL)` + compressed raw frame bytes
   keyed by `batch_id` — the **store-and-forward buffer**, pruned after sync.
- Cursors: `strap_trim_cursor` (last acked trim), `backfill_highwater(stream, last_ts)`.

**On collect:** decode every frame → **persist decoded streams (the permanent local
record)** AND append raw to the outbox. Pruning raw therefore never loses a metric.

**Raw retention / backpressure:**
- Prune a batch's raw once `synced_at` is set and it is older than a small **rolling window**
  (default ~24 h, configurable; 0 = prune immediately on ack) so recent raw stays browsable
  offline without a server round-trip.
- **Outbox cap:** if un-synced raw exceeds a cap (long server outage), drop the **oldest
  un-synced** raw (its decoded streams are already persisted) and surface a warning — the
  phone never fills up; only raw fidelity for that window is lost, not the metrics.
- Older raw drill-in fetches from the server (`/v1/batches/{id}/frames`).

### 4. Sync (bidirectional store-and-forward)
- **Push:** background task drains `raw_batches WHERE synced_at IS NULL` →
  `POST /v1/ingest` with the deployed contract (raw frame `hex` + `clock_ref{device,wall}`
  + client `batch_id` + `device{device_id,mac,name}`). Idempotent on `batch_id`; on `200`
  set `synced_at`. Queues when offline, drains when reachable.
- **Pull / restore:** `GET /v1/streams/{hr|rr|events|battery}?device=&from=&to=&limit=`
  paged forward from each stream's `backfill_highwater` (0 on fresh install → full
  history); upsert into local decoded tables. The History view always reads the local
  store, which is thus the **union of phone + server**.
- **Raw drill-in:** for a historical window, `GET /v1/batches?device=` then
  `GET /v1/batches/{id}/frames` (server re-decodes archived raw → `parsed{}` per frame) to
  chart historical IMU bursts without re-downloading raw bytes.
- Reachability via the **Cloudflare tunnel** public hostname (works home + away).

### 5. UI (SwiftUI + Swift Charts) — friendly, charts-first
See "The viewer" below.

## Data pipeline (the spine)

```
strap ──BLE──▶ reassemble ──▶ decode (schema.json) ──▶ decoded (kept) + raw outbox ──┬─▶ live charts
                                                                                     ├─▶ push raw  → server
on (re)connect:  GET_CLOCK (capture device↔wall correlation)                         └◀─ pull decoded ← server
                 GET_DATA_RANGE  +  SEND_HISTORICAL_DATA → HISTORY_END/trim-ack loop → local store
                 advance strap trim cursor once stored locally (decoded persisted + raw queued)
```

**Two clocks** (handled exactly as the server does):
- **REALTIME_DATA ts = device monotonic epoch** → mapped to wall-clock via the
  `(device_clock_ref, wall_clock_ref)` correlation captured at connect (`GET_CLOCK` + now).
- **EVENT / METADATA ts = real unix** → stored as-is, never offset.
Both are uploaded as part of the batch so the server decodes identically.

**Historical backfill (the device-side store-and-forward, = how WHOOP gets 24/7 data):**
on each reconnect run `GET_DATA_RANGE`, then `SEND_HISTORICAL_DATA(22)` → strap streams
`METADATA HISTORY_START/END` bracketing payload packets → ack each `HISTORY_END` with
`HISTORICAL_DATA_RESULT(23)` carrying the `trim` cursor (`<BLL>` = 1, trim, 0) → loop until
`HISTORY_COMPLETE`. Store into the local store; **advance the strap trim cursor once stored
locally** (independent of whether the server has it yet).

## Raw sensor collection strategy (WHOOP-faithful)

WHOOP itself does **not** stream raw 24/7 (that's why the strap lasts ~5 days): the strap
logs to its own flash continuously, the phone drains that buffer in periodic background
bursts via the historical-offload loop, and **realtime streaming is used only for live
viewing**. We mirror this:

- **Continuous (always while connected):** HR / R-R / events / battery (low-rate).
- **24/7 coverage:** the **historical-buffer offload** (compact, low-power), not a stream.
- **Realtime raw IMU/optical (`ENABLE_OPTICAL_DATA`=1, `TOGGLE_IMU_MODE`=1,
  `START_RAW_DATA`=1):** **on-demand only** — when the user opens the live sensors view or
  taps "capture a burst." Those seconds/minutes are decoded, charted, stored, uploaded.

> **Open question to settle empirically in M4:** does the strap's historical buffer contain
> full 52 Hz raw IMU/optical, or only HR/R-R-level records? (Almost certainly the compact
> version — full raw for weeks would be gigabytes, and in RE full raw only ever appeared via
> realtime `START_RAW_DATA`.) M4 inspects a historical chunk's packet sizes (1917/1921 =
> full raw present) to decide. If compact: HR/HRV/events/battery are retrievable
> historically; **full raw accel/gyro/PPG is only for windows that were live-viewed.**

## The viewer (friendly, no hex required)

Three tabs (Swift Charts throughout):
- **Live** — big current HR; R-R / instantaneous HRV; rolling HR chart; connection + bond
  + battery chips. When raw is on (on-demand): live accel/gyro traces and the PPG waveform.
- **History** — device + date/range picker → charts from the **local store (= phone +
  server union)**: HR, HRV, battery, event timeline, and accel/gyro envelopes for windows
  that have raw. Live-incoming and historical render the same way. Clear empty/loading
  states; "restoring from server…" on a fresh install.
- **Device** — status (battery %/mV, charging, on-wrist, firmware harvard/boylston, serial,
  stored-history range, last sync, local storage used) + a **curated command panel**:
  toggle realtime HR, start/stop raw sensors, "sync history now", refresh battery/clock/
  version/range, buzz/haptic. **Destructive commands excluded** (reboot, firmware load,
  trim-all, ship-mode, power-cycle).

**Optical honesty:** the optical/PPG view is labeled "raw / experimental" — it shows the
located pulsatile channel waveform; SpO₂/temp are not available locally.

*(Optional, tucked behind a debug toggle: a raw-frame hex inspector reusing the decode —
not part of the primary UX.)*

## Server-side extension (home-server — minimal)

The deployed read API already supports backfill (`/v1/devices`, `/v1/batches`,
`/v1/streams/{kind}`, `/v1/batches/{id}/frames`). The **only** change:
- **Add a read token (Bearer) to the read routes**, since the phone pulls biometric history
  over the public Cloudflare tunnel and the routes are currently unauthenticated. Bake the
  token into the app and the dashboard JS. (Alternative if preferred: gate the whole tunnel
  hostname with Cloudflare Access — no app-level token.)
- Add a **`cloudflared` route** for `whoop-ingest` (mirroring `cloudflared-home-api`) so the
  phone can reach `/v1/ingest` + reads off-LAN.

## Testing

- **Protocol parity (unit, simulator/CI, no BLE):** feed the existing labeled captures
  (`capture.jsonl`, `motion_capture.jsonl`, `optical_capture.jsonl`) as fixtures; assert the
  Swift interpreter's `parsed{}`/`fields[]` match the Python interpreter **byte-for-byte**
  (a golden-output fixture generated from `whoop_protocol`). This *is* the no-drift guarantee
  in code. Assert known HR/RR/IMU values from FINDINGS.
- **Framing (unit):** reassembly of multi-notification fragments; CRC8/CRC32 pass/fail.
- **Store + sync (unit):** upsert dedup by natural key; idempotent push (same `batch_id`);
  backfill merge produces the union; fresh-install restore from a mocked server.
- **On-device BLE (manual):** real iPhone + strap (CoreBluetooth has no simulator), from M1.
  A **replay mode** feeds captured frames through the real store/sync path so persistence +
  upload are testable without the strap.

## Milestones

- **M0 — Repo setup.** `git init` `~/Developer/whoop`, clean up, restructure to the
  `openwhoop` monorepo layout (below), move the **canonical `whoop_protocol.json`** here,
  push to `github.com/johnmiddleton12/openwhoop`. Point home-server's `whoop-protocol` at a
  vendored copy synced from openwhoop, guarded by its existing parity test. Scaffold the
  Xcode project under `ios/`.
- **M1 — Connect + bond + live HR/R-R on the iPhone.** The riskiest unknown, proven first.
  Minimal UI: connection/bond state + live HR + R-R. (Subscribe std `0x2A37`/`0x2A19` too.)
- **M2 — Swift protocol library + parity tests.** `framing.swift` + `interpreter.swift`
  reading `whoop_protocol.json`; decodes all types; byte-parity vs Python in CI.
- **M3 — Local store + background collection.** GRDB schema; `bluetooth-central` background
  + state restoration; continuously collect HR/RR/events/battery; capture clock correlation.
- **M4 — Historical backfill on reconnect.** `GET_DATA_RANGE` + offload/trim-cursor loop
  into the local store; **verify historical raw contents** (the open question above).
- **M5 — Bidirectional sync.** Push raw → `/v1/ingest`; pull decoded streams ← server,
  merged into local; fresh-install restore. Read-token + cloudflared route on the server.
- **M6 — All sensors + device status.** On-demand raw IMU/optical (decode accel/gyro, show
  PPG channel); device status via command-response decoders (incl. `GET_HELLO_HARVARD`).
- **M7 — Friendly charts viewer + curated commands.** The three-tab SwiftUI dashboard.

Pipeline-first (M1–M5) with a usable Live view from M1; richer surface (M6–M7) on top.

## Repo cleanup → `openwhoop` monorepo

`git init`; `.gitignore` venvs / `__pycache__` / `*.out` / transient logs
(`re_log.jsonl`, `harness.out`, `phase.txt`, `control.txt`, `whoop_hist.bin`). Keep the
**labeled captures as `fixtures/`** (reusable test data — never re-run the physical
protocol). Layout:

```
openwhoop/
  ios/                      the Swift app (Xcode project)
  protocol/
    whoop_protocol.json     CANONICAL schema (single source of decode truth)
    README.md
  re/                       RE scripts + FINDINGS.md + PROJECT_MEMORY.md (history)
  dashboard/                the Mac live BLE tool (reference)
  fixtures/                 labeled captures (capture / motion_capture / optical_capture)
  docs/specs/               this doc + future specs
  README.md
```

home-server's `packages/whoop-protocol/whoop_protocol/schema/whoop_protocol.json` becomes a
**vendored copy synced from `openwhoop/protocol/whoop_protocol.json`**, with the existing
parity test asserting they match (so the server can never drift from the canonical).

## Risks & open questions

- **Historical raw fidelity** — see M4. May limit full raw history to live-viewed windows.
- **iOS background BLE limits** — sustained background raw streaming may be throttled; v1's
  on-demand raw sidesteps this. Continuous HR/RR + periodic historical sync are within the
  `bluetooth-central` budget. State restoration must be wired correctly.
- **Bonding on real CoreBluetooth** — proven in concept (the bleak prototype is a
  CoreBluetooth behavior), de-risked first in M1.
- **Optical/PPG decode** — partial; shown as raw/experimental; no SpO₂/temp locally.
- **Read-path security** — biometric data over a public tunnel needs the read token (or
  Cloudflare Access); do not ship reads unauthenticated.
- **Schema send-vs-decode gap** — the canonical schema is decode-only; the Swift command
  sender needs the full `CommandNumber` set (curated, safe subset) maintained separately.

## Success criteria

1. The app connects to the WHOOP 4.0, **bonds**, and shows **live HR + R-R** on the iPhone.
2. The Swift decoder matches the Python interpreter **byte-for-byte** on the fixture suite.
3. Data collected while paired has its **decoded streams persisted locally** and its **raw
   buffered, uploaded idempotently when reachable, then pruned**; gaps are backfilled from
   the strap's history on reconnect.
4. The History view shows the **union of phone + server** data; a **fresh reinstall
   recovers** the device's decoded history from the server.
5. Every sensor metric is viewable with charts — HR, R-R/HRV, accel/gyro, raw PPG waveform,
   battery, events — live and historical; raw IMU/optical captured on-demand.
6. Device status and a **curated, safe command sender** are available in-app.
7. `~/Developer/whoop` is a clean public `openwhoop` monorepo; the canonical schema lives
   here and the server consumes a parity-checked vendored copy.
