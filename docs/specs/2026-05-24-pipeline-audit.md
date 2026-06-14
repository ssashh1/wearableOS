# WHOOP Pipeline Audit — idempotency, dedup, gaps, ordering, resilience

_Task 4.2 of the insights mega-plan. Audited 2026-05-24 across the iOS app (`ios/OpenWhoop`),
the Swift packages (`Packages/WhoopProtocol`, `Packages/WhoopStore`) and the ingest server
(`home-server/stacks/whoop/ingest`). For each invariant: the guarantee, where it is enforced,
where it is tested, and a PASS / GAP verdict. Gaps found are fixed inline (one real bug fixed).
Ends with a guarantees summary the user can trust._

## How the pipeline moves data (one paragraph)

The strap holds a ~14-day type-47 V24 biometric store (1 Hz HR/HRV/SpO2/skin-temp/resp/gravity).
On connect the phone does the high-freq-sync handshake; the strap streams the store as a sequence of
records bracketed by **one HISTORY_START then repeated HISTORY_ENDs**. The phone decodes each chunk,
persists decoded streams locally (GRDB), then **acks every HISTORY_END** so the strap advances its own
trim and the offload drains. Decoded rows are uploaded to the server (`/v1/ingest-decoded`) gated by a
per-stream upload **highwater** cursor; the server upserts by natural key and recomputes derived
metrics (sleep/recovery/strain/daily). The phone also pulls server decoded + derived back down
(`ServerSync`) gated by a per-stream **read** cursor, so History = union(phone-decoded, server-computed).
Raw frames are OFF by default (decoded-only); raw capture is a research toggle / bounded on-demand window.

---

## Audit findings table

| # | Invariant | Guaranteed? | Enforced at | Tested at | Verdict |
|---|---|---|---|---|---|
| 1 | Idempotent re-ingest (server, all stream + derived tables) | Yes | `app/store.py` ON CONFLICT on every table | `test_ingest_decoded_api.py::test_ingest_decoded_idempotent`, `test_daily.py::test_idempotent_recompute`, `test_e2e.py` | **PASS** |
| 2 | Upload highwater monotonic (forward-only, only on 2xx) | Yes | `Uploader.swift` (query `from=hw+1`, set on 2xx) + local store filter | `UploaderTests` (200-advances / 500-no-advance / idempotent) + **new** `testUploadHighwaterIsMonotonicForwardOnly`, `testUploadHighwaterAdvancesOnNewerRows` | **PASS (test added)** |
| 3 | Read highwater monotonic (forward-only, only on 2xx) | **Now yes (was a gap)** | `ServerSync.swift` — clamp `max(current, maxTs)` (**fix added**) | `ServerSyncTests` (advance/500/multipage) + **new** `testReadHighwaterIsMonotonicForwardOnly` | **GAP FOUND + FIXED** |
| 4 | Backfill resume-from-trim after disconnect | Yes (strap-side; cursor is the durable record) | `Backfiller.finishChunk` (ack every END) + `BLEManager.didDisconnect` (clean reset) | `BackfillerTests` (multi-end/every-end-ack, throws suppress ack) + **new** `testResumeFromTrimAfterDisconnect` | **PASS (regression added)** |
| 5 | Safe-trim invariant (decoded durable, raw if enabled, BEFORE ack) | Yes | `Backfiller.finishChunk` (insert→enqueueRaw→setCursor→ack; early-return on any throw) | `BackfillerTests::testInsertThrowsSuppressesRest`, `testEnqueueThrowsSuppressesRest`, `testSetCursorThrowsSuppressesAck`, `testChunkWithNilClockRefNoOps` | **PASS** |
| 6 | Clock-correlation edge cases (pre-clock buffer cap + correct ts once clock lands) | Yes | `Collector.ingest` (pre-clock cap, drop-oldest) + `flush` (map ts via clockRef) | `CollectorTests::testPreClockBufferIsCappedDropOldest` + **new** `testPreClockFramesFlushWithCorrectTsOnceClockLands` | **PASS (test added)** |
| 7 | Stream-count reconciliation phone↔server | Yes | server: distinct-key upsert (no drop); phone: `storageStats` vs `/v1/summary`, union model | `test_e2e.py` (server reconciliation, distinct-key counts) | **PASS** (see note below) |
| 8 | BLE disconnect/reconnect doesn't thrash | Yes (no double-fire) | `BLEManager` (`backfillStarted` gate, `shouldRunPeriodicBackfill` `!backfilling`, clean teardown, 3s rescan) | `shouldRunPeriodicBackfill` is pure + audited; deep robustness is Task 4.3 | **PASS (audit only)** |

---

## The one real gap found + fixed

**Read-highwater could regress (ServerSync).** `setReadHighwater`/`setCursor` are *unconditional*
upserts (`cursors` table, `ON CONFLICT(name) DO UPDATE SET value = excluded.value`) — they do not
clamp. The read pager advanced the cursor to `max(ts in page)` of each pulled page. A correct server
filters `ts >= from`, so the page max is normally ≥ the cursor and it only ever moves forward. **But if
the server ever returns a row OLDER than the current cursor** (a misbehaving/older server, or
clock-skew), the cursor would be set BACKWARD. Data-wise this is harmless — the upsert dedups by
natural key — but it forces a needless re-pull and could spin. The new regression test
`testReadHighwaterIsMonotonicForwardOnly` reproduced the regression (cursor went `...509 → ...508`).

**Fix** (`ServerSync.pullStream`): read the current cursor and only advance when `maxTs > current`,
i.e. clamp forward-only. The upload highwater path was already safe because its store query filters
`ts >= from` locally, so an older row is never even returned for posting — the new
`testUploadHighwaterIsMonotonicForwardOnly` confirms that. The two paths now have parity: **neither
cursor can move backward.**

No other gaps were found. Server-side idempotency, the safe-trim ordering, and the disconnect/reconnect
gate were all already correctly implemented and tested — no padding tests were added there.

## Regression tests added (5 new test functions covering 4 invariants; all green)

- `UploaderTests.testUploadHighwaterIsMonotonicForwardOnly` — older row after the cursor advanced does
  not regress the upload highwater and is not re-posted.
- `UploaderTests.testUploadHighwaterAdvancesOnNewerRows` — companion: newer row advances it further.
- `ServerSyncTests.testReadHighwaterIsMonotonicForwardOnly` — older pulled row does not regress the read
  cursor (this caught the bug fixed above) and dedups by natural key.
- `CollectorTests.testPreClockFramesFlushWithCorrectTsOnceClockLands` — a frame buffered before the clock
  lands is later persisted with the CORRECT wall ts (device-ts → wall via the clock offset), not dropped.
- `BackfillerTests.testResumeFromTrimAfterDisconnect` — disconnect mid-chunk drops the open chunk WITHOUT
  acking (safe-trim), the `strap_trim` cursor survives into a new Backfiller instance, and the reconnect
  resumes acking the NEXT trims and advances the cursor forward (10 → 30, never backward).

---

## Per-invariant detail

### 1. Idempotent re-ingest (server)

Every persisted table uses an `ON CONFLICT` upsert (`app/store.py`):

| Table | Natural key | Conflict action |
|---|---|---|
| `hr_samples` | `(device_id, ts)` | `DO UPDATE SET bpm` |
| `rr_intervals` | `(device_id, ts, rr_ms)` | `DO NOTHING` |
| `events` | `(device_id, ts, kind)` | `DO UPDATE SET payload` |
| `battery_samples` | `(device_id, ts)` | `DO UPDATE SET soc, mv` |
| `spo2_samples` | `(device_id, ts)` | `DO UPDATE SET red, ir` |
| `skin_temp_samples` / `resp_samples` | `(device_id, ts)` | `DO UPDATE SET raw` |
| `gravity_samples` | `(device_id, ts)` | `DO UPDATE SET x, y, z` |
| `daily_metrics` | `(device_id, day)` | `DO UPDATE` (recompute overwrites in place) |
| `sleep_sessions` | `(device_id, start_ts)` | `DO UPDATE` |
| `raw_batches` | `(batch_id)` | `DO NOTHING` |

Re-POSTing the same payload leaves `/v1/summary` counts unchanged (`test_e2e.py`), and a daily
recompute is idempotent + delete-then-insert-consistent when sessions shrink (`test_daily.py`).
The phone-side `WhoopStore.insert` is `ON CONFLICT DO NOTHING` (local decode wins on a union).

### 2 + 3. Highwater monotonicity (upload + read)

Both cursors live in the `cursors` table under distinct prefixes (`highwater:` for upload,
`read:` for pull — `Cursors.swift`) so they never collide. The cursor primitive is an unconditional
upsert (verified: `CursorTests.testCursorUpsertsOnConflict`). Monotonicity is therefore a **caller**
property:

- **Upload** advances only on a 2xx (`Uploader.drainHR` etc. set the highwater inside the
  `if await postDecoded(...)` branch) and queries `from = highwater+1` from a store that filters
  `ts >= from`, so an older row is never posted and the cursor never regresses. PASS.
- **Read** advances only on a successful pull-and-upsert and now **clamps forward-only** (the fix).
  A non-2xx / thrown error stops that stream and leaves both the store and cursor untouched
  (`ServerSyncTests.testPullDecoded500LeavesStoreAndHighwaterUnchanged`). PASS.

### 4 + 5. Backfill resume-from-trim + safe-trim invariant

`Backfiller.finishChunk` enforces the order **decode → insert (decoded durable) → enqueueRaw (only if
raw toggle on) → setCursor(strap_trim) → ackTrim**, early-returning on ANY throw so a chunk is acked
only after it is locally durable. If `clockRef` hasn't landed yet, the chunk is NOT acked — the strap
re-offloads it next session (no data loss). High-freq-sync sends ONE START then REPEATED ENDs; every
END is acked (the critical memory fix) so the strap advances and the offload catches up to live.

**Resume across disconnect** is ultimately a **strap-side** guarantee: the strap re-offloads from its
own last-acked trim. The phone's `strap_trim` cursor is the *durable record* of that position (used for
logging/observability, per the `ackHistoricalChunk` comment in `BLEManager`), not a value replayed to
the strap. On disconnect, `BLEManager.didDisconnectPeripheral` resets per-connection state
(`backfillStarted=false`, clears the frame queue + draining flag, cancels timers) but the on-disk
cursor and decoded rows persist. The new `testResumeFromTrimAfterDisconnect` proves: an interrupted
open chunk is dropped without an ack (safe-trim holds — no premature trim advance), the cursor survives
into a fresh Backfiller, and the reconnect resumes acking forward.

### 6. Clock-correlation edge cases

`ClockCorrelation.clockRef` builds the `(device, wall)` ref from a CRC-OK GET_CLOCK response. Until it
lands, the Collector buffers frames un-persisted and bounds the **pre-clock buffer** at
`maxPreClockFrames` (default 4096, drop-oldest) so a strap that never replies can't OOM the phone
(`testPreClockBufferIsCappedDropOldest`). Once the clock lands, `flush` maps each frame's device ts to
wall time via the offset; the new `testPreClockFramesFlushWithCorrectTsOnceClockLands` proves a
pre-clock-buffered frame is later persisted with the CORRECT wall ts (not dropped, not mis-stamped).
The Backfiller's historical path is simpler: type-47 V24 records carry their own real `unix` ts, and a
chunk that arrives before `clockRef` is simply not acked (re-offloaded next session).

### 7. Stream-count reconciliation phone↔server

Server side: `/v1/summary` counts equal the distinct decoded natural keys persisted — no drop, no dup
(`test_e2e.py`). Phone side: the union model means the phone never needs the counts to match exactly —
it pulls server rows it doesn't have (`ServerSync`, dedup by natural key) and uploads rows the server
doesn't have (`Uploader`, highwater-gated). The phone's local view is summarized by
`Collector.storageStats()` (decoded rows + raw batches/bytes) for the UI; reconciliation is "eventually
both sides hold the union," not "counts are equal at every instant." This is intended.

### 8. BLE disconnect/reconnect doesn't thrash (audit only — deep work is Task 4.3)

- The **initial** backfill kick is guarded once-per-connect by `backfillStarted` (set true on first bond
  confirmation, reset on disconnect).
- The **periodic** re-trigger (every 300 s) is a separate gate: `shouldRunPeriodicBackfill(connected,
  bonded, backfilling)` returns true only when connected + bonded + `!backfilling`, so it can't stack a
  second offload on top of a running one. (Pure function — directly unit-testable.)
- The **drain queue** (`backfillFrameQueue` + `backfillDraining`) guarantees a single serial drain task;
  a second frame can't launch a second drainer.
- On disconnect, all timers are cancelled, the queue is cleared, and (if unintentional) a rescan is
  scheduled after 3 s. No tight reconnect loop, no double-armed timers.

No thrash problem found. Backoff tuning / jittered reconnect is explicitly **Task 4.3** scope.

---

## Deliberate decisions on accumulated findings

### A. gravity2 (2nd accel/gravity triplet) — DO NOT build the persistence pipeline now

V24 carries a SECOND gravity/accel triplet at frame offsets 56–68 (`gravity2_x/y/z`, decoded since Task
1.1; `schema/whoop_protocol.json`). It is **not** persisted server-side, and `app/analysis/activity.py`
uses the single triplet today with a forward-compatible both-triplet averaging path already written for
when/if `x2/y2/z2` are persisted.

**Data evidence (this audit).** I re-decoded all type-47 records from
`home-server/stacks/whoop/ingest/tests/fixtures/hist_biometric.bin` via the 4.1 replay helper and
compared `gravity` vs `gravity2` per record:

```
records with gravity: 762  with gravity2: 762
L2(g1,g2) min/mean/max: 0.000000 / 0.000000 / 0.000000
identical (L2==0): 762   close (L2<0.01): 0   diverge (L2>=0.01): 0
mean |g1| = 0.9903   mean |g2| = 0.9903
```

The two triplets are **bit-for-bit identical** in the observed data — not merely "close," but L2 = 0.0
across all 762 records. **Decision:** do NOT build the gravity2 persistence pipeline. It would be a
large multi-repo parity change (Swift store + GRDB schema + server table/columns + read API + analysis)
for ~zero information gain, since both triplets carry the same value. The forward-compat averaging path
in `activity.py` is retained so a future capture that DOES show divergence can be wired up by persisting
`x2/y2/z2` and flipping that path on. **If a future sample shows the triplets diverge, that is a real
finding** and gravity2 should be persisted in a follow-up — but on every byte we have today they do not.

### B. 1-second-resolution natural-key collapse — intended, bounded fidelity

Single-`ts` stream tables key on `(device_id, ts)` at 1-second resolution. Sub-second samples sharing a
second collapse last-write-wins on upsert (~762 records → ~722 distinct keys over a ~12-min fixture, per
4.1). **Decision: intended.** The biometric store is ~1 Hz; sub-second duplicates are near-identical
biometric values and last-write-wins on a 1 Hz metric is acceptable. The `rr_intervals` table keys on
`(device_id, ts, rr_ms)` and `events` on `(device_id, ts, kind)`, so those do NOT collapse multiple
distinct values in one second. This is a known, bounded fidelity property of the 1 Hz store — not a bug
and not a drop (the 4.1 reconciliation compares against distinct keys, not raw record count).

### C. Optical byte[3] / IMU-tail completeness — deferred, non-blocking

Per `docs/specs/2026-05-24-decode-completeness-matrix.md` §"Open unknowns", the remaining undecoded bytes
are all in the **raw type-43 IMU/optical packets**: GAP1 `frame[24:82]`, GAP2 `frame[682:685]`, TAIL
`frame[1292:1917]` (~33% of the IMU packet, constant-ish), the 1921 config/TLV header `frame[15:42]`,
and the per-sample optical `aux` byte (`byte[3]`, ~73% sign-extension else burst markers). **None of
these are in the type-47 V24 biometric store** that drives the primary metric pipeline — they live in
the research-only raw path (OFF by default). **Decision: deferred completeness, not blocking.** They
are kept verbatim in the raw outbox when the research toggle is on, so nothing is lost; resolving them
needs targeted captures (e.g. an ambient/light capture for the `aux` byte) and is not worth implementing
speculatively here. Cheap wins: none identified — the bytes are constant-ish and lack ground truth.

---

## Guarantees summary (what you can trust)

1. **Re-ingesting the same data never duplicates rows** — every server table upserts by natural key;
   re-POST leaves `/v1/summary` counts and daily recompute unchanged.
2. **Neither cursor ever moves backward.** Upload highwater is forward-only (store filters `ts >= from`,
   advances only on 2xx). Read highwater is now forward-only too (clamped `max(current, maxTs)` — the one
   bug this audit found and fixed). A failed upload/pull leaves the cursor and store untouched → safe retry.
3. **A historical chunk is acked only after it is locally durable** (decoded persisted, raw too if the
   toggle is on). If decode/persist/cursor fails, or the clock hasn't landed, the chunk is NOT acked and
   the strap re-offloads it — no data loss, no false trim advance.
4. **The offload catches up to live** — every HISTORY_END is acked so the strap's trim advances; a
   disconnect mid-drain drops only the open (un-committed) chunk and the persisted trim cursor survives,
   so the reconnect resumes forward.
5. **Frames that arrive before the clock lands are buffered (capped, drop-oldest) and later persisted
   with the correct wall ts** — not dropped, not mis-timestamped.
6. **History = union(phone-decoded, server-computed)** — upload + pull are both idempotent and
   highwater/natural-key gated, so the two sides converge without dropping or duplicating.
7. **The BLE reconnect path does not thrash** — once-per-connect initial kick, gated periodic re-trigger,
   single serial drain, clean teardown + 3s rescan. (Backoff tuning is Task 4.3.)

### Suite status at audit close

| Suite | Count | Result |
|---|---|---|
| `swift test Packages/WhoopProtocol` | 62 | green |
| `swift test Packages/WhoopStore` | 46 | green |
| iOS (`xcodebuild test OpenWhoop`) | 95 (was ~91; +5 test functions covering 4 invariants) | green |
| ingest (`pytest`) | 166 | green |
