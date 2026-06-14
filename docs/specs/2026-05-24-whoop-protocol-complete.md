# WHOOP 4.0 BLE Protocol — Complete Reference

_Compiled 2026-05-24 from a hands-on RE session against the user's own WHOOP 4.0 (serial
`<DEVICE_SERIAL>`, harvard fw `41.16.6.0`, boylston `17.2.2.0`), cross-checked for interoperability
against the official app's command enum and the `whoomp` reference. Supersedes the scattered notes
in `FINDINGS.md` / `re/PROJECT_MEMORY.md` for
the protocol map; those remain the authority for the raw IMU/PPG array layout._

> **Captures contain the user's biometrics — keep all `.bin`/`.jsonl` captures local/gitignored.
> Only this doc + `protocol/whoop_protocol.json` are committed.**

---

## 0-bis. BREAKTHROUGH (2026-05-24, later session): the 14-day biometric store IS reachable

Earlier this doc concluded the historical offload carried only telemetry. **That was wrong — it was
two bugs on our side**, now fixed and verified on-device (762 records pulled, 1 Hz, HR 57–70 + R-R +
SpO2 + skin-temp + resp + gravity):

1. **The strap's RTC was frozen at 2025-01-08** (no app session in ~16 months). A clock-lost strap
   **suppresses biometric data-product logging**. Fix: `SET_CLOCK`(10, `[unix u32 LE][5 pad]`) then
   `REBOOT_STRAP` to latch — biometric logging resumes. (The 16 months of frozen-clock data is lost;
   from then on it logs at 1 Hz.)
2. **Biometric records require the high-frequency-sync handshake, not a plain offload.** Gen4 sync
   (the Gen4 high-frequency-sync command sequence, implemented in `re/sync_openwhoop.py`):
   `GET_HELLO_HARVARD` → `SET_CLOCK` → `GET_ADVERTISING_NAME_HARVARD` → **`ENTER_HIGH_FREQ_SYNC`(96,
   empty payload)** → `SEND_HISTORICAL_DATA`(22,`[0x00]`) → per `METADATA HISTORY_END`, ack
   `HISTORICAL_DATA_RESULT`(23) = **`[0x01] + end_data[8]`** where `end_data = metadata.data[10:18]`
   (unix u32, skip 6, then two u32s — NOT `[0x01][trim][0]`). Loop to `HISTORY_COMPLETE`.

**type-47 HISTORICAL_DATA EXISTS** (our earlier "no type-47 payload" was because we never drove this
handshake + the RTC was dead). On this Gen4 it is the **V24** format (seq byte = 24), 93-byte payload:

| off (in `data`=pkt.data) | field |
|---|---|
| 0:4 | sequence (u32 LE) |
| 4:8 | unix (u32 LE) · 8:10 subsec · 10:12 flags · 12 sensor_m · 13 sensor_n |
| **14** | **heart rate (u8)** |
| **15** | **rr_count (u8)** · 16:24 up to 4 R-R intervals (u16 LE ms) |
| 24:30 | ppg_flags / ppg_ch1(green) / ppg_ch2(red-IR) (u16 each) |
| **33:45** | **accel gravity vector x,y,z (3×f32 LE, |g|≈1.0)** |
| 48 | skin_contact (u8) |
| 61:63 / 63:65 | **spo2_red / spo2_ir (u16 LE)** |
| 65:67 | **skin_temp_raw (u16 LE)** · 67:69 ambient · 69:73 led_drive · **73:75 resp_rate_raw** · 75:77 signal_quality |

(Other formats exist: V5/V7/V9 generic = HR/RR only; V18 (Maverick); ≥1188-byte variant = full IMU
arrays. Use the seq byte to pick the parser.)

**App path:** on connect `SET_CLOCK` + run the high-freq-sync + decode type-47 → real 14-day
HR/HRV/SpO2/skin-temp/resp/activity. Full 52 Hz accel is still the live type-43 (§6) or the heavy IMU
historical variant; the V24 gravity vector covers orientation/activity.

## 0. TL;DR for the app (earlier-session findings — superseded in part by §0-bis above)

- **The strap is NOT stuck / NOT abnormal.** The continuous type-43 raw stream is normal
  *stream-while-bonded* behavior and is **live-only — it is NOT written to flash**. Decisive
  read-only test (`re/flash_rate_test.py`): over equal 120 s windows the flash write cursor grew
  **+3 connected (with 250 raw frames flooding) vs +4 disconnected** — i.e. the live flood adds
  nothing to flash; flash logs a compact/sparse record (~1 / 35 s) **continuously regardless of
  connection** (sustainable 24/7, 5-day-battery behaviour). So there is **nothing to "stop" or
  "switch" on the strap** — the official app received this same stream and decoded it.
- **Stopping the stream is neither possible nor necessary here.** For completeness: the modern
  control (`TOGGLE_PERSISTENT_R20`=153 / `R21`=154) returns **status `0x03` UNSUPPORTED** on harvard
  `41.16.6`; the device-config/FF stores hold no raw flag (only `sigproc_wear_detect`,
  `general_ab_test`); reboot/`STOP_RAW_DATA` don't affect it. None of that matters given the above.
- **The fix is entirely app-side: decode HR/R-R from the type-43 header** (offset 14/15) in BOTH
  the live path and the historical-offload path. Verified live: 1 Hz, HR `[78,80,79,80,80,78,79,78]`.
  The earlier "overnight HR gap" was solely OpenWhoop's live decoder reading only type-40 and
  discarding the type-43 header HR — not a strap fault.
- Flash/historical records also carry the type-43 HR header, so the same decode covers live +
  historical; `extractHistoricalStreams` (M4) already does this.

---

## 1. Transport

| Layer | Value |
|---|---|
| Service | `61080001-8d6d-82b8-614a-1c8cb0f8dcc6` |
| `61080002` | **write / write-no-response** — commands → strap |
| `61080003` | notify — command responses ← |
| `61080004` | notify — events ← |
| `61080005` | notify — data ← (realtime, raw, historical, console logs, metadata) |
| `61080007` | notify — memfault / diagnostics ← |
| Standard | `0x2A37` HR+R-R (unbonded), `0x2A19` battery, `0x2A29` mfr "WHOOP Inc." |

**Bond:** one *confirmed* write (`response=True`) to `61080002` triggers just-works bonding
(no OS dialog); the custom notify chars deliver nothing until bonded. Always do this right after connect.

**Frame:** `[0xAA][len u16 LE][crc8(len)][type u8][seq u8][cmd u8][payload…][crc32 LE]`
- crc8 poly `0x07` over the 2 length bytes; crc32 = standard zlib over `[type][seq][cmd][payload]`.
- **Reassembly is mandatory**: raw/historical frames are ~1920 B and fragment across ~244 B
  notifications; only the first fragment starts with `0xAA`. Accumulate by length, then parse.
- **Command responses begin `0a <status>`**: status `01`=ok, `03`=unsupported-on-this-firmware,
  `00`=empty/uninitialised (e.g. config value before a successful key-exchange). The value (for
  bool/byte getters) sits at payload offset 2.

---

## 2. Packet types (`PacketType`)

Authoritative list (observed; interoperability) — supersedes the 10-entry list in the schema:

| # | Name | Seen on this 4.0? | Notes |
|---|---|---|---|
| 35 | COMMAND | → | app→strap |
| 36 | COMMAND_RESPONSE | ✅ | strap→app, `0a <status> …` |
| 37 | PUFFIN_COMMAND | — | newer-gen strap only |
| 38 | PUFFIN_COMMAND_RESPONSE | — | newer-gen |
| 40 | REALTIME_DATA | ✅ | compact HR/R-R, only while `TOGGLE_REALTIME_HR`=1 |
| 43 | REALTIME_RAW_DATA | ✅✅ | **the dominant stream**; IMU(1917)+optical(1921) pair/sec |
| 47 | HISTORICAL_DATA | ✅ **(biometric!)** | the 14-day store: 1 Hz HR/RR/SpO2/skin-temp/resp/gravity records (V24 here). Requires the high-freq-sync handshake + valid RTC — see §0-bis. NOT an alias of 43. |
| 48 | EVENT | ✅ | |
| 49 | METADATA | ✅ | history start/end/complete markers |
| 50 | CONSOLE_LOGS | ✅ | firmware text log (mostly in historical replay) |
| 51 | REALTIME_IMU_DATA_STREAM | not observed | dedicated IMU stream (same 6-axis layout) |
| 52 | HISTORICAL_IMU_DATA_STREAM | not observed | |
| 53 | RELATIVE_PUFFIN_EVENTS | — | newer-gen |
| 54 | PUFFIN_EVENTS_FROM_STRAP | — | newer-gen |
| 55 | RELATIVE_BATTERY_PACK_CONSOLE_LOGS | — | newer-gen |
| 56 | PUFFIN_METADATA | — | newer-gen |

---

## 3. Command catalog (every `CommandNumber`)

Observed for interoperability. **Direction = app→strap** for all. Risk: 🟢 safe/read-only · 🟡 reversible
state change · 🔴 destructive/confirm-first. "Dec" = decoded on this device.

| # | Name | Payload | Response | Effect / semantics | Dec | Risk |
|---|---|---|---|---|---|---|
| 1 | LINK_VALID | `00` | `0a01` + "There it is." | liveness easter-egg | ✅ | 🟢 |
| 2 | GET_MAX_PROTOCOL_VERSION | `00` | `0a03` | **unsupported** here | ✅ | 🟢 |
| 3 | TOGGLE_REALTIME_HR | `01`/`00` | — | start/stop compact type-40 HR stream; **resets per connection** | ✅ | 🟡 |
| 7 | REPORT_VERSION_INFO | `00` | u32 `{maj,min,patch,build}` quads | harvard `41.16.6.0`, boylston `17.2.2.0`, +2 components, trailer | ✅ | 🟢 |
| 10 | SET_CLOCK | clock | — | set device RTC | partial | 🟡 |
| 11 | GET_CLOCK | `00` | `0a01 <u32 dev_clock><u16 subsec>` | device monotonic epoch (~31.6M), **NOT unix** | ✅ | 🟢 |
| 14 | TOGGLE_GENERIC_HR_PROFILE | `01`/`00` | — | enable/disable standard `0x2A37` HR profile | ✅ | 🟡 |
| 16 | TOGGLE_R7_DATA_COLLECTION | `01`/`00` | — | R7 raw record collection (did NOT stop the type-43 flood) | partial | 🟡 |
| 19 | RUN_HAPTIC_PATTERN_MAVERICK | — | — | haptics (newer-gen) | no | 🟡 |
| 20 | ABORT_HISTORICAL_TRANSMITS | `00` | — | stop an in-progress history offload (no trim) | ✅ | 🟢 |
| 22 | SEND_HISTORICAL_DATA | `00` | stream + METADATA | start historical offload loop | ✅ | 🟢 |
| 23 | HISTORICAL_DATA_RESULT | `<B=1><L trim><L=0>` | — | **ack a chunk → DESTRUCTIVE TRIM up to `trim`** | ✅ | 🔴 |
| 25 | FORCE_TRIM | `<LL>` | — | **wipe history** | no | 🔴 |
| 26 | GET_BATTERY_LEVEL | `00` | `0a01 <u16 soc×10>` | SOC %; ignore 1st read after connect (stale) | ✅ | 🟢 |
| 29 | REBOOT_STRAP | `00` | — drops link | reboot; **does NOT clear the raw mode** | ✅ | 🔴 |
| 32 | POWER_CYCLE_STRAP | — | — | power cycle | no | 🔴 |
| 33 | SET_READ_POINTER | cursor | — | move history read pointer (re-read without trim) | partial | 🟡 |
| 34 | GET_DATA_RANGE | `00` | cursors+unix (see §5) | stored-history extent for sync planning | ✅ | 🟢 |
| 35 | GET_HELLO_HARVARD | `00` | serial+key+clock+ver | byte7=charging, **byte116=isWorn**, serial, device key | ✅ | 🟢 |
| 36/37/38 | START/LOAD/PROCESS_FIRMWARE_IMAGE | fw | — | **firmware load (old)** | no | 🔴 |
| 39/40 | SET/GET_LED_DRIVE | cfg | `0a01 …` | PPG LED drive (0 when optical off; settable) | ✅ | 🟡/🟢 |
| 41/42 | SET/GET_TIA_GAIN | cfg | `0a01 …` | PPG transimpedance gain | ✅ | 🟡/🟢 |
| 43/44 | SET/GET_BIAS_OFFSET | cfg | `0a01 …` | PPG bias offset | ✅ | 🟡/🟢 |
| 45 | ENTER_BLE_DFU | — | — | **bootloader / firmware update** | no | 🔴 |
| 52 | SET_DP_TYPE | ? | — | set "data processor/packet" type (no app builder; not on this fw path) | no | 🟡 |
| 53 | FORCE_DP_TYPE | ? | — | force DP type (untested; candidate but unproven) | no | 🟡 |
| 63 | SEND_R10_R11_REALTIME | ? | — | R10/R11 realtime raw packets (= the realtime raw class) | partial | 🟡 |
| 66/67 | SET/GET_ALARM_TIME | time | `0a01 …` | strap alarm | ✅ | 🟡/🟢 |
| 68/69 | RUN_ALARM / DISABLE_ALARM | `00` | — | fire/cancel alarm | partial | 🟡 |
| 76/77 | GET/SET_ADVERTISING_NAME_HARVARD | str | `0a01 …` | BLE adv name (harvard) | ✅ | 🟢/🟡 |
| 79/80 | RUN_HAPTICS_PATTERN / GET_ALL_HAPTICS_PATTERN | id | `0a01 …` | haptics | ✅ | 🟡/🟢 |
| 81 | START_RAW_DATA | `<u32 ms LE>` | — | **timed** R10/R11 raw capture, `hours×3_600_000` ms; auto-expires. A prior reference's 1-byte payload was wrong. | ✅ | 🟡 |
| 82 | STOP_RAW_DATA | `01` | — | stop R10/R11 raw (payload `[0x01]` confirmed via app `lh0/b.a()`) — **does NOT stop the persistent type-43 flood** | ✅ | 🟢 |
| 83 | VERIFY_FIRMWARE_IMAGE | — | — | fw verify | no | 🔴 |
| 84 | GET_BODY_LOCATION_AND_STATUS | `00` | `0a00 01 …` | on-body status | ✅ | 🟢 |
| 96/97 | ENTER/EXIT_HIGH_FREQ_SYNC | `00` | — | high-frequency sync mode | partial | 🟡 |
| 98 | GET_EXTENDED_BATTERY_INFO | `00` | voltage/capacity | mV + capacity + fuel-gauge | ✅ | 🟢 |
| 99 | RESET_FUEL_GAUGE | — | — | reset battery gauge | no | 🟡 |
| 100 | CALIBRATE_CAPSENSE | — | — | cap-touch calibration | no | 🟡 |
| 105 | TOGGLE_IMU_MODE_HISTORICAL | `01`/`00` | — | IMU in historical | partial | 🟡 |
| 106 | TOGGLE_IMU_MODE | `01`/`00` | — | enable IMU axes in raw (part of enable-seq) | ✅ | 🟡 |
| 107 | ENABLE_OPTICAL_DATA | `01`/`00` | — | enable optical in raw (part of enable-seq) | ✅ | 🟡 |
| 108 | TOGGLE_OPTICAL_MODE | `01`/`00` | — | optical mode | partial | 🟡 |
| 115 | START_DEVICE_CONFIG_KEY_EXCHANGE | `01` | `0a01 01 <u16 count>` | begin device-config read; count=**1** here | ✅ | 🟢 |
| 116 | SEND_NEXT_DEVICE_CONFIG | `<u8 idx>` | `0a01 01 00 01 <name\0>` | enumerate config key at idx (only idx 1 populated) | ✅ | 🟢 |
| 117 | START_FF_KEY_EXCHANGE | `01` | `0a01 01 <u16 count>` | begin feature-flag read; count=**11** here | ✅ | 🟢 |
| 118 | SEND_NEXT_FF | `<u8 idx>` | `0a01 01 00 01 <name\0>` | enumerate FF at idx (only idx 1 populated) | ✅ | 🟢 |
| 119 | SET_DEVICE_CONFIG_VALUE | name+val | — | write a device-config value | no | 🟡 |
| 120 | SET_FF_VALUE | name+val | — | write a feature-flag value | no | 🟡 |
| 121 | GET_DEVICE_CONFIG_VALUE | (idx/name) | `0a00 …` | read config value — returns status 0 (see §4) | partial | 🟢 |
| 122 | STOP_HAPTICS | `00` | — | stop haptics | partial | 🟢 |
| 123 | SELECT_WRIST | L/R | — | set wrist | partial | 🟡 |
| 124 | TOGGLE_LABRADOR_DATA_GENERATION | `01`/`00` | — | "labrador" pipeline gen (no effect on flood) | partial | 🟡 |
| 125 | TOGGLE_LABRADOR_RAW_SAVE | `01`/`00` | — | labrador raw save | partial | 🟡 |
| 128 | GET_FF_VALUE | (idx/name) | `0a00 …` | read FF value — status 0 (see §4) | partial | 🟢 |
| 131 | SET_RESEARCH_PACKET | str | — | set research-packet config (strings below) | no | 🟡 |
| 132 | GET_RESEARCH_PACKET | `<u8 idx>` | data (idx0 only) | read research-packet config | partial | 🟢 |
| 139 | TOGGLE_LABRADOR_FILTERED | `01`/`00` | — | labrador filtered | no | 🟡 |
| 140/141 | SET/GET_ADVERTISING_NAME | str | `0a03` | **unsupported** here | ✅ | 🟢 |
| 142/143/144 | *_FIRMWARE_*_NEW | fw | — | **firmware load (new)** | no | 🔴 |
| 145 | GET_HELLO | `00` | `0a03` | **unsupported** here (harvard uses GET_HELLO_HARVARD) | ✅ | 🟢 |
| **151** | **GET_BATTERY_PACK_INFO** | `00` | `0a03` | **UNSUPPORTED on this fw** (new in a current app build) | ✅ | 🟢 |
| **153** | **TOGGLE_PERSISTENT_R20** | `[01, 0/1]` | `0a03` | **UNSUPPORTED on this fw** — payload `[REVISION_1, on]` (observed) | ✅ | 🟡 |
| **154** | **TOGGLE_PERSISTENT_R21** | `[01, 0/1]` | `0a03` | **UNSUPPORTED on this fw** (observed) | ✅ | 🟡 |

> The three bold rows (151/153/154) and packet types 37/38/53–56 are **new in a current app build and
> absent from the older `whoomp` enum**. 153/154 are the firmware-native control for persistent
> raw records on *newer* straps; this 4.0's 2024-era firmware does not implement them.

---

## 4. Device-config / feature-flag / research key-exchange (TOP-PRIORITY result)

The handshake (never run before — it was commented out in `whoomp`) is now cracked. Flow:

```
START_*_KEY_EXCHANGE(payload 0x01)         -> 0a 01 01 <u16 count LE>
SEND_NEXT_*(payload <u8 index>)            -> 0a 01 01 00 01 <name\0…>   (populated slot)
                                              0a 00 01 00…                (empty slot)
GET_*_VALUE(...)                           -> 0a 00 …                    (see caveat)
SET_*_VALUE(name,value)                    -> (write; not exercised)
```

**It is NOT crypto — plaintext UTF-8 key/value strings.** Exact formats (from app builders
`lh0/v0,w0` START, `lh0/k0,l0` SEND_NEXT, `lh0/t0` SET_DEVICE_CONFIG, `lh0/u0` SET_FF):
- `START_*`(115/117) payload `[0x01]` → `0a 01 01 <u16 count LE>`.
- `SEND_NEXT_*`(116/118) payload **always `[0x01]`** (a CURSOR — *not* an index; repeat to walk all
  keys) → `0a 01 01 <flags> 01 <key name, NUL-padded>`; cursor exhausted → `0a 01 01 ff …`.
- `SET_DEVICE_CONFIG_VALUE`(119) / `SET_FF_VALUE`(120) payload = **`[0x01][32-byte key utf8][32-byte
  value utf8]`**. FF value `"1"`=ON / `"2"`=OFF. (Verified: SET_FF returns `0a0101<key>31…` on success.)
- `GET_*_VALUE`(121/128): no app builder; `[0x01][32-byte key]` returns the key + value but the
  trailing value field is contaminated by a stale shared buffer, so read on/off is unreliable — the
  app never reads values, only enumerates + sets.

**Full key dump of this device (re-enumerated correctly with the `[0x01]` cursor):**

| Store | count | Keys |
|---|---|---|
| Device config (115/116) | 1 | `sigproc_wear_detect` |
| Feature flags (117/118) | 11 | `general_ab_test`, `sigproc_10_sec_dp`, `enable_r19_packets`, `enable_r19_v2_packets` … `enable_r19_v6_packets`, **`enable_write_r24_packets`**, **`enable_write_r25_packets`**, `enable_sigproc_walk_detector` |

- These are the **data-product / research-packet** controls (R19 sigproc variants; R24/R25 "write"
  packets; 10-sec DP; walk detector). They tune which *raw/research* products are produced — they do
  **NOT** gate basic biometric logging (which is default-on once the RTC is valid; see §0-bis).
- Research-packet (132) idx-0 returns 18 B `00 9c8ae2 01 50 7b0c00 …` (undecoded).

---

## 5. Read-only command decodes

**`GET_CLOCK`** `0a01 <u32 dev_clock LE> <u16 subsec>` — e.g. `31624076`, subsec `704`. Device
monotonic epoch, not unix.

**`GET_DATA_RANGE`** `0a0101` then u32 LE words (this device):
`[end=52352, ?=51578, write=52297, trim=51575, 28, 131072, count=722, 1303500, oldest_unix=1734300717
(2024-12-15), 30672, newest_unix=1736365593 (2025-01-08), 5992, …repeat]`. The **write cursor
advanced +3 and `count` +3 over a 150 s disconnected window** → the strap logs to flash with no
client, slowly. Trim cursor = oldest un-erased record (offload read pointer).

**`REPORT_VERSION_INFO`** `0a01` + u32 `{major,minor,patch,build}` quads:
harvard `41.16.6.0`, boylston `17.2.2.0`, then `3.5.0.0`, `3.9.0.0`, trailer `0x08 02 01`.

**`GET_HELLO_HARVARD`** `0a 01 04 …`: `f5`-flag, device-clock region, **serial `<DEVICE_SERIAL>\0`**,
**device key hex `b3cbe7d072223f918fbab26f9e5dc01b252a7b89855a0e788460df`**, then a u32 version/config
trailer. byte7 = charging flag, byte116 = isWorn.

**`GET_EXTENDED_BATTERY_INFO`** `0a01` + voltage (mV, ~3687) + capacity + fuel-gauge fields.

---

## 6. Data streams (strap → app, char `05`)

### REALTIME_DATA (type 40) — compact HR/R-R
Only streams while `TOGGLE_REALTIME_HR`=1 (resets each connection). Frame-absolute offsets (type-40
has no separate cmd byte — the record starts at offset 6): `timestamp@6` u32 (device epoch),
`subseconds@10` u16, **`heart_rate@12`** u8, `rr_count@13` u8, R-R u16[] at `@14+2n`. VERIFIED on
real frames (HR 59–62 bpm). (An earlier draft mislabeled these @14/@15 using a data-relative base.)

### REALTIME_RAW_DATA (type 43) — the dominant stream (1 pair/sec, persistent)
Emitted **continuously and unprompted while bonded**, in **pairs per second**. Offsets below are
**frame-absolute** (= the data-relative offset + 7).

- **cmd=41, ~1917 B = IMU + HR header (RESOLVED, device-verified from `motion_capture.jsonl`).**
  Signed **int16 LITTLE-endian**, **100 samples/axis**, ~100 Hz (1 pkt/s). Frame-absolute offsets:
  **HR@21(u8)**, rr_count@22, R-R@23.., accelX@89, accelY@289, accelZ@489, gyroX@692, gyroY@892,
  gyroZ@1092.
  - **ACCEL scale = 1/4096 LSB/g (±8 g)** — sphere-fit over 67 still packets: |g|=0.99, residual std
    0.0%; per-pose gravity vectors confirmed. VERIFIED. (Replaces the earlier "1 g ≈ ~3900 LSB" guess.)
  - **GYRO scale = 0.06104 deg/s/LSB = ±2000 dps full-scale (16.4 LSB per deg/s)** — VERIFIED via a
    controlled 720° (2-turn) rotation about each axis (`re/capture_session.py` → `re/analyze_gyro_scale.py`,
    `fixtures/gyro_calib.jsonl`): rotation A averaged 19.7 °/s over 36.5 s = 720° ✓ and gave K=0.0611,
    an exact match to the textbook ±2000 dps sensitivity; a 2nd axis gave 0.0657 (±~10% from human
    turn-counting). openwhoop's ÷15 (0.0667) is within tolerance. (Earlier freehand captures couldn't
    pin it — gyro–gravity R²≈0 — because they were multi-axis + accel-contaminated.)
  - Unmapped: GAP1 frame[24:82] (58 B), GAP2 frame[682:685] (3 B pad), TAIL frame[1292:1917] (632 B)
    — ~36% still unidentified (constant-ish, not motion axes; possibly status/optical).
  - **Do NOT conflate** with openwhoop's IMU parser (big-endian, ÷1875 accel, ÷15 gyro, offsets
    85/285/485…): that is for the type-47 ≥1188-byte HISTORICAL-IMU variant, not this 1917 packet.
- **cmd=0, ~1921 B = raw optical/PPG (PARTIAL, from `optical_capture.jsonl`).** The earlier "4
  interleaved 24-bit channels from ~byte 33" hypothesis is **WRONG**. It is a **SINGLE AC-coupled
  (DC-removed / high-pass) PPG waveform**. Structure: shared 8-byte header frame[7:15] (dual u32
  counters, same as the IMU partner); config/TLV header frame[15:42] (UNKNOWN, likely LED-current
  config); PPG array from frame[42], stride 4, sample = bytes[0:3] **signed 24-bit LE**, byte[3] = aux
  (UNKNOWN — ~73% sign-ext copy else small burst markers); ~419 samples/pkt @ ~437 Hz; zero-padded
  after ~frame[1718]. Channel ground-truth (phase test): finger → clean 1.04 Hz (63 bpm) fundamental +
  harmonics = pulsatile = **GREEN/HR LED**; air → flatlines. **Red/IR/ambient are NOT in this raw
  stream** — they appear only as the DSP'd scalars in the type-47 V24 record
  (`ppg_green`/`ppg_red_ir`/`ambient`). The green waveform decodes losslessly (1 channel); byte[3] +
  the [15:42] config header stay raw (a `light`/ambient capture would resolve byte[3]).

**HR/R-R decode from the header (offsets 14/15) is identical for live AND historical type-43** —
this is the basis of the recommended fix. Verified live: 1 Hz, `[78,80,79,80,80,78,79,78]` bpm.

### EVENT (type 48, char 04)
`event@6(u8)` (`EventNumber`), `event_timestamp@8(u32)`. **Clock base differs by subtype**: connect/
wrist/charging events carry real unix; battery events (`BATTERY_LEVEL`=3, `EXTENDED_BATTERY_INFORMATION`=63)
carry the device epoch. Notable enums: 9/10 WRIST_ON/OFF, 7/8 CHARGING, 23 BLE_BONDED, 33/34
BLE_REALTIME_HR_ON/OFF, **46/47 RAW_DATA_COLLECTION_ON/OFF**, 26/27 TRIM_ALL_DATA(_ENDED), 1 ERROR.

### METADATA (type 49) — historical offload markers
`meta_type@6(u8)`: 1 HISTORY_START, 2 HISTORY_END (`<L unix><H subsec><L unk><L trim>`), 3 HISTORY_COMPLETE.

### CONSOLE_LOGS (type 50) — firmware text
ASCII after a 7-byte header (strip the `34 00 01` marker, cut at NUL). **Only replayed during
historical offload, not streamed live.** Self-narration confirms the model — e.g.
`BLE: Stop raw data collection`, `Sensors: R10+R11 generation disabled`,
`BLE: R10+R11 data packet transmission default`, `BLE: History burst success. Trim: 0x…:0000c7ee (0:51182)`,
`SUPERVISOR: SOC report: 72.86`. The raw realtime class is internally **"R10+R11"** (controlled by
`START_/STOP_RAW_DATA`), distinct from the persistent **R20/R21** class (commands unsupported here).

---

## 7. Historical offload loop (store-and-forward)

```
SEND_HISTORICAL_DATA(22)
  → METADATA HISTORY_START(1)
  → … frame stream (type-43 IMU+optical pairs + CONSOLE_LOGS + EVENT + METADATA) …
  → METADATA HISTORY_END(2)  payload <L unix><H subsec><L unk><L trim>
  → ack: HISTORICAL_DATA_RESULT(23)  struct.pack("<BLL", 1, trim, 0)   [.withResponse]  ← DESTRUCTIVE TRIM
  → (repeat per chunk)
  → METADATA HISTORY_COMPLETE(3)
```
**There is NO distinct type-47 payload** — history is the recorded native frame stream replayed in
type-43/48/49/50. To capture losslessly, log every char-05 notification verbatim and reassemble
offline (frames fragment across ~244 B notifications). Acking is the only destructive step; capture
without acking (then `ABORT_HISTORICAL_TRANSMITS`) is read-only.

---

## 8. Modes: compact-HR vs raw, and switching between them

| Mode | How | State on this device |
|---|---|---|
| Compact HR (type 40) | `TOGGLE_REALTIME_HR`=1 | available on demand; **resets per connection** |
| Realtime raw R10/R11 (type 43) | `START_RAW_DATA`/`STOP_RAW_DATA` (+IMU/optical enables) | transient; stop works |
| **Persistent raw R20/R21 (type 43, the flood)** | `TOGGLE_PERSISTENT_R20/R21` on newer fw | **UNSUPPORTED here → cannot toggle**; streams unprompted, survives reboot |

**Bottom line:** the type-43 stream is **live-only** (not flashed — see §0 rate test) and is the
strap's autonomous default output to a bonded listener. Flash logs a **compact record continuously**
(~1/35 s, same connected or not → sustainable 24/7). So there is no mode to switch and nothing
stuck — the app just **decodes the type-43 header** (live + historical) and runs the offload.

**App-side confirmation:** the official app sends **no** persistent-mode / DP-type /
research / R7 command to a GEN_4 strap, ever. `SET_DP_TYPE`(52), `FORCE_DP_TYPE`(53),
`SET_RESEARCH_PACKET`(131), `TOGGLE_R7_DATA_COLLECTION`(16) have **zero command-builders and zero
references** in the app; `TOGGLE_PERSISTENT_R20/R21` + labrador builders exist but are **never
instantiated** (dead code). GEN_4 collection is the strap's own default; the app only toggles
*transient* live streaming for its in-app view — GEN_4 enable = `TOGGLE_IMU_MODE`(106)=1 +
`TOGGLE_OPTICAL_MODE`(108)=1 (observed); disable = same with `0`; plus the
realtime-HR trio `TOGGLE_REALTIME_HR`(3)=1 → `TOGGLE_IMU_MODE`=1 → `ABORT_HISTORICAL_TRANSMITS`
 (observed). `START_/STOP_RAW_DATA` are used only by the opt-in WhoopLabs "DWL" campaign.

---

## 9. Safety classification (never send without explicit confirmation)

🔴 `FORCE_TRIM`(25), `HISTORICAL_DATA_RESULT`(23, trims), `REBOOT_STRAP`(29), `POWER_CYCLE_STRAP`(32),
`ENTER_BLE_DFU`(45), all firmware-load (36/37/38/83/142/143/144). Ship-mode / virgin-mode not present
in this enum but treat any unknown high-number command as 🔴.

---

## 10. Open unknowns (future passes)

1. **Authenticated config read/write** — `GET_*_VALUE` needs the key-exchange auth (device key
   `b3cbe7d0…`); decode the handshake to read/set config & FF values in the clear.
2. **`FORCE_DP_TYPE`(53) / `SET_DP_TYPE`(52)** — untested DP-type override; the only protocol lever
   left, but **no builder/reference exists in the current app**, so the payload can't be recovered from this
   APK (would be pure guesswork, write-risky). Likely moot since the strap is operating normally.
3. **Raw optical/PPG** (1921 B): channel→LED(green/red/IR) map + 24-bit scaling; SpO2/skin-temp are
   cloud-computed, not on the wire.
4. **`GET_RESEARCH_PACKET`(132) idx-0** 18-byte struct: decode fields.
5. Whether a firmware update (official app, or DFU) would expose the R20/R21 compact control.
   (Low value: the strap already logs compact 24/7; the live raw stream is harmless to flash/battery.)
6. An older (~v4.x) app build could be examined to double-check the contemporary GEN_4 path.
   Low priority given the current build already shows GEN_4 collection is autonomous.

---

## 11. Decode library status (2026-05-24)

The unified decode library now parses the WHOOP 4.0 biometric/motion/optical fields with
**Swift == Python byte-parity**. Canonical schema `protocol/whoop_protocol.json` is mirrored
**byte-identical** into the Python `whoop_protocol` package and the Swift `WhoopProtocol` package
(3 copies, verified identical). New dtypes `f32` and `s24` were added; **type-47 is now its own
version-keyed packet** (selected by the seq byte), no longer a type-43 alias.

**Decoded with parity** (full field map in
[`2026-05-24-decode-completeness-matrix.md`](2026-05-24-decode-completeness-matrix.md)):

- **type-47 HISTORICAL_DATA V24** (the 14-day biometric store):
  HR · R-R · gravity vector (x/y/z, in g) · ppg_green · ppg_red_ir · spo2_red · spo2_ir ·
  skin_temp_raw · ambient · led_drive_1/2 · resp_rate_raw · signal_quality · skin_contact · unix.
  SpO2 / skin-temp / resp are emitted **raw** (cloud-computed server-side). V5/V7/V9 generic HR/RR
  records also decoded. `extract_historical_streams` / `extractHistoricalStreams` emit
  hr/rr/spo2/skin_temp/resp/gravity from type-47.
- **type-43/1917 IMU**: HR header + 6-axis arrays; accel in g (×1/4096), gyro ×0.06104 deg/s
  (±2000 dps, verified by controlled rotation).
- **type-43/1921 optical**: single green PPG waveform (s24); config header + aux byte kept raw.
- **type-40 / type-48 / type-49 / type-50 / type-36** envelopes + headers.

**Test status:** **62 Swift tests + 33 Python tests green**; cross-language parity validated over
**924 frames**, including **60 real V24 records** (a subset of the 762 in `fixtures/hist_biometric.bin`).

### Device-session findings (2026-05-24, on-wrist verification)
- **Gyro scale pinned** to ±2000 dps / 0.06104 deg/s/LSB (controlled 720° rotations).
- **r24/r25 = negative**: a read-only no-ack historical peek (high-freq-sync → ABORT, never acked →
  no trim) returned **only 96-byte V24 records, zero ≥1188-byte full-IMU records**. So enabling
  `enable_write_r24/r25_packets` did NOT make the strap log 52 Hz accel/gyro to flash; the 14-day
  store stays the compact V24 biometric record.
- **Optical saturation latch**: a direct flashlight on the sensor triggered a CH1/CH2-saturation-style
  event that **latched the entire raw optical+IMU stream OFF** (it did not recover on finger contact);
  re-sending the enable sequence (`ENABLE_OPTICAL_DATA`+`TOGGLE_OPTICAL_MODE`+`TOGGLE_IMU_MODE`+
  `START_RAW_DATA`) restored it (no reboot needed). The biometric store (contact-gated) is unaffected.
- **byte[3]** of the optical sample stayed inconclusive (mostly 0 with 255 spikes, no clean
  phase separation) — kept raw.
- **GET_RESEARCH_PACKET(132)** idx-0 → `0001010000` (short config; still only partially meaningful).

See the companion **[Decode Completeness Matrix](2026-05-24-decode-completeness-matrix.md)** for the
field-by-field decode/verification status and the full list of open unknowns.
