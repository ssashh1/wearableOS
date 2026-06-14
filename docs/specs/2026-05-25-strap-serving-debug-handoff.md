# WHOOP Strap "Won't Serve type-47" — Deep-Debug Handoff (2026-05-25)

> **You are picking up a hard, unsolved hardware/protocol bug. Work AUTONOMOUSLY and EXHAUSTIVELY.**
> Use subagents for parallel research. Test on real hardware (the iPhone AND the Mac-BLE prototype).
> Try things, observe, iterate — do NOT stop to ask the user unless you are truly blocked on a physical
> action only they can do. Keep going until type-47 historical data flows end-to-end. The previous
> session did ~20 build/test cycles + 3 deep-research subagents and narrowed it a lot but did not crack
> it; this doc hands you everything so you don't repeat dead ends.

---

## 0. THE MISSION

Make the WHOOP 4.0 strap **serve its type-47 HISTORICAL_DATA (1 Hz biometric records: HR/HRV/SpO2/
skin-temp/resp/accel-gravity) in response to `SEND_HISTORICAL_DATA(22)`**, so the OpenWhoop iOS app can
offload → decode → persist → upload the strap's 14-day flash store. This is the core data pipeline; it is
currently BROKEN. The strap is logging fine but refuses to *serve*.

Secondary: leave the iOS app in the optimal **WHOOP-faithful** steady state (mimic exactly what WHOOP's
own app does to talk to the strap).

---

## 1. THE BUG — precise current symptom (verified on-device this session)

The strap is **bonded, powered, healthy, and actively logging**, but:

| Command sent | Strap response |
|---|---|
| `SET_CLOCK(10)` | ✅ acked (`COMMAND_RESPONSE` type=36 cmd=10) — *sometimes* (flaky) |
| `GET_DATA_RANGE(34)` | ✅ full 80-byte response, reliably |
| `GET_BATTERY_LEVEL(26)` | ✅ response |
| EVENT push (type=48) | ✅ strap pushes many: cmd 1,3,9,16,28,61,62,63,67,68,69,102 |
| **`GET_CLOCK(11)`** | ❌ **DEAD SILENT** — never responds |
| **`SEND_HISTORICAL_DATA(22)`** | ❌ **DEAD SILENT** — zero type-47 frames → 60 s watchdog timeout |

**Decoding `GET_DATA_RANGE` confirms the strap IS logging** (format in §4.3): write-cursor `W` climbs
steadily across tests (73,114 → ~74,400), read-cursor `U` stuck at 72,950, capacity `T`=131072 →
**~1,450 records pending and un-served.** So there is plenty of data to serve; the strap just won't.

**This state is PERSISTENT and NOVEL:**
- Survives a full `REBOOT_STRAP(29)` (confirmed: fresh boot, boot-event flood, then *still* silent).
- Survives a correct 8-byte `SET_CLOCK` + reboot-to-latch.
- `GET_CLOCK(11)` + `SEND_HISTORICAL(22)` **worked in prior sessions** (762 records pulled; 48 type-47 in
  a soak) — so this is a *new* state change, not a permanent strap limitation.
- Onset: data capture stopped at **~17:23 PDT (2026-05-25)**, ~4 min before the new sync-hardening iOS
  build first connected (~17:27). Strong temporal link to that build's first handshake.

**Key unexplained anomaly:** `GET_CLOCK(11)` and `SEND_HISTORICAL(22)` are *both* silent, while
`GET_DATA_RANGE(34)` (same cmd-notify characteristic 61080003) works. Selective, command-specific silence
that survives reboot. Both silent commands are "clock/time-dependent." No documented RE state matches this
exact signature. **Cracking *why these two specific commands went silent* is probably the whole ballgame.**

Caveat: after ~20 reconnect/reboot cycles over ~2 hours + a low battery, the strap also became **BLE-flaky**
(intermittent failure to connect, inconsistent acks). Some inconsistency is churn/battery, but the
GET_CLOCK+SEND_HISTORICAL silence has been 100% consistent (every single capture) — that part is the real fault.

---

## 2. TOOLING & WORKFLOW (you will use this constantly)

### Hardware / signing
- **iPhone** (named "Galaxy S9", actually iPhone 16 Pro). xcodebuild/devicectl device id (UDID):
  **`<DEVICE_UDID>`**. (devicectl also shows a CoreDevice id `<COREDEVICE_ID>`; use the UDID for builds.)
- **Code-signing team: `<TEAM_ID>`** (this is the cert's **OU**, the real Team ID). The cert CN paren
  `<APPLE_USER_ID>` is the *user* id — do NOT use it as the team. Cert: "Apple Development: Johnathan Middleton".
- The strap is bonded to the OpenWhoop app (bundle `com.openwhoop.OpenWhoop`).

### Build + install to the phone
```bash
cd ~/openwhoop/ios
# regenerate the Xcode project only if you ADD/REMOVE source files:
xcodegen generate            # needs Secrets.xcconfig + Info.plist present (both gitignored; already in place)
xcodebuild -project OpenWhoop.xcodeproj -scheme OpenWhoop \
  -destination 'platform=iOS,id=<DEVICE_UDID>' \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=<TEAM_ID> build 2>&1 | tail -3
xcrun devicectl device install app --device <DEVICE_UDID> \
  "~/Library/Developer/Xcode/DerivedData/OpenWhoop-asfsvxavppmlyifxnzsxzqienrar/Build/Products/Debug-iphoneos/OpenWhoop.app" 2>&1 | grep -iE "App installed"
```
(The DerivedData hash `OpenWhoop-asfsvxavppmlyifxnzsxzqienrar` is keyed to the checkout path; re-derive if
it changes via `xcodebuild -showBuildSettings | grep BUILT_PRODUCTS_DIR`.)

### **Capture the app's logs off the phone (THE key technique)**
The app's `log()` was instrumented to also `print("[OW] …")`, and `devicectl … --console` streams stdout:
```bash
xcrun devicectl device process launch --console --terminate-existing \
  --device <DEVICE_UDID> com.openwhoop.OpenWhoop > /tmp/ow.log 2>&1 &
LP=$!
# poll the file until you see what you want, then read it:
for i in $(seq 1 30); do grep -q "BF chunk\|type=47\|cmd=11\|session ended" /tmp/ow.log && break; sleep 5; done
cat /tmp/ow.log; kill $LP 2>/dev/null
```
- `--terminate-existing` relaunches fresh (a fresh connect → full handshake → offload).
- The `Failed to load provisioning paramter list … No provider was found.` line from devicectl is **benign**.
- Occasionally the first launch logs nothing (transient no-connect) — just relaunch.
- `print()` output IS captured by `--console`. The DIAG instrumentation (see §9) logs every non-realtime
  received frame as `[OW] DIAG rx type=<t> cmd=<c> len=<n>`, plus GET_DATA_RANGE raw, plus per-chunk decode.

### **The Mac-BLE prototype = GROUND TRUTH (the previous session under-used this — START HERE)**
`re/` contains a working Python/bleak prototype that talked to this exact strap and **pulled 762 type-47
records** before. It is the fastest, cleanest way to test the strap directly, bypassing the entire iOS app.
**The single most valuable first experiment: run `re/sync_openwhoop.py` (or `re/diagnose_biometrics.py`,
read-only) against the strap and see whether type-47 serves NOW.**
- This requires the **phone app quit + iPhone Bluetooth OFF** (or the strap free) so the Mac can bond
  (two centrals can't both own it). Ask the user to toggle iPhone BT off for this, OR just try — bleak
  scans for the strap.
- If the prototype **serves type-47** → the strap is fine and the bug is **iOS-app-side**; diff the iOS
  handshake against the prototype byte-for-byte to find what the app does differently.
- If the prototype **also gets silence** → the strap is genuinely stuck (needs deeper recovery / official app).
- Device identity for the scripts lives in **gitignored `re/device_local.py`** (real BLE UUID/MAC/serial).
  `re/device_config.py` imports it. Run scripts from a venv that has `bleak` (the repo used
  `whoomp/.venv` or `whoop-reader/.venv`; check `re/README.md`).
- **WARNING from the runbook:** Mac BLE sessions interrupt the strap's free-running 1 Hz logging (cause
  gaps). Use read-only scripts (`diagnose_biometrics.py`) for diagnosis; minimize churn.

### Server (to check the true data frontier, independent of the device)
```bash
KEY=<WHOOP_API_KEY>
curl -s -H "Authorization: Bearer $KEY" \
 "https://whoop.example.com/v1/streams/hr?device=my-whoop&from=<unix>&to=<unix>&limit=200" | python3 -m json.tool
curl -s -H "Authorization: Bearer $KEY" "https://whoop.example.com/v1/summary?device=my-whoop&from=<unix>&to=<unix>"
```
Cloudflare WAF 403s default user-agents — **use `curl`**, not urllib. The server's newest HR was
**2026-05-25 17:23 PDT** (= the gap onset). 426,970 phone "samples" ≈ the 14-day server total
(hr 76929 + rr 43590 + ev 476 + bat 29 + spo2/skin/resp/gravity 76471×4) — it was cloud-restored to the
phone, so phone == server; neither is advancing.

---

## 3. HOW THE STRAP EXPECTS TO BE TALKED TO (observed behavior)

The following is the **interoperable behavior model** — what the strap expects on the wire, as
needed to talk to one's own device. It is a description of byte-level protocol behavior, not a
reproduction of anyone's source.

- **Sync session:** offload = rate-limit ≥5 s → `GET_DATA_RANGE` (analytics only) → **plain
  `SEND_HISTORICAL_DATA(22)` with EMPTY payload** → ack loop. **No SET_CLOCK, no ENTER/EXIT
  high-freq, no R10/R11 toggle in the offload path.** On watchdog timeout: `ABORT_HISTORICAL_TRANSMITS`,
  wait 3000 ms, retry. Command-response timeout = 5000 ms.
- **Offload reduction:** `HISTORY_START`→begin, `HISTORY_END`→ack chunk, `HISTORY_COMPLETE`→end;
  non-type-47 packets are dropped. "Stuck" is declared after **15** consecutive burst-validation failures.
- **Connect lifecycle:** **hello → set RTC → sync**. On an RTC-lost event the clock is re-set.
  Drift check `>= 2 s`. Strap-pushed events trigger syncs (a high-freq-sync prompt → a normal
  1-minute offload, NOT enter-high-freq).
- **Packet formats:** `SET_CLOCK` = 8 bytes `[seconds u32 LE][subseconds u32 LE]`, subsec in
  1/32768 s; `ENTER_HIGH_FREQ_SYNC` = 5 bytes `[0x02][interval u16 LE][duration u16 LE]`
  (duration ≤7200, auto-exits) — used **only** for Smart-Alarm, never for offload; EXIT = empty;
  `SEND_HISTORICAL_DATA` = EMPTY payload, fire-and-forget; SET_FF = 65 bytes (see §4.5);
  `HISTORICAL_DATA_RESULT` ack = 9 bytes (see §4.2).
- **Event numbers:** RTC_LOST=13, SET_RTC=16, BOOT=15, FLASH_INIT_COMPLETE=28, BLE_SYSTEM_INITIALIZED=45.

**Bottom line on the model:** persistent bonded connection; set the RTC on connect; offload with plain
`SEND_HISTORICAL_DATA` + per-`HISTORY_END` ack; react to strap-pushed events; high-freq-sync is a
Smart-Alarm feature, NOT part of offload.

---

## 4. PROTOCOL REFERENCE (commands, formats — verified)

GATT (custom service `61080001-8d6d-82b8-614a-1c8cb0f8dcc6`):
- `61080002` = cmd write (→ strap). `61080003` = cmd-notify (responses). `61080004` = event-notify.
  `61080005` = data-notify (historical/fragmented). Standard `2A37` HR, `2A19` battery.
- Frame layout (a complete reassembled frame): `[0]=0xAA SOF, [1..2]=len u16 LE, [3]=crc8(len bytes),
  [4]=type, [5]=seq, [6]=cmd, [7…]=payload, [last 4]=crc32 LE]`. COMMAND type byte=35; responses type=36;
  EVENT type=48; historical types 47/48/49/50.

### 4.1 Command codes (observed)
`TOGGLE_REALTIME_HR=3, REPORT_VERSION=7, SET_CLOCK=10, GET_CLOCK=11, SEND_HISTORICAL_DATA=22,
HISTORICAL_DATA_RESULT=23, GET_BATTERY_LEVEL=26, REBOOT_STRAP=29, POWER_CYCLE_STRAP=32, GET_DATA_RANGE=34,
GET_HELLO_HARVARD=35, SEND_R10_R11_REALTIME=63, GET_ADVERTISING_NAME=76, RUN_HAPTICS=79, START_RAW_DATA=81,
STOP_RAW_DATA=82, ENTER_HIGH_FREQ_SYNC=96, EXIT_HIGH_FREQ_SYNC=97, GET_EXTENDED_BATTERY=98,
TOGGLE_IMU_MODE=106, ENABLE_OPTICAL_DATA=107, START_FF_KEY_EXCHANGE=117, SEND_NEXT_FF=118, SET_FF_VALUE=120,
GET_FF_VALUE=128, START_DEVICE_CONFIG_KEY_EXCHANGE=115, SEND_NEXT_DEVICE_CONFIG=116,
SET_DEVICE_CONFIG_VALUE=119, GET_DEVICE_CONFIG_VALUE=121, STOP_HAPTICS=122.`

### 4.2 Offload (the goal)
`SEND_HISTORICAL_DATA(22)`: **WHOOP sends EMPTY payload, fire-and-forget (.withoutResponse)**. Strap streams
`HISTORY_START` → [type-47 records] → `HISTORY_END` → … → `HISTORY_COMPLETE` (caught up). Ack each
`HISTORY_END` with `HISTORICAL_DATA_RESULT(23)` = **9 bytes = `[0x01] + HISTORY_END frame[17:25]`** (the
strap's read-cursor words echoed back, advancing/trimming). The ack offset `frame[17:25]` is verified
correct (matches our `Backfiller.endData`).

### 4.3 GET_DATA_RANGE(34) response (80 bytes) — decode (verified)
Payload `I()` starts at frame[9]; `V(i)` = u32 LE at **frame[10 + 4*i]**:
- `W` = write cursor (newest record idx) = `V(2)` = **frame[18:22] LE**
- `U` = read/trim cursor (oldest un-offloaded) = `V(3)` = **frame[22:26] LE**
- `T` = ring capacity = `V(5)` = **frame[30:34] LE** (= 131072)
- pending = `W < U ? W + (T - U) : W - U`
- Then a tail of `(count u32, unix-timestamp u32)` range records ~frame[38:70].
(Our app's `BLEManager.dataRangeNewestUnix` is a BROKEN ad-hoc parser — it scans 4-aligned words for a
unix-ish max and grabs garbage. Replace it with the W/U/T decode above. It only feeds the watchdog, not
the offload, so it's not the root bug — but fix it.)

### 4.4 Clock
- `SET_CLOCK(10)` = **8 bytes `[unix_seconds u32 LE][subseconds u32 LE]`** (subsec 1/32768 s; 0 is fine).
  (Our app shipped 9 bytes `[u32][5 pad]` — WRONG; fixed this session. A wrong-length SET_CLOCK is
  ack-received but may NOT latch.)
- `GET_CLOCK(11)` returns the strap's **device-monotonic epoch (~31.6 M), NOT unix** (`0a01 <u32 dev_clock LE><u16 subsec>`).
  The app correlates (device, wall) at connect to map type-47 device-epoch timestamps → wall time
  (`Collect/ClockCorrelation.swift`). GET_CLOCK has decoded fine on THIS strap before (dev_clock=31624076).
- Frozen/lost RTC suppresses biometric logging AND serving. Documented recovery: **correct SET_CLOCK +
  REBOOT_STRAP to LATCH** (`docs/specs/2026-05-24-whoop-protocol-complete.md` §0-bis; the strap had been
  frozen at 2025-01-08 before). Events: `RTC_LOST=13`, `SET_RTC=16` (emitted when a clock latches).

### 4.5 Feature flags (do NOT gate serving — see §5, but documented for completeness)
- `START_FF_KEY_EXCHANGE(117)` payload `[0x01]` → resp `0a 01 01 <u16 count LE>` (this strap: count=11).
- `SEND_NEXT_FF(118)` payload `[0x01]` repeatedly (cursor) → `0a 01 01 00 01 <32-byte name>` (populated) or
  `0a 00 01 00 00 <zeros>` (exhausted).
- `SET_FF_VALUE(120)` = **65 bytes `[0x01][32-byte key UTF8 NUL-pad][32-byte value NUL-pad]`**, value `"1"`=ON / `"2"`=OFF.
- `GET_FF_VALUE(128)` is **unreliable** (returns contaminated stale-buffer garbage; can't trust the value).
- The 11 flags: `general_ab_test, sigproc_10_sec_dp, enable_r19_packets, enable_r19_v2…v6_packets,
  enable_write_r24_packets, enable_write_r25_packets, enable_sigproc_walk_detector` + device-config
  `sigproc_wear_detect`. They tune raw/research/sigproc products. Recipe to toggle: `re/enable_dataproducts.py`
  (`on`/`off`), `re/fix_raw_flood.py`.

### 4.6 High-freq-sync (NOT needed for offload)
`ENTER(96)` = `[0x02][interval u16][duration u16]` (bounded, auto-exits); `EXIT(97)` = empty. Smart-Alarm only.

---

## 5. WHAT WE PROVED / RULED OUT (do NOT re-litigate without new evidence)

1. **Feature flags do NOT gate type-47 serving.** (Research agent + runbook gotcha #4 + the strap is
   writing W regardless.) Prior RE left 4 sigproc flags OFF (never restored) + r24/r25 ON — but those tune
   raw products, not serving. *(Still UNTESTED on-device specifically for the serving question — see §6.)*
2. **High-freq-sync is NOT required for offload** (WHOOP doesn't use it; APK-confirmed). The OLD build's
   "serving worked" was a **spurious correlation** — the OLD build also sent **unconditional SET_CLOCK
   every connect**, which kept the RTC valid.
3. **The real regression in the merged plan:** Task 8 made `SET_CLOCK` **conditional on a GET_CLOCK
   correlation that never arrives** (GET_CLOCK silent) → the app stopped setting the clock → RTC drifted.
   Plus `setClockPayload` was the wrong length (9 vs 8 bytes). Plus the defensive `EXIT_HIGH_FREQ_SYNC`.
4. **The strap IS logging** (W climbs, ~1450 pending) — not a logging/data-loss problem; a *serving* problem.
5. **Data is safe**: 14-day flash persists across reboot (W retained post-reboot); server has ≤17:23 data.

### On-device experiments that did NOT restore serving (don't repeat these blindly):
- Empty vs `[0x00]` `SEND_HISTORICAL` payload.
- With vs without `EXIT_HIGH_FREQ_SYNC` on connect.
- `ENTER_HIGH_FREQ_SYNC` (empty payload) on connect.
- `SEND_R10_R11_REALTIME[0x00]` (flood-stop) present vs removed.
- Unconditional `SET_CLOCK` (9-byte, wrong) every connect.
- `REBOOT_STRAP(29)` — TWICE. Cleared RAM (fresh boot + boot-event flood) but serving still dead.
- Correct **8-byte** `SET_CLOCK` + 2 s + `REBOOT_STRAP` to latch ("recovery v2"). GET_CLOCK STILL silent, serving STILL dead.
- The exact OLD (known-working) handshake: `SET_CLOCK` + R10/R11-stop + `ENTER` + `SEND_HISTORICAL`, correct order.

All produced the same result: strap answers SET_CLOCK/GET_DATA_RANGE/battery + pushes events, but **GET_CLOCK
+ SEND_HISTORICAL stay silent.**

---

## 6. HYPOTHESES NOT YET TESTED (your starting menu — pursue these)

1. **★ Run the Mac-BLE prototype (`re/sync_openwhoop.py`) directly against the strap (GROUND TRUTH).**
   It pulled 762 records before. If it serves type-47 NOW → the bug is iOS-side; if not → strap is stuck.
   This is the highest-value untried experiment. (Phone app quit / BT off so the Mac can bond.)
2. **`SEND_HISTORICAL_DATA` with `.withoutResponse`** (WHOOP fire-and-forgets it; our app uses
   `.withResponse`). If the strap's GATT write-response for cmd 22 is part of the fault, a `.withResponse`
   write may stall/fail at the ATT layer and never reach the strap.
3. **Log the CHARACTERISTIC each received frame arrives on**, and confirm we actually receive on data-notify
   `61080005`. Maybe the strap IS streaming type-47 on 05 and the app drops/misroutes it. (Note: GET_CLOCK's
   silence is on cmd-notify 03 where GET_DATA_RANGE works, so this alone doesn't explain GET_CLOCK — but
   worth ruling out for the historical stream.)
4. **Read the strap's current feature-flag values** (enum via START/SEND_NEXT_FF) and/or just **run the full
   `enable_dataproducts.py` recipe** (SET_FF all data-product flags ON + SET_CLOCK + REBOOT) — to *definitively*
   rule flags in/out for serving on this strap (prior dismissal was reasoning, not an on-device serving test).
5. **Why is GET_CLOCK(11) silent specifically?** This is the crux. Compare the exact GET_CLOCK frame our app
   sends vs `re/` vs the observed builder. Is the command code/payload right? Does GET_CLOCK respond
   on the Mac prototype? Does it respond right after a confirmed `SET_RTC` event (16)?
6. **Full recharge + rest the strap** (it was low + churned). Then ONE clean test. (Physical — user action.)
7. **Official WHOOP app**: if our app can't un-stick it, re-pair to the official app and let it sync (full
   proper handshake). It may clear a firmware state. (Will re-bond away from our app; re-bond after. User action.)
8. Consider `POWER_CYCLE_STRAP(32)` (deeper than reboot) as a last-resort reset (more aggressive than 29).

---

## 7. CURRENT CODE STATE (uncommitted debug changes on `main`)

`git` is on **`main` at `9befee3`** (the merged sync-hardening plan + a comment-cleanup commit; the
isolated worktree was already removed). The working tree at **`~/openwhoop`** has
**UNCOMMITTED debug changes** on top — these are scaffolding, not final:

In `ios/OpenWhoop/BLE/BLEManager.swift`:
- `setClockPayload()` → **8 bytes** (fixed; was 9).
- **Unconditional `SET_CLOCK`** sent on every bond (before GET_CLOCK). [This is a real intended fix.]
- A **one-shot recovery** block gated by `UserDefaults "diagRecoverV2"` (now SET → inert): it did
  SET_CLOCK → 2 s → `REBOOT_STRAP`. There's also an older `"diagRebootedOnce"` flag (set). Both inert now.
- Handshake: **no `EXIT_HIGH_FREQ_SYNC`**; sends `SEND_R10_R11_REALTIME[0x00]` + `GET_DATA_RANGE` + `requestSync(.connect)`.
- `beginBackfill()` sends `SEND_HISTORICAL_DATA` with **empty payload, `.withResponse`** (the per-offload
  `GET_DATA_RANGE` that Task 5 added was removed).
- DIAG instrumentation: `log()` also `print("[OW] …")`; a receive-log line `[OW] DIAG rx type=<t> cmd=<c>
  len=<n>` for every non-(type40/type43) frame; `[OW] DIAG DataRange resp: …raw=<hex>`; `[OW] DIAG
  Liveness: strapNewest=… frontier=… gap=…`.
- `BackfillPolicy` floors back to real (900/90). For rapid testing, lower `eventFloorSeconds` (used 5).

In `ios/OpenWhoop/BLE/Commands.swift`: added `case rebootStrap = 29` (+ label) — the recovery command.

In `ios/OpenWhoop/Collect/Backfiller.swift`: `finishChunk` instrumented — `[OW] BF chunk …` logs decoded
HR count + ts range + inserted-row counts per HISTORY_END, and `[OW] BF chunk EMPTY …` for empty ENDs.
(This is how you'll SEE serving work: if type-47 flows you'll get `BF chunk frames=N hr=… NEW(hr=…)` lines.)

**Decide deliberately what to keep:** the genuine fixes worth committing eventually are (a) 8-byte
SET_CLOCK, (b) unconditional SET_CLOCK per connect / decouple from the silent GET_CLOCK, (c) no
`EXIT_HIGH_FREQ_SYNC`, (d) plain `SEND_HISTORICAL` offload, (e) the corrected GET_DATA_RANGE W/U/T parse.
The reboot one-shot + DIAG prints + lowered floors are debug-only — strip before any real commit.

### The merged plan (context)
`docs/plans/2026-05-25-sync-hardening.md` (17 tasks) + `docs/specs/2026-05-25-sync-hardening-design.md`.
Its core premise ("high-freq-sync is purely harmful + unnecessary; plain offload just works") was **too
narrowly verified** — the A/B test (`re/test_offload_without_highfreq.py`) ran while the strap was already
RTC-valid/servable, and never tested steady-state. Treat that design's F1/F2 with skepticism; trust the APK +
live hardware.

---

## 8. RATE-LIMITER & ORDERING GOTCHAS (they wasted time last session)

- `BackfillPolicy` floors + a persisted `UserDefaults "backfillLastAt"` watermark gate offloads. The app
  **auto-reconnects via CoreBluetooth restoration and offloads between your launches**, keeping the
  watermark fresh — so a fresh `devicectl` launch often logs `Backfill: connect/foreground skipped
  (rate-limited; last Ns ago)` and NO offload fires. **Lower `eventFloorSeconds` (e.g. to 5) for testing.**
- **Ordering race:** with low floors, the foreground/strap trigger fires `SEND_HISTORICAL` *before* the
  bond-block handshake (SET_CLOCK/ENTER come after). To force order for a test, call `beginBackfill()`
  directly in the handshake (bypass `requestSync`) so SEND_HISTORICAL comes after your handshake sends.

---

## 9. KEY FILES

- iOS: `ios/OpenWhoop/BLE/{BLEManager,Commands,FrameRouter,BackfillPolicy,LiveState}.swift`,
  `ios/OpenWhoop/Collect/{Collector,Backfiller,ClockCorrelation}.swift`,
  `Packages/WhoopProtocol/Sources/WhoopProtocol/*` (decoder; `Streams.swift`, `Interpreter.swift`),
  `Packages/WhoopStore/Sources/WhoopStore/{Reads,StreamStore}.swift`.
- RE prototype (Mac BLE, Python/bleak): `re/sync_openwhoop.py` (working offload!), `re/diagnose_biometrics.py`
  (read-only flag+range dump), `re/enable_dataproducts.py`, `re/fix_raw_flood.py`, `re/test_reboot.py`,
  `re/enum_config_v4.py`, `re/device_config.py` (+ gitignored `re/device_local.py` = real UUID/MAC/serial),
  `re/README.md`, `re/PROJECT_MEMORY.md`, `FINDINGS.md`.
- Protocol/docs: `docs/specs/2026-05-24-whoop-protocol-complete.md` (THE catalog + GET_DATA_RANGE/clock/FF +
  the frozen-RTC §0-bis), `docs/specs/2026-05-25-debugging-runbook.md` (gotchas; server access §1),
  `docs/specs/2026-05-25-sync-stall-frozen-strap-investigation.md`,
  `docs/specs/2026-05-25-sync-hardening-design.md`, `docs/plans/2026-05-25-sync-hardening.md`.
- Reference clones (gitignored): `whoomp/` (JS+Python reimpl; `whoomp/scripts/packet.py` = CommandNumber,
  `whoomp/whoomp.js`). See §3 for the observed strap behavior.
- Auto-memory: `~/.claude/projects/-Users-jp-Developer-whoop/memory/MEMORY.md` (+ linked files) — the
  project's running state.

---

## 10. RECOMMENDED AUTONOMOUS APPROACH

1. **Re-establish ground truth first.** Check the strap's CURRENT state (maybe it recovered after rest /
   official app). Run the **read-only Mac script `re/diagnose_biometrics.py`** (phone app quit) — does
   GET_CLOCK respond? does GET_DATA_RANGE show W>U? Then run **`re/sync_openwhoop.py`** — does type-47 serve?
   - This single experiment splits the entire problem: **strap-side fault vs iOS-app-side bug.**
2. If the prototype serves type-47 → the strap is fine → **diff the iOS app's exact byte sequence against
   the prototype** (capture both; compare every command frame, write type, ordering, characteristic). Fix
   the iOS app to match WHOOP/the prototype exactly. Verify via the `--console` capture (look for
   `[OW] BF chunk frames=N hr=… NEW(hr=…)` = serving works).
3. If the prototype also gets silence → the strap is stuck → focus on recovery: the §6 untested levers
   (full power-cycle, official app, feature-flag enable recipe, the GET_CLOCK-silence root cause).
4. Use **subagents** for parallel research (the APK offload/clock/event paths; the re/ history; the
   protocol doc) and for parallel hypothesis prep. Don't re-derive what §3–§5 already established.
5. Keep a tight loop: hypothesis → minimal on-hardware test → read the capture → next. Don't thrash >3
   fixes on one theory without stepping back. Don't churn the strap so hard it degrades (the previous
   session did — give it breathing room; prefer the read-only Mac path for diagnosis).
6. **Definition of done:** type-47 records flow from the strap → decoded → persisted → uploaded (server HR
   frontier advances past the gap), reliably and repeatedly, with the iOS handshake matching WHOOP's
   model (set RTC on connect; plain SEND_HISTORICAL; ack each HISTORY_END; react to strap events; no
   EXIT_HIGH_FREQ_SYNC; bounded ENTER only if ever used). Then write up the root cause + the WHOOP-faithful
   steady-state design, and leave the code committed-clean (DIAG stripped).

The crux to crack: **why did `GET_CLOCK(11)` and `SEND_HISTORICAL_DATA(22)` go silent together, persistently,
when everything else works — and is it strap-side or app-side?** The Mac prototype answers that fastest. Go.
