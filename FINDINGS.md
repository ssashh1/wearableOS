# WHOOP 4.0 BLE Protocol — Reverse-Engineering Findings

_Last updated: 2026-05-23. Working dir: `~/Developer/whoop`. Target: the user's own Whoop 4.0 (`WHOOP <DEVICE_SERIAL>`, macOS BLE UUID `<DEVICE_UUID>`, MAC `<DEVICE_MAC>`)._

## Goal

Read raw biometrics off your own WHOOP 4.0 **locally over BLE**, for interoperability with your own device data. Target architecture is **device → phone → cloud** store-and-forward (buffer at each hop, forward on reconnect). This doc captures everything decoded so far. Independent reverse-engineering for interoperability; not affiliated with WHOOP, Inc.

## Status at a glance

| Capability | Status |
|---|---|
| Connect over BLE (unbonded) | ✅ Works |
| **Bonding** (unlocks custom data channels) | ✅ Solved — see below |
| Command/response protocol | ✅ Full surface mapped |
| Heart rate + R-R intervals (realtime + historical) | ✅ Decoded |
| Battery %, voltage, charging/wrist events | ✅ Decoded |
| Historical buffer offload (store-and-forward) | ✅ Working end-to-end |
| Device data-range / optical (PPG) config | ✅ Readable |
| **Accelerometer + gyroscope (raw)** | ✅ **Fully decoded** — APK-confirmed offsets, validated on-device |
| **Raw PPG / optical** | 🟡 **Located** — the 1921-byte companion packet (24-bit, ~4 channels, pulsatile). Channel→LED map + bit-scaling still open |
| SpO2 / skin temp (computed values) | ⚫ Not on the wire — computed in WHOOP cloud from the raw red/IR PPG above |

We are at or beyond the public state of the art: **no published project has decoded the raw sensor array** (verified across whoomp, bWanShiTong, whoop-reader, Gadgetbridge, blogs, HN). bWanShiTong explicitly failed to locate the accelerometer; we located both accel and gyro via controlled-motion analysis.

---

## 1. Connecting & bonding (the key unlock)

- The strap advertises and is connectable over BLE with **no prior pairing**. It even advertises while charging (it charges on-wrist via the slide-on pack).
- It exposes **standard BLE services** that work *unbonded*: Heart Rate `0x180D`/`0x2A37` (HR + R-R intervals), Battery `0x180F`/`0x2A19`, Device Info `0x180A`.
- The **custom service** (command/response, realtime, historical, raw) requires a **bonded/encrypted link**. Unbonded, those characteristics deliver nothing.
- **macOS gotcha:** `bleak`'s `client.pair()` raises `NotImplementedError` on CoreBluetooth. **Fix: issue one *confirmed* write** (`write_gatt_char(..., response=True)`) to the command char `61080002`. This forces encryption and triggers silent "just-works" bonding (you'll see a `BLE_BONDED` event). After that, all custom channels work.
- **Always do a confirmed write right after connect to bond.** (The strap also stayed bonded to the user's phone simultaneously without issue.)

## 2. GATT map (authoritative — from whoomp, confirmed on-device)

```
Service 61080001-8d6d-82b8-614a-1c8cb0f8dcc6
  61080002  write / write-no-response   CMD → strap   (send commands here)
  61080003  notify                      CMD responses ←
  61080004  notify                      events ←
  61080005  notify                      data ← (realtime, raw, historical, console logs)
  61080007  notify                      memfault / diagnostics ←
Standard: 0x2A37 (HR+RR), 0x2A19 (battery), 0x2A29 (manufacturer "WHOOP Inc.")
```
> ⚠️ The `whoop-reader` repo's UUID map is **shifted by one and wrong** (it calls `61080000` the service). It is fabricated — do not use it.

## 3. Frame format (whoomp's, verified by CRC on-device)

```
[0xAA][len u16 LE][crc8(len bytes)][type u8][seq u8][cmd u8][payload...][crc32 LE]
```
- `crc8` poly `0x07` over the 2 length bytes.
- `crc32` is **standard zlib** (poly `0xEDB88320`) over `[type][seq][cmd][payload]`.
- Use whoomp's `WhoopPacket` (`whoomp/scripts/packet.py`) — it's correct. Our own copies/loaders import it.
- **BLE reassembly is mandatory:** large packets (raw/historical, ~1920 B) exceed one BLE notification and arrive as ~244-byte fragments. Only the first fragment starts with `0xAA`. Reassemble using the length header before parsing. (whoomp parses per-notification and therefore misses these.)
- Response status byte: payloads begin `0x0a` then a status — `01` = ok, `03` = unsupported on this firmware.

## 4. Command surface (probed live on the device)

All of these returned responses (`probe_commands.py` → `command_probe.jsonl`). Non-destructive GETs:

| Command (code) | Response (decoded) |
|---|---|
| `GET_BATTERY_LEVEL` (26) | `battery(24.5%)` — uint16 ÷10 |
| `GET_CLOCK` (11) | device clock, **own epoch** (~31.5M), NOT unix — correlate to wall-clock at capture |
| `REPORT_VERSION_INFO` (7) | harvard `41.16.6.0`, boylston `17.2.2.0` |
| `GET_HELLO_HARVARD` (35) | serial `<DEVICE_SERIAL>`, device key, clock; **byte 7 = charging flag, byte 116 = isWorn** |
| `GET_DATA_RANGE` (34) | extent of stored historical data (pointers + timestamps) — **use for sync planning** |
| `GET_LED_DRIVE`(40)/`GET_TIA_GAIN`(42)/`GET_BIAS_OFFSET`(44) | optical (PPG) front-end config — all 0 when optical off; **settable** |
| `GET_EXTENDED_BATTERY_INFO` (98) | voltage 3687 mV, capacity, etc. |
| `GET_BODY_LOCATION_AND_STATUS` (84) | on-body status |
| `GET_ALARM_TIME`(67), `GET_ALL_HAPTICS_PATTERN`(80), `GET_ADVERTISING_NAME_HARVARD`(76) | config |
| `LINK_VALID` (1) | ASCII easter egg "There it is." |
| `GET_HELLO`(145), `GET_ADVERTISING_NAME`(141), `GET_MAX_PROTOCOL_VERSION`(2) | unsupported (`0a03`) on this firmware |

Sensor-control commands (from whoomp's enum; map to the MAX86171 optical chip): `TOGGLE_REALTIME_HR`(3), `START_RAW_DATA`(81)/`STOP_RAW_DATA`(82), `TOGGLE_IMU_MODE`(106), `ENABLE_OPTICAL_DATA`(107), `TOGGLE_OPTICAL_MODE`(108), `SET_LED_DRIVE`(39)/`SET_TIA_GAIN`(41)/`SET_BIAS_OFFSET`(43), `SET_RESEARCH_PACKET`(131). Research-mode string payloads found by bWanShiTong: `enable_r19_packets`, `sigproc_10_sec_dp`, `sigproc_pdaf`, `general_ab_test` — may unlock richer raw streams (untested).

## 5. Decoded data streams

### Heart rate (realtime, `REALTIME_DATA` type 40, 24-byte packet)
`data[0:4]=record hdr, [4:8]=unix(device epoch), [8:10]=subsec, [10:14]=unk, [14]=heartRate, [15]=rr_count, [16:24]=up to 4 R-R intervals (uint16 ms)`. Toggle with `TOGGLE_REALTIME_HR=1`. Confirmed live (HR 57–69 bpm).

### R-R intervals
Also available via the **standard** Heart Rate profile `0x2A37` (works unbonded) — HR + R-R in BLE-standard format. This alone is enough for HRV / resting-HR / your own recovery score.

### Historical offload (the device-side store-and-forward)
1. Send `SEND_HISTORICAL_DATA` (22).
2. Strap streams `METADATA` (type 49) `HISTORY_START`/`HISTORY_END` markers bracketing `REALTIME_RAW_DATA`(43) payload packets on char `05`.
3. `HISTORY_END` payload = `[unix u32][subsec u16][unk0 u32][trim u32]` (`<LHLL`). Ack each with `HISTORICAL_DATA_RESULT`(23) carrying `[0x01][trim u32][0x00000000]` (`<BLL`).
4. Loop until `HISTORY_COMPLETE`. The `trim` cursor is how you tell the strap "I've got it" — i.e. the offload-and-clear mechanism for tier-1→tier-2 sync.

Verified end-to-end (`HISTORY_COMPLETE`, multiple chunks with data). Historical packets carry the same `REALTIME_RAW_DATA` HR-header layout, so HR + R-R time-series are decodable from history.

### Events (type 48, char 04) — all decode via whoomp's `EventNumber`
`WRIST_ON/OFF`, `CHARGING_ON/OFF`, `BATTERY_PACK_CONNECTED/REMOVED`, `BLE_BONDED`, `BATTERY_LEVEL`, `EXTENDED_BATTERY_INFORMATION`. Battery event payload: **uint16 at offset 1 = state-of-charge ×10**, **uint16 at offset 5 = millivolts** (decoded by correlating to the 24% standard read).

---

## 6. The frontier: raw accelerometer / gyroscope / PPG

`START_RAW_DATA`(81) (with `ENABLE_OPTICAL_DATA`+`TOGGLE_IMU_MODE`) produces `REALTIME_RAW_DATA` (type 43) packets in **two sizes**, which we determined are **two different sensor formats**:

- **1917-byte packets = IMU + PPG.** Contains the **accelerometer and gyroscope** (plus the bulk PPG).
- **1921-byte packets = a different format** (gravity-correlated but no rotation-specific axes — likely PPG/optical-dominant). Distinction is undocumented anywhere public.

### Methodology (novel — bWanShiTong failed at this)
We ran a **labeled controlled-motion capture** (`capture_motion.py` → `motion_capture.jsonl`): 4 static wrist orientations (isolate accelerometer via gravity) + 3 single-axis rotations (isolate each gyro axis). Then per-int16-position statistics:
- **Accelerometer** = positions whose mean shifts with static orientation (gravity projection).
- **Gyroscope** = positions quiet when still but spiking in **one specific** rotation.

### What we found (1917-byte packet, int16 little-endian)
- **Header**: bytes 0–23 (ts / HR / R-R as above).
- **Accelerometer block**: ~bytes **38–68** — a compact block, gravity-sensitive, ±~8000 ≈ ±1 g (suggesting ~±4 g range, ~8192 LSB/g). Repeats with an 8×int16 period.
- **Gyroscope block**: ~bytes **1512–1692** — **three distinct axes**, each dominant in exactly one rotation:
  - forearm-twist axis spikes at bytes ~1548/1648/1684
  - wrist-flex axis spikes at bytes ~1516/1568/1588
  - side-wave axis spikes at bytes ~1528/1556
  - quiet (σ≈1500) when still, σ≈5000–7400 in its own rotation — a clean gyro signature.
- **PPG bulk**: the remaining ~900+ values — gravity-blind, motion-noisy, pulsatile. Likely **multi-channel high-bit-depth** samples (MAX86171 is 19.5-bit, 4 photodiodes / 5 LEDs = 3 green + 1 red + 1 IR), so probably **not plain int16** — needs 20-bit/int32 unpacking.

### Confirmed by independent sources
- Field naming in the community `whoomp` reference indicates the raw result holds **accelerometer + gyroscope sample arrays** (blocked, multiple samples/packet).
- **tazjin** (Gadgetbridge #5731, Whoop 5.0): IMU = **"6 integers (X/Y/Z per sensor)"** — matches our int16 finding. Also: a "set sampling frequency" command exists; the device does **no** analytics on-device (all HRV/sleep/strain is cloud-side — so self-analysis is the only sub-free path).
- **52 Hz** HR+accel sampling (WHOOP Unite Research FAQ) → a ~1917-byte packet ≈ **~1 second** of data ≈ ~52 samples/axis.

### Still open
- Exact channel order, byte-perfect stride, and **scale factors** (LSB/g, LSB/deg-s) for accel/gyro.
- PPG bit-packing and per-channel (green/red/IR) mapping.
- SpO2 and skin temperature: not streamed/decoded by anyone. `TEMPERATURE_LEVEL` is an event (17) we haven't captured; bWanShiTong believes SpO2 is sampled intermittently during sleep, not streamed. tazjin couldn't crack the temp format.

---

## 7. Prior-art summary (from deep repo + web research)

| Source | How far it got | Trust |
|---|---|---|
| [jogolden/whoomp](https://github.com/jogolden/whoomp) | Framing, commands, HR/RR, historical, console logs. **Never parses the raw array.** | High |
| [bWanShiTong/reverse-engineering-whoop(-post)](https://github.com/bWanShiTong/reverse-engineering-whoop) | Deepest traffic analysis; reversed legacy CRC; alarm/sync. **Tried & failed to find the accelerometer** ("values don't change with rotation"). | High |
| [tazjin, Gadgetbridge #5731](https://codeberg.org/Freeyourgadget/Gadgetbridge/issues/5731) | Whoop **5.0**: IMU = 6 integers, ~70 commands. **Code unpublished, no scale factors.** | Medium (claim) |
| [jacc/whoop-re](https://github.com/jacc/whoop-re) | Whoop **cloud REST API** (separate from BLE) — endpoints for HRV/recovery/sleep trends. | Medium |
| [christianmeurer/whoop-reader](https://github.com/christianmeurer/whoop-reader) | **Fabricated/AI-scaffold.** Wrong UUIDs, invented commands, speculative "SpO2/temp/accel" byte table. **Do not trust.** | ❌ Low |

Hardware (TechInsights / the5krunner): optical AFE **MAX86171**, MCU **MAX32652**, temp sensor **MAX6631**. No public source documents the raw BLE sensor byte-layout for 4.0 or 5.0.

---

## 8. Tooling in this folder

| Script | Purpose |
|---|---|
| `whoop-reader/.venv/` | Python venv (bleak, numpy, pytz). Run everything with `./whoop-reader/.venv/bin/python`. |
| `re_harness.py` | Persistent connection holder + control-file command driver + JSONL logger. |
| `capture_motion.py` | Controlled-motion raw capture, tags packets by phase from `phase.txt`. |
| `probe_commands.py` | Enumerates the command surface → `command_probe.jsonl`. |
| `decode.py` / `decode_raw.py` / `analyze_*.py` | BLE reassembly + sensor-array analysis. |
| `motion_capture.jsonl` | **Labeled controlled-motion dataset — reusable; don't redo the physical protocol.** |
| `whoomp/`, `whoop-reader/`, `research/` | Cloned reference repos. |

## 9. Next steps

1. **Finish accel/gyro decode** from `motion_capture.jsonl`: pin the exact stride/scale (use the 52-sample/packet prior; treat IMU as int16, PPG as 20-bit/int32). Validate accel by `‖(ax,ay,az)‖ ≈ 1 g` across static poses.
2. **Try research toggles** (`SET_RESEARCH_PACKET` + `enable_r19_packets` / `sigproc_*`) and `REALTIME_IMU_DATA_STREAM`(51) to see if a cleaner dedicated IMU stream appears.
3. **Build Phase 1 pipeline** (the HR/RR/events/historical data is fully decoded): capture → local SQLite, lossless-raw-first, with a sync cursor for the future cloud tier. Fold the confirmed-write bond into the connector.
4. SpO2/temp: capture overnight / watch for `TEMPERATURE_LEVEL`(17) events.

## 9b. Decode addendum (session 2)

- **`GET_DATA_RANGE` decoded:** the response embeds real Unix timestamps marking the **stored-history window on the device — ~2024-12-15 → 2025 (your last usage period).** So weeks of old biometrics are still buffered on the strap and recoverable via the historical-offload loop. (Live `GET_CLOCK` returns a device-relative epoch ~31.5M, but stored records carry absolute Unix time from the last phone sync.) Decoded in `dashboard/whoop_fields.py`.
- **`GET_EXTENDED_BATTERY_INFO`:** battery voltage = `pay[7:9]` u16 = millivolts (e.g. 3687 mV). SOC % comes from `GET_BATTERY_LEVEL` (u16 ÷10).
- **`GET_HELLO_HARVARD`:** byte 7 = charging flag (0 = off charger), then device-epoch clock u32, serial `<DEVICE_SERIAL>`, and a device key/uuid hex string.
- **IMU FULLY DECODED (definitive).** The raw-stream layout was determined for interoperability and **validated against our own `motion_capture.jsonl`** captures. Earlier purely-empirical guesses (accel 38–68, gyro 1512–1692) were WRONG. The true layout for `REALTIME_RAW_DATA` (type 43, subtype 10), **all signed int16 little-endian**, offsets in `data` (=pkt.data, after type/seq/cmd):

  | field | data offset | frame offset | size |
  |---|---|---|---|
  | timestampSeconds (device epoch) | 4 | 11 | u32 |
  | timestampSubseconds | 8 | 15 | u16 |
  | heartRate | 14 | 21 | u8 |
  | **accelX** | 82 | 89 | 100×i16 |
  | **accelY** | 282 | 289 | 100×i16 |
  | **accelZ** | 482 | 489 | 100×i16 |
  | **gyroX** | 685 | 692 | 100×i16 |
  | **gyroY** | 885 | 892 | 100×i16 |
  | **gyroZ** | 1085 | 1092 | 100×i16 |

  **100 samples/axis/packet** (~52 Hz → ~2 s/packet, or buffered). Validated on-device: still-flat → accelZ μ≈3944, gyro≈0; gyroX σ=2023 in twist, gyroY in flex, gyroZ in wave. **The app applies NO scale** — raw LSB counts go to the cloud. Empirical scale: **1 g ≈ ~3900 LSB (≈ ±8 g range)**; pin exactly with a device-flat-on-table capture (`‖a‖=1g`). Type **51** `REALTIME_IMU_DATA_STREAM` = the same 6-axis structure, variable-length (`[28-B header][accelX×G][accelY×G][accelZ×G][gyroX×H][gyroY×H][gyroZ×H][crc32]`, G=u16@raw[24], H=u16@raw[26]).
- **RAW OPTICAL / PPG LOCATED (novel — past all public work).** The type-43 stream emits TWO paired packets per timestamp: **data-len 1917 = IMU** (above) and **data-len 1921 = raw optical/PPG**. The 1921 packet: byte entropy 2.5 bits/byte (NOT encrypted), decodes as **24-bit little-endian samples, ~4 interleaved photodiode channels starting ~data byte 33**. At least one channel is a smooth pulsatile PPG waveform (lag-1 autocorr 0.96, ~1 cycle/packet ≈ heart rate). This is the green/red/IR optical the app forwards to the cloud unparsed. **Still open:** exact channel→LED(green/red/IR) mapping, bit-scaling (values look ~20-bit within 24-bit fields, possibly with status bits), and where skin-temp sits. Best next step: controlled optical capture (cover sensor → all channels drop; finger-press → pulse changes) to label channels. Annotated in `dashboard/whoop_fields.py`.
- **SpO2 / skin-temp computed VALUES: NOT in the BLE stream.** Exhaustive app search shows no client-side decoders — these are computed in WHOOP's cloud. So they cannot be read from the device locally (only raw IMU + HR/RR + the unparsed optical tail). `TEMPERATURE_LEVEL` exists only as an event enum, never parsed to a value. The `dashboard/whoop_fields.py` parser now uses these confirmed offsets.

## 10. Sources
- whoomp, bWanShiTong, jacc/whoop-re, christianmeurer/whoop-reader (GitHub)
- [Gadgetbridge #5731](https://codeberg.org/Freeyourgadget/Gadgetbridge/issues/5731) (tazjin, Whoop 5.0 IMU)
- [WHOOP CTO on 4.0 accuracy](https://www.whoop.com/us/en/thelocker/chief-technology-officer-whoop-4-0-accuracy/) (4 photodiodes / 5 LEDs)
- [WHOOP Unite Research FAQ](https://sensorlab.arizona.edu/sites/default/files/2023-05/WHOOP%20Unite%20Research%20FAQs_0.pdf) (52 Hz)
- TechInsights / the5krunner teardown (MAX86171 / MAX32652 / MAX6631)

---

## 11. Background collection (M3) — on-device checklist

Manual verification steps for E4 (state restoration) and E6 (storage counter).

1. **Live connection + storage baseline (E6 prerequisite)**
   - Run on a real iPhone. Press Connect, confirm HR appears and the "stored: N samples" line is non-zero (proves E6 storage counter is wired).

2. **Background collection**
   - Lock the phone (or send app to background via Home button). Wear the strap. Leave backgrounded ~5–10 minutes.
   - Reopen the app. Confirm the "stored: N samples" count is higher than before locking — proving collection continued in the background.

3. **Force-quit + relaunch (state restoration)**
   - While connected and collecting, force-quit the app (swipe up from app switcher).
   - Relaunch without pressing Connect.
   - Confirm the BLE log shows `poweredOn with restored peripheral — reconnecting <UUID>` and that HR + storage resume automatically within ~10 seconds — proving `willRestoreState` re-discovers services and collection resumes without user interaction.

### Known limitations (M3)

- **Stale clock on mid-session strap reboot**: `clockRef` is captured once and reused across same-process reconnects (correct while the strap stays powered). If the strap reboots/clock-resets mid-session, REALTIME_DATA timestamps would be mis-correlated until the next app relaunch. Acceptable for v1; revisit if strap-reboot detection is added.
- **Battery under-sampling within a session**: COMMAND_RESPONSE battery readings carry no device timestamp, so all are stamped at `wallClockRef`; with the `battery` PK `(deviceId, ts)` + ON CONFLICT DO NOTHING, multiple battery reads in one clock-correlation collapse to one row. Battery is slow-changing so this is mostly cosmetic; revisit if finer battery history is needed.
