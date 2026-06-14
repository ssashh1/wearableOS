# Sync stall investigation — strap halts biometric logging, stuck in high-freq-sync (2026-05-25)

**Audience:** the session that is going to redesign syncing. This is a self-contained handoff —
it explains the bug we hit, the evidence, the current sync architecture (so you know what you're
changing), the root cause, and concrete recommendations. No prior context required.

**TL;DR:** A worn, connected WHOOP 4.0 stopped logging biometrics at **20:15:17 UTC** and stayed
stuck for 65+ minutes. The phone app, server, upload, decode, and ack/trim were all **healthy** —
the strap simply produced no new data. Root cause: the app sends `ENTER_HIGH_FREQ_SYNC` on connect
but **never sends `EXIT_HIGH_FREQ_SYNC`** (the command isn't even in the app's enum). High-freq-sync
suppresses the strap's free-running 1 Hz logging (documented gotcha #1). Two back-to-back app
**re-installs force-killed the app mid-session**, dropping BLE abruptly so the strap never got the
implicit "leave sync / resume logging" signal — it was parked in sync mode and never recovered.
The data from 20:15→recovery is **permanently lost** (never logged, so not offloadable).

---

## 1. Symptom (as reported)

- "Haven't seen an update in ~35 min." Dashboard not advancing; in-app sample count flat.
- "The app **is** getting historical data results" — i.e. the app is connected and receiving
  offload frames — "but sample count isn't going up (in app), same for dashboard."
- Strap was **on-wrist the entire time** (user confirmed; never removed). So this is NOT off-wrist.

---

## 2. Evidence

### 2.1 Server frontier (race-free read; reflects full pipeline)
Last sample per stream (queried ~21:09 UTC):

| stream | count | last ts (UTC) |
|---|---|---|
| hr | 67,731 | 2026-05-25 **20:15:17** |
| gravity | 67,273 | 2026-05-25 **20:15:17** |
| rr | 40,478 | 2026-05-25 **20:15:17** |
| battery | 6 | 08:55 (battery uploads rarely; not relevant) |
| events | — | last event **20:10:35** |

So the **entire strap→server flow stopped ~20:10–20:15**, ~54 min before the first query.

### 2.2 On-device SQLite (GRDB) — the source of truth before upload
Pulled from the phone (see §6 for the command). Three samples over ~11 min:

| | 21:09 | 21:12 | 21:20 |
|---|---|---|---|
| hr max ts (UTC) | 20:15:17 | 20:15:17 | **20:15:17** (frozen) |
| hr row count | 67,731 | 67,731 | **67,731** (frozen) |
| `cursors.strap_trim` | 68,883 | 68,911 | **69,010** (climbing) |

- **Device frontier == server frontier exactly** (67,731 @ 20:15:17). Upload is healthy.
- **`hrSample` unsynced backlog = 0.** Everything the device has is already uploaded — there's
  simply nothing newer to upload.
- **`strap_trim` is steadily climbing** (~0.19/s) while the data frontier is frozen. The app is
  connected and actively offloading + acking — it just isn't getting any new biometric records.

### 2.3 The frontier is a clean 1 Hz hard-stop (not a frozen-timestamp pile-up)
Last 12 `hrSample` rows: one row per second, contiguous, HR 72–74 bpm (normal worn resting HR)
right up to 20:15:17, then nothing. `hrSample` PRIMARY KEY is `(deviceId, ts)`.

> Note: because the PK dedupes on `ts`, a strap re-sending records stamped at a **frozen
> timestamp** would also show exactly one row at 20:15:17 with trim advancing as duplicates get
> consumed and dropped. So "one row at the max ts" does **not** by itself distinguish "stopped
> logging" from "logging with a frozen clock." The trim *rate* (below) is what distinguishes them.

### 2.4 Trim rate rules out "logging but mis-decoded"
`strap_trim` is the strap's offload frontier (the `trim` u32 from each `HISTORY_END`, see §3).
It advanced **68,883 → 69,010 = +127 in ~11 min ≈ 0.19/s** — far below 1 Hz.

- If the strap were logging at 1 Hz and only the **phone's decode/timestamping** were broken, the
  offload would still pull ~1 record/s, so trim would advance ~60/min and the data frontier would
  either jump to a wrong value or the rows would be dropped at ~1/s. Neither happens.
- ~0.19/s means the strap is feeding only sparse trailing/empty `HISTORY_END`s — **it is producing
  no new 1 Hz biometric records.** The offload is chewing past the frontier and finding nothing.

**Conclusion (high confidence): the strap halted biometric logging at 20:15:17.** The phone/server
pipeline is blameless.

---

## 3. Current sync architecture (what you're changing)

All iOS, in `ios/OpenWhoop/`. The strap's 14-day biometric store is type-47 `HISTORICAL_DATA`
(HR/HRV/SpO2/skin-temp/resp/gravity at 1 Hz), reachable only via the high-freq-sync handshake.

### 3.1 Connect handshake — runs **once per physical connect** (`backfillStarted` gate)
`BLEManager.swift` ~line 620, in `didWriteValueFor` (first confirmed write = bond):
```
GET_CLOCK (sent earlier, when clockRef == nil; builds device↔wall correlation)   // ~line 611
SET_CLOCK(now)                  // "fix the frozen RTC so the strap logs + timestamps sanely"
SEND_R10_R11_REALTIME [0x00]    // stop the ~2/s type-43 realtime-raw flood (the REAL control)
ENTER_HIGH_FREQ_SYNC []         // cmd 96 — unlocks the type-47 store
GET_DATA_RANGE
beginBackfill()                 // SEND_HISTORICAL_DATA → start draining
uploadOpportunistically(); startUploadTimer(); startBackfillTimer()
```
`SET_CLOCK(10)` payload = current unix time as u32 LE + 5 zero pad (`setClockPayload`, ~line 652).

### 3.2 Offload state machine — `Collect/Backfiller.swift`
High-freq-sync replays the store as **1 `HISTORY_START` then REPEATED `HISTORY_END`s** (a chunk
closes every ~50 records). Per `HISTORY_END` (`finishChunk`, ~line 118):
```
decode accumulated chunk (extractHistoricalStreams, needs clockRef) →
store.insert(decoded)  →  store.setCursor("strap_trim", trim)  →  ackTrim(trim, endData)
```
- `strap_trim` = first u32 of `end_data` (= `HISTORY_END` metadata `data[10:14]`).
- Ack form: `HISTORICAL_DATA_RESULT(23)` payload `[0x01] + end_data` (`end_data` = `data[10:18]`,
  8 bytes), `.withResponse`. The strap forgets (trims) a chunk only after this confirmed ack.
- An **empty `HISTORY_END` is still acked** — that's how the frontier advances when caught up.
- Safe-trim invariant: a chunk is acked only after decoded rows are locally durable. Never waits
  on the server.

### 3.3 Periodic re-offload + timers (continuous while connected)
- `backfillIntervalSeconds = 300` (5 min): re-runs `beginBackfill()` (just `SEND_HISTORICAL_DATA`
  + re-arm watchdog) — the handshake itself does NOT re-run (it's gated once per connect).
- `backfillIdleTimeoutSeconds = 60`: idle watchdog; on fire → `exitBackfilling(reason:"timeout")`.
- `uploadIntervalSeconds = 30`: push pending rows to server.
- `exitBackfilling()` (~line 313) is **LOCAL ONLY**: cancels timers, clears the frame queue, kicks
  upload + server pull. **It sends NOTHING to the strap.**

### 3.4 Clock correlation — `Collect/ClockCorrelation.swift`
`GET_CLOCK` (sent **before** `SET_CLOCK` in the handshake) → `ClockRef(device, wall=now)`.
Historical type-47 timestamps are derived from this correlation
(`extractHistoricalStreams(parsed, deviceClockRef:, wallClockRef:)`), **not** a raw embedded unix.
`clockRef` is suppressed-from-re-request on a *same-process* reconnect (monotonic clock assumed
still valid); re-requested on a fresh process / background relaunch.

### 3.5 Upload / pull — `Upload/Uploader.swift`, `Upload/ServerSync.swift`
Per-row `synced` flag (WhoopStore v5), not a forward highwater (a highwater stranded backfilled
older-ts rows). Server pull/cloud-restore run from `exitBackfilling()`, deferred so they don't
starve the offload's per-chunk insert→ack.

---

## 4. Root cause

### 4.1 The code gap: enter sync, never exit
- The app sends `ENTER_HIGH_FREQ_SYNC` (cmd **96**) on connect.
- `EXIT_HIGH_FREQ_SYNC` (cmd **97**, defined in `protocol/whoop_protocol.json`) is **not in the
  `WhoopCommand` enum at all** (`ios/OpenWhoop/BLE/Commands.swift`). The app never sends it.
- The app relies on the strap **implicitly** auto-exiting sync (on a clean disconnect / idle).

### 4.2 High-freq-sync suppresses logging (runbook gotcha #1)
> *"Driving the strap … and repeated high-freq-sync sessions (`ENTER_HIGH_FREQ_SYNC`) tie the strap
> up so it isn't free-running its 1 Hz biometric logging → creates gaps."*
> — `docs/specs/2026-05-25-debugging-runbook.md` §3.1

### 4.3 The trigger: abrupt app-kills from re-installing builds
Timeline (all UTC):
- … strap logging fine at 1 Hz, HR ~73 bpm, up to **20:15:17**.
- **~20:18** — installed build #1 (haptics). Installing **force-kills the running app** → BLE drops
  abruptly (no graceful teardown). The strap, parked in high-freq-sync, never got the implicit
  exit → stopped free-running logging.
- **~20:27** — installed build #2 (battery alerts) → killed again.
- On every reconnect since, the app re-enters high-freq-sync (and the 5-min periodic backfill keeps
  poking it), so the strap is held in sync mode and **never gets a window to resume 1 Hz logging**.
- **65+ min later** — still frozen at 20:15:17; not self-recovering.

The two installs are the proximate cause. But the **latent defect** is architectural: the app can
put the strap into a logging-suppressed state and has **no command and no logic to get it back out**
(no explicit `EXIT_HIGH_FREQ_SYNC`, no "frontier not advancing while connected" watchdog/recovery).

### 4.4 Alternative/contributing mechanism: frozen RTC
`SET_CLOCK` is in the handshake specifically to "fix the frozen RTC so the strap logs." Prior work
(see `MEMORY.md` / `whoop-productionization.md`) found the type-47 store needs
`SET_CLOCK(fix frozen RTC) + REBOOT` to become reachable when the RTC is frozen. The app
**deliberately omits REBOOT** (safety), so a `SET_CLOCK`-only reconnect cannot clear a truly frozen
RTC. From the phone side, "stuck in sync" and "frozen RTC" are **indistinguishable** (worn,
connected, offloading nothing) and have the **same practical fix** (force the strap out of its
state). Disambiguating requires a Mac BLE session — see §6.

### 4.5 Explicitly ruled out
- **Off-wrist** — user confirmed continuous wear.
- **Trim-stuck / no-ack bug** (a prior, fixed failure mode) — `strap_trim` is advancing fine.
- **Upload stall** — 0 unsynced; device == server.
- **Decode regression from this session's changes** — haptics/battery-alert changes don't touch the
  offload/decode/ack paths; `WhoopProtocol` decode unchanged (62 tests green); pre-20:15 data
  decoded fine through the same code; the app isn't crashing (it's receiving frames).

---

## 5. Recommendations for the sync redesign

These are the takeaways most relevant to a sync rewrite:

1. **Always pair enter/exit of high-freq-sync.** Add `EXIT_HIGH_FREQ_SYNC` (cmd 97) to
   `WhoopCommand` and send it at the end of every offload session (in `exitBackfilling()` and on
   graceful disconnect), so the strap is *explicitly* returned to free-running 1 Hz logging instead
   of relying on implicit auto-exit. Treat "the strap is in sync mode" as a state the app owns and
   must always release.
2. **Minimize time spent in sync.** The current design enters sync once per connect and stays
   connected continuously, re-poking every 5 min. If the strap does not free-run logging while in
   sync, that's fundamentally at odds with continuous connection. Consider: enter sync → drain →
   **exit sync** → idle (let the strap log) → re-enter on the next interval. (Open question 6.1.)
3. **Add a liveness/recovery watchdog.** If connected+bonded but the data frontier (`max(ts)` /
   `strap_trim`) hasn't advanced in N minutes, escalate: re-issue `SET_CLOCK`, exit+re-enter sync,
   and surface a user-visible "strap may need a reboot" state. Today there is **no detection** of a
   stuck strap — it silently logs nothing for an hour.
4. **Survive abrupt app termination.** Installs, crashes, and OS kills will drop BLE without a
   graceful teardown. The design must assume the strap can be left in *any* mid-session state and
   must recover deterministically on the next connect (e.g. unconditionally exit-then-enter sync at
   the start of a session, rather than assuming the strap auto-cleaned-up).
5. **Don't trust the wall clock for gap reasoning; reconcile against `GET_DATA_RANGE`.** The
   handshake reads `GET_DATA_RANGE` but the result isn't used to verify the strap actually has data
   newer than the local frontier. A redesign should compare the strap's reported newest record
   against the local frontier to *detect* "strap has nothing new" vs "we're behind."
6. **Re-examine the SET_CLOCK / clock-correlation coupling.** `GET_CLOCK` is captured *before*
   `SET_CLOCK` resets the strap clock; historical ts are derived from that correlation. If a
   reconnect's `SET_CLOCK` introduces a clock discontinuity, post-reset records could map to wrong
   unix times. This wasn't the cause here (the strap produced no records at all) but is a latent
   hazard worth designing out (e.g. correlate *after* `SET_CLOCK`, or trust an embedded record
   unix if one exists).

---

## 6. Reference: how to reach the data & the strap (for the next session)

Full detail in `docs/specs/2026-05-25-debugging-runbook.md`. Essentials:

- **Device:** iPhone udid `<DEVICE_UDID>`, team `<TEAM_ID>`, bundle
  `com.openwhoop.OpenWhoop`. Server device id `my-whoop` at `https://whoop.example.com`
  (Bearer key lives only in gitignored config — never committed). Cloudflare WAF 403s default
  UAs → use `curl`.
- **Server frontier per stream:**
  ```bash
  KEY=<see runbook §1>
  curl -s -H "Authorization: Bearer $KEY" \
    "https://whoop.example.com/v1/streams/hr?device=my-whoop&from=0&to=2000000000&limit=200000" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d), d[-1]['ts'] if d else 'NONE')"
  ```
- **Pull device SQLite** (⚠️ WAL gotcha: if mid-write, also copy `-wal`/`-shm`, or just use the
  server). "No provider was found" from devicectl is benign noise.
  ```bash
  xcrun devicectl device copy from --device <DEVICE_UDID> \
    --domain-type appDataContainer --domain-identifier com.openwhoop.OpenWhoop \
    --source "Library/Application Support/OpenWhoop/whoop.sqlite" --destination /tmp/x.sqlite
  sqlite3 /tmp/x.sqlite "SELECT datetime(MAX(ts),'unixepoch'), COUNT(*) FROM hrSample;"
  sqlite3 /tmp/x.sqlite "SELECT name,value FROM cursors;"   # strap_trim = offload frontier
  ```
- **Is the strap logging RIGHT NOW?** `re/diagnose_biometrics.py` (read-only: dumps feature flags;
  `GET_DATA_RANGE` ×2 ~20 s apart → does newest-unix advance ⇒ logging; decodes newest type-47).
  **Requires a Mac BLE connection → quit the phone app first** (one BLE connection at a time), and
  per gotcha #1 a Mac session can itself interrupt logging — use only when you accept that.

### Key source files
- `ios/OpenWhoop/BLE/BLEManager.swift` — handshake (~620), `exitBackfilling` (~313), timers (~50),
  `setClockPayload` (~652), `armBackfillTimeout` (~298).
- `ios/OpenWhoop/BLE/Commands.swift` — `WhoopCommand` enum (has `enterHighFreqSync = 96`, **no 97**).
- `ios/OpenWhoop/Collect/Backfiller.swift` — offload state machine, `finishChunk` (~118).
- `ios/OpenWhoop/Collect/ClockCorrelation.swift` — device↔wall correlation.
- `ios/OpenWhoop/Upload/{Uploader,ServerSync}.swift` — upload + pull.
- `protocol/whoop_protocol.json` — command numbers (96 enter / 97 exit high-freq-sync).

---

## 7. Recovery for the *current* stuck strap (not the redesign — immediate)

The 20:15→now data is gone (never logged). To resume logging:
1. **Clean reconnect**: in the app, Disconnect → wait ~10 s → Connect. A graceful BLE teardown may
   let the strap exit sync and resume; the fresh handshake re-sends `SET_CLOCK`. Verify the server
   frontier climbs past 20:15:17.
2. **If that fails → reboot the strap** (documented `SET_CLOCK + REBOOT` frozen-RTC fix). The app
   excludes the reboot command, so this is a manual strap reboot.

---

## 8. Open questions for the redesign session

1. **Does high-freq-sync actually suppress the strap's flash logging, or only change the BLE
   replay mode?** Gotcha #1 says it suppresses logging — but 67,731 rows (~18.8 h of 1 Hz data)
   accumulated while the app was (presumably) connected and had entered sync once. Either the strap
   free-runs logging *between* the brief periodic drains, or it disconnects between them, or sync
   doesn't fully suppress logging. Resolve this empirically (it determines whether recommendation
   #2's "exit between intervals" is necessary).
2. **What is the strap's own auto-exit behavior for high-freq-sync** (idle timeout? disconnect?),
   and does an *abrupt* (non-graceful) BLE drop bypass it? This determines how aggressively the app
   must force exit/re-enter on reconnect.
3. **Is the stuck state a sync-mode lock or a frozen RTC?** Run `diagnose_biometrics.py` (§6, phone
   app quit) to see if the strap clock/newest-unix advances. Drives whether `EXIT_HIGH_FREQ_SYNC`
   alone is sufficient recovery or whether a reboot path is mandatory.
4. **Should `SET_CLOCK` move to *after* `GET_CLOCK`'s response** (or be skipped when the clock is
   already sane) to avoid clock discontinuities in historical-record timestamps?
