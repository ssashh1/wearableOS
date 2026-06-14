# OpenWhoop iOS — M4 + M5 write-path: Historical Backfill + Decoded Upload — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On every (re)connect, drain the WHOOP strap's onboard history buffer into the local store as **decoded** streams (HR/R‑R + whatever the RE reveals), preserving the safe-trim invariant, then push those decoded streams to the server — completing the 24/7 write path without sending raw bytes to the server.

**Architecture:** The phone is the decoding middle-man: it decodes once and uploads **decoded** (no raw round-trip, no server-side decode). Phase **F** reverse-engineers + decodes the historical payload (Python reference → Swift byte-parity). Phase **H** moves `WhoopStore` off the main actor (it becomes an `async actor`) so large backfill writes never jank the UI, and adds a cursors table. Phase **G** adds the `Backfiller` state machine (the safe-trim invariant: a chunk's destructive `trim` is acked only after its decoded streams are stored **and** every byte is accounted for) and wires it into `BLEManager` with auto Stop‑Raw/Start‑HR. Phase **I** adds an `Uploader` + a new server `POST /v1/ingest-decoded` + the Cloudflare tunnel route.

**Tech Stack:** Swift 6.3 / Xcode 26.4, SwiftPM, GRDB.swift 6.29.3, XcodeGen, SwiftUI, CoreBluetooth, XCTest; Python 3 (`whoop_protocol`) for the historical decode reference + parity; FastAPI + TimescaleDB (home-server). iOS simulator = **iPhone 17**; device build = **iPhone 16 Pro** (udid `<DEVICE_UDID>`, team `<TEAM_ID>`).

**Spec:** `docs/specs/2026-05-23-openwhoop-m4-historical-backfill-design.md`. **Builds on** Plan 1 (foundation) and Plan 2 / M3 (`docs/plans/2026-05-23-openwhoop-m3-local-store.md`) — both complete + hardware-verified.

---

## Conventions

- **TDD where testable** (failing test → run-fail → implement → run-pass → commit); **parity** for the historical decoder (Python reference is the source of truth, Swift matches byte-for-byte); CoreBluetooth + tunnel are **build-verify** (no radio/network in tests).
- **Commit after every task**, ending each commit message with a second `-m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"`. Commit directly on `main` (this repo's established workflow).
- **Two repos:** the app/decoder/spec live in `~/openwhoop`; the server lives in `~/Developer/home-server` (Phase I's server tasks commit there).
- **Package tests:** `swift test --package-path Packages/WhoopProtocol` (and `…/WhoopStore`). **App build/tests:** `cd ios && xcodegen generate && xcodebuild [test] -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17'`.
- **Never `git add`** the generated `ios/OpenWhoop.xcodeproj`, `ios/OpenWhoop/Info.plist`, the generated golden JSON test resources, or the real `ios/OpenWhoop/Config/Secrets.xcconfig` (all git-ignored; `project.yml`/`gen_golden.py`/templates are the sources of truth).
- **The decoded-only + safe-trim principle:** capture is decoded-only (no raw to the server for this data). A chunk's destructive `trim` is acked **only after** its decoded streams are durably stored **and** the decoder accounts for **every** byte of the chunk (`fullyAccounted`). A chunk with unmapped bytes is **never trimmed** — left on the strap, flagged for RE. Trim never depends on the server.

## Cross-phase integration notes (READ FIRST)

These reconcile the four phases; they override anything in a phase section that conflicts.

1. **Execution order is `F → H → G → I`** (NOT alphabetical). Phase G's `Backfiller` consumes Phase F's `extractHistoricalStreams` and Phase H's async store; Phase I consumes Phase H's store + the server. `BLEManager` is modified by H4 (async store), then G3 (Backfiller routing), then I4 (Uploader) — in that order.

2. **Packet types (verified against `protocol/whoop_protocol.json`):** `REALTIME_DATA=40`, `REALTIME_RAW_DATA=43`, `HISTORICAL_DATA=47` (today aliased under `REALTIME_RAW_DATA.aliases=[47]` — F0 un-aliases it), `EVENT=48`, `METADATA=49`, `HISTORICAL_IMU_DATA_STREAM=52`. `MetadataType`: `1=HISTORY_START, 2=HISTORY_END, 3=HISTORY_COMPLETE`. **Correction to Phase G:** every metadata-frame builder/literal in G uses the METADATA packet type **`49`**, not `47` (47 is HISTORICAL_DATA). F0 must also inventory whether historical includes **type‑52** `HISTORICAL_IMU_DATA_STREAM` frames (a strong candidate for the "more than HR/R‑R" data) — if present, decode them too or, per safe-trim, do not trim chunks containing bytes we can't account for.

3. **Store-writing seams are plain `async` protocols, NOT `@MainActor`.** Define both `StoreWriting` (Phase H, `insert`+`enqueueRawBatch`) and `BackfillStoreWriting` (Phase G, `insert`+`setCursor`+`cursor`) as non-isolated `protocol …: AnyObject { … async throws … }`. The `WhoopStore` **actor** conforms (its `async` methods satisfy the async requirements), and the `@MainActor` test spies conform too (async witnesses hop actors). If strict concurrency rejects a conformance, adjust isolation here — do **not** force `@MainActor` onto the protocol. The conformances live with their protocols: `extension WhoopStore: StoreWriting {}` in Phase H (H4); `extension WhoopStore: BackfillStoreWriting {}` in Phase G (Backfiller.swift, G2).

4. **`Streams.empty`:** add `public static let empty = Streams()` to `Streams` in Phase F (F2) — the Backfiller tests use it. (Equivalent to the all-defaults `Streams()`.)

5. **Activity/steps is conditional on F0's discovery.** HR/R‑R/events/battery are the guaranteed baseline. **If F0 identifies an activity/step family (or decodes type‑52 IMU history):** the ripple is — F adds `ActivitySample` + `Streams.activity`; H adds an `activitySample` table migration + insert handling and the `insert` return tuple gains an `activity` count; I adds an `activity` upload stream + the server `/v1/ingest-decoded` handling + a server table. We cannot pre-write code for a field we have not found; F0 documents the fields and these additions are made when F0 confirms them. Every phase's task code below shows the HR/R‑R/events/battery baseline; extend it per F0.

6. **Phase I test fixes (apply when writing I3's test):** seed the in-memory store via `try await store.insert(Streams(hr: [...], rr: [...]), deviceId: "devA")` (there is no `insertHR`/`insertRR`), and use `try await WhoopStore.inMemory()` (async, Phase H).

## File structure (created/modified)

```
Packages/WhoopProtocol/Sources/WhoopProtocol/HistoricalStreams.swift   NEW: extractHistoricalStreams + HistoricalExtract (+ActivitySample if F0)
Packages/WhoopProtocol/Sources/WhoopProtocol/HistoricalMeta.swift      NEW: classifyHistoricalMeta (reuses metadata PostHook)
Packages/WhoopProtocol/Sources/WhoopProtocol/{Streams,PostHooks}.swift MODIFIED: HistoricalExtract/Streams.empty; historical_data hook
Packages/WhoopProtocol/Sources/WhoopProtocol/Resources/whoop_protocol.json  MODIFIED: HISTORICAL_DATA packet spec; un-alias 47
protocol/whoop_protocol.json                                           MODIFIED: same (canonical)
home-server/packages/whoop-protocol/whoop_protocol/interpreter.py      MODIFIED: historical_data hook + extract_historical_streams (reference)
scripts/gen_golden.py                                                  MODIFIED: emit historical_frames/golden.json
fixtures/historical_capture.bin                                        NEW: a captured historical chunk (committed)
Packages/WhoopStore/Sources/WhoopStore/{WhoopStore,Database,StreamStore,RawOutbox,Reads}.swift  MODIFIED: class→actor, async
Packages/WhoopStore/Sources/WhoopStore/Cursors.swift                   NEW: cursors table accessors
Packages/WhoopStore/Tests/WhoopStoreTests/*                            MODIFIED: async; + CursorTests
ios/OpenWhoop/Collect/{Backfiller}.swift                               NEW; Collector.swift MODIFIED (async)
ios/OpenWhoop/Upload/Uploader.swift, ios/OpenWhoop/Config/{AppConfig,Secrets.example}.{swift,xcconfig}  NEW
ios/OpenWhoop/BLE/BLEManager.swift                                     MODIFIED: send(writeType:), Backfiller wiring, Uploader, async store
ios/project.yml, .gitignore                                            MODIFIED: WhoopStore already present; add Secrets config
ios/OpenWhoopTests/{Backfiller,Uploader}Tests.swift, …                 NEW; CollectorTests MODIFIED (async)
home-server/stacks/whoop/ingest/app/main.py + tests/                   MODIFIED: POST /v1/ingest-decoded
```

---

## Phase F — Historical payload decode (RE-first + Swift parity)

The historical-offload *loop* (`SEND_HISTORICAL_DATA` → per-chunk `HISTORY_START`/payload/`HISTORY_END(trim)` → ack → `HISTORY_COMPLETE`) is already proven end-to-end in `re/hist_raw_test.py` and `re/re_harness.py`, but the **payload body has never been parsed** — its byte layout, per-record timestamp scheme, and full field inventory (HR/R-R confirmed; step/activity-type recalled; possible type‑52 IMU history) are genuine unknowns. So this phase opens with a hands-on RE spike (**F0**) that captures a real chunk and produces a *Python reference decoder* (`extract_historical_streams`) proven on those bytes; F1+ then port that reference to Swift under the same byte-parity discipline that de-risked the live decoder (`StreamsParityTests` / `gen_golden.py`). **The Python reference is the source of truth; Swift must match it byte-for-byte. No byte offset below is invented — every concrete offset Swift uses comes from whatever F0 establishes.**

A structural note: in `protocol/whoop_protocol.json` the packet-type byte **47** (`HISTORICAL_DATA`) is currently an **alias of `REALTIME_RAW_DATA`** (`"aliases": [47]`), so today type-47 frames parse through the `raw_data` post-hook, not a historical one. F0 gives `HISTORICAL_DATA` its own packet spec + post-hook so the historical body is parsed as itself.

- [ ] **Step F0: RE spike — capture a real historical chunk on-device and reverse-engineer its payload into a Python reference decoder.** *(Exploratory/collaborative: the loop is mechanical, but the body parse is hands-on RE. Definition of done is concrete and below; the specific offsets are the discovery.)*

  **F0.a — Capture raw historical bytes from the strap.** Reuse the proven offload harness against the live strap (it must hold un-trimmed history — don't run a normal app session that drains it first):
  ```
  ~/openwhoop/whoop-reader/.venv/bin/python re/hist_raw_test.py
  ```
  Expect `META: …HISTORY_START`, repeated `HISTORY_END` acks, then `>>> HISTORY_COMPLETE`. Only a run reaching `HISTORY_COMPLETE` (or a clean known boundary) is usable. Preserve it:
  ```
  cp ~/openwhoop/whoop_hist.bin ~/openwhoop/fixtures/historical_capture.bin
  ```

  **F0.b — Inventory the payload, field by field.** Each captured record is a type-**47** (and possibly type‑**52** `HISTORICAL_IMU_DATA_STREAM`) frame inside the standard envelope (`0xAA`, `<u16 length>`, `crc8`, `packet_type`, `seq`, … payload …, `crc32`). Work inside the verified envelope only. Determine and **write down** (this becomes the spec's field map):
  - Per-record structure (one record/frame vs many fixed-width records packed per frame).
  - The **timestamp scheme**: self-timestamped per record, or derived from the chunk's `HISTORY_END` unix + per-record offset/cadence. (`HISTORY_END` payload is `<LHLL>` = `unix u32, subsec u16, unk0 u32, trim u32`.)
  - Every field `(off, len, dtype, meaning)`: HR + R-R, and **look for step counts / activity-type / kcal / strain inputs**, and inspect any type‑52 frames.
  - **Byte accounting:** sum the spans of identified fields per record vs the record width. Note any trailing/interior unmapped bytes — these define "not fully accounted."

  **F0.c — Extend the canonical schema with a `HISTORICAL_DATA` packet spec.** In **`protocol/whoop_protocol.json`** add a `"packets"` entry for type 47 (mirror `REALTIME_DATA`'s shape: `"type": 47`, `"fields": [ … static fields at F0.b offsets … ]`, `"post": "historical_data"`) and **remove `47` from `REALTIME_RAW_DATA`'s `"aliases"`**. (If type‑52 carries historical IMU, give it a spec too.) Mirror the edit verbatim into **`Packages/WhoopProtocol/Sources/WhoopProtocol/Resources/whoop_protocol.json`**.

  **F0.d — Add the `historical_data` post-hook + `extract_historical_streams` to the Python interpreter.** In **`home-server/packages/whoop-protocol/whoop_protocol/interpreter.py`**:
  - Register `@_hook("historical_data")` that `fb.add(...)`s every field at the F0.b offsets into `fb.parsed` (e.g. `heart_rate`, `rr_intervals`, and any `steps`/`activity`), and records an explicit **consumed-byte count** vs the record width.
  - Add `extract_historical_streams(parsed_results, device_clock_ref, wall_clock_ref)` modeled on `extract_streams`: skip `not ok`/`crc_ok is False`, map device/anchor timestamps to wall-clock via `_to_wall`, build the stream rows, and return:
    ```python
    {"hr": [...], "rr": [...], "events": [...], "battery": [...],
     "activity": [...],            # only if F0.b found the family; else omit
     "fully_accounted": True/False}  # True iff EVERY in-scope frame's payload fully consumed by known fields
    ```
  - Define `fully_accounted` *in code* (track consumed vs payload_len per frame; OR-reduce across frames).

  **F0.e — Prove the reference on the captured bytes.** A throwaway driver reads `fixtures/historical_capture.bin`, runs `parse_frame` + `extract_historical_streams`, prints the streams + `fully_accounted`; eyeball HR plausibility, timestamps inside the `GET_DATA_RANGE` window, sane step/activity, and a believable `fully_accounted`. **Done when:** (1) `fixtures/historical_capture.bin` committed; (2) field map written into the spec's "Open questions"; (3) the schema (both copies) has a real `HISTORICAL_DATA` spec with 47 un-aliased; (4) `extract_historical_streams` runs clean on the capture.

  Commit (both repos):
  ```
  git add protocol/whoop_protocol.json Packages/WhoopProtocol/Sources/WhoopProtocol/Resources/whoop_protocol.json fixtures/historical_capture.bin
  git commit -m "F0: RE historical payload — HISTORICAL_DATA schema + captured fixture" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  git -C ~/Developer/home-server add packages/whoop-protocol/whoop_protocol/interpreter.py
  git -C ~/Developer/home-server commit -m "F0: historical_data hook + extract_historical_streams reference" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

- [ ] **Step F1: Extend `gen_golden.py` to emit `historical_golden.json` (+ `historical_frames.json`).** In **`scripts/gen_golden.py`**, add `extract_historical_streams` to the import line, add a `_split_frames(blob)` helper, and after the streams block read `fixtures/historical_capture.bin`, split into frames, keep only `type_name == "HISTORICAL_DATA"` (assert non-empty), run `extract_historical_streams(…, _DEVICE_CLOCK_REF, _WALL_CLOCK_REF)`, and write `historical_frames.json` + `historical_golden.json` into the test Resources dir (`Packages/WhoopProtocol/Tests/WhoopProtocolTests/Resources/`). Full helper:
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
  ```
  Run it (generated JSON are resources — **never git-add them**):
  ```
  ~/openwhoop/whoop-reader/.venv/bin/python scripts/gen_golden.py
  ```
  Confirm it prints `historical_golden.json: frames=… hr=… fully_accounted=…`. Commit only the script:
  ```
  git add scripts/gen_golden.py
  git commit -m "F1: gen_golden emits historical_frames/golden.json from the captured chunk" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

- [ ] **Step F2: Add contract types to `Streams.swift`.** Edit **`Packages/WhoopProtocol/Sources/WhoopProtocol/Streams.swift`**. Add `HistoricalExtract` (always) and `Streams.empty`; add `ActivitySample` + `Streams.activity` **only if F0 found the family** (fields from F0):
  ```swift
  public struct HistoricalExtract: Equatable {
      public let streams: Streams
      /// true iff EVERY byte of EVERY in-scope historical frame mapped to a known field.
      /// Consumed by Phase G's Backfiller to gate the destructive trim ack.
      public let fullyAccounted: Bool
      public init(streams: Streams, fullyAccounted: Bool) {
          self.streams = streams; self.fullyAccounted = fullyAccounted
      }
  }

  extension Streams { public static let empty = Streams() }

  // ONLY if F0 found an activity/step family (fields/types from the RE):
  // public struct ActivitySample: Equatable, Codable {
  //     public let ts: Int
  //     public let steps: Int            // example — match F0
  //     public init(ts: Int, steps: Int) { self.ts = ts; self.steps = steps }
  // }
  // …and add `public var activity: [ActivitySample]` to Streams (default [], update init).
  ```
  ```
  swift build --package-path Packages/WhoopProtocol
  git add Packages/WhoopProtocol/Sources/WhoopProtocol/Streams.swift
  git commit -m "F2: HistoricalExtract + Streams.empty (+ ActivitySample/Streams.activity if RE found it)" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

- [ ] **Step F3: Add the `historical_data` Swift post-hook + a failing parity test.** Create **`Packages/WhoopProtocol/Tests/WhoopProtocolTests/HistoricalStreamsParityTests.swift`** mirroring `StreamsParityTests.swift` verbatim in structure:
  ```swift
  import XCTest
  @testable import WhoopProtocol

  final class HistoricalStreamsParityTests: XCTestCase {
      private let deviceClockRef = 31_538_447
      private let wallClockRef = 1_736_365_593

      private struct FrameEntry: Decodable { let hex: String }
      private struct HRGold: Decodable, Equatable { let ts: Int; let bpm: Int }
      private struct RRGold: Decodable, Equatable { let ts: Int; let rr_ms: Int }
      private struct HistGold: Decodable {
          let hr: [HRGold]; let rr: [RRGold]; let fully_accounted: Bool
      }
      private func resourceURL(_ name: String, _ ext: String) throws -> URL {
          try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext),
                        "missing \(name).\(ext) — run scripts/gen_golden.py (Phase F1)")
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
          XCTAssertTrue(parsed.allSatisfy { $0.typeName == "HISTORICAL_DATA" },
                        "type 47 still routing to REALTIME_RAW_DATA — fix the schema alias (F0.c)")
          let extract = extractHistoricalStreams(parsed,
                          deviceClockRef: deviceClockRef, wallClockRef: wallClockRef)
          XCTAssertEqual(extract.streams.hr, gold.hr.map { HRSample(ts: $0.ts, bpm: $0.bpm) })
          XCTAssertEqual(extract.streams.rr, gold.rr.map { RRInterval(ts: $0.ts, rrMs: $0.rr_ms) })
          XCTAssertEqual(extract.fullyAccounted, gold.fully_accounted)
          XCTAssertGreaterThan(extract.streams.hr.count, 0)
      }
  }
  ```
  (Add an `ActivityGold` + assertion if F0 found the family — mirror `StreamsParityTests`.) Run RED:
  ```
  swift test --package-path Packages/WhoopProtocol --filter HistoricalStreamsParityTests
  ```
  Confirm RED (no `extractHistoricalStreams`). Now add the `historical_data` post-hook to **`PostHooks.swift`** — a faithful port of F0.d's Python hook (same offsets, `fb.add(...)` via the existing read helpers), stamping an explicit consumed-byte tally into `fb.parsed` (e.g. `fb.parsed["_consumed"]`). Register it as `"historical_data"`. Build:
  ```
  swift build --package-path Packages/WhoopProtocol
  git add Packages/WhoopProtocol/Sources/WhoopProtocol/PostHooks.swift Packages/WhoopProtocol/Tests/WhoopProtocolTests/HistoricalStreamsParityTests.swift
  git commit -m "F3: historical_data Swift post-hook + failing parity test" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

- [ ] **Step F4: Implement `extractHistoricalStreams` to GREEN the parity test.** Create **`Packages/WhoopProtocol/Sources/WhoopProtocol/HistoricalStreams.swift`** as the byte-parity port of the Python `extract_historical_streams` — mirror `extractStreams` (`Streams.swift`): skip `!r.ok || r.crcOK == false`, route only `typeName == "HISTORICAL_DATA"`, map timestamps via the same `toWall` logic, build rows from `r.parsed`, and compute `fullyAccounted` from the per-frame consumed-byte tally vs each frame's payload width (true iff *all* in-scope frames fully consumed — matching F0.d). Return `HistoricalExtract(streams:, fullyAccounted:)`. Read offsets/keys from `r.parsed`; do not hardcode a fabricated layout. GREEN:
  ```
  swift test --package-path Packages/WhoopProtocol --filter HistoricalStreamsParityTests
  git add Packages/WhoopProtocol/Sources/WhoopProtocol/HistoricalStreams.swift
  git commit -m "F4: extractHistoricalStreams — Swift port, byte-parity with Python golden (GREEN)" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

- [ ] **Step F5: Unit-test the `fullyAccounted` signal directly.** Add two tests to `HistoricalStreamsParityTests.swift`: `testFullyAccountedTrueOnCleanChunk` (a fixture frame → true) and `testFullyAccountedFalseOnUnmappedTrailingBytes` (splice extra payload bytes before the crc32 trailer, bump the u16 length, recompute crc8 over bytes `4..<length` + the crc32 trailer using the package's own `crc8`/`crc32` from `Framing.swift` — `@testable` exposes them — then assert `fullyAccounted == false` while the rows that WERE mapped are still emitted). This proves the gate behaves on both clean and corrupt chunks since it guards a destructive trim. Run:
  ```
  swift test --package-path Packages/WhoopProtocol --filter HistoricalStreamsParityTests
  git add Packages/WhoopProtocol/Tests/WhoopProtocolTests/HistoricalStreamsParityTests.swift
  git commit -m "F5: fullyAccounted unit tests — clean true, unmapped-trailing false (rows still emitted)" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

- [ ] **Step F6: Full WhoopProtocol suite green (regression gate).** Un-aliasing 47 touches the shared decoder — confirm the live path didn't regress. Regenerate goldens (generated artifacts — don't git-add) and run the whole suite:
  ```
  ~/openwhoop/whoop-reader/.venv/bin/python scripts/gen_golden.py
  swift test --package-path Packages/WhoopProtocol
  ```
  Confirm every test passes — especially `StreamsParityTests` (live decode unchanged; type‑43 motion/optical fixtures still route to `raw_data`) and `HistoricalStreamsParityTests`. Commit only if a *source* fix was needed:
  ```
  git commit --allow-empty -m "F6: full WhoopProtocol suite green (live + historical parity)" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

## Phase H — WhoopStore off the main actor (async actor)

M3 shipped `WhoopStore` as a `final class` doing synchronous GRDB work on the caller's thread (in practice the main actor, via `Collector`). M4 backfill dumps large bursts of decoded rows, so this phase converts `WhoopStore` into an `actor`: all public methods become `async`, callers `await` them, and the SQLite work runs on the actor's own executor instead of the caller's. **Rationale for keeping `DatabaseQueue` under the actor:** `dbQueue.read`/`write` are synchronous-blocking — the actor doesn't make them non-blocking, it moves them off the *main* thread (they block the `WhoopStore` actor's serial executor, never the UI). That is the intended v1 win; we deliberately do **not** introduce `DatabasePool`/async-GRDB. This phase also adds a `cursors` table (migration `v2`) for `strap_trim` (Phase G) and per-stream highwaters (Phase I).

- [ ] **Step H1.1: Baseline build.** `swift build --package-path Packages/WhoopStore` (confirm green before touching). Read `Packages/WhoopStore/Sources/WhoopStore/{WhoopStore,Database,StreamStore,RawOutbox,Reads}.swift`. No change.

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

- [ ] **Step H1.3: Make every instance method in `StreamStore.swift`, `RawOutbox.swift`, `Reads.swift` `async`.** Add `async` to each public instance method that touches `dbQueue` (bodies unchanged); the `static` pure helpers (`encodePayload`, `packFrames`, `unpackFrames`, `zlibCompressWithLength`, `zlibDecompressWithLength`, `metaFromRow`) stay synchronous. So: `upsertDevice`, `insert`, `storageStats_rowCountsForTest`, `deviceRowForTest` (StreamStore); `enqueueRawBatch`, `rawFrames`, `pendingRawBatches`, `markRawBatchSynced`, `pruneRaw`, `allBatchIdsForTest` (RawOutbox); `hrSamples`, `rrIntervals`, `events`, `batterySamples`, `storageStats` (Reads) — all gain `async`. Build the library green, then commit:
  ```
  swift build --package-path Packages/WhoopStore 2>&1 | tail -20
  git add -A && git commit -m "H1: WhoopStore class → actor (all methods async; schemaVersion=2)" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

- [ ] **Step H2: Port every WhoopStore test to async.** In `Packages/WhoopStore/Tests/WhoopStoreTests/`: mark each store-touching test method `async`, `await` every store call, and `try await WhoopStore.inMemory()` / `WhoopStore(path:)`. `ScaffoldTests.testLibraryVersionMarkerPresent` now asserts `schemaVersion == 2`; `testGRDBIsLinkedAndUsable` stays sync. `ReadTests.seeded()` becomes `async throws`. Pure helpers (`sampleStreams`, `meta`, `frames`) stay sync. (Mirror the M3 test bodies exactly, only adding `async`/`await`.) Run + commit:
  ```
  swift test --package-path Packages/WhoopStore 2>&1 | tail -25
  git add -A && git commit -m "H2: port all WhoopStore tests to async/await actor API" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

- [ ] **Step H3: Add v2 cursors migration + cursor/highwater accessors + CursorTests.** First a failing `Packages/WhoopStore/Tests/WhoopStoreTests/CursorTests.swift`:
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

- [ ] **Step H4: Async `StoreWriting` seam + `Collector`/`BLEManager`/`CollectorTests` on the actor store.**
  - In `ios/OpenWhoop/Collect/Collector.swift`, make the seam a **plain async protocol** (per integration note 3) and keep the conformance:
    ```swift
    protocol StoreWriting: AnyObject {
        @discardableResult
        func insert(_ streams: Streams, deviceId: String) async throws -> (hr: Int, rr: Int, events: Int, battery: Int)
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws
    }
    extension WhoopStore: StoreWriting {}
    ```
  - Make `Collector.ingest`/`flush`/`prune`/`storageStats` `async`, `await`ing the store. **Preserve decoded-before-raw** by snapshotting `buffer` into `frames` and clearing it *synchronously before* the first `await` in `flush()` (so a mid-flush `ingest` accumulates cleanly for the next flush), then `try await store.insert(...)` (catch → re-buffer + return) → `batchStartedAt = monotonic()` → `try? await store.enqueueRawBatch(...)`. The two awaits run sequentially so insert fully completes before enqueue is attempted.
  - In `ios/OpenWhoop/BLE/BLEManager.swift`: `WhoopStore(path:)` is now `async`, so it can't be built in `init`. Set `collector = nil` (make it `var`) in `init`; add `func bootstrapStore() async` that builds the store + `Collector` and is called once at startup (a `Task` from the app root or first power-on). Wrap the now-async `ingest`/`flush` at their delegate call sites in `Task { @MainActor in await … }`; make `pruneRaw()`/`storageStats()` wrap in `Task`/become async. (Frames still append to `buffer` synchronously in delegate order; only flush is async — ordering preserved by the snapshot-before-await.)
  - Port `ios/OpenWhoopTests/CollectorTests.swift` to async: `makeStore()` → `async throws` + `await`; every test `async` + `await`s; `SpyStore`'s two methods become `async throws` and `await wrapped.…`.
  - Build + green:
    ```
    cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -30
    git add -A && git commit -m "H4: async StoreWriting seam + Collector/BLEManager/CollectorTests on the actor store" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
    ```
  (Do NOT git-add `ios/OpenWhoop.xcodeproj` or `Info.plist`. The full async test bodies follow the M3 CollectorTests exactly with `await` added — see M3 plan / current CollectorTests as the template.)

---

## Phase G — Backfiller + BLE wiring + auto-enable

This phase builds the offload state machine that drains the strap's history buffer on every (re)connect. The `Backfiller` (`@MainActor`, unit-tested with a `SpyStore` mirroring `CollectorTests`) owns the safe-trim invariant — decode → persist → fully-accounted check → save cursor → ack `trim` — so a chunk is forgotten by the strap only after it is durably stored *and* every byte is accounted for. CoreBluetooth wiring into `BLEManager` is build-verify. Assumes Phase F's `extractHistoricalStreams` and Phase H's async `WhoopStore` exist. **Reminder (integration note 2): the METADATA packet type is `49`, not 47.**

### G1 — `send(writeType:)` + the historical ack uses `.withResponse`

- [ ] **Step 1: Add `writeType:` to `send`.** In `ios/OpenWhoop/BLE/BLEManager.swift` replace the `send` signature/body so it takes `writeType: CBCharacteristicWriteType = .withoutResponse` and passes it to `p.writeValue(..., type: writeType)`; delete the stale `// TODO(M4)` comment. Add an ack helper:
  ```swift
  /// Ack one HISTORY_END chunk so the strap may trim it. Confirmed write — the strap forgets
  /// the chunk once this lands (link-layer half of safe-trim; decoded already persisted).
  /// Payload mirrors RE struct.pack("<BLL", 1, trim, 0) = [0x01, trim LE32, 0,0,0,0].
  func ackHistoricalTrim(_ trim: UInt32) {
      let trimLE: [UInt8] = [UInt8(trim & 0xFF), UInt8((trim >> 8) & 0xFF),
                             UInt8((trim >> 16) & 0xFF), UInt8((trim >> 24) & 0xFF)]
      send(.historicalDataResult, payload: [0x01] + trimLE + [0, 0, 0, 0], writeType: .withResponse)
  }
  ```
- [ ] **Step 2: Build-verify the app suite (the default keeps all call sites compiling).**
  ```
  cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17'
  git add ios/OpenWhoop/BLE/BLEManager.swift
  git commit -m "G1: send(writeType:) + ackHistoricalTrim uses .withResponse" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

### G2 — `Backfiller` state machine (TDD, SpyStore)

- [ ] **Step 1: Add `classifyHistoricalMeta` to `WhoopProtocol`.** Create `Packages/WhoopProtocol/Sources/WhoopProtocol/HistoricalMeta.swift` — a pure classifier reusing the metadata PostHook (`unix`/`trim_cursor` parsed fields + the `meta_type`/`MetadataType` schema enum), no new byte parsing:
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
  (Confirm the `meta_type`/`unix`/`trim_cursor` field names against the schema + metadata PostHook; adjust the lookups if they differ.)
- [ ] **Step 2: Parity test `HistoricalMetaTests.swift`** building real METADATA frames with the package's own framer (use **packet type `49`** for METADATA), asserting `.end(unix:trim:)`/`.start`/`.complete`/`.other`. Run RED→GREEN: `swift test --package-path Packages/WhoopProtocol --filter HistoricalMetaTests`. Commit the classifier + test.
- [ ] **Step 3: Write failing `Backfiller` tests** `ios/OpenWhoopTests/BackfillerTests.swift`. Define `BackfillStoreWriting` (the async seam) is consumed; use a `SpyBackfillStore` (`@MainActor`) recording `insert`/`setCursor`/`ackTrim`, and an injected `extract` closure so tests need no real golden. Build scripted frames with a `metaFrame(_ metaType:_ payload:)` helper using **packet type `49`**. Cover: clean chunk persists-then-acks-once; `fullyAccounted=false` persists but **never** acks; insert-throw → no cursor/no ack; multi-chunk acks in order then `HISTORY_COMPLETE` exits backfilling; timeout exits without acking; payload-before-START is a no-op. (Use `Streams()` / `Streams.empty` for the stub extract result.)
- [ ] **Step 4: Implement `Backfiller`** `ios/OpenWhoop/Collect/Backfiller.swift`:
  ```swift
  import Foundation
  import WhoopProtocol
  import WhoopStore

  /// The async subset the Backfiller needs (Phase H actor). Plain async protocol (not @MainActor).
  protocol BackfillStoreWriting: AnyObject {
      @discardableResult
      func insert(_ streams: Streams, deviceId: String) async throws -> (hr: Int, rr: Int, events: Int, battery: Int)
      func setCursor(_ name: String, _ value: Int) async throws
      func cursor(_ name: String) async throws -> Int?
  }
  extension WhoopStore: BackfillStoreWriting {}

  /// Historical-offload state machine (idle / backfilling). Per chunk the SAFE-TRIM invariant:
  /// decode → await insert (durable) → if fullyAccounted: await setCursor(strap_trim) → ackTrim;
  /// else log/flag and DO NOT ack (strap keeps the chunk). A chunk is forgotten only after it is
  /// stored AND fully accounted AND the ack (.withResponse) is link-layer confirmed.
  @MainActor
  final class Backfiller {
      typealias Extractor = ([ParsedFrame], Int, Int) -> HistoricalExtract
      private let store: BackfillStoreWriting
      private let deviceId: String
      private let ackTrim: (UInt32) -> Void
      private let extract: Extractor
      private let onUnaccounted: (UInt32, Int) -> Void
      var clockRef: ClockRef?
      private(set) var isBackfilling = false
      private var chunk: [[UInt8]] = []
      private var chunkOpen = false

      init(store: BackfillStoreWriting, deviceId: String,
           ackTrim: @escaping (UInt32) -> Void,
           extract: @escaping Extractor = { extractHistoricalStreams($0, deviceClockRef: $1, wallClockRef: $2) },
           onUnaccounted: @escaping (UInt32, Int) -> Void = { _, _ in }) {
          self.store = store; self.deviceId = deviceId
          self.ackTrim = ackTrim; self.extract = extract; self.onUnaccounted = onUnaccounted
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
          let parsed = chunk.map { parseFrame($0) }
          let decoded = extract(parsed, ref.device, ref.wall)
          do { try await store.insert(decoded.streams, deviceId: deviceId) } catch { return }
          guard decoded.fullyAccounted else { onUnaccounted(trim, chunk.count); return }
          do { try await store.setCursor("strap_trim", Int(trim)) } catch { return }
          ackTrim(trim)
      }
      func timeoutFired() { isBackfilling = false; chunk.removeAll(keepingCapacity: true); chunkOpen = false }
  }
  ```
  Run the Backfiller tests RED→GREEN, then the full app suite green. Commit `Backfiller.swift` + `BackfillerTests.swift`.

### G3 — Wire the Backfiller into `BLEManager` (build-verify)

- [ ] **Step 1: Own a `Backfiller` + a `backfilling` routing flag.** Add to `BLEManager`: `private var backfiller: Backfiller?`, `private var backfilling = false`, `private var backfillTimeout: DispatchWorkItem?`, `private var backfillStarted = false`. Build the `Backfiller` from the **same** `WhoopStore` the Collector uses, **after** `super.init()` (its `ackTrim` captures `self`): a `makeBackfiller(store:)` factory with `ackTrim: { [weak self] in self?.ackHistoricalTrim($0) }` and `onUnaccounted: { [weak self] trim, n in self?.log("UNACCOUNTED chunk (trim=\(trim), \(n) frames) — NOT trimmed, flagged for RE") }`. (Hold the opened store in a `private var store: WhoopStore?` shared by both Collector and Backfiller; both are created in `bootstrapStore()` from H4.)
- [ ] **Step 2: Route custom-char frames to the Backfiller while backfilling** (in `didUpdateValueFor`, the `dataNotifyChar/cmdNotifyChar/eventNotifyChar` case): run clock correlation in BOTH modes (set `collector?.clockRef` AND `backfiller?.clockRef`); if `backfilling`, `armBackfillTimeout()` and `Task { @MainActor in await backfiller?.ingest(frame); self.afterBackfillIngest() }`; else the normal live path (`router.handle` + `Task { @MainActor in await collector?.ingest(frame) }`). Add `afterBackfillIngest()` (if `!backfiller.isBackfilling && backfilling` → `exitBackfilling("HISTORY_COMPLETE")`), `armBackfillTimeout()` (~20 s `DispatchWorkItem` → `backfiller?.timeoutFired()` + `exitBackfilling("timeout")`), and `exitBackfilling(reason:)` (clear flag + timeout, `log`, `send(.toggleRealtimeHR, payload: [0x01])`).
- [ ] **Step 3: Orchestrate connect.** In `didWriteValueFor`, after the existing clock-request block, on the first bond confirmation (`!backfillStarted`): set it, `send(.stopRawData, payload: [0x01])`, `send(.getDataRange)`, then `beginBackfill()` (`backfiller?.begin()`; `backfilling = true`; `send(.sendHistoricalData, payload: [0x00], writeType: .withResponse)`; `armBackfillTimeout()`; if no backfiller, just `send(.toggleRealtimeHR, payload:[0x01])`). Reset `backfillStarted=false`, `backfilling=false`, cancel the timeout in `didDisconnectPeripheral`. (Ordering note: GET_CLOCK and the history writes queue in order; clock correlation runs on every frame in both modes, and `finishChunk` no-ops until `clockRef` is set, so a chunk arriving before the clock simply isn't acked and is re-offloaded next connect — safe.)
- [ ] **Step 4: Build + full app suite green** (`cd ios && xcodegen generate && xcodebuild test … -destination 'platform=iOS Simulator,name=iPhone 17'`). On-device acceptance is in the exit criteria. Commit `BLEManager.swift` (never the xcodeproj/Info.plist):
  ```
  git commit -m "G3: wire Backfiller into BLEManager (routing, connect orchestration, auto Stop-Raw/Start-HR)" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

## Phase I — Decoded upload + server endpoint

Phase H left `WhoopStore` an `async` actor exposing per-stream reads plus `highwater`/`setHighwater`. Phase I closes the write-path: a new `Uploader` reads decoded rows newer than each stream's highwater, POSTs them to a new server endpoint, and advances the highwater only on a 2xx — idempotent, retry-safe, decoupled from `strap_trim`. The server gains `POST /v1/ingest-decoded`, which skips decoding and reuses the existing hypertable upsert. Reachability is "try on connect, retry next connect"; the secret/base-URL live in a gitignored xcconfig.

### I1: Server `POST /v1/ingest-decoded` (TDD, home-server)

- [ ] **Step 1: Failing API test** `home-server/stacks/whoop/ingest/tests/test_ingest_decoded_api.py` (mirror `test_ingest_api.py`'s `client` fixture + `requires_docker`): assert 401 without auth; with `Bearer secret`, POST `{device:{id,mac,name}, streams:{hr:[{ts,bpm}…], rr:[{ts,rr_ms}], events:[{ts,kind,payload}], battery:[{ts,soc,mv}]}}` → 200 `{"upserted":{"hr":2,"rr":1,"events":1,"battery":1}}`, re-POST idempotent (row counts unchanged), and a partial-streams body (only `hr`) → `{"hr":1,"rr":0,"events":0,"battery":0}`. Run RED: `cd ~/Developer/home-server/stacks/whoop/ingest && python -m pytest tests/test_ingest_decoded_api.py -q` (404).
- [ ] **Step 2: Implement** in `home-server/stacks/whoop/ingest/app/main.py`: add `DecodedDevice`/`DecodedStreams`/`DecodedBatch` Pydantic models and an `@app.post("/v1/ingest-decoded", dependencies=[Depends(require_auth)])` route that calls `store.ensure_device(conn, …)` + `store.upsert_streams(conn, device_id, streams)` (reuse the existing helpers — read `app/store.py` to confirm names/return shape; they already do `ON CONFLICT` upserts and return a `{"hr":n,…}` dict) and returns `{"upserted": counts}`. Add `store` to the `from . import …` line. Run GREEN; run the full ingest suite (`python -m pytest -q`); commit in the home-server repo.

### I2: Gitignored secrets config + project.yml wiring + `UploaderConfig` runtime read (build-verify)

- [ ] Create committed template `ios/OpenWhoop/Config/Secrets.example.xcconfig` (`WHOOP_BASE_URL`, `WHOOP_API_KEY`, using the `https:/$()/host` trick so `//` isn't an xcconfig comment); create the real gitignored `ios/OpenWhoop/Config/Secrets.xcconfig` (fill locally, never commit); append `ios/OpenWhoop/Config/Secrets.xcconfig` to `.gitignore`; verify `git check-ignore` hides it. Wire `configFiles: {Debug,Release: OpenWhoop/Config/Secrets.xcconfig}` on the `OpenWhoop` target in `ios/project.yml` and add `info.properties` `WHOOP_BASE_URL: $(WHOOP_BASE_URL)` / `WHOOP_API_KEY: $(WHOOP_API_KEY)`. Add `ios/OpenWhoop/Config/AppConfig.swift` reading those Info.plist keys into an optional `UploaderConfig` (nil/placeholder → no upload). Build-verify (defer the build to end of I3 if `UploaderConfig` isn't defined yet). Commit template + gitignore + project.yml + AppConfig only (NEVER the real `Secrets.xcconfig`/xcodeproj/Info.plist).

### I3: The `Uploader` (TDD with `URLProtocol` stub + in-memory store)

- [ ] **Step 1: Failing test** `ios/OpenWhoopTests/UploaderTests.swift` with a `StubURLProtocol` (captures request bodies, returns a scripted status) on an ephemeral `URLSession`, and an in-memory store **seeded via `try await store.insert(Streams(hr: [...], rr: [...]), deviceId: "devA")`** (integration note 6; `try await WhoopStore.inMemory()`). Assert: a 200 drain POSTs hr + rr once each (battery/events empty → no POST), advances `highwater("hr")`/`("rr")` to the last ts, and the hr body shape is `{device:{id:"devA"}, streams:{hr:[{ts,bpm}…]}}`; a 500 leaves highwater nil (retry-safe); a second drain after success is a no-op (idempotent). Run RED.
- [ ] **Step 2: Implement** `ios/OpenWhoop/Upload/Uploader.swift`: `struct UploaderConfig {baseURL; apiKey}` and `final class Uploader` with `drain()` calling per-stream drains — each reads `highwater(stream) ?? Int.min`, fetches rows `from: after+1, to: .max, limit: 5000`, maps to the wire shape (`hr`→`{ts,bpm}`, `rr`→`{ts,rr_ms}`, `events`→`{ts,kind,payload}` via `JSONEncoder` on `ParsedValue`, `battery`→`{ts,soc?,mv?}`), POSTs `{device:{id,name}, streams:{<stream>: rows}}` with `Authorization: Bearer <key>` to `baseURL/v1/ingest-decoded`, and on 2xx `setHighwater(stream, rows.last!.ts)`; non-2xx/throw leaves the highwater. Run GREEN; commit `Uploader.swift` + `UploaderTests.swift` (never xcodeproj/Info.plist).

### I4: Wire `uploader.drain()` into the connect / post-backfill path (build-verify)

- [ ] Add `private let uploader: Uploader?` to `BLEManager`; construct it from `AppConfig.uploaderConfig(deviceId:)` + the shared `WhoopStore` (nil if unconfigured); `self.uploader = nil` in the test init. Add `private func uploadOpportunistically() { guard let uploader else { return }; Task { await uploader.drain() } }`. Call it on the connect path (in `didWriteValueFor` after the clock block) **and** at Phase G's `exitBackfilling` (post-backfill) so freshly-backfilled rows upload immediately. Build + suite green; commit `BLEManager.swift`.

### I5: Cloudflare tunnel route (ops / build-verify with verification curl)

- [ ] On jpserver: add a `cloudflared` ingress rule routing `whoop.<domain>` → the whoop-ingest service host:port (covers `/v1/ingest` + `/v1/ingest-decoded`; Bearer auth is the access control), `cloudflared tunnel route dns <tunnel> whoop.<domain>`, `cloudflared tunnel ingress validate`, restart the tunnel. Verify: `curl -sS https://whoop.<domain>/healthz` → `{"status":"ok"}`; `curl -sS -X POST https://whoop.<domain>/v1/ingest-decoded -H "Authorization: Bearer <key>" -H "Content-Type: application/json" -d '{"device":{"id":"my-whoop"},"streams":{"hr":[]}}'` → `{"upserted":{"hr":0,…}}`. Then set the real `WHOOP_BASE_URL`/`WHOOP_API_KEY` in the gitignored `Secrets.xcconfig`, rebuild onto the device, and confirm decoded rows appear in the dashboard. No code commit (ops + on-device acceptance).

---

## Exit criteria

- **Decode:** `extractHistoricalStreams` is Python-parity-proven over a real captured chunk; the historical payload's full field inventory is documented; `fullyAccounted` is unit-tested (clean → true, unmapped bytes → false with mapped rows still emitted). Live decode (`StreamsParityTests`) unregressed.
- **Backfill:** on (re)connect the strap's history drains into the local store as decoded streams with correct wall-clock timestamps; a chunk's `trim` is acked only after durable storage **and** full accounting; unaccounted chunks are never trimmed (flagged for RE); an interrupted backfill resumes losslessly (idempotent); live HR/R‑R persists automatically after backfill (no manual Start HR); the type‑43 flood is stopped on connect. Verified on-device by pulling the SQLite (`devicectl … copy from`) and confirming a phone-off gap fills + `strap_trim` advances.
- **Off-main:** `WhoopStore` is an `async actor`; the whole WhoopStore + app suites are green async; UI doesn't jank during a large backfill.
- **Upload:** decoded streams (historical + live) reach the server via `POST /v1/ingest-decoded` and are visible in the dashboard; uploads are idempotent + retried; highwaters advance only on 2xx; trim never depends on the server. The tunnel route is verified by curl.
- **Hygiene:** no raw bytes uploaded for this milestone's data; the real `Secrets.xcconfig` and the generated xcodeproj/Info.plist/golden JSON are never committed; all commits carry the `Co-Authored-By` trailer.

**Deferred to the next plan (M5 read-path):** pull decoded streams back, History = union(phone, server), fresh-reinstall cloud restore, read-auth on the server's read endpoints. **Future (not scheduled):** emit full type‑43/type‑52 IMU samples; the HRV/SpO2/skin-temp/strain analysis (server sub-project B); live raw-burst capture/upload (M6).
