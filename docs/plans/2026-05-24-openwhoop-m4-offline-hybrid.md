# OpenWhoop iOS — M4 + M5 write-path: Offline-First Hybrid Backfill — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On every (re)connect, drain the WHOOP strap's history buffer: the phone decodes the **known** fields (HR/R‑R/events/battery) from the recorded type-43 frame stream into the local store **and** keeps every chunk's **whole raw frames** locally, trims a chunk only once **both** are durable on the phone (works offline), and opportunistically uploads **both** decoded streams and raw batches to the server.

**Architecture:** History is the recorded **raw frame stream** replayed in native types (type-43 `REALTIME_RAW_DATA` carrying an HR/R‑R header + IMU/PPG arrays, plus `EVENT`/`CONSOLE_LOGS`/`METADATA`) — **not** a novel type-47 payload (F0 RE spike). The phone is the **sole decoder** (offline-first): it decodes known fields locally (the decoder already parses the type-43 header — we just stop suppressing it for the no-type-40 historical case), stores raw via M3's `RawOutbox`, and trims on **local** persistence (never the server). Phase **F** adds the historical stream extractor (Python reference → Swift parity). Phase **H** moves `WhoopStore` to an `actor` + adds a `cursors` table + makes unsynced raw un-prunable. Phase **G** adds the `Backfiller` (decode→insert+enqueueRaw→trim) and wires BLE. Phase **I** adds the `Uploader` (decoded + raw drains), the server's `POST /v1/ingest-decoded` + archive-only `/v1/ingest`, and the tunnel route.

**Tech Stack:** Swift 6.3 / Xcode 26.4, SwiftPM, GRDB.swift 6.29.3, XcodeGen, SwiftUI, CoreBluetooth, XCTest; Python 3 (`whoop_protocol`) for the decode reference + parity; FastAPI + TimescaleDB (home-server). iOS simulator = **iPhone 17**; device build = **iPhone 16 Pro** (udid `<DEVICE_UDID>`, team `<TEAM_ID>`).

**Spec:** `docs/specs/2026-05-24-openwhoop-m4-offline-hybrid-backfill-design.md`. **Builds on** M1/M2 and M3 (`docs/plans/2026-05-23-openwhoop-m3-local-store.md`) — complete + hardware-verified. **F0 RE spike is DONE** (capture preserved at `fixtures/historical_capture.bin`).

---

## Conventions

- **TDD where testable** (failing test → run-fail → implement → run-pass → commit); **parity** for the historical decoder (Python reference is source of truth, Swift matches byte-for-byte); CoreBluetooth + tunnel are **build-verify** (no radio/network in tests).
- **Commit after every task**, ending each commit message with a second `-m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"`. Commit directly on `main` (this repo's established workflow).
- **Two repos:** app/decoder/spec live in `~/openwhoop`; the server in `~/Developer/home-server` (Phase I server tasks commit there).
- **Package tests:** `swift test --package-path Packages/WhoopProtocol` (and `…/WhoopStore`). **App build/tests:** `cd ios && xcodegen generate && xcodebuild [test] -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17'`.
- **The golden JSON resources are TRACKED (committed) parity artifacts** — `Packages/WhoopProtocol/Tests/WhoopProtocolTests/Resources/{frames,golden,streams_golden,historical_frames,historical_golden}.json`. They are NOT git-ignored. **Whenever the decoder or a fixture changes, regenerate (`gen_golden.py`) and commit any changed golden(s)** in the same task — otherwise a clean checkout's parity test fails against a stale golden. (The existing `golden.json` etc. are already tracked; the new historical goldens follow the same rule.)
- **The historical fixture `.bin` stays local (git-ignored).** `fixtures/historical_capture.bin` is real biometric data; it is **never committed**. `gen_golden.py` reads it locally to emit the (committed) historical golden resources. The committed goldens contain biometric-derived values — consistent with the already-committed `golden.json`; full redaction is the known pre-public-push deferred item (repo is local-only).
- **Never `git add`** the generated `ios/OpenWhoop.xcodeproj`, `ios/OpenWhoop/Info.plist`, the fixture `.bin`, or the real `ios/OpenWhoop/Config/Secrets.xcconfig` (all git-ignored). **Golden JSON resources ARE committed** (see above).

## Cross-phase integration notes (READ FIRST)

These reconcile the phases; they override anything in a phase section that conflicts.

1. **Execution order is `F → H → G → I`** (NOT alphabetical). G's `Backfiller` consumes F's `extractHistoricalStreams` + H's async store + M3's `enqueueRawBatch`; I consumes H's store + the server. `BLEManager` is modified by H4 (async store), then G3 (Backfiller routing), then I4 (Uploader) — in that order.

2. **No new packet types, no schema un-aliasing.** History arrives as **type-43 `REALTIME_RAW_DATA`** (the existing schema already routes 43→`raw_data` and aliases 47 to the same spec). The `raw_data` hook **already parses** the type-43 header HR/R‑R (full-frame `hr_off=21`, `rr_count_off=22`, `rr_first_off=23` — i.e. payload offsets 14/15/16). The only decoder change (F1) is to **surface** those already-computed values into `parsed`, then add a historical extractor (F2/F4) that **routes `REALTIME_RAW_DATA`→HR/RR** (live `extractStreams` deliberately suppresses this to avoid type-40/type-43 double-count; historical has no type-40, so it is correct to emit).

3. **Known vs unknown.** Known (decoded → streams): **HR, R‑R, events, battery**. Unknown (kept raw): IMU accel/gyro arrays, optical/PPG arrays, console logs. We do **not** decode the arrays this milestone.

4. **Trim gate = LOCAL only.** A chunk's destructive `trim` ack is sent **iff** (a) its decoded streams are durably `insert`ed **and** (b) its whole raw frames are durably `enqueueRawBatch`ed — both on the phone. **Never** waits for the server. There is **no `fullyAccounted` byte-decode gate** (the raw is the catch-all). If either local write throws, do **not** ack (chunk re-offloads next connect — idempotent).

5. **Store-writing seams are plain `async` protocols, NOT `@MainActor`.** Define `StoreWriting` (H4: `insert`+`enqueueRawBatch`) and `BackfillStoreWriting` (G2: `insert`+`enqueueRawBatch`+`setCursor`+`cursor`) as non-isolated `protocol …: AnyObject { … async throws … }`. The `WhoopStore` **actor** conforms; `@MainActor` test spies conform too (async witnesses hop actors). If strict concurrency rejects a conformance, adjust isolation here — do **not** force `@MainActor` onto the protocol.

6. **`Streams.empty`:** add `public static let empty = Streams()` to `Streams` in Phase F (F4) — the Backfiller tests use it.

7. **Server, Option A (no decoder drift):** the phone is the only decoder. The decoded upload (`/v1/ingest-decoded`) is authoritative; the raw upload reuses `/v1/ingest` in **archive-only** mode (`decode_streams=false`) so the server never re-decodes phone raw.

## File structure (created/modified)

```
Packages/WhoopProtocol/Sources/WhoopProtocol/PostHooks.swift         MODIFIED: raw_data hook stashes heart_rate/rr_intervals into parsed
Packages/WhoopProtocol/Sources/WhoopProtocol/HistoricalStreams.swift NEW: extractHistoricalStreams
Packages/WhoopProtocol/Sources/WhoopProtocol/HistoricalMeta.swift    NEW: classifyHistoricalMeta
Packages/WhoopProtocol/Sources/WhoopProtocol/Streams.swift           MODIFIED: Streams.empty
Packages/WhoopProtocol/Tests/WhoopProtocolTests/{HistoricalStreamsParityTests,HistoricalMetaTests}.swift  NEW
home-server/packages/whoop-protocol/whoop_protocol/interpreter.py    MODIFIED: raw_data hook stashes hr/rr; + extract_historical_streams
scripts/gen_golden.py                                                MODIFIED: emit historical_frames/golden.json
Packages/WhoopStore/Sources/WhoopStore/{WhoopStore,Database,StreamStore,RawOutbox,Reads}.swift  MODIFIED: class→actor, async; pruneRaw keeps unsynced
Packages/WhoopStore/Sources/WhoopStore/Cursors.swift                 NEW: cursors table accessors
Packages/WhoopStore/Tests/WhoopStoreTests/*                          MODIFIED: async; + CursorTests + pruneRaw-keeps-unsynced test
ios/OpenWhoop/Collect/Backfiller.swift                               NEW; Collector.swift MODIFIED (async)
ios/OpenWhoop/Upload/Uploader.swift, ios/OpenWhoop/Config/{AppConfig,Secrets.example}.{swift,xcconfig}  NEW
ios/OpenWhoop/BLE/BLEManager.swift                                   MODIFIED: send(writeType:), Backfiller wiring, Uploader, async store
ios/project.yml, .gitignore                                          MODIFIED: Secrets config
ios/OpenWhoopTests/{Backfiller,Uploader}Tests.swift                  NEW; CollectorTests MODIFIED (async)
home-server/stacks/whoop/ingest/app/main.py + ingest.py + tests/     MODIFIED: /v1/ingest-decoded + archive-only /v1/ingest
```

---

## Phase F — Historical HR/R-R decode (parity)

F0 (capture) is **done**: `fixtures/historical_capture.bin` (885 KB, 104 chunks, `HISTORY_COMPLETE`). The decoder already parses the type-43 header; this phase surfaces it and adds the historical extractor under M2's byte-parity discipline.

### Task F1: `raw_data` hook surfaces `heart_rate`/`rr_intervals` into `parsed` (both repos)

**Files:**
- Modify: `Packages/WhoopProtocol/Sources/WhoopProtocol/PostHooks.swift` (the `raw_data` hook, ~L178-227)
- Modify: `home-server/packages/whoop-protocol/whoop_protocol/interpreter.py` (the `@_hook("raw_data")` body, ~L176-203)

- [ ] **Step 1: Python — stash hr/rr in `fb.parsed`.** In `_post_raw_data`, inside the `variant["kind"] == "imu"` branch, after the existing `fb.add(...)` calls for `heart_rate`/`rr`, add:
  ```python
          fb.parsed["heart_rate"] = hr
          rr_vals = []
          for i in range(min(rrn, 4)):
              off = variant["rr_first_off"] + i * 2
              v = _read(frame, off, "u16")
              if v is not None:
                  rr_vals.append(v)
          fb.parsed["rr_intervals"] = rr_vals
  ```
  (Keep the existing `fb.add(...)` field annotations; this only ALSO records the values in `parsed`. Replace the existing per-i `fb.add` loop if it duplicates — keep one loop that both `fb.add`s and appends to `rr_vals`.)

- [ ] **Step 2: Swift — mirror it.** In `PostHooks.swift` `raw_data` hook, inside the `variant.kind == "imu"` branch, after the `fb.add` calls, add:
  ```swift
          fb.parsed["heart_rate"] = hr.map { .int($0) }
          var rrVals: [Int] = []
          for i in 0..<min(rrn, 4) {
              let off = rrFirstOff + i * 2
              if let v = u16(frame, off) { rrVals.append(v) }
          }
          fb.parsed["rr_intervals"] = .intArray(rrVals)
  ```

- [ ] **Step 3: Regenerate goldens + run live parity (must stay GREEN).** The change is symmetric (both decoders add the same `parsed` keys to type-43 frames), so live `StreamsParityTests` and `golden.json` parity hold (`extract_streams` ignores type-43).
  ```
  ~/openwhoop/whoop-reader/.venv/bin/python scripts/gen_golden.py
  swift test --package-path Packages/WhoopProtocol
  ```
  Expected: PASS (especially `StreamsParityTests` — live decode unchanged; the new `parsed` keys appear on type-43 frames in both Swift + golden).

- [ ] **Step 4: Commit (both repos).**
  ```
  git add Packages/WhoopProtocol/Sources/WhoopProtocol/PostHooks.swift
  git commit -m "F1: raw_data hook surfaces type-43 heart_rate/rr_intervals into parsed" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  git -C ~/Developer/home-server add packages/whoop-protocol/whoop_protocol/interpreter.py
  git -C ~/Developer/home-server commit -m "F1: raw_data hook surfaces type-43 heart_rate/rr_intervals into parsed" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

### Task F2: Python `extract_historical_streams` reference

**Files:**
- Modify: `home-server/packages/whoop-protocol/whoop_protocol/interpreter.py` (add function next to `extract_streams`, ~L238)

- [ ] **Step 1: Add the reference extractor.** Mirror `extract_streams`, but route `REALTIME_RAW_DATA`→HR/RR (events/battery identical):
  ```python
  def extract_historical_streams(parsed_results, device_clock_ref, wall_clock_ref):
      """Historical offload is the recorded RAW frame stream (no type-40). HR/R-R come
      from REALTIME_RAW_DATA (type 43) headers; events/battery identical to extract_streams.
      Returns {"hr":[...], "rr":[...], "events":[...], "battery":[...]} with wall-clock ts."""
      out = {"hr": [], "rr": [], "events": [], "battery": []}
      for r in parsed_results:
          if not r.get("ok") or r.get("crc_ok") is False:
              continue
          tname = r["type_name"]
          p = r["parsed"]
          if tname == "REALTIME_RAW_DATA":
              ts = _to_wall(p.get("timestamp"), device_clock_ref, wall_clock_ref)
              hr = p.get("heart_rate")
              if ts is not None and hr:
                  out["hr"].append({"ts": ts, "bpm": hr})
              for rr in (p.get("rr_intervals") or []):
                  if ts is not None:
                      out["rr"].append({"ts": ts, "rr_ms": rr})
          elif tname == "EVENT":
              et = p.get("event_timestamp")
              if et is not None:
                  payload = {k: v for k, v in p.items() if k not in ("event", "event_timestamp")}
                  out["events"].append({"ts": et, "kind": p.get("event"), "payload": payload})
          elif tname == "COMMAND_RESPONSE":
              soc = p.get("battery_pct"); mv = p.get("battery_mV")
              if soc is not None or mv is not None:
                  out["battery"].append({"ts": wall_clock_ref, "soc": soc, "mv": mv})
      return out
  ```
  (Confirm the `parsed` key names against `extract_streams` — `timestamp`, `heart_rate`, `rr_intervals`, `event`, `event_timestamp`, `battery_pct`, `battery_mV` — and match them exactly.)

- [ ] **Step 2: Sanity-run on the fixture (throwaway).**
  ```
  cd ~/Developer/home-server
  .venv/bin/python - <<'PY'
  import sys; sys.path.insert(0, "~/openwhoop/whoomp/scripts")
  from whoop_protocol.interpreter import parse_frame, extract_historical_streams
  blob = open("~/openwhoop/fixtures/historical_capture.bin","rb").read()
  def split(b):
      i=0
      while i+4<=len(b):
          if b[i]!=0xAA: i+=1; continue
          L=int.from_bytes(b[i+1:i+3],"little"); e=i+L+4
          if e>len(b): break
          yield b[i:e]; i=e
  parsed=[parse_frame(f) for f in split(blob)]
  s=extract_historical_streams(parsed, 31538447, 1736365593)
  print("hr",len(s["hr"]),"rr",len(s["rr"]),"events",len(s["events"]),"battery",len(s["battery"]))
  print("hr sample", s["hr"][:3])
  PY
  ```
  Expected: ~126 hr rows, ~23 rr, HR values 52–69. (`parse_frame` import path may be `whoop_protocol.interpreter`; adjust if the package layout differs.)

- [ ] **Step 3: Commit (home-server).**
  ```
  git -C ~/Developer/home-server add packages/whoop-protocol/whoop_protocol/interpreter.py
  git -C ~/Developer/home-server commit -m "F2: extract_historical_streams reference (type-43 HR/RR + events/battery)" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

### Task F3: `gen_golden.py` emits historical goldens

**Files:**
- Modify: `scripts/gen_golden.py`

- [ ] **Step 1: Add import + a frame splitter + a historical block.** Add `extract_historical_streams` to the interpreter import line. After the existing streams block, add:
  ```python
  def _split_frames(blob):
      i = 0
      while i + 4 <= len(blob):
          if blob[i] != 0xAA:
              i += 1; continue
          length = int.from_bytes(blob[i + 1:i + 3], "little")
          end = i + length + 4
          if end > len(blob): break
          yield blob[i:end]; i = end

  _HIST = os.path.join(_REPO, "fixtures", "historical_capture.bin")
  if os.path.exists(_HIST):
      hblob = open(_HIST, "rb").read()
      hframes = [bytes(f) for f in _split_frames(hblob)]
      hparsed = [parse_frame(f) for f in hframes]
      keep = [(f, pr) for f, pr in zip(hframes, hparsed)
              if pr.get("ok") and pr["type_name"] in ("REALTIME_RAW_DATA", "EVENT")]
      assert keep, "no historical REALTIME_RAW_DATA/EVENT frames in fixture"
      hstreams = extract_historical_streams([pr for _, pr in keep], _DEVICE_CLOCK_REF, _WALL_CLOCK_REF)
      json.dump([{"hex": f.hex()} for f, _ in keep],
                open(os.path.join(_OUT_DIR, "historical_frames.json"), "w"))
      json.dump(hstreams, open(os.path.join(_OUT_DIR, "historical_golden.json"), "w"))
      print(f"historical_golden.json: frames={len(keep)} hr={len(hstreams['hr'])} rr={len(hstreams['rr'])}")
  ```
  (Use the script's existing `parse_frame`, `_OUT_DIR`, `_REPO`, `_DEVICE_CLOCK_REF`, `_WALL_CLOCK_REF` names — match them.)

- [ ] **Step 2: Run it.**
  ```
  ~/openwhoop/whoop-reader/.venv/bin/python scripts/gen_golden.py
  ```
  Expected: prints `historical_golden.json: frames=… hr=126 rr=23` (approx).

- [ ] **Step 3: Commit the script + the new (tracked) golden resources.** The historical goldens are committed parity artifacts (see Conventions), so the historical parity test passes on a clean checkout.
  ```
  git add scripts/gen_golden.py Packages/WhoopProtocol/Tests/WhoopProtocolTests/Resources/historical_frames.json Packages/WhoopProtocol/Tests/WhoopProtocolTests/Resources/historical_golden.json
  git commit -m "F3: gen_golden emits historical_frames/golden.json from the captured chunk" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

### Task F4: Swift `extractHistoricalStreams` + `Streams.empty` + failing parity test

**Files:**
- Modify: `Packages/WhoopProtocol/Sources/WhoopProtocol/Streams.swift` (add `Streams.empty`)
- Create: `Packages/WhoopProtocol/Tests/WhoopProtocolTests/HistoricalStreamsParityTests.swift`

- [ ] **Step 1: Add `Streams.empty`.** In `Streams.swift`:
  ```swift
  extension Streams { public static let empty = Streams() }
  ```

- [ ] **Step 2: Write the failing parity test.** Create `HistoricalStreamsParityTests.swift` (mirror `StreamsParityTests` structure):
  ```swift
  import XCTest
  @testable import WhoopProtocol

  final class HistoricalStreamsParityTests: XCTestCase {
      private let deviceClockRef = 31_538_447
      private let wallClockRef = 1_736_365_593

      private struct FrameEntry: Decodable { let hex: String }
      private struct HRGold: Decodable, Equatable { let ts: Int; let bpm: Int }
      private struct RRGold: Decodable, Equatable { let ts: Int; let rr_ms: Int }
      private struct HistGold: Decodable { let hr: [HRGold]; let rr: [RRGold] }

      private func resourceURL(_ name: String, _ ext: String) throws -> URL {
          try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext),
                        "missing \(name).\(ext) — run scripts/gen_golden.py (Phase F3)")
      }
      private func bytes(_ s: String) -> [UInt8] {
          var out = [UInt8](); out.reserveCapacity(s.count / 2); var i = s.startIndex
          while i < s.endIndex { let j = s.index(i, offsetBy: 2)
              out.append(UInt8(s[i..<j], radix: 16)!); i = j }
          return out
      }
      func testSwiftHistoricalMatchesPythonGolden() throws {
          let frames = try JSONDecoder().decode(
              [FrameEntry].self, from: Data(contentsOf: resourceURL("historical_frames", "json")))
          let gold = try JSONDecoder().decode(
              HistGold.self, from: Data(contentsOf: resourceURL("historical_golden", "json")))
          let parsed = frames.map { parseFrame(bytes($0.hex)) }
          let streams = extractHistoricalStreams(parsed,
                          deviceClockRef: deviceClockRef, wallClockRef: wallClockRef)
          XCTAssertEqual(streams.hr, gold.hr.map { HRSample(ts: $0.ts, bpm: $0.bpm) })
          XCTAssertEqual(streams.rr, gold.rr.map { RRInterval(ts: $0.ts, rrMs: $0.rr_ms) })
          XCTAssertGreaterThan(streams.hr.count, 0)
      }
  }
  ```

- [ ] **Step 3: Run RED.**
  ```
  swift test --package-path Packages/WhoopProtocol --filter HistoricalStreamsParityTests
  ```
  Expected: FAIL — `extractHistoricalStreams` undefined.

- [ ] **Step 4: Commit the test + Streams.empty.**
  ```
  git add Packages/WhoopProtocol/Sources/WhoopProtocol/Streams.swift Packages/WhoopProtocol/Tests/WhoopProtocolTests/HistoricalStreamsParityTests.swift
  git commit -m "F4: Streams.empty + failing historical parity test" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

### Task F5: Implement `extractHistoricalStreams` (GREEN)

**Files:**
- Create: `Packages/WhoopProtocol/Sources/WhoopProtocol/HistoricalStreams.swift`

- [ ] **Step 1: Implement (byte-parity port of F2).** Mirror `extractStreams`; route `REALTIME_RAW_DATA`→HR/RR. `toWall` is `private` in `Streams.swift`, so recompute the offset inline:
  ```swift
  import Foundation

  /// Historical offload = recorded RAW frame stream (no type-40). HR/R-R from
  /// REALTIME_RAW_DATA (type 43) headers; events/battery identical to extractStreams.
  /// Byte-parity with Python extract_historical_streams.
  public func extractHistoricalStreams(_ parsed: [ParsedFrame],
                                       deviceClockRef: Int, wallClockRef: Int) -> Streams {
      func wall(_ deviceTs: Int?) -> Int? {
          guard let d = deviceTs else { return nil }
          return wallClockRef + (d - deviceClockRef)
      }
      var s = Streams()
      for r in parsed {
          guard r.ok, r.crcOK != false else { continue }
          switch r.typeName {
          case "REALTIME_RAW_DATA":
              guard case .int(let dev)? = r.parsed["timestamp"], let ts = wall(dev) else { continue }
              if case .int(let bpm)? = r.parsed["heart_rate"], bpm > 0 {
                  s.hr.append(HRSample(ts: ts, bpm: bpm))
              }
              if case .intArray(let rrs)? = r.parsed["rr_intervals"] {
                  for rr in rrs { s.rr.append(RRInterval(ts: ts, rrMs: rr)) }
              }
          case "EVENT":
              guard case .int(let et)? = r.parsed["event_timestamp"] else { continue }
              var kind = ""
              if case .string(let k)? = r.parsed["event"] { kind = k }
              var payload = r.parsed
              payload.removeValue(forKey: "event"); payload.removeValue(forKey: "event_timestamp")
              s.events.append(WhoopEvent(ts: et, kind: kind, payload: payload))
          case "COMMAND_RESPONSE":
              var soc: Double? = nil; var mv: Int? = nil
              if case .double(let d)? = r.parsed["battery_pct"] { soc = d }
              if case .int(let i)? = r.parsed["battery_pct"] { soc = Double(i) }
              if case .int(let i)? = r.parsed["battery_mV"] { mv = i }
              if soc != nil || mv != nil {
                  s.battery.append(BatterySample(ts: wallClockRef, soc: soc, mv: mv))
              }
          default: continue
          }
      }
      return s
  }
  ```
  (Match the `ParsedValue` cases + key names to `extractStreams` in `Streams.swift` exactly — especially how `battery_pct` is typed and how `event`/`event_timestamp` are read. Adjust the `case` patterns to the real `ParsedValue` enum.)

- [ ] **Step 2: Run GREEN.**
  ```
  swift test --package-path Packages/WhoopProtocol --filter HistoricalStreamsParityTests
  ```
  Expected: PASS.

- [ ] **Step 3: Commit.**
  ```
  git add Packages/WhoopProtocol/Sources/WhoopProtocol/HistoricalStreams.swift
  git commit -m "F5: extractHistoricalStreams — Swift port, byte-parity with Python golden (GREEN)" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

### Task F6: Full WhoopProtocol suite green (regression gate)

- [ ] **Step 1: Regenerate goldens + run the whole suite.**
  ```
  ~/openwhoop/whoop-reader/.venv/bin/python scripts/gen_golden.py
  swift test --package-path Packages/WhoopProtocol
  ```
  Expected: ALL pass — especially `StreamsParityTests` (live decode unchanged) and `HistoricalStreamsParityTests`.

- [ ] **Step 2: Commit any regenerated goldens (or empty if none changed).** After F1/F3 the goldens should already be current, so this is usually a no-op — but if `git status` shows a changed golden resource, `git add` it (tracked artifact). Then commit:
  ```
  git add Packages/WhoopProtocol/Tests/WhoopProtocolTests/Resources/ 2>/dev/null; true
  git commit --allow-empty -m "F6: full WhoopProtocol suite green (live + historical parity)" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

## Phase H — WhoopStore off the main actor (async actor) + cursors + un-prunable raw

M3 shipped `WhoopStore` as a `final class` doing synchronous GRDB on the caller's thread. Backfill dumps large bursts, so convert it to an `actor` (public API `async`; SQLite work on the actor's executor, off the main thread — `DatabaseQueue` kept, not `DatabasePool`). Add a `cursors` table (`strap_trim` + per-stream upload highwaters), and change `pruneRaw` so **unsynced** raw is never dropped (it is the sole copy of unknown bytes post-trim).

- [ ] **Step H1.1: Baseline build.** `swift build --package-path Packages/WhoopStore` (confirm green). Read `WhoopStore.swift`, `Database.swift`, `StreamStore.swift`, `RawOutbox.swift`, `Reads.swift`. No change.

- [ ] **Step H1.2: Convert `WhoopStore` class → actor; bump schemaVersion to 2.** Replace `Packages/WhoopStore/Sources/WhoopStore/WhoopStore.swift`:
  ```swift
  import Foundation
  import GRDB
  import WhoopProtocol

  public enum WhoopStoreInfo {
      /// Bumped whenever the migrator gains a new migration.
      public static let schemaVersion = 2
  }

  /// WhoopStore is an `actor`: its public API is `async`, and all GRDB work runs on the
  /// actor's serial executor rather than the caller's (the main actor). DatabaseQueue calls
  /// are synchronous-blocking; the actor moves them off the main thread (it does not make them
  /// non-blocking). That is the intended off-main win — DatabaseQueue kept, not DatabasePool.
  public actor WhoopStore {
      let dbQueue: DatabaseQueue
      private init(dbQueue: DatabaseQueue) throws {
          self.dbQueue = dbQueue
          try WhoopStore.makeMigrator().migrate(dbQueue)
      }
      public init(path: String) async throws { try self.init(dbQueue: try DatabaseQueue(path: path)) }
      public static func inMemory() async throws -> WhoopStore { try WhoopStore(dbQueue: try DatabaseQueue()) }

      public func tableNames() async throws -> Set<String> {
          try dbQueue.read { db in
              try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
          }
      }
      public func primaryKeyColumns(_ table: String) async throws -> [String] {
          try dbQueue.read { db in try db.primaryKey(table).columns }
      }
  }
  ```
  Build will fail until H1.3 (expected): `swift build --package-path Packages/WhoopStore 2>&1 | tail -20`.

- [ ] **Step H1.3: Make every instance method in `StreamStore.swift`, `RawOutbox.swift`, `Reads.swift` `async`.** Add `async` to each public instance method touching `dbQueue` (bodies unchanged); the `static` pure helpers (`encodePayload`, `packFrames`, `unpackFrames`, `zlibCompressWithLength`, `zlibDecompressWithLength`, `metaFromRow`) stay synchronous. So: `upsertDevice`, `insert`, `storageStats_rowCountsForTest`, `deviceRowForTest` (StreamStore); `enqueueRawBatch`, `rawFrames`, `pendingRawBatches`, `markRawBatchSynced`, `pruneRaw`, `allBatchIdsForTest` (RawOutbox); `hrSamples`, `rrIntervals`, `events`, `batterySamples`, `storageStats` (Reads) — all gain `async`. Build green, commit:
  ```
  swift build --package-path Packages/WhoopStore 2>&1 | tail -20
  git add -A && git commit -m "H1: WhoopStore class → actor (all methods async; schemaVersion=2)" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

- [ ] **Step H2: Port every WhoopStore test to async.** In `Tests/WhoopStoreTests/`: mark each store-touching test method `async`, `await` every store call, use `try await WhoopStore.inMemory()` / `WhoopStore(path:)`. `ScaffoldTests.testLibraryVersionMarkerPresent` asserts `schemaVersion == 2`; `testGRDBIsLinkedAndUsable` stays sync. `ReadTests.seeded()` becomes `async throws`. Pure helpers stay sync. (Mirror M3 bodies; only add `async`/`await`.)
  ```
  swift test --package-path Packages/WhoopStore 2>&1 | tail -25
  git add -A && git commit -m "H2: port all WhoopStore tests to async/await actor API" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

- [ ] **Step H3: v2 cursors migration + accessors + CursorTests.** First a failing `Tests/WhoopStoreTests/CursorTests.swift`:
  ```swift
  import XCTest
  import GRDB
  @testable import WhoopStore

  final class CursorTests: XCTestCase {
      func testV2CreatesCursorsTable() async throws {
          let store = try await WhoopStore.inMemory()
          XCTAssertTrue(try await store.tableNames().contains("cursors"))
          XCTAssertEqual(try await store.primaryKeyColumns("cursors"), ["name"])
      }
      func testCursorRoundTrips() async throws {
          let store = try await WhoopStore.inMemory()
          XCTAssertNil(try await store.cursor("strap_trim"))
          try await store.setCursor("strap_trim", 12345)
          XCTAssertEqual(try await store.cursor("strap_trim"), 12345)
      }
      func testCursorUpsertsOnConflict() async throws {
          let store = try await WhoopStore.inMemory()
          try await store.setCursor("strap_trim", 1)
          try await store.setCursor("strap_trim", 2)
          XCTAssertEqual(try await store.cursor("strap_trim"), 2)
      }
      func testHighwaterRoundTripsUnderPrefix() async throws {
          let store = try await WhoopStore.inMemory()
          XCTAssertNil(try await store.highwater("hr"))
          try await store.setHighwater("hr", 1_716_400_000)
          XCTAssertEqual(try await store.highwater("hr"), 1_716_400_000)
          XCTAssertEqual(try await store.cursor("highwater:hr"), 1_716_400_000)
      }
      func testHighwaterStreamsAreIndependent() async throws {
          let store = try await WhoopStore.inMemory()
          try await store.setHighwater("hr", 100)
          try await store.setHighwater("rr", 200)
          XCTAssertEqual(try await store.highwater("hr"), 100)
          XCTAssertEqual(try await store.highwater("rr"), 200)
      }
  }
  ```
  Run RED. Then in `Database.swift` register `v2` immediately before `return migrator` (leave `v1` intact):
  ```swift
  migrator.registerMigration("v2") { db in
      try db.create(table: "cursors") { t in
          t.column("name", .text).primaryKey()
          t.column("value", .integer)
      }
  }
  ```
  Create `Packages/WhoopStore/Sources/WhoopStore/Cursors.swift`:
  ```swift
  import Foundation
  import GRDB

  extension WhoopStore {
      public func setCursor(_ name: String, _ value: Int) async throws {
          try dbQueue.write { db in
              try db.execute(sql: """
                  INSERT INTO cursors (name, value) VALUES (?, ?)
                  ON CONFLICT(name) DO UPDATE SET value = excluded.value
                  """, arguments: [name, value])
          }
      }
      public func cursor(_ name: String) async throws -> Int? {
          try dbQueue.read { db in
              try Int.fetchOne(db, sql: "SELECT value FROM cursors WHERE name = ?", arguments: [name])
          }
      }
      public func setHighwater(_ stream: String, _ ts: Int) async throws { try await setCursor("highwater:" + stream, ts) }
      public func highwater(_ stream: String) async throws -> Int? { try await cursor("highwater:" + stream) }
  }
  ```
  GREEN + commit:
  ```
  swift test --package-path Packages/WhoopStore 2>&1 | tail -25
  git add -A && git commit -m "H3: v2 cursors migration + setCursor/cursor/setHighwater/highwater + CursorTests" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

- [ ] **Step H3.5: `pruneRaw` never drops unsynced raw.** Unsynced raw is the sole copy of unknown bytes after trim. First a failing test in `Tests/WhoopStoreTests/` (add to the raw-outbox test file, or a new `PruneRawKeepsUnsyncedTests.swift`):
  ```swift
  func testPruneNeverDropsUnsyncedEvenOverCap() async throws {
      let store = try await WhoopStore.inMemory()
      // Enqueue three unsynced batches well over a tiny cap.
      for i in 0..<3 {
          let meta = RawBatchMeta(batchId: "b\(i)", deviceId: "d", clockRef: ClockRef(device: 0, wall: 0),
                                  capturedAt: i, startTs: 0, endTs: 0, frameCount: 1, byteSize: 1000)
          try await store.enqueueRawBatch(meta, frames: [[0xAA]])
      }
      _ = try await store.pruneRaw(now: 10_000, keepWindowSeconds: 0, maxUnsyncedBytes: 1)
      XCTAssertEqual(try await store.allBatchIdsForTest().count, 3, "unsynced raw must never be pruned")
  }
  ```
  Run RED (current `pruneRaw` Policy 2 drops oldest unsynced). Then in `RawOutbox.swift` `pruneRaw`, **delete Policy 2 entirely** (the `maxUnsyncedBytes` block) — keep only Policy 1 (age out **synced** batches). Update the doc-comment to: "Unsynced raw is never dropped (sole copy of unknown bytes post-trim); only synced batches older than the keep window are removed." **Keep** the `maxUnsyncedBytes` parameter in the signature (callers still pass it) but **ignore it** — do not delete Policy 2's parameter (dropping it would ripple into M3's still-sync call sites before H4 converts them). Add a comment: `// maxUnsyncedBytes intentionally unused: unsynced raw is the sole copy of unknown bytes post-trim and must never be dropped.` GREEN + commit:
  ```
  swift test --package-path Packages/WhoopStore 2>&1 | tail -25
  git add -A && git commit -m "H3.5: pruneRaw never drops unsynced raw (catch-all for unknown bytes)" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

- [ ] **Step H4: Async `StoreWriting` seam + `Collector`/`BLEManager`/`CollectorTests` on the actor store.**
  - In `ios/OpenWhoop/Collect/Collector.swift`, make the seam a **plain async protocol** (integration note 5):
    ```swift
    protocol StoreWriting: AnyObject {
        @discardableResult
        func insert(_ streams: Streams, deviceId: String) async throws -> (hr: Int, rr: Int, events: Int, battery: Int)
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws
    }
    extension WhoopStore: StoreWriting {}
    ```
  - Make `Collector.ingest`/`flush`/`prune`/`storageStats` `async`, `await`ing the store. **Preserve decoded-before-raw** by snapshotting `buffer` into `frames` and clearing it *synchronously before* the first `await` in `flush()`, then `try await store.insert(...)` (catch → re-buffer + return) → `batchStartedAt = monotonic()` → `try? await store.enqueueRawBatch(...)`.
  - In `ios/OpenWhoop/BLE/BLEManager.swift`: `WhoopStore(path:)` is now `async`, so set `collector = nil` (make it `var`) in `init`; add `func bootstrapStore() async` that builds the store + `Collector` once at startup. Wrap async `ingest`/`flush` at delegate call sites in `Task { @MainActor in await … }`; make `pruneRaw()`/`storageStats()` wrap in `Task`/become async.
  - Port `ios/OpenWhoopTests/CollectorTests.swift` to async: `makeStore()` → `async throws` + `await`; every test `async` + `await`; `SpyStore`'s two methods `async throws` + `await wrapped.…`.
  - Build + green:
    ```
    cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -30
    git add -A && git commit -m "H4: async StoreWriting seam + Collector/BLEManager/CollectorTests on the actor store" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
    ```
  (Do NOT git-add `ios/OpenWhoop.xcodeproj` or `Info.plist`. Async test bodies follow M3 CollectorTests with `await` added.)

---

## Phase G — Backfiller + BLE wiring + auto-enable

Drains the strap on every (re)connect. The `Backfiller` (`@MainActor`, unit-tested with a `SpyStore` mirroring `CollectorTests`) owns the **local** safe-trim invariant: decode known → insert decoded → enqueue raw → save cursor → ack `trim`. A chunk is forgotten by the strap only after decoded + raw are both durably stored. CoreBluetooth wiring is build-verify. Assumes F's `extractHistoricalStreams` and H's async store + `enqueueRawBatch`. **METADATA packet type is `49`.**

### G1 — `send(writeType:)` + the historical ack uses `.withResponse`

- [ ] **Step 1: Add `writeType:` to `send`.** In `ios/OpenWhoop/BLE/BLEManager.swift` replace the `send` signature/body so it takes `writeType: CBCharacteristicWriteType = .withoutResponse` and passes it to `p.writeValue(..., type: writeType)`; delete the stale `// TODO(M4)` comment. Add an ack helper:
  ```swift
  /// Ack one HISTORY_END chunk so the strap may trim it. Confirmed write — the strap forgets
  /// the chunk once this lands (link-layer half of safe-trim; decoded + raw already persisted).
  /// Payload mirrors RE struct.pack("<BLL", 1, trim, 0) = [0x01, trim LE32, 0,0,0,0].
  func ackHistoricalTrim(_ trim: UInt32) {
      let trimLE: [UInt8] = [UInt8(trim & 0xFF), UInt8((trim >> 8) & 0xFF),
                             UInt8((trim >> 16) & 0xFF), UInt8((trim >> 24) & 0xFF)]
      send(.historicalDataResult, payload: [0x01] + trimLE + [0, 0, 0, 0], writeType: .withResponse)
  }
  ```
- [ ] **Step 2: Build-verify the app suite.**
  ```
  cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17'
  git add ios/OpenWhoop/BLE/BLEManager.swift
  git commit -m "G1: send(writeType:) + ackHistoricalTrim uses .withResponse" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

### G2 — `classifyHistoricalMeta` + `Backfiller` (TDD, SpyStore)

- [ ] **Step 1: Add `classifyHistoricalMeta` to `WhoopProtocol`.** Create `Packages/WhoopProtocol/Sources/WhoopProtocol/HistoricalMeta.swift`:
  ```swift
  import Foundation
  public enum HistoricalMeta: Equatable { case start; case end(unix: UInt32, trim: UInt32); case complete; case other }
  public func classifyHistoricalMeta(_ p: ParsedFrame) -> HistoricalMeta {
      guard p.typeName == "METADATA" else { return .other }
      let metaName: String? = {
          if case .string(let s)? = p.fields.first(where: { $0.name == "meta_type" })?.value { return s }
          return nil
      }()
      switch metaName {
      case "HISTORY_START":    return .start
      case "HISTORY_COMPLETE": return .complete
      case "HISTORY_END":
          guard case .int(let unix)? = p.parsed["unix"], case .int(let trim)? = p.parsed["trim_cursor"]
          else { return .other }
          return .end(unix: UInt32(truncatingIfNeeded: unix), trim: UInt32(truncatingIfNeeded: trim))
      default: return .other
      }
  }
  ```
  (Confirm the `meta_type`/`unix`/`trim_cursor` field names against the schema + metadata PostHook; adjust if they differ. Per F0, HISTORY_END payload is `<LHLL>` = unix u32, subsec u16, unk u32, trim u32 — make sure the metadata hook exposes `unix` and `trim_cursor` accordingly, else read the raw payload.)

- [ ] **Step 2: Parity test `HistoricalMetaTests.swift`** building real METADATA frames with the package's own framer (**packet type `49`**), asserting `.start`/`.end(unix:trim:)`/`.complete`/`.other`. Run RED→GREEN: `swift test --package-path Packages/WhoopProtocol --filter HistoricalMetaTests`. Commit classifier + test:
  ```
  git add Packages/WhoopProtocol/Sources/WhoopProtocol/HistoricalMeta.swift Packages/WhoopProtocol/Tests/WhoopProtocolTests/HistoricalMetaTests.swift
  git commit -m "G2.1: classifyHistoricalMeta + parity test" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

- [ ] **Step 3: Write failing `Backfiller` tests** `ios/OpenWhoopTests/BackfillerTests.swift`. Use a `SpyBackfillStore` (`@MainActor`) recording `insert`/`enqueueRawBatch`/`setCursor`/`ackTrim`, and an injected `extract` closure (no real golden). Build scripted frames with a `metaFrame(_ metaType:_ payload:)` helper (**packet type `49`**). Cover:
  - clean chunk → `insert` once + `enqueueRawBatch` once + `setCursor("strap_trim", …)` + `ackTrim` once, in that order;
  - `insert` throws → no enqueue, no cursor, **no ack**;
  - `enqueueRawBatch` throws → no cursor, **no ack** (decoded already inserted is fine — re-offload dedupes);
  - multi-chunk → acks in order, then `HISTORY_COMPLETE` exits backfilling;
  - timeout → exits without acking;
  - payload-before-START → no-op.
  (Use `Streams.empty` for the stub extract result.)

- [ ] **Step 4: Implement `Backfiller`** `ios/OpenWhoop/Collect/Backfiller.swift`:
  ```swift
  import Foundation
  import WhoopProtocol
  import WhoopStore

  /// The async subset the Backfiller needs (Phase H actor). Plain async protocol (not @MainActor).
  protocol BackfillStoreWriting: AnyObject {
      @discardableResult
      func insert(_ streams: Streams, deviceId: String) async throws -> (hr: Int, rr: Int, events: Int, battery: Int)
      func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws
      func setCursor(_ name: String, _ value: Int) async throws
      func cursor(_ name: String) async throws -> Int?
  }
  extension WhoopStore: BackfillStoreWriting {}

  /// Historical-offload state machine (idle / backfilling). Per chunk the LOCAL safe-trim invariant:
  /// decode known → await insert (decoded durable) → await enqueueRawBatch (raw durable) →
  /// await setCursor(strap_trim) → ackTrim. A chunk is forgotten only after decoded AND raw are
  /// both locally durable AND the ack (.withResponse) is link-layer confirmed. Never waits on server.
  @MainActor
  final class Backfiller {
      typealias Extractor = ([ParsedFrame], Int, Int) -> Streams
      private let store: BackfillStoreWriting
      private let deviceId: String
      private let ackTrim: (UInt32) -> Void
      private let extract: Extractor
      var clockRef: ClockRef?
      private(set) var isBackfilling = false
      private var chunk: [[UInt8]] = []
      private var chunkOpen = false

      init(store: BackfillStoreWriting, deviceId: String,
           ackTrim: @escaping (UInt32) -> Void,
           extract: @escaping Extractor = { extractHistoricalStreams($0, deviceClockRef: $1, wallClockRef: $2) }) {
          self.store = store; self.deviceId = deviceId
          self.ackTrim = ackTrim; self.extract = extract
      }
      func begin() { isBackfilling = true; chunk.removeAll(keepingCapacity: true); chunkOpen = false }
      func ingest(_ frame: [UInt8]) async {
          switch classifyHistoricalMeta(parseFrame(frame)) {
          case .start: isBackfilling = true; chunk.removeAll(keepingCapacity: true); chunkOpen = true
          case .end(let unix, let trim): await finishChunk(unix: unix, trim: trim)
          case .complete: isBackfilling = false; chunk.removeAll(keepingCapacity: true); chunkOpen = false
          case .other: if chunkOpen { chunk.append(frame) }
          }
      }
      private func finishChunk(unix: UInt32, trim: UInt32) async {
          defer { chunk.removeAll(keepingCapacity: true); chunkOpen = false }
          guard chunkOpen, !chunk.isEmpty, let ref = clockRef else { return }
          let frames = chunk
          let parsed = frames.map { parseFrame($0) }
          let decoded = extract(parsed, ref.device, ref.wall)
          // 1) decoded durable
          do { try await store.insert(decoded, deviceId: deviceId) } catch { return }
          // 2) raw durable (whole chunk frames) — meta mirrors the live RawOutbox shape
          let meta = RawBatchMeta(
              batchId: "hist-\(deviceId)-\(trim)", deviceId: deviceId, clockRef: ref,
              capturedAt: Int(Date().timeIntervalSince1970),
              startTs: ref.wall, endTs: ref.wall, frameCount: frames.count,
              byteSize: frames.reduce(0) { $0 + $1.count })
          do { try await store.enqueueRawBatch(meta, frames: frames) } catch { return }
          // 3) cursor then ack (local persistence complete)
          do { try await store.setCursor("strap_trim", Int(trim)) } catch { return }
          ackTrim(trim)
      }
      func timeoutFired() { isBackfilling = false; chunk.removeAll(keepingCapacity: true); chunkOpen = false }
  }
  ```
  Run Backfiller tests RED→GREEN, then full app suite green. Commit `Backfiller.swift` + `BackfillerTests.swift`:
  ```
  cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -30
  git add ios/OpenWhoop/Collect/Backfiller.swift ios/OpenWhoopTests/BackfillerTests.swift
  git commit -m "G2: Backfiller — decode→insert→enqueueRaw→cursor→ack (local safe-trim)" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

### G3 — Wire the Backfiller into `BLEManager` (build-verify)

- [ ] **Step 1: Own a `Backfiller` + routing flags.** Add to `BLEManager`: `private var backfiller: Backfiller?`, `private var backfilling = false`, `private var backfillTimeout: DispatchWorkItem?`, `private var backfillStarted = false`, `private var store: WhoopStore?` (shared by Collector + Backfiller, both created in `bootstrapStore()` from H4). `makeBackfiller(store:)` factory with `ackTrim: { [weak self] in self?.ackHistoricalTrim($0) }`.
- [ ] **Step 2: Route custom-char frames while backfilling** (in `didUpdateValueFor`): run clock correlation in BOTH modes (set `collector?.clockRef` AND `backfiller?.clockRef`); if `backfilling`, `armBackfillTimeout()` and `Task { @MainActor in await backfiller?.ingest(frame); self.afterBackfillIngest() }`; else the normal live path. Add `afterBackfillIngest()` (if `!backfiller.isBackfilling && backfilling` → `exitBackfilling("HISTORY_COMPLETE")`), `armBackfillTimeout()` (~20 s → `backfiller?.timeoutFired()` + `exitBackfilling("timeout")`), `exitBackfilling(reason:)` (clear flag + timeout, `log`, `send(.toggleRealtimeHR, payload: [0x01])`). (I5 later adds a `uploadOpportunistically()` call here — do not reference it yet.)
- [ ] **Step 3: Orchestrate connect.** In `didWriteValueFor`, after the existing clock-request block, on first bond confirmation (`!backfillStarted`): set it, `send(.stopRawData, payload: [0x01])`, `send(.getDataRange)`, then `beginBackfill()` (`backfiller?.begin()`; `backfilling = true`; `send(.sendHistoricalData, payload: [0x00], writeType: .withResponse)`; `armBackfillTimeout()`; if no backfiller, just `send(.toggleRealtimeHR, payload:[0x01])`). Reset `backfillStarted=false`, `backfilling=false`, cancel timeout in `didDisconnectPeripheral`. (A chunk arriving before `clockRef` is set simply isn't acked and re-offloads next connect — safe.)
- [ ] **Step 4: Build + full app suite green.** Commit `BLEManager.swift` (never xcodeproj/Info.plist):
  ```
  cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17'
  git add ios/OpenWhoop/BLE/BLEManager.swift
  git commit -m "G3: wire Backfiller into BLEManager (routing, connect orchestration, auto Stop-Raw/Start-HR)" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

## Phase I — Hybrid upload (decoded + raw) + server endpoints

The `Uploader` runs two idempotent drains when online: **decoded** (per-stream rows newer than `highwater`, advance highwater on 2xx) and **raw** (`pendingRawBatches` → archive-only `/v1/ingest` → `markRawBatchSynced` on 2xx). Server gains `POST /v1/ingest-decoded` (no decode) and an archive-only switch on `/v1/ingest` (no re-decode → no drift). Reachability is "try on connect/after-backfill, retry next opportunity"; secret/base-URL live in a gitignored xcconfig.

### I1: Server `POST /v1/ingest-decoded` (TDD, home-server)

- [ ] **Step 1: Failing API test** `home-server/stacks/whoop/ingest/tests/test_ingest_decoded_api.py` (mirror `test_ingest_api.py`'s `client` fixture + `requires_docker`): 401 without auth; with `Bearer secret`, POST `{device:{id,mac,name}, streams:{hr:[{ts,bpm}…], rr:[{ts,rr_ms}], events:[{ts,kind,payload}], battery:[{ts,soc,mv}]}}` → 200 `{"upserted":{"hr":2,"rr":1,"events":1,"battery":1}}`, re-POST idempotent, partial body (only `hr`) → `{"hr":1,"rr":0,"events":0,"battery":0}`. Run RED: `cd ~/Developer/home-server/stacks/whoop/ingest && python -m pytest tests/test_ingest_decoded_api.py -q` (404).
- [ ] **Step 2: Implement** in `app/main.py`: add `DecodedDevice`/`DecodedStreams`/`DecodedBatch` Pydantic models + `@app.post("/v1/ingest-decoded", dependencies=[Depends(require_auth)])` that opens a conn, `store.ensure_device(conn, …)` + `store.upsert_streams(conn, device_id, streams)` (reuse existing helpers), commits, returns `{"upserted": counts}`. Add `store` to the `from . import …` line. Run GREEN; run the full ingest suite (`python -m pytest -q`); commit (home-server):
  ```
  git -C ~/Developer/home-server add stacks/whoop/ingest/app/main.py stacks/whoop/ingest/tests/test_ingest_decoded_api.py
  git -C ~/Developer/home-server commit -m "I1: POST /v1/ingest-decoded (no decode; reuse upsert_streams)" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

### I2: Archive-only `/v1/ingest` (TDD, home-server)

- [ ] **Step 1: Failing test** in `tests/test_ingest_api.py` (or a new file): POST a raw batch with `decode_streams=false` → 200, the raw is archived (a row in `raw_batches`, `/v1/batches/{id}/frames` returns the frames) but **no** decoded rows are upserted (`/v1/streams/hr?device=…` count unchanged). Run RED.
- [ ] **Step 2: Implement.** In `app/main.py` add `decode_streams: bool = True` to the `IngestBatch` model. In `app/ingest.py` `process_batch(...)`, guard the decode/upsert section: `if batch.get("decode_streams", True): parsed = …; streams = extract_streams(…); counts = store.upsert_streams(…)` else skip decode and return `{"upserted": {}, "archived": meta}`. The raw archive always runs. Run GREEN; full suite; commit:
  ```
  git -C ~/Developer/home-server add stacks/whoop/ingest/app/main.py stacks/whoop/ingest/app/ingest.py stacks/whoop/ingest/tests/
  git -C ~/Developer/home-server commit -m "I2: /v1/ingest archive-only mode (decode_streams=false) — no re-decode of phone raw" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

### I3: Gitignored secrets config + project.yml + `AppConfig` (build-verify)

- [ ] Create committed template `ios/OpenWhoop/Config/Secrets.example.xcconfig` (`WHOOP_BASE_URL`, `WHOOP_API_KEY`, using the `https:/$()/host` trick so `//` isn't an xcconfig comment); create the real gitignored `ios/OpenWhoop/Config/Secrets.xcconfig`; append it to `.gitignore`; verify `git check-ignore` hides it. Wire `configFiles: {Debug,Release: OpenWhoop/Config/Secrets.xcconfig}` on the `OpenWhoop` target in `ios/project.yml` + `info.properties` `WHOOP_BASE_URL: $(WHOOP_BASE_URL)` / `WHOOP_API_KEY: $(WHOOP_API_KEY)`. Add `ios/OpenWhoop/Config/AppConfig.swift` reading those Info.plist keys into an optional `UploaderConfig` (nil/placeholder → no upload). Build-verify (defer build to end of I4 if `UploaderConfig` isn't defined yet). Commit template + gitignore + project.yml + AppConfig only (NEVER the real `Secrets.xcconfig`/xcodeproj/Info.plist):
  ```
  git add ios/OpenWhoop/Config/Secrets.example.xcconfig ios/OpenWhoop/Config/AppConfig.swift ios/project.yml .gitignore
  git commit -m "I3: gitignored Secrets.xcconfig + AppConfig/UploaderConfig wiring" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

### I4: The `Uploader` — decoded + raw drains (TDD with `URLProtocol` stub + in-memory store)

- [ ] **Step 1: Failing test** `ios/OpenWhoopTests/UploaderTests.swift` with a `StubURLProtocol` (captures request bodies + URL, returns scripted status) on an ephemeral `URLSession`, and an in-memory store seeded via `try await store.insert(Streams(hr: [...], rr: [...]), deviceId: "devA")` and `try await store.enqueueRawBatch(meta, frames: …)` (`try await WhoopStore.inMemory()`). Assert:
  - **decoded drain:** a 200 POSTs hr + rr once each (battery/events empty → no POST) to `…/v1/ingest-decoded`, advances `highwater("hr")`/`("rr")` to last ts; hr body shape `{device:{id:"devA"}, streams:{hr:[{ts,bpm}…]}}`; a 500 leaves highwater nil; a second drain after success is a no-op.
  - **raw drain:** a 200 POSTs each pending batch to `…/v1/ingest` with `decode_streams=false`, then `markRawBatchSynced` (so `pendingRawBatches` becomes empty); a 500 leaves it pending.
  Run RED.
- [ ] **Step 2: Implement** `ios/OpenWhoop/Upload/Uploader.swift`: `struct UploaderConfig {baseURL; apiKey}` and `final class Uploader` with `drain()` calling `drainDecoded()` then `drainRaw()`.
  - `drainDecoded()`: per stream (`hr`,`rr`,`events`,`battery`) read `highwater(stream) ?? Int.min`, fetch rows `from: after+1, to: .max, limit: 5000`, map to wire shape (`hr`→`{ts,bpm}`, `rr`→`{ts,rr_ms}`, `events`→`{ts,kind,payload}`, `battery`→`{ts,soc?,mv?}`), POST `{device:{id,name}, streams:{<stream>: rows}}` with `Authorization: Bearer <key>` to `baseURL/v1/ingest-decoded`; on 2xx `setHighwater(stream, rows.last!.ts)`.
  - `drainRaw()`: `pendingRawBatches(limit: 20)`; for each, `rawFrames(batchId:)` → POST `{device:{id}, decode_streams:false, frames:[{hex}…], clock_ref:{device,wall}, batch_id}` (match the existing `/v1/ingest` `IngestBatch` shape) to `baseURL/v1/ingest`; on 2xx `markRawBatchSynced(batchId:, at: now)`.
  Run GREEN; commit `Uploader.swift` + `UploaderTests.swift` (never xcodeproj/Info.plist):
  ```
  cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -30
  git add ios/OpenWhoop/Upload/Uploader.swift ios/OpenWhoopTests/UploaderTests.swift
  git commit -m "I4: Uploader — idempotent decoded + raw drains (highwater/syncedAt on 2xx)" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

### I5: Wire `uploader.drain()` into connect / post-backfill (build-verify)

- [ ] Add `private let uploader: Uploader?` to `BLEManager`; construct from `AppConfig.uploaderConfig(deviceId:)` + the shared `WhoopStore` (nil if unconfigured); `self.uploader = nil` in the test init. Add `private func uploadOpportunistically() { guard let uploader else { return }; Task { await uploader.drain() } }`. Call it on the connect path (in `didWriteValueFor` after the clock block) **and** at G3's `exitBackfilling` (post-backfill). Build + suite green; commit `BLEManager.swift`:
  ```
  cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17'
  git add ios/OpenWhoop/BLE/BLEManager.swift
  git commit -m "I5: wire uploadOpportunistically() into connect + post-backfill" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

### I6: Cloudflare tunnel route (ops / build-verify with curl)

- [ ] On jpserver: add a `cloudflared` ingress rule routing `whoop.<domain>` → the whoop-ingest service host:port (covers `/v1/ingest` + `/v1/ingest-decoded`; Bearer auth is the access control), `cloudflared tunnel route dns <tunnel> whoop.<domain>`, `cloudflared tunnel ingress validate`, restart the tunnel. Verify: `curl -sS https://whoop.<domain>/healthz` → `{"status":"ok"}`; `curl -sS -X POST https://whoop.<domain>/v1/ingest-decoded -H "Authorization: Bearer <key>" -H "Content-Type: application/json" -d '{"device":{"id":"my-whoop"},"streams":{"hr":[]}}'` → `{"upserted":{"hr":0,…}}`. Then set the real `WHOOP_BASE_URL`/`WHOOP_API_KEY` in the gitignored `Secrets.xcconfig`, rebuild onto the device, confirm decoded rows AND raw batches appear in the dashboard. No code commit (ops + on-device acceptance).

---

## Exit criteria

- **Decode:** `extractHistoricalStreams` is Python-parity-proven over the real captured chunk (HR 52–69 across the window); live decode (`StreamsParityTests`) unregressed.
- **Backfill (offline-safe):** on (re)connect the strap drains into the local store as decoded streams (correct wall-clock ts) **and** raw batches; a chunk's `trim` is acked only after **both** decoded and raw are locally durable; with **no server reachable**, capture+decode+store+trim still proceed; interrupted backfill resumes losslessly (decoded dedupes by `(device,ts)`, raw by `batch_id`); live HR resumes after backfill; the type-43 flood is stopped during backfill. Verified on-device (SQLite pull: a phone-off gap fills + `strap_trim` advances).
- **Off-main:** `WhoopStore` is an `async actor`; WhoopStore + app suites green; UI doesn't jank during a large backfill; **unsynced raw is never pruned**.
- **Upload:** decoded streams reach `/v1/ingest-decoded` and raw batches reach archive-only `/v1/ingest`; idempotent + retried; highwaters/`syncedAt` advance only on 2xx; the server does **not** re-decode phone raw; trim never depends on the server. Tunnel verified by curl.
- **Hygiene:** the fixture `.bin`, real `Secrets.xcconfig`, and generated xcodeproj/Info.plist/golden JSON are never committed; all commits carry the `Co-Authored-By` trailer.

**Deferred to the next plan (M5 read-path):** pull decoded streams back, History = union(phone, server), fresh-reinstall cloud restore, read-auth on read endpoints. **Future milestone:** decode IMU accel/gyro + optical/PPG arrays + console logs on the phone, then **retire raw upload** (app sends only decoded).
