# WHOOP 4.0 BLE — Decode Completeness Matrix

_Compiled 2026-05-24, companion to `2026-05-24-whoop-protocol-complete.md`. Field-by-field decode
status for every packet type plus a command-by-command table. Source of truth: the canonical schema
`protocol/whoop_protocol.json` (mirrored byte-identical in the Python `whoop_protocol` and Swift
`WhoopProtocol` packages) and the protocol-complete doc §3._

## Conventions

- **Offsets are FRAME-absolute** — counted from the `0xAA` start-of-frame byte. The frame envelope
  is `[0xAA][len u16 @1][crc8 @3][type u8 @4][seq u8 @5]`, so the packet body begins at frame[6].
  Where an implementation reports a "data-relative" offset (counting from the start of `pkt.data`,
  i.e. after the 7-byte `[type][seq][cmd]`-style prefix used by the raw/historical decoders),
  **data-relative = frame-absolute − 7**. Every row below is frame-absolute.
- **Decoded?** ✅ = field is parsed into a human-meaningful value · partial = located but
  semantics/scale incomplete · ❌ = not located / not decoded.
- **Verified?** names the SOURCE of confidence:
  - `on-device` — confirmed against the physical strap this session (live command probe).
  - `from-capture (motion|optical|biometric)` — confirmed by replaying a recorded `.jsonl`/`.bin`
    capture (`motion_capture.jsonl`, `optical_capture.jsonl`, `fixtures/hist_biometric.bin`).
  - `from-app` — confirmed against the official app's command enum/builders (interoperability).
  - `❌` — unverified (located by structure/reference only).
- dtypes: `u8/u16/u32` little-endian unsigned · `s16` signed 16-bit LE · `s24` signed 24-bit LE ·
  `f32` IEEE-754 LE.

---

## Frame envelope (all packet types)

| Field | Offset | dtype | Unit | Meaning | Decoded? | Verified? |
|---|---|---|---|---|---|---|
| SOF | 0 | u8 | — | start-of-frame `0xAA` | ✅ | on-device |
| length | 1 | u16 | bytes | frame payload length | ✅ | on-device |
| crc8 | 3 | u8 | — | crc8 (poly 0x07) over the 2 length bytes | ✅ | on-device |
| packet_type | 4 | u8 | enum | `PacketType` | ✅ | on-device |
| seq | 5 | u8 | — | sequence byte; **doubles as VERSION selector for type-47** | ✅ | from-capture (biometric) |
| crc32 | last 4 | u32 | — | zlib crc32 over `[type][seq][cmd][payload]` | ✅ | on-device |

---

## type-40 REALTIME_DATA — compact HR/R-R

Streams only while `TOGGLE_REALTIME_HR`=1 (resets per connection). NOTE: the schema records this
type-40 has NO separate cmd byte — the record begins at frame offset 6 (so the "cmd" position is
the low byte of the timestamp). The frame-absolute offsets below are the schema/interpreter values
and are VERIFIED against real captured frames (decoded HR = 60/59/60 bpm, plausible resting).
(NB: the prose in protocol-complete §6 used a confusing data-relative base — these are authoritative.)

| Field | Offset | dtype | Unit | Meaning | Decoded? | Verified? |
|---|---|---|---|---|---|---|
| timestamp | 6 | u32 | s | device-epoch seconds | ✅ | from-capture (verified) |
| subseconds | 10 | u16 | 1/65536 s | sub-second fraction | ✅ | from-capture (verified) |
| heart_rate | 12 | u8 | bpm | instantaneous HR | ✅ | from-capture (HR=60, plausible) |
| rr_count | 13 | u8 | count | number of R-R intervals following | ✅ | from-capture |
| R-R[] | 14 + 2·n | u16 | ms | beat-to-beat intervals (×rr_count) | ✅ | from-capture |

---

## type-43 REALTIME_RAW_DATA — common header

Both variants share this header. `cmd` (frame[6]) discriminates the variant: cmd=41 → 1917-byte IMU;
cmd=0 → 1921-byte optical. The two arrive as a pair, ~1/s, while bonded.

| Field | Offset | dtype | Unit | Meaning | Decoded? | Verified? |
|---|---|---|---|---|---|---|
| cmd | 6 | u8 | — | variant discriminator (41=IMU, 0=optical) | ✅ | from-capture |
| record_hdr | 7 | u32 | — | frame counter (dual u32 counters in 7:15) | partial | from-capture |
| timestamp | 11 | u32 | s | device-epoch seconds | ✅ | from-capture |
| subseconds | 15 | u16 | 1/65536 s | sub-second fraction | ✅ | from-capture |
| unknown_hdr | 17 | u32 | — | second header word (counter/flags) | partial | from-capture |

### type-43 variant 1917 — IMU + HR (RESOLVED, motion-verified)

Signed int16 LE, 100 samples/axis, ~100 Hz, 1 packet/s. Axis arrays are contiguous 200-byte blocks.

| Field | Offset | dtype | Unit | Meaning | Decoded? | Verified? |
|---|---|---|---|---|---|---|
| heart_rate | 21 | u8 | bpm | header HR (same decode as live + historical) | ✅ | on-device |
| rr_count | 22 | u8 | count | R-R intervals following | ✅ | from-capture |
| R-R[] | 23 + 2·n | u16 | ms | beat-to-beat intervals | ✅ | from-capture |
| GAP1 | 24:82 | bytes (58) | — | unmapped (constant-ish; status/optical?) | ❌ | ❌ |
| accelX[100] | 89 | s16×100 | g (×1/4096) | X accel, ×0.000244140625 g/LSB | ✅ | from-capture (motion) |
| accelY[100] | 289 | s16×100 | g (×1/4096) | Y accel | ✅ | from-capture (motion) |
| accelZ[100] | 489 | s16×100 | g (×1/4096) | Z accel | ✅ | from-capture (motion) |
| GAP2 | 682:685 | bytes (3) | — | alignment pad between accel and gyro | ❌ | ❌ |
| gyroX[100] | 692 | s16×100 | deg/s (×0.06104) | X angular rate, **±2000 dps / 16.4 LSB·deg⁻¹·s** | ✅ | from-capture (720° rotation) |
| gyroY[100] | 892 | s16×100 | deg/s (×0.06104) | Y angular rate | ✅ | from-capture (720° rotation) |
| gyroZ[100] | 1092 | s16×100 | deg/s (×0.06104) | Z angular rate | ✅ | from-capture (720° rotation) |
| TAIL | 1292:1917 | bytes (632) | — | unmapped (~33% of packet; constant-ish, not a motion axis) | ❌ | ❌ |

- **ACCEL scale = 1/4096 LSB/g (±8 g range)** — sphere-fit over 67 still packets gave |g|=0.99,
  residual std 0.0%; per-pose gravity vectors confirmed (flat/palmup/thumbup/fingersup). VERIFIED.
- **GYRO scale = 0.06104 deg/s/LSB (±2000 dps, 16.4 LSB per deg/s) — VERIFIED.** Controlled 720°
  (2-turn) rotations (`re/analyze_gyro_scale.py`): rotation A = 19.7 °/s × 36.5 s = 720° ✓, K=0.0611
  (exact ±2000 dps sensitivity); a 2nd axis = 0.0657 (±~10%, human turn-count). openwhoop's ÷15
  (0.0667) is within tolerance. (Earlier freehand captures couldn't pin it: gyro-gravity R²≈0.)
- **Do NOT conflate** with openwhoop's IMU parser (big-endian, ÷1875 accel, ÷15 gyro, offsets
  85/285/485…): that is for the type-47 ≥1188-byte HISTORICAL-IMU variant, not this packet.

### type-43 variant 1921 — optical / PPG (PARTIAL, optical-verified)

A SINGLE AC-coupled (DC-removed / high-pass) PPG waveform — NOT 4 interleaved channels. Shares the
8-byte dual-counter header (frame[7:15]) with the 1917 IMU partner.

| Field | Offset | dtype | Unit | Meaning | Decoded? | Verified? |
|---|---|---|---|---|---|---|
| config / TLV header | 15:42 | bytes (27) | — | likely LED-current / exposure config | ❌ | ❌ |
| ppg_sample[].value | 42 + 4·n | s24 | ADC counts | green/HR-LED PPG waveform (AC-coupled) | ✅ | from-capture (optical) |
| ppg_sample[].aux | 45 + 4·n | u8 | — | per-sample aux byte; ~73% sign-ext of value else small burst markers (status/exposure?) | partial | from-capture (optical) |
| zero-pad tail | ~1718:1921 | bytes | — | zero padding after ~419 samples | ✅ | from-capture (optical) |

- ~419 samples/packet @ ~437 Hz, stride 4 (`bytes[0:3]`=s24 value, `byte[3]`=aux).
- Channel ground-truth (phase test): finger phase → clean 1.04 Hz (63 bpm) fundamental + 2nd/3rd
  harmonics = pulsatile = GREEN/HR LED; air phase → flatlines. Red/IR/ambient are NOT in this raw
  stream — they appear only as the DSP'd scalars inside the type-47 V24 record
  (`ppg_green`/`ppg_red_ir`/`ambient`).
- The green waveform decodes losslessly (1 channel). `aux` byte semantics + the [15:42] config header
  remain UNKNOWN → kept raw. A `light`/ambient capture would help resolve the `aux` byte.

---

## type-47 HISTORICAL_DATA — the 14-day biometric store

Version = the seq byte (frame[5]). This WHOOP 4.0 emits **V24**. Verified on 762 records from
`fixtures/hist_biometric.bin` (HR min57/median61/max70, |gravity|≈0.99–1.0 g, 545 records carry R-R).
Reachable only via the high-freq-sync handshake + valid RTC (protocol-complete §0-bis).

### V24 / V12 — full DSP biometric record (frame-absolute = openwhoop data-offset + 7)

| Field | Offset | dtype | Unit | Meaning | Decoded? | Verified? |
|---|---|---|---|---|---|---|
| unix | 11 | u32 | s | real unix seconds (e.g. 1700000000) | ✅ | from-capture (biometric) |
| heart_rate | 21 | u8 | bpm | heart rate | ✅ | from-capture (biometric) |
| rr_count | 22 | u8 | count | number of R-R intervals following | ✅ | from-capture (biometric) |
| R-R[] | 23 + 2·n | u16 | ms | beat-to-beat intervals (×rr_count) | ✅ | from-capture (biometric, 545/762 records) |
| ppg_green | 33 | u16 | ADC counts | green LED ADC (raw) | ✅ (raw) | from-capture (biometric) |
| ppg_red_ir | 35 | u16 | ADC counts | red/IR LED ADC (raw) | ✅ (raw) | from-capture (biometric) |
| gravity_x | 40 | f32 | g | accel gravity vector X (already in g) | ✅ | from-capture (biometric, |g|≈1) |
| gravity_y | 44 | f32 | g | accel gravity vector Y | ✅ | from-capture (biometric) |
| gravity_z | 48 | f32 | g | accel gravity vector Z | ✅ | from-capture (biometric) |
| skin_contact | 55 | u8 | bool | 0 = off-wrist | ✅ | from-capture (biometric) |
| spo2_red | 68 | u16 | ADC counts | raw; SpO2 % computed server-side (cloud DSP) | ✅ (raw) | from-capture (biometric) |
| spo2_ir | 70 | u16 | ADC counts | raw; SpO2 % computed server-side | ✅ (raw) | from-capture (biometric) |
| skin_temp_raw | 72 | u16 | ADC counts | raw; °C computed server-side | ✅ (raw) | from-capture (biometric) |
| ambient | 74 | u16 | ADC counts | ambient light ADC | ✅ (raw) | from-capture (biometric) |
| led_drive_1 | 76 | u16 | — | LED drive setting | ✅ (raw) | from-capture (biometric) |
| led_drive_2 | 78 | u16 | — | LED drive setting | ✅ (raw) | from-capture (biometric) |
| resp_rate_raw | 80 | u16 | ADC counts | raw; breaths/min computed server-side | ✅ (raw) | from-capture (biometric) |
| signal_quality | 82 | u16 | — | signal-quality metric | ✅ (raw) | from-capture (biometric) |

> **CRITICAL:** SpO2 / skin-temp / resp are RAW ADC values. WHOOP computes the human-unit values
> (SpO2 %, °C, breaths/min) SERVER-SIDE. No open implementation (openwhoop included) converts them
> client-side — they are uploaded raw for cloud DSP. The gravity vector is the exception: already in g.

### V5 / V7 / V9 — generic HR/RR-only record (no DSP sensor block)

| Field | Offset | dtype | Unit | Meaning | Decoded? | Verified? |
|---|---|---|---|---|---|---|
| unix | 11 | u32 | s | unix seconds | ✅ | from-capture (ref) |
| heart_rate | 21 | u8 | bpm | heart rate | ✅ | from-capture (ref) |
| rr_count | 22 | u8 | count | R-R intervals following | ✅ | from-capture (ref) |
| R-R[] | 23 + 2·n | u16 | ms | beat-to-beat intervals | ✅ | from-capture (ref) |

### V18 — Gen5/Maverick (NOT this device)

| Field | Offset | dtype | Unit | Meaning | Decoded? | Verified? |
|---|---|---|---|---|---|---|
| (different layout) | — | — | — | HR at data-offset 11; SpO2 as a direct u8 % at data-offset 48 | partial (ref) | ❌ (not this device) |

> ≥1188-byte type-47 variant = full IMU arrays (openwhoop big-endian parser). Not emitted by this
> WHOOP 4.0; out of scope for the V24 store.

---

## type-48 EVENT

| Field | Offset | dtype | Unit | Meaning | Decoded? | Verified? |
|---|---|---|---|---|---|---|
| event | 6 | u8 | enum | `EventNumber` (e.g. 9/10 WRIST_ON/OFF, 23 BLE_BONDED, 46/47 RAW_DATA_COLLECTION_ON/OFF) | ✅ | on-device / from-app |
| (pad) | 7 | u8 | — | unused byte before timestamp | ❌ | ❌ |
| event_timestamp | 8 | u32 | s | event time; **clock base differs by subtype** — connect/wrist/charging carry real unix, battery events (3, 63) carry device epoch | ✅ | from-capture |

---

## type-49 METADATA — historical offload markers

| Field | Offset | dtype | Unit | Meaning | Decoded? | Verified? |
|---|---|---|---|---|---|---|
| meta_type | 6 | u8 | enum | `MetadataType` (1 HISTORY_START, 2 HISTORY_END, 3 HISTORY_COMPLETE) | ✅ | on-device |
| HISTORY_END.unix | 7 | u32 | s | end-of-chunk unix | ✅ | from-capture |
| HISTORY_END.subsec | 11 | u16 | 1/65536 s | sub-second | partial | from-capture |
| HISTORY_END.unk | 13 | u32 | — | unknown word | ❌ | ❌ |
| HISTORY_END.trim | 17 | u32 | — | trim cursor → fed back in HISTORICAL_DATA_RESULT ack | ✅ | from-capture |

> ack `end_data` = `metadata.data[10:18]` (unix u32, skip 6, then two u32s) per §0-bis.

---

## type-50 CONSOLE_LOGS — firmware text

| Field | Offset | dtype | Unit | Meaning | Decoded? | Verified? |
|---|---|---|---|---|---|---|
| header | 6:13 | bytes (7) | — | log header; strip `34 00 01` marker | ✅ | from-capture |
| text | 13.. | ascii | — | NUL-terminated firmware log line | ✅ | from-capture (replayed during historical offload only) |

---

## type-36 COMMAND_RESPONSE

| Field | Offset | dtype | Unit | Meaning | Decoded? | Verified? |
|---|---|---|---|---|---|---|
| (marker) | 4 | u8 | — | `0a` response marker (type byte) | ✅ | on-device |
| status | 5 | u8 | — | 01=ok · 03=unsupported-on-fw · 00=empty/uninitialised | ✅ | on-device |
| resp_cmd | 6 | u8 | enum | echoed `CommandNumber` | ✅ | on-device |
| value | 7.. | varies | — | getter payload (per-command, see command table) | ✅/partial | on-device |

---

## Command table — every `CommandNumber`

Direction = app→strap for all. **Dec** = decoded response/semantics on this device.
Risk: 🟢 safe/read-only · 🟡 reversible state change · 🔴 destructive/confirm-first.
Semantics per protocol-complete §3.

| # | Name | Decoded response? | Semantics | Verified? | Risk |
|---|---|---|---|---|---|
| 1 | LINK_VALID | ✅ `0a01` + "There it is." | liveness easter-egg | on-device | 🟢 |
| 2 | GET_MAX_PROTOCOL_VERSION | ✅ `0a03` | unsupported on this fw | on-device | 🟢 |
| 3 | TOGGLE_REALTIME_HR | ✅ (no resp; starts type-40) | start/stop compact HR; resets per connection | on-device | 🟡 |
| 7 | REPORT_VERSION_INFO | ✅ u32 `{maj,min,patch,build}` quads | harvard 41.16.6.0, boylston 17.2.2.0 + 2 components | on-device | 🟢 |
| 10 | SET_CLOCK | partial (no resp) | set RTC; payload `[unix u32 LE][5 pad]`; the fix persists (RTC now valid) | on-device | 🟡 |
| 11 | GET_CLOCK | ✅ `0a01 <u32 dev_clock><u16 subsec>` | device monotonic epoch (NOT unix); read 1779665639 valid this session | on-device | 🟢 |
| 14 | TOGGLE_GENERIC_HR_PROFILE | ✅ (no resp) | enable/disable standard 0x2A37 HR profile | on-device | 🟡 |
| 16 | TOGGLE_R7_DATA_COLLECTION | partial | R7 raw record collection; did NOT stop type-43 flood; no app builder | from-app | 🟡 |
| 19 | RUN_HAPTIC_PATTERN_MAVERICK | ❌ | haptics (newer-gen) | ❌ | 🟡 |
| 20 | ABORT_HISTORICAL_TRANSMITS | ✅ (no resp) | stop in-progress offload, no trim | on-device | 🟢 |
| 22 | SEND_HISTORICAL_DATA | ✅ stream + METADATA | start historical offload loop; payload `[0x00]` | on-device | 🟢 |
| 23 | HISTORICAL_DATA_RESULT | ✅ | ack a chunk → **DESTRUCTIVE TRIM**; payload `[0x01]+end_data[8]` | from-capture | 🔴 |
| 25 | FORCE_TRIM | ❌ | wipe history | ❌ | 🔴 |
| 26 | GET_BATTERY_LEVEL | ✅ `0a01 <u16 soc×10>` | SOC %; ignore 1st read after connect; read 59.6% this session | on-device | 🟢 |
| 29 | REBOOT_STRAP | ✅ (drops link) | reboot; does NOT clear raw mode; latches SET_CLOCK | on-device | 🔴 |
| 32 | POWER_CYCLE_STRAP | ❌ | power cycle | ❌ | 🔴 |
| 33 | SET_READ_POINTER | partial | move history read pointer (re-read without trim) | from-app | 🟡 |
| 34 | GET_DATA_RANGE | ✅ cursors + unix words | stored-history extent for sync planning | on-device | 🟢 |
| 35 | GET_HELLO_HARVARD | ✅ serial+key+clock+ver | byte7=charging, byte116=isWorn, serial, device key | on-device | 🟢 |
| 36 | START_FIRMWARE_LOAD | ❌ | firmware load (old) | ❌ | 🔴 |
| 37 | LOAD_FIRMWARE_DATA | ❌ | firmware load (old) | ❌ | 🔴 |
| 38 | PROCESS_FIRMWARE_IMAGE | ❌ | firmware load (old) | ❌ | 🔴 |
| 39 | SET_LED_DRIVE | ✅ `0a01` | set PPG LED drive | on-device | 🟡 |
| 40 | GET_LED_DRIVE | ✅ `0a01` (zeros when optical off) | read PPG LED drive | on-device | 🟢 |
| 41 | SET_TIA_GAIN | ✅ `0a01` | set PPG transimpedance gain | on-device | 🟡 |
| 42 | GET_TIA_GAIN | ✅ `0a01` (zeros when optical off) | read PPG TIA gain | on-device | 🟢 |
| 43 | SET_BIAS_OFFSET | ✅ `0a01` | set PPG bias offset | on-device | 🟡 |
| 44 | GET_BIAS_OFFSET | ✅ `0a01` (zeros when optical off) | read PPG bias offset | on-device | 🟢 |
| 45 | ENTER_BLE_DFU | ❌ | bootloader / firmware update | ❌ | 🔴 |
| 52 | SET_DP_TYPE | ❌ | set data-processor/packet type; no app builder | from-app (absent) | 🟡 |
| 53 | FORCE_DP_TYPE | ❌ | force DP type; no app builder | from-app (absent) | 🟡 |
| 63 | SEND_R10_R11_REALTIME | partial | R10/R11 realtime raw packets | from-app | 🟡 |
| 66 | SET_ALARM_TIME | ✅ `0a01` | set strap alarm | on-device | 🟡 |
| 67 | GET_ALARM_TIME | ✅ `0a01` | read strap alarm | on-device | 🟢 |
| 68 | RUN_ALARM | partial | fire alarm | from-app | 🟡 |
| 69 | DISABLE_ALARM | partial | cancel alarm | from-app | 🟡 |
| 76 | GET_ADVERTISING_NAME_HARVARD | ✅ `0a01` | read BLE adv name (harvard) | on-device | 🟢 |
| 77 | SET_ADVERTISING_NAME_HARVARD | ✅ `0a01` | set BLE adv name (harvard) | on-device | 🟡 |
| 79 | RUN_HAPTICS_PATTERN | ✅ `0a01` | run haptic pattern by id | on-device | 🟡 |
| 80 | GET_ALL_HAPTICS_PATTERN | ✅ `0a01` | enumerate haptic patterns | on-device | 🟢 |
| 81 | START_RAW_DATA | ✅ (no resp) | timed R10/R11 raw, `[u32 ms LE]`=hours×3,600,000; auto-expires | from-app | 🟡 |
| 82 | STOP_RAW_DATA | ✅ (no resp) | stop R10/R11 raw, payload `[0x01]`; does NOT stop persistent flood | on-device / from-app | 🟢 |
| 83 | VERIFY_FIRMWARE_IMAGE | ❌ | fw verify | ❌ | 🔴 |
| 84 | GET_BODY_LOCATION_AND_STATUS | ✅ `0a00 01 …` | on-body status | on-device | 🟢 |
| 96 | ENTER_HIGH_FREQ_SYNC | partial (no resp; gates type-47) | enter high-frequency sync mode; empty payload | on-device | 🟡 |
| 97 | EXIT_HIGH_FREQ_SYNC | partial (no resp) | exit high-frequency sync mode | from-app | 🟡 |
| 98 | GET_EXTENDED_BATTERY_INFO | ✅ voltage/capacity/fuel-gauge | mV (~3687) + capacity + gauge fields | on-device | 🟢 |
| 99 | RESET_FUEL_GAUGE | ❌ | reset battery gauge | ❌ | 🟡 |
| 100 | CALIBRATE_CAPSENSE | ❌ | cap-touch calibration | ❌ | 🟡 |
| 105 | TOGGLE_IMU_MODE_HISTORICAL | partial | IMU in historical | from-app | 🟡 |
| 106 | TOGGLE_IMU_MODE | ✅ (no resp) | enable IMU axes in raw (Gen4 enable-seq) | on-device / from-app | 🟡 |
| 107 | ENABLE_OPTICAL_DATA | ✅ (no resp) | enable optical in raw (enable-seq) | on-device / from-app | 🟡 |
| 108 | TOGGLE_OPTICAL_MODE | partial | optical mode (Gen4 enable-seq) | from-app | 🟡 |
| 115 | START_DEVICE_CONFIG_KEY_EXCHANGE | ✅ `0a01 01 <u16 count>` | begin device-config read; count=1 here | on-device | 🟢 |
| 116 | SEND_NEXT_DEVICE_CONFIG | ✅ `0a01 01 <flags> 01 <name\0>` | walk config keys; cursor payload `[0x01]` | on-device | 🟢 |
| 117 | START_FF_KEY_EXCHANGE | ✅ `0a01 01 <u16 count>` | begin feature-flag read; count=11 here | on-device | 🟢 |
| 118 | SEND_NEXT_FF | ✅ `0a01 01 <flags> 01 <name\0>` | walk FF keys; cursor payload `[0x01]` | on-device | 🟢 |
| 119 | SET_DEVICE_CONFIG_VALUE | partial (write, builder known) | `[0x01][32B key][32B value]` | from-app | 🟡 |
| 120 | SET_FF_VALUE | ✅ (`0a0101<key>31…` on success) | `[0x01][32B key][32B value]`; "1"=ON/"2"=OFF | from-app | 🟡 |
| 121 | GET_DEVICE_CONFIG_VALUE | partial `0a00 …` | read config value; trailing value contaminated by stale buffer | on-device | 🟢 |
| 122 | STOP_HAPTICS | partial | stop haptics | on-device | 🟢 |
| 123 | SELECT_WRIST | partial | set wrist L/R | from-app | 🟡 |
| 124 | TOGGLE_LABRADOR_DATA_GENERATION | partial | "labrador" pipeline gen (no effect on flood) | from-app | 🟡 |
| 125 | TOGGLE_LABRADOR_RAW_SAVE | partial | labrador raw save | from-app | 🟡 |
| 128 | GET_FF_VALUE | partial `0a00 …` | read FF value; trailing value unreliable (stale buffer) | on-device | 🟢 |
| 131 | SET_RESEARCH_PACKET | ❌ | set research-packet config; no app builder | from-app (absent) | 🟡 |
| 132 | GET_RESEARCH_PACKET | partial | read research-packet; idx-0 returns 18 B `00 9c8ae2 01 50 7b0c00 …` undecoded; payload-0x00 got no response (needs u8 index) | on-device | 🟢 |
| 139 | TOGGLE_LABRADOR_FILTERED | ❌ | labrador filtered | ❌ | 🟡 |
| 140 | SET_ADVERTISING_NAME | ✅ `0a03` | unsupported on this fw | on-device | 🟢 |
| 141 | GET_ADVERTISING_NAME | ✅ `0a03` | unsupported (non-harvard) on this fw | on-device | 🟢 |
| 142 | START_FIRMWARE_LOAD_NEW | ❌ | firmware load (new) | ❌ | 🔴 |
| 143 | LOAD_FIRMWARE_DATA_NEW | ❌ | firmware load (new) | ❌ | 🔴 |
| 144 | PROCESS_FIRMWARE_IMAGE_NEW | ❌ | firmware load (new) | ❌ | 🔴 |
| 145 | GET_HELLO | ✅ `0a03` | unsupported here (harvard uses GET_HELLO_HARVARD) | on-device | 🟢 |
| 151 | GET_BATTERY_PACK_INFO | ✅ `0a03` | unsupported on this fw (new in a current app build) | on-device | 🟢 |
| 153 | TOGGLE_PERSISTENT_R20 | ✅ `0a03` | unsupported on this fw; payload `[0x01, on]` | on-device | 🟡 |
| 154 | TOGGLE_PERSISTENT_R21 | ✅ `0a03` | unsupported on this fw | on-device | 🟡 |

---

## Open unknowns (what remains undecoded, and why)

### Packet-field unknowns

1. **type-43/1917 GAP1 `frame[24:82]` (58 B)** — located, undecoded. Constant-ish across packets, not
   a smooth motion axis; candidate status/optical sidecar. Needs a capture that varies a single
   plausible driver (e.g. contact/temperature) to attribute it.
2. **type-43/1917 GAP2 `frame[682:685]` (3 B)** — alignment pad between accelZ and gyroX; almost
   certainly padding, not a field.
3. **type-43/1917 TAIL `frame[1292:1917]` (632 B, ~33% of packet)** — located, undecoded.
   Constant-ish, not a motion axis; possibly status/optical/CRC-region. Largest remaining gap.
4. **type-43/1917 GYRO scale** — RESOLVED 2026-05-24: ±2000 dps / 0.06104 deg/s/LSB, verified by
   controlled 720° rotation (see IMU notes above). No longer open.
5. **type-43/1921 config / TLV header `frame[15:42]` (27 B)** — undecoded; likely LED-current /
   exposure config. Kept raw.
6. **type-43/1921 per-sample `aux` byte (`frame[45]+4·n`)** — STILL UNKNOWN after the labeled
   finger/dark/light/air session: mostly 0 with 255 spikes, no clean phase separation, so NOT a
   simple exposure/ambient channel. Kept raw. (Session note: a direct flashlight triggered a
   CH1/CH2-saturation latch that took the whole raw optical+IMU stream offline until the enable
   sequence was re-sent — so an ambient channel may simply not be exposed in this raw stream.)
7. **type-43 header `record_hdr` / `unknown_hdr` (frame[7], frame[17])** — dual u32 counters located;
   exact counter/flag semantics partial.
8. **type-47 V18 (Gen5/Maverick) layout** — referenced from openwhoop only; not emitted by this
   device, so unverified here.
9. **type-49 HISTORY_END `unk` word (frame[13])** — present, not decoded; not needed for the ack
   (the ack uses unix + trim).
10. **type-48 EVENT byte 7** — single byte between `event` and `event_timestamp`; unused/padding,
    not decoded.

### Command unknowns

11. **Authenticated config read/write** — `GET_DEVICE_CONFIG_VALUE`(121) / `GET_FF_VALUE`(128) return
    a value field contaminated by a stale shared buffer, so on/off reads are unreliable. The app
    never reads values (only enumerates + sets), so the read path is not fully crackable from the APK.
12. **`SET_DP_TYPE`(52) / `FORCE_DP_TYPE`(53) / `SET_RESEARCH_PACKET`(131)** — payloads unknown; these
    have NO command-builder and zero references in the current app, so the payload cannot be recovered
    from this APK (pure guesswork, write-risky). Likely moot — the strap operates normally.
13. **`GET_RESEARCH_PACKET`(132)** — idx-0 returns an 18-byte struct (`00 9c8ae2 01 50 7b0c00 …`) that
    is not field-decoded; a `payload=0x00` probe got no response, indicating it needs a u8 index.
14. **Firmware-load / DFU commands (36/37/38/45/83/142/143/144)** — semantics known by name only;
    intentionally not exercised (🔴 destructive).
15. **Maverick / battery-pack / haptics-maverick commands (19/99/100 and the unsupported 151)** — not
    applicable or unsupported on this Gen4 firmware; not decoded.
