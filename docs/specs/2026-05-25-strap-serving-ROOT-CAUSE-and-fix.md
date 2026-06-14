# Strap "won't serve type-47" — ROOT CAUSE + Fix (SOLVED 2026-05-25)

> Resolves the deep-debug handoff `docs/specs/2026-05-25-strap-serving-debug-handoff.md`.
> **Status: FIXED and verified end-to-end on device** (server HR frontier advanced past the gap;
> read cursor draining; confirmed again with the cleaned/committed build).

## TL;DR

The strap was **healthy the whole time.** The bug was **entirely in the iOS app** — three
independent defects that together stopped the type-47 historical offload. The handoff's leading
theories (RTC lost, missing hello, removed high-freq-sync) were **all red herrings**, disproven by a
read-only Mac ground-truth test that pulled 50 type-47 records from the strap with *plain*
`SEND_HISTORICAL_DATA` — no hello, no high-freq-sync, no clock set.

## How we proved strap-vs-app (the step that should have been first)

`re/diagnose_biometrics.py` and `re/test_offload_without_highfreq.py` (read-only, no ack/trim), run
from the Mac with the phone's Bluetooth off, **served 50 type-47 records** from the strap at 50%
battery:

```
PHASE A: plain SEND_HISTORICAL_DATA (no hello, no high-freq) -> 50 type-47 records
PHASE B: ENTER_HIGH_FREQ_SYNC + SEND_HISTORICAL              -> 0
```

That single experiment proved the strap serves fine and split the entire problem to the app side.

## The three real root causes (all iOS)

### 1. Handshake re-entrancy storm
The connect handshake lived in `BLEManager.didWriteValueFor(...)`, which CoreBluetooth calls on the
completion of **every `.withResponse` write** — the bond write, every `SEND_HISTORICAL`, and every
`HISTORY_END` ack. The hello/`SET_CLOCK` sends in that handler were unguarded, so each with-response
write **re-ran the whole handshake**, re-blasting hello/`SET_CLOCK` at the strap *during* the offload
(observed: 3 handshakes in 3 s) plus reconnect churn. The strap never got a stable window to stream
type-47. The Mac prototype works because it runs the sequence **once** on a stable, paced connection.

**Fix:** a `connectHandshakeDone` flag runs the handshake **exactly once per connection** (reset on
disconnect); `beginBackfill()` is gated on it so a racing foreground/restore trigger can't fire
`SEND_HISTORICAL` ahead of the handshake.

### 2. `SEND_HISTORICAL_DATA` payload must be `[0x00]`, not empty
The app sent an **empty** payload (a mistaken "match WHOOP" change). On this strap, `SEND_HISTORICAL`
with an empty payload returns **nothing**; with `[0x00]` it streams the store (ground truth: the Mac
offload uses `[0x00]`). Verified on a clean, stable link with ~2 k records pending: empty → 0 frames,
`[0x00]` → full stream. (The handoff's "empty vs `[0x00]` doesn't matter" was tested during the storm
state above, so it was invalid.)

**Fix:** `send(.sendHistoricalData, payload: [0x00], writeType: .withResponse)`.

### 3. Backfiller hard-blocked on a clock correlation type-47 doesn't need
type-47 `HISTORICAL_DATA` carries its **own real-unix timestamp** (frame offset 11);
`extractHistoricalStreams` deliberately **ignores the clock offset** for it. The `(device, wall)`
`clockRef` is only needed to map **REALTIME** (type-40/43) device-epoch timestamps. But the Backfiller
did `guard let ref = clockRef else { return }`, so the (separately) silent `GET_CLOCK(11)` blocked
*all* persistence + ack — even though the type-47 records were arriving fine.

**Fix:** identity-`clockRef` fallback (`device == wall == now`) when the correlation isn't established
— a no-op for type-47, so records persist + ack + upload regardless of `GET_CLOCK`.

## Red herrings (do not chase again)
- **Hello is not required to serve.** The Mac never sends `GET_HELLO_HARVARD(35)` yet serves. We keep
  hello in the handshake only to mirror WHOOP exactly (apk connect lifecycle hello → set RTC → READY),
  not because the offload needs it.
- **High-freq-sync is not needed** (plain = 50 records, high-freq = 0). Confirms the prior
  `[[whoop-offload-no-highfreq]]` finding.
- **RTC/clock are fine.** The strap holds correct unix time (type-47 timestamps decode to real wall
  time). `GET_CLOCK(11)` is still silent even with WHOOP's empty payload — **unexplained but now
  non-blocking**, since the offload no longer depends on it.
- `GET_DATA_RANGE(34)` going silent during the failed phone captures was the storm/churn, not a fault.

## WHOOP-faithful steady-state handshake (what the app now does, once per connection)
1. Bond (confirmed `GET_BATTERY_LEVEL` write) → subscribe to 61080003/4/5 + HR/battery.
2. `GET_HELLO_HARVARD(35)` → `GET_ADVERTISING_NAME(76)` → `SET_CLOCK(10)` (8-byte) → `GET_CLOCK(11)`
   (empty payload, best-effort).
3. Stop the R10/R11 type-43 realtime flood (`SEND_R10_R11_REALTIME[0x00]`); `GET_DATA_RANGE(34)`.
4. After ~1.5 s settle, rate-limited `requestSync(.connect)` → `beginBackfill()` →
   `SEND_HISTORICAL_DATA[0x00]` (plain; no high-freq). Strap streams `HISTORY_START` → type-47 →
   `HISTORY_END` (acked with `[0x01]+end_data`) … → `HISTORY_COMPLETE`. Each ack advances/trims the
   strap's read cursor; the periodic timer keeps draining.

## Verification
- Mac ground truth: 50 type-47 records, twice, plain offload.
- On device (fix build): 354 → 3410 type-47 frames per capture, chunks persisted, read cursor (trim)
  climbing 73,184 → 73,521+, timestamps decoding to correct wall unix.
- Server: HR total 76,929 → 77,558 → 84,9xx and climbing; frontier advanced from 00:23 UTC (the
  17:23 PDT gap onset) forward. Re-confirmed with the cleaned/committed build (hr advanced within 10 s
  of launch).

## Known follow-ups (separate from the serving fix)
- **Residual server gap 00:23–02:48 UTC (~2.4 h):** the drain resumed at the strap's current read
  cursor (~02:48), leaving an earlier window un-uploaded. The data is likely still in 14-day flash
  behind the cursor; forward draining won't fill it. Recovery would mean rewinding the strap's read
  cursor (the ack echoes the read-cursor words) — investigated separately.
- **`GET_CLOCK(11)` silent** even with WHOOP's empty payload — non-blocking; left as a curiosity.
- The `dataRangeNewestUnix` parser is still the ad-hoc scanner (feeds only the watchdog); the
  verified `W/U/T` decode from §4.3 of the handoff is the better long-term replacement.
