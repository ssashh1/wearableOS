# OpenWhoop iOS — M3: Local Store + Background Collection (Plan 2 of N)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist decoded biometric streams locally (durable) and buffer raw frames in a transient outbox, collected continuously while connected — including in the background — on top of the Plan 1 foundation.

**Architecture:** A Swift `extractStreams` added to `WhoopProtocol` (port of the Python `extract_streams`, parity-tested) turns decoded frames into HR/RR/event/battery rows with wall-clock timestamps. A new **`WhoopStore`** GRDB package persists those rows (idempotent upsert by natural key) and a raw outbox. In the app, the device↔wall **clock correlation** is captured at connect, a **`Collector`** persists decoded streams **before** queueing raw (the invariant that makes pruning safe), background collection survives relaunch via `CBCentralManager` **state restoration**, and the raw outbox is bounded by a **prune** policy.

**Tech Stack:** Swift 6.3, SwiftPM, **GRDB.swift**, XcodeGen, SwiftUI, CoreBluetooth, XCTest; Python 3 (existing `whoop_protocol`) for stream parity. iOS simulator = **iPhone 17**.

**Spec:** `docs/specs/2026-05-23-openwhoop-ios-app-design.md` (the "Local store" + "Data pipeline" sections). **Builds on Plan 1** (the foundation — decoder + BLE bond + live HR — complete and green: 40 decoder tests + 26 app tests).

**Scope:** **M3 only.** Phase D = the persistence library (testable on macOS); Phase E = app integration (collection + background). Later plans: M4 (historical backfill), M5 (bidirectional sync + cloud restore), M6 (all sensors), M7 (charts viewer + commands).

---

## Conventions

- **TDD where testable** (failing test → fail → implement → pass → commit); CoreBluetooth/UI tasks use complete-code + build/manual verification.
- **Commit after every task**, ending the message with `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.
- **Package tests:** `swift test --package-path Packages/WhoopStore` (and `…/WhoopProtocol`). **App build/tests:** `cd ios && xcodegen generate` then `xcodebuild [test] -project ios/OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17'`.
- **Never `git add`** the generated `ios/OpenWhoop.xcodeproj` or `ios/OpenWhoop/Info.plist` (git-ignored; `project.yml` is the source of truth).
- **GRDB.swift** resolves over the network on first build (expected). Pin `from: "6.0.0"` (or current 6.x/7.x; use the SQLite/`DatabaseQueue` + `DatabaseMigrator` API).
- **The core invariant (Phase E):** on every flush, persist **decoded streams first**, then enqueue the raw batch. Decoded is the durable local record; raw is the transient outbox (pruned after sync). Persisting decoded first means pruning raw can never lose a decoded metric.
- **Two clocks** (from the spec / Plan-1 decoder): REALTIME_DATA timestamps are a device monotonic epoch → mapped to wall-clock via the `(device, wall)` correlation captured at connect; EVENT/METADATA timestamps are real unix and stored as-is.

## File structure (created/modified by this plan)

```
Packages/WhoopProtocol/Sources/WhoopProtocol/Streams.swift   NEW: Streams + extractStreams (parity-tested)
Packages/WhoopStore/                                         NEW package (GRDB; depends on WhoopProtocol)
  Package.swift  Sources/WhoopStore/{WhoopStore,Schema,Records,RawOutbox,Reads}.swift
  Tests/WhoopStoreTests/*.swift
scripts/gen_golden.py                                        EXTENDED: also emit streams_golden.json
ios/OpenWhoop/Collect/{ClockCorrelation,Collector,StorePaths,PrunePolicy}.swift   NEW
ios/OpenWhoop/BLE/BLEManager.swift                           MODIFIED: clock capture, Collector, restoration, prune
ios/OpenWhoop/Live/{LiveView,LiveViewModel}.swift            MODIFIED: storage status line
ios/OpenWhoop/App/OpenWhoopApp.swift                         MODIFIED: prune on background
ios/project.yml                                              MODIFIED: add WhoopStore package dependency
ios/OpenWhoopTests/{ClockCorrelation,Collector}Tests.swift   NEW
```

**Prerequisite:** Plan 1 is complete (foundation green). This plan also **completes the deferred Plan-1 review items** (CBCentralManager state-restoration correctness 1.3/1.4) in Phase E Task E4.

## Phase D — Persistence library: extractStreams + WhoopStore (GRDB)

This phase adds the stream-extraction layer to `WhoopProtocol` (porting `home-server`'s `extract_streams`/`_to_wall`) and a new GRDB-backed `WhoopStore` package. Decoded streams are durable; raw frames are a transient, compressed, prunable outbox. Phase E depends on the EXACT public shapes defined here — do not deviate.

Conventions for the executing engineer:
- Toolchain Swift 6.3 / Xcode 26.4; iOS simulator is **`iPhone 17`**.
- Run `WhoopProtocol` tests with `swift test --package-path Packages/WhoopProtocol`.
- Run `WhoopStore` tests with `swift test --package-path Packages/WhoopStore`. GRDB resolves over the network on the first build — that is expected and fine.
- Commit after every task; the `Co-Authored-By` trailer is required.
- Work from repo root `~/openwhoop`. All `git add` paths below are repo-relative.

---

### Task D1: `extractStreams` + stream structs in `WhoopProtocol`
**Files:** Create: `Packages/WhoopProtocol/Sources/WhoopProtocol/Streams.swift` · Create Test: `Packages/WhoopProtocol/Tests/WhoopProtocolTests/StreamsTests.swift`

Port `extract_streams`/`_to_wall` from `home-server/.../interpreter.py`. Semantics that MUST hold:
- Skip frames where `ok == false` OR `crcOK == false` (treat `crcOK == nil` as not-false, i.e. keep — matches Python `r.get("crc_ok") is False`).
- HR/RR come **only** from `REALTIME_DATA` (typeName `"REALTIME_DATA"`), never from `REALTIME_RAW_DATA` (type 43), even though type-43 also carries `heart_rate` (avoids double-counting).
- REALTIME_DATA `ts = wallClockRef + (timestamp - deviceClockRef)`. Emit an HR sample only if `timestamp` present AND `heart_rate` present. Emit one RR interval per value in `rr_intervals`, each stamped with the same `ts`.
- EVENT `ts = event_timestamp` (a real unix second — NOT offset). `kind = event`. `payload` = every parsed key except `event` and `event_timestamp`.
- COMMAND_RESPONSE: if `battery_pct` OR `battery_mV` is present, emit a battery sample with `ts = wallClockRef`, `soc = battery_pct` (Double?), `mv = battery_mV` (Int?).

- [ ] **Step 1: Write the failing test**
```swift
import XCTest
@testable import WhoopProtocol

/// Real fixture frames (full_hex from fixtures/capture.jsonl), decoded then stream-extracted.
/// Refs chosen so the first REALTIME_DATA timestamp (31538447) maps onto a known wall instant.
final class StreamsTests: XCTestCase {
    private let deviceClockRef = 31_538_447
    private let wallClockRef = 1_736_365_593

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    // REALTIME_DATA: ts=31538447 hr=60 ; ts=31538448 hr=59
    private let rt0 = "aa1800ff28020f3de10128663c00000000000000000001010d844e7c"
    private let rt1 = "aa1800ff2802103de10148613b0000000000000000000101831ca421"
    // EVENT RAW_DATA_COLLECTION_ON(46), event_timestamp=1736365593 (real unix)
    private let ev = "aa10005730262e0019d67e676817000016376706"
    // COMMAND_RESPONSE GET_BATTERY_LEVEL(26), battery_pct=25.5
    private let battery = "aa10005724231a0a01ff0000000000002f1ea284"
    // REALTIME_RAW_DATA (type 43): carries a heart_rate byte but MUST NOT feed the HR stream
    private let raw43 = "aa8407f72b0a29be933102183de101b039805440013f0000000000000000000020e900e600000000000000000000383eb83d3dca663d"

    private func parsedFrames(_ hexes: [String]) -> [ParsedFrame] {
        hexes.map { parseFrame(bytes($0)) }
    }

    func testRealtimeHRMapsDeviceToWallClock() {
        let s = extractStreams(parsedFrames([rt0, rt1]),
                               deviceClockRef: deviceClockRef, wallClockRef: wallClockRef)
        XCTAssertEqual(s.hr, [HRSample(ts: 1_736_365_593, bpm: 60),
                              HRSample(ts: 1_736_365_594, bpm: 59)])
        XCTAssertTrue(s.rr.isEmpty)
    }

    func testEventTimestampIsNotOffset() {
        let s = extractStreams(parsedFrames([ev]),
                               deviceClockRef: deviceClockRef, wallClockRef: wallClockRef)
        XCTAssertEqual(s.events.count, 1)
        XCTAssertEqual(s.events[0].ts, 1_736_365_593)          // raw event_timestamp, not offset
        XCTAssertEqual(s.events[0].kind, "RAW_DATA_COLLECTION_ON(46)")
        XCTAssertEqual(s.events[0].payload, [:])                // event/event_timestamp stripped
    }

    func testBatteryStampedAtWallClockRef() {
        let s = extractStreams(parsedFrames([battery]),
                               deviceClockRef: deviceClockRef, wallClockRef: wallClockRef)
        XCTAssertEqual(s.battery, [BatterySample(ts: 1_736_365_593, soc: 25.5, mv: nil)])
    }

    func testHRNotTakenFromType43RawData() {
        // raw43 decodes with a heart_rate in parsed, but it is REALTIME_RAW_DATA → no HR row.
        let p = parseFrame(bytes(raw43))
        XCTAssertEqual(p.typeName, "REALTIME_RAW_DATA")
        XCTAssertNotNil(p.parsed["heart_rate"])
        let s = extractStreams([p], deviceClockRef: deviceClockRef, wallClockRef: wallClockRef)
        XCTAssertTrue(s.hr.isEmpty)
        XCTAssertTrue(s.rr.isEmpty)
    }

    func testCrcFailedAndNotOkFramesSkipped() {
        let good = parseFrame(bytes(rt0))                       // ok, crc ok
        let truncated = parseFrame([0xAA, 0x00])                // ok==false (INVALID/FRAGMENT)
        let s = extractStreams([good, truncated],
                               deviceClockRef: deviceClockRef, wallClockRef: wallClockRef)
        XCTAssertEqual(s.hr.count, 1)
    }
}
```
- [ ] **Step 2: Run test to verify it fails** Run: `swift test --package-path Packages/WhoopProtocol --filter StreamsTests` Expected: FAIL — compile error / unresolved identifiers `extractStreams`, `HRSample`, `RRInterval`, `WhoopEvent`, `BatterySample`, `Streams` (Streams.swift does not exist yet).
- [ ] **Step 3: Implement**
```swift
import Foundation

// MARK: - Decoded stream rows (the durable, compact local record)
// Phase E and WhoopStore depend on these EXACT shapes. ts is wall-clock unix seconds
// EXCEPT inside extractStreams' inputs; the structs themselves always carry wall-clock ts.

public struct HRSample: Equatable, Codable {
    public let ts: Int          // wall-clock unix seconds
    public let bpm: Int
    public init(ts: Int, bpm: Int) { self.ts = ts; self.bpm = bpm }
}

public struct RRInterval: Equatable, Codable {
    public let ts: Int          // wall-clock unix seconds
    public let rrMs: Int
    public init(ts: Int, rrMs: Int) { self.ts = ts; self.rrMs = rrMs }
}

public struct WhoopEvent: Equatable, Codable {
    public let ts: Int          // real unix seconds (event RTC; never offset)
    public let kind: String
    public let payload: [String: ParsedValue]
    public init(ts: Int, kind: String, payload: [String: ParsedValue]) {
        self.ts = ts; self.kind = kind; self.payload = payload
    }
}

public struct BatterySample: Equatable, Codable {
    public let ts: Int          // wall-clock unix seconds (stamped at wallClockRef)
    public let soc: Double?
    public let mv: Int?
    public init(ts: Int, soc: Double?, mv: Int?) { self.ts = ts; self.soc = soc; self.mv = mv }
}

public struct Streams: Equatable {
    public var hr: [HRSample]
    public var rr: [RRInterval]
    public var events: [WhoopEvent]
    public var battery: [BatterySample]
    public init(hr: [HRSample] = [], rr: [RRInterval] = [],
                events: [WhoopEvent] = [], battery: [BatterySample] = []) {
        self.hr = hr; self.rr = rr; self.events = events; self.battery = battery
    }
}

/// Map a device-epoch timestamp to wall-clock unix seconds via a pure linear offset.
/// Assumes strap clock and wall clock tick at the same rate (no skew/drift). Port of _to_wall.
private func toWall(_ deviceTs: Int?, _ deviceClockRef: Int, _ wallClockRef: Int) -> Int? {
    guard let deviceTs = deviceTs else { return nil }
    return wallClockRef + (deviceTs - deviceClockRef)
}

/// Turn parsed frames into datastore rows. Port of interpreter.extract_streams.
///
/// HR/R-R are taken ONLY from REALTIME_DATA (type 40). REALTIME_RAW_DATA (type 43) also
/// carries an HR byte but streams alongside type-40 during raw collection, so routing both
/// would double-count HR for the same instants. CRC-failed and non-ok frames are skipped.
public func extractStreams(_ parsed: [ParsedFrame],
                           deviceClockRef: Int, wallClockRef: Int) -> Streams {
    var out = Streams()
    for r in parsed {
        if !r.ok || r.crcOK == false { continue }
        let p = r.parsed
        switch r.typeName {
        case "REALTIME_DATA":
            let ts = toWall(p["timestamp"]?.intValue, deviceClockRef, wallClockRef)
            if let ts = ts, let bpm = p["heart_rate"]?.intValue {
                out.hr.append(HRSample(ts: ts, bpm: bpm))
            }
            if let ts = ts, let rrs = p["rr_intervals"]?.intArrayValue {
                for rr in rrs { out.rr.append(RRInterval(ts: ts, rrMs: rr)) }
            }
        case "EVENT":
            // EVENT timestamps are real RTC unix seconds — already wall-clock, NOT offset.
            guard let ts = p["event_timestamp"]?.intValue else { continue }
            let kind = p["event"]?.stringValue ?? ""
            var payload = p
            payload.removeValue(forKey: "event")
            payload.removeValue(forKey: "event_timestamp")
            out.events.append(WhoopEvent(ts: ts, kind: kind, payload: payload))
        case "COMMAND_RESPONSE":
            // No device timestamp on COMMAND_RESPONSE → stamp battery at wallClockRef.
            let soc = p["battery_pct"]?.doubleValue
            let mv = p["battery_mV"]?.intValue
            if soc != nil || mv != nil {
                out.battery.append(BatterySample(ts: wallClockRef, soc: soc, mv: mv))
            }
        default:
            continue
        }
    }
    return out
}
```
- [ ] **Step 4: Run test to verify it passes** Run: `swift test --package-path Packages/WhoopProtocol --filter StreamsTests` Expected: PASS (4 tests).
- [ ] **Step 5: Commit**
```bash
git add Packages/WhoopProtocol/Sources/WhoopProtocol/Streams.swift Packages/WhoopProtocol/Tests/WhoopProtocolTests/StreamsTests.swift ; git commit -m "D1: extractStreams + stream structs in WhoopProtocol" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task D2: cross-language stream parity (`streams_golden.json` + Swift parity test)
**Files:** Modify: `scripts/gen_golden.py` · Create Test: `Packages/WhoopProtocol/Tests/WhoopProtocolTests/StreamsParityTests.swift`

Extend (do not rewrite) `gen_golden.py` so it ALSO runs the Python `extract_streams` over the SAME `golden` dicts it already produced, with fixed refs, and writes `streams_golden.json` into the Swift test Resources. The Swift parity test loads `frames.json` + `streams_golden.json`, decodes each frame with `parseFrame`, runs `extractStreams` with the identical refs, and asserts equality field-by-field. Mirrors the existing `ParityTests` approach.

The fixed refs (constants in BOTH the script and the test) are `DEVICE_CLOCK_REF = 31538447`, `WALL_CLOCK_REF = 1736365593`.

- [ ] **Step 1: Write the failing test**
```swift
import XCTest
@testable import WhoopProtocol

/// Cross-language guarantee that Swift extractStreams == Python extract_streams over the
/// same fixture frames + refs. streams_golden.json is generated by scripts/gen_golden.py.
final class StreamsParityTests: XCTestCase {
    // MUST equal the constants in scripts/gen_golden.py.
    private let deviceClockRef = 31_538_447
    private let wallClockRef = 1_736_365_593

    private struct FrameEntry: Decodable { let hex: String }
    private struct HRGold: Decodable, Equatable { let ts: Int; let bpm: Int }
    private struct RRGold: Decodable, Equatable { let ts: Int; let rr_ms: Int }
    private struct BatGold: Decodable, Equatable { let ts: Int; let soc: Double?; let mv: Int? }
    private struct EvGold: Decodable { let ts: Int; let kind: String; let payload: [String: ParsedValue] }
    private struct StreamsGold: Decodable {
        let hr: [HRGold]; let rr: [RRGold]; let events: [EvGold]; let battery: [BatGold]
    }

    private func resourceURL(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext),
                      "missing \(name).\(ext) — run scripts/gen_golden.py")
    }
    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return out
    }

    func testSwiftStreamsMatchPythonGolden() throws {
        let frames = try JSONDecoder().decode(
            [FrameEntry].self, from: Data(contentsOf: resourceURL("frames", "json")))
        let gold = try JSONDecoder().decode(
            StreamsGold.self, from: Data(contentsOf: resourceURL("streams_golden", "json")))

        let parsed = frames.map { parseFrame(bytes($0.hex)) }
        let s = extractStreams(parsed, deviceClockRef: deviceClockRef, wallClockRef: wallClockRef)

        XCTAssertEqual(s.hr, gold.hr.map { HRSample(ts: $0.ts, bpm: $0.bpm) })
        XCTAssertEqual(s.rr, gold.rr.map { RRInterval(ts: $0.ts, rrMs: $0.rr_ms) })
        XCTAssertEqual(s.battery, gold.battery.map { BatterySample(ts: $0.ts, soc: $0.soc, mv: $0.mv) })
        XCTAssertEqual(s.events.count, gold.events.count, "event count mismatch")
        for (i, g) in gold.events.enumerated() {
            XCTAssertEqual(s.events[i].ts, g.ts, "event ts mismatch #\(i)")
            XCTAssertEqual(s.events[i].kind, g.kind, "event kind mismatch #\(i)")
            XCTAssertEqual(s.events[i].payload, g.payload, "event payload mismatch #\(i) (\(g.kind))")
        }
        // Sanity: the fixture must actually exercise the stream types.
        XCTAssertGreaterThan(s.hr.count, 0)
        XCTAssertGreaterThan(s.events.count, 0)
        XCTAssertGreaterThan(s.battery.count, 0)
    }
}
```
- [ ] **Step 2: Run test to verify it fails** Run: `swift test --package-path Packages/WhoopProtocol --filter StreamsParityTests` Expected: FAIL — `streams_golden.json` resource is missing (the `XCTUnwrap` throws).
- [ ] **Step 3: Implement** — edit `scripts/gen_golden.py`. Add the import + constants near the top, and the emit block at the end of `main()`.

In the imports section (after `from whoop_protocol.interpreter import parse_frame`), change it to also import `extract_streams`:
```python
from whoop_protocol.interpreter import extract_streams, parse_frame
```
Add the fixed refs as module constants (place them right after the `_CAPTURES = [...]` list):
```python
# Fixed correlation refs for the cross-language stream parity fixture. These MUST match the
# constants in WhoopProtocolTests/StreamsParityTests.swift. The first REALTIME_DATA timestamp
# in the fixtures is 31538447; mapping it onto a known wall instant keeps the golden stable.
_DEVICE_CLOCK_REF = 31538447
_WALL_CLOCK_REF = 1736365593
```
Then, inside `main()`, immediately BEFORE the final `print(f"wrote {len(frames)} frames ...")` line, add:
```python
    # Cross-language stream parity: run the canonical extract_streams over the same golden
    # dicts and emit streams_golden.json for StreamsParityTests.swift.
    streams = extract_streams(golden, _DEVICE_CLOCK_REF, _WALL_CLOCK_REF)
    assert streams["hr"], "stream fixture produced no HR rows"
    assert streams["events"], "stream fixture produced no EVENT rows"
    assert streams["battery"], "stream fixture produced no battery rows"
    with open(os.path.join(_OUT_DIR, "streams_golden.json"), "w") as fh:
        json.dump(streams, fh, indent=0)
    print(f"wrote streams_golden.json: hr={len(streams['hr'])} rr={len(streams['rr'])} "
          f"events={len(streams['events'])} battery={len(streams['battery'])}")
```
Now regenerate the fixtures:
```bash
~/openwhoop/whoop-reader/.venv/bin/python ~/openwhoop/scripts/gen_golden.py
```
Expected stdout includes `wrote streams_golden.json: hr=7 rr=0 events=5 battery=1`. (`extract_streams` emits Python dicts keyed `rr_ms`/`soc`/`mv`/`bpm`/`ts`/`kind`/`payload`, which the Swift test decodes directly.)
- [ ] **Step 4: Run test to verify it passes** Run: `swift test --package-path Packages/WhoopProtocol --filter StreamsParityTests` Expected: PASS. Then run the full suite to confirm no regression: `swift test --package-path Packages/WhoopProtocol` Expected: PASS (all prior 40 tests + StreamsTests + StreamsParityTests).
- [ ] **Step 5: Commit**
```bash
git add scripts/gen_golden.py Packages/WhoopProtocol/Tests/WhoopProtocolTests/streams_golden.json Packages/WhoopProtocol/Tests/WhoopProtocolTests/StreamsParityTests.swift ; git commit -m "D2: cross-language stream parity (streams_golden + Swift test)" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task D3: scaffold the `WhoopStore` SwiftPM package
**Files:** Create: `Packages/WhoopStore/Package.swift` · Create: `Packages/WhoopStore/Sources/WhoopStore/WhoopStore.swift` · Create Test: `Packages/WhoopStore/Tests/WhoopStoreTests/ScaffoldTests.swift`

Stand up a package that depends on `WhoopProtocol` (path dependency `../WhoopProtocol`) and GRDB.swift (`from: "6.0.0"`), with a placeholder source that builds. GRDB resolves over the network on first build.

- [ ] **Step 1: Write the failing test**
```swift
import XCTest
import GRDB
@testable import WhoopStore

final class ScaffoldTests: XCTestCase {
    func testGRDBIsLinkedAndUsable() throws {
        // Proves the GRDB dependency resolved and a DB can be opened.
        let queue = try DatabaseQueue()
        let answer = try queue.read { db in try Int.fetchOne(db, sql: "SELECT 42") }
        XCTAssertEqual(answer, 42)
    }

    func testLibraryVersionMarkerPresent() {
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 1)
    }
}
```
- [ ] **Step 2: Run test to verify it fails** Run: `swift test --package-path Packages/WhoopStore --filter ScaffoldTests` Expected: FAIL — the package does not exist (`error: could not find Package.swift`).
- [ ] **Step 3: Implement** — create `Packages/WhoopStore/Package.swift`:
```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhoopStore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "WhoopStore", targets: ["WhoopStore"])],
    dependencies: [
        .package(path: "../WhoopProtocol"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
    ],
    targets: [
        .target(
            name: "WhoopStore",
            dependencies: [
                "WhoopProtocol",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "WhoopStoreTests",
            dependencies: ["WhoopStore"]
        ),
    ]
)
```
Create `Packages/WhoopStore/Sources/WhoopStore/WhoopStore.swift`:
```swift
import Foundation
import GRDB
import WhoopProtocol

/// OpenWhoop persistence library — decoded streams are durable; raw frames are a
/// transient, compressed, prunable outbox. Built on GRDB/SQLite.
public enum WhoopStoreInfo {
    /// Bumped whenever the migrator gains a new migration (placeholder until D4).
    public static let schemaVersion = 1
}
```
- [ ] **Step 4: Run test to verify it passes** Run: `swift test --package-path Packages/WhoopStore --filter ScaffoldTests` Expected: PASS (GRDB resolves over the network on first run, then both tests pass).
- [ ] **Step 5: Commit**
```bash
git add Packages/WhoopStore/Package.swift Packages/WhoopStore/Sources/WhoopStore/WhoopStore.swift Packages/WhoopStore/Tests/WhoopStoreTests/ScaffoldTests.swift ; git commit -m "D3: scaffold WhoopStore package (GRDB + WhoopProtocol)" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task D4: GRDB schema + migrations
**Files:** Create: `Packages/WhoopStore/Sources/WhoopStore/Database.swift` · Modify: `Packages/WhoopStore/Sources/WhoopStore/WhoopStore.swift` · Create Test: `Packages/WhoopStore/Tests/WhoopStoreTests/MigrationTests.swift`

Add the `WhoopStore` class with `init(path:)` / `inMemory()` that opens a `DatabaseQueue` and runs a `DatabaseMigrator`. Tables (decoded durable, raw transient):
- `device(id PK, mac, name, firstSeen, lastSeen)`
- `hrSample(deviceId, ts, bpm)` — PK `(deviceId, ts)`
- `rrInterval(deviceId, ts, rrMs)` — PK `(deviceId, ts, rrMs)`
- `event(deviceId, ts, kind, payloadJSON)` — PK `(deviceId, ts, kind)`
- `battery(deviceId, ts, soc, mv)` — PK `(deviceId, ts)`
- `rawBatch(batchId PK, deviceId, capturedAt, deviceClockRef, wallClockRef, startTs, endTs, frameCount, byteSize, framesBlob BLOB, syncedAt INTEGER NULL)`

- [ ] **Step 1: Write the failing test**
```swift
import XCTest
import GRDB
@testable import WhoopStore

final class MigrationTests: XCTestCase {
    func testInMemoryRunsMigrations() throws {
        let store = try WhoopStore.inMemory()
        let tables = try store.tableNames()
        for t in ["device", "hrSample", "rrInterval", "event", "battery", "rawBatch"] {
            XCTAssertTrue(tables.contains(t), "missing table \(t)")
        }
    }

    func testFileInitRunsMigrations() throws {
        let path = NSTemporaryDirectory() + "whoopstore-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try WhoopStore(path: path)
        XCTAssertTrue(try store.tableNames().contains("hrSample"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testHrSamplePrimaryKeyIsDeviceIdTs() throws {
        let store = try WhoopStore.inMemory()
        let cols = try store.primaryKeyColumns("hrSample")
        XCTAssertEqual(cols, ["deviceId", "ts"])
    }

    func testRrIntervalPrimaryKeyIncludesRrMs() throws {
        let store = try WhoopStore.inMemory()
        XCTAssertEqual(try store.primaryKeyColumns("rrInterval"), ["deviceId", "ts", "rrMs"])
    }
}
```
- [ ] **Step 2: Run test to verify it fails** Run: `swift test --package-path Packages/WhoopStore --filter MigrationTests` Expected: FAIL — compile error: `WhoopStore` has no `inMemory()`, `init(path:)`, `tableNames()`, or `primaryKeyColumns(_:)`.
- [ ] **Step 3: Implement** — create `Packages/WhoopStore/Sources/WhoopStore/Database.swift`:
```swift
import Foundation
import GRDB

extension WhoopStore {
    /// The schema migrator. v1 creates decoded-stream tables (durable) + the raw outbox.
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "device") { t in
                t.column("id", .text).primaryKey()
                t.column("mac", .text)
                t.column("name", .text)
                t.column("firstSeen", .integer)
                t.column("lastSeen", .integer)
            }
            try db.create(table: "hrSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("bpm", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "rrInterval") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("rrMs", .integer).notNull()
                t.primaryKey(["deviceId", "ts", "rrMs"])
            }
            try db.create(table: "event") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("payloadJSON", .text).notNull()
                t.primaryKey(["deviceId", "ts", "kind"])
            }
            try db.create(table: "battery") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("soc", .double)
                t.column("mv", .integer)
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "rawBatch") { t in
                t.column("batchId", .text).primaryKey()
                t.column("deviceId", .text).notNull()
                t.column("capturedAt", .integer).notNull()
                t.column("deviceClockRef", .integer).notNull()
                t.column("wallClockRef", .integer).notNull()
                t.column("startTs", .integer).notNull()
                t.column("endTs", .integer).notNull()
                t.column("frameCount", .integer).notNull()
                t.column("byteSize", .integer).notNull()
                t.column("framesBlob", .blob).notNull()
                t.column("syncedAt", .integer)
            }
        }
        return migrator
    }
}
```
Replace the contents of `Packages/WhoopStore/Sources/WhoopStore/WhoopStore.swift`:
```swift
import Foundation
import GRDB
import WhoopProtocol

/// OpenWhoop persistence library — decoded streams are durable; raw frames are a
/// transient, compressed, prunable outbox. Built on GRDB/SQLite.
public enum WhoopStoreInfo {
    /// Bumped whenever the migrator gains a new migration.
    public static let schemaVersion = 1
}

public final class WhoopStore {
    let dbQueue: DatabaseQueue

    private init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try WhoopStore.makeMigrator().migrate(dbQueue)
    }

    /// Open (creating if needed) a database at `path` and run migrations.
    public convenience init(path: String) throws {
        try self.init(dbQueue: try DatabaseQueue(path: path))
    }

    /// An in-memory store (migrations applied). For tests.
    public static func inMemory() throws -> WhoopStore {
        try WhoopStore(dbQueue: try DatabaseQueue())
    }

    // MARK: - Introspection (used by tests)

    public func tableNames() throws -> Set<String> {
        try dbQueue.read { db in
            try Set(String.fetchAll(db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
    }

    public func primaryKeyColumns(_ table: String) throws -> [String] {
        try dbQueue.read { db in
            try db.primaryKey(table).columns
        }
    }
}
```
- [ ] **Step 4: Run test to verify it passes** Run: `swift test --package-path Packages/WhoopStore --filter MigrationTests` Expected: PASS (4 tests).
- [ ] **Step 5: Commit**
```bash
git add Packages/WhoopStore/Sources/WhoopStore/Database.swift Packages/WhoopStore/Sources/WhoopStore/WhoopStore.swift Packages/WhoopStore/Tests/WhoopStoreTests/MigrationTests.swift ; git commit -m "D4: GRDB schema + migrations" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task D5: `upsertDevice` + idempotent `insert(_ streams:)`
**Files:** Create: `Packages/WhoopStore/Sources/WhoopStore/StreamStore.swift` · Create Test: `Packages/WhoopStore/Tests/WhoopStoreTests/InsertTests.swift`

Add `upsertDevice(id:mac:name:)` and `insert(_ streams: Streams, deviceId:)`. Inserts use `INSERT ... ON CONFLICT DO NOTHING` so re-inserting the same `Streams` produces no duplicates. The return tuple counts rows **actually inserted** (use `db.changesCount` per insert). Event payloads serialize to JSON via the `ParsedValue` Codable conformance (deterministic with `.sortedKeys`).

- [ ] **Step 1: Write the failing test**
```swift
import XCTest
import WhoopProtocol
@testable import WhoopStore

final class InsertTests: XCTestCase {
    private func sampleStreams() -> Streams {
        Streams(
            hr: [HRSample(ts: 1000, bpm: 60), HRSample(ts: 1001, bpm: 61)],
            rr: [RRInterval(ts: 1000, rrMs: 800), RRInterval(ts: 1000, rrMs: 820)],
            events: [WhoopEvent(ts: 1736365593, kind: "BLE_CONNECTION_DOWN(12)",
                                payload: ["foo": .int(7), "bar": .string("x")])],
            battery: [BatterySample(ts: 1736365593, soc: 25.5, mv: nil)])
    }

    func testInsertReturnsRowCounts() throws {
        let store = try WhoopStore.inMemory()
        try store.upsertDevice(id: "dev1", mac: "AA:BB", name: "Strap")
        let n = try store.insert(sampleStreams(), deviceId: "dev1")
        XCTAssertEqual(n.hr, 2)
        XCTAssertEqual(n.rr, 2)
        XCTAssertEqual(n.events, 1)
        XCTAssertEqual(n.battery, 1)
    }

    func testInsertIsIdempotentByNaturalKey() throws {
        let store = try WhoopStore.inMemory()
        try store.upsertDevice(id: "dev1", mac: nil, name: nil)
        _ = try store.insert(sampleStreams(), deviceId: "dev1")
        let second = try store.insert(sampleStreams(), deviceId: "dev1")
        // Same natural keys → nothing new inserted the second time.
        XCTAssertEqual(second.hr, 0)
        XCTAssertEqual(second.rr, 0)
        XCTAssertEqual(second.events, 0)
        XCTAssertEqual(second.battery, 0)
        let stats = try store.storageStats_rowCountsForTest()
        XCTAssertEqual(stats.hr, 2)
        XCTAssertEqual(stats.rr, 2)
        XCTAssertEqual(stats.events, 1)
        XCTAssertEqual(stats.battery, 1)
    }

    func testUpsertDeviceUpdatesFields() throws {
        let store = try WhoopStore.inMemory()
        try store.upsertDevice(id: "dev1", mac: "AA", name: "first")
        try store.upsertDevice(id: "dev1", mac: "BB", name: "second")
        let row = try store.deviceRowForTest(id: "dev1")
        XCTAssertEqual(row?.mac, "BB")
        XCTAssertEqual(row?.name, "second")
    }

    func testTwoDevicesAreIndependent() throws {
        let store = try WhoopStore.inMemory()
        try store.upsertDevice(id: "a", mac: nil, name: nil)
        try store.upsertDevice(id: "b", mac: nil, name: nil)
        _ = try store.insert(sampleStreams(), deviceId: "a")
        let nb = try store.insert(sampleStreams(), deviceId: "b")
        XCTAssertEqual(nb.hr, 2)   // same ts/bpm but different deviceId → not a conflict
    }
}
```
- [ ] **Step 2: Run test to verify it fails** Run: `swift test --package-path Packages/WhoopStore --filter InsertTests` Expected: FAIL — compile error: `upsertDevice`, `insert(_:deviceId:)`, `storageStats_rowCountsForTest`, `deviceRowForTest` are undefined.
- [ ] **Step 3: Implement** — create `Packages/WhoopStore/Sources/WhoopStore/StreamStore.swift`:
```swift
import Foundation
import GRDB
import WhoopProtocol

extension WhoopStore {
    /// Deterministic JSON for an event payload (sorted keys so the same payload always
    /// serializes byte-identically — important for the natural-key dedupe and parity).
    static func encodePayload(_ payload: [String: ParsedValue]) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    /// Insert or update a device row (natural key = id).
    public func upsertDevice(id: String, mac: String?, name: String?) throws {
        let now = Int(Date().timeIntervalSince1970)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO device (id, mac, name, firstSeen, lastSeen)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    mac = excluded.mac,
                    name = excluded.name,
                    lastSeen = excluded.lastSeen
                """, arguments: [id, mac, name, now, now])
        }
    }

    /// Idempotent upsert of decoded streams by natural key. Returns the number of rows
    /// ACTUALLY inserted per stream (0 for rows that already existed).
    @discardableResult
    public func insert(_ streams: Streams, deviceId: String) throws
        -> (hr: Int, rr: Int, events: Int, battery: Int) {
        try dbQueue.write { db in
            var hr = 0, rr = 0, ev = 0, bat = 0
            for s in streams.hr {
                try db.execute(sql: """
                    INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """, arguments: [deviceId, s.ts, s.bpm])
                hr += db.changesCount
            }
            for r in streams.rr {
                try db.execute(sql: """
                    INSERT INTO rrInterval (deviceId, ts, rrMs) VALUES (?, ?, ?)
                    ON CONFLICT(deviceId, ts, rrMs) DO NOTHING
                    """, arguments: [deviceId, r.ts, r.rrMs])
                rr += db.changesCount
            }
            for e in streams.events {
                let json = try WhoopStore.encodePayload(e.payload)
                try db.execute(sql: """
                    INSERT INTO event (deviceId, ts, kind, payloadJSON) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts, kind) DO NOTHING
                    """, arguments: [deviceId, e.ts, e.kind, json])
                ev += db.changesCount
            }
            for b in streams.battery {
                try db.execute(sql: """
                    INSERT INTO battery (deviceId, ts, soc, mv) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """, arguments: [deviceId, b.ts, b.soc, b.mv])
                bat += db.changesCount
            }
            return (hr, rr, ev, bat)
        }
    }

    // MARK: - Test helpers

    public func storageStats_rowCountsForTest() throws
        -> (hr: Int, rr: Int, events: Int, battery: Int) {
        try dbQueue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hrSample") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rrInterval") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM battery") ?? 0)
        }
    }

    public func deviceRowForTest(id: String) throws -> (mac: String?, name: String?)? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT mac, name FROM device WHERE id = ?", arguments: [id]) else {
                return nil
            }
            return (row["mac"], row["name"])
        }
    }
}
```
- [ ] **Step 4: Run test to verify it passes** Run: `swift test --package-path Packages/WhoopStore --filter InsertTests` Expected: PASS (4 tests).
- [ ] **Step 5: Commit**
```bash
git add Packages/WhoopStore/Sources/WhoopStore/StreamStore.swift Packages/WhoopStore/Tests/WhoopStoreTests/InsertTests.swift ; git commit -m "D5: upsertDevice + idempotent stream insert" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task D6: raw outbox — `enqueueRawBatch` / `rawFrames` / `pendingRawBatches` / `markRawBatchSynced`
**Files:** Create: `Packages/WhoopStore/Sources/WhoopStore/RawOutbox.swift` · Create Test: `Packages/WhoopStore/Tests/WhoopStoreTests/RawOutboxTests.swift`

Add the public `ClockRef` and `RawBatchMeta` types and the raw outbox methods. Frames are length-prefixed (`UInt32` LE count of frames, then per frame `UInt32` LE length + bytes), the whole buffer zlib-compressed via GRDB's bundled zlib (`Data.compress(...)` / `Data.decompress(...)`). `enqueueRawBatch` stores meta + the compressed blob; `rawFrames` decompresses and round-trips the exact bytes. `pendingRawBatches` returns `syncedAt IS NULL` ordered by `capturedAt`, limited. `markRawBatchSynced` sets `syncedAt`.

- [ ] **Step 1: Write the failing test**
```swift
import XCTest
import WhoopProtocol
@testable import WhoopStore

final class RawOutboxTests: XCTestCase {
    private let frames: [[UInt8]] = [
        [0xAA, 0x18, 0x00, 0xFF, 0x28, 0x02, 0x0F, 0x01, 0x02, 0x03],
        [0xAA, 0x0C, 0x00, 0xFC, 0x24, 0x24, 0x03, 0x0A],
        [],                                   // empty frame must survive the round-trip
    ]
    private func meta(_ id: String, capturedAt: Int = 5000, synced: Bool = false) -> RawBatchMeta {
        RawBatchMeta(batchId: id, deviceId: "dev1",
                     clockRef: ClockRef(device: 31538447, wall: 1736365593),
                     capturedAt: capturedAt, startTs: 1736365593, endTs: 1736365600,
                     frameCount: frames.count, byteSize: frames.reduce(0) { $0 + $1.count })
    }

    func testEnqueueThenRawFramesRoundTrips() throws {
        let store = try WhoopStore.inMemory()
        try store.upsertDevice(id: "dev1", mac: nil, name: nil)
        try store.enqueueRawBatch(meta("b1"), frames: frames)
        let got = try store.rawFrames(batchId: "b1")
        XCTAssertEqual(got, frames)
    }

    func testRawFramesUnknownBatchIsEmpty() throws {
        let store = try WhoopStore.inMemory()
        XCTAssertEqual(try store.rawFrames(batchId: "nope"), [])
    }

    func testPendingExcludesSyncedAndRespectsLimitAndOrder() throws {
        let store = try WhoopStore.inMemory()
        try store.upsertDevice(id: "dev1", mac: nil, name: nil)
        try store.enqueueRawBatch(meta("old", capturedAt: 100), frames: frames)
        try store.enqueueRawBatch(meta("mid", capturedAt: 200), frames: frames)
        try store.enqueueRawBatch(meta("new", capturedAt: 300), frames: frames)
        try store.markRawBatchSynced(batchId: "mid", at: 999)

        let pending = try store.pendingRawBatches(limit: 10)
        XCTAssertEqual(pending.map { $0.batchId }, ["old", "new"])   // mid synced; oldest first

        let limited = try store.pendingRawBatches(limit: 1)
        XCTAssertEqual(limited.map { $0.batchId }, ["old"])
    }

    func testMetaRoundTripsThroughPending() throws {
        let store = try WhoopStore.inMemory()
        try store.upsertDevice(id: "dev1", mac: nil, name: nil)
        let m = meta("b1")
        try store.enqueueRawBatch(m, frames: frames)
        let pending = try store.pendingRawBatches(limit: 10)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0], m)
    }
}
```
- [ ] **Step 2: Run test to verify it fails** Run: `swift test --package-path Packages/WhoopStore --filter RawOutboxTests` Expected: FAIL — compile error: `ClockRef`, `RawBatchMeta`, `enqueueRawBatch`, `rawFrames`, `pendingRawBatches`, `markRawBatchSynced` undefined.
- [ ] **Step 3: Implement** — create `Packages/WhoopStore/Sources/WhoopStore/RawOutbox.swift`:
```swift
import Foundation
import GRDB
import WhoopProtocol

public struct ClockRef: Equatable, Codable {
    public let device: Int
    public let wall: Int
    public init(device: Int, wall: Int) { self.device = device; self.wall = wall }
}

public struct RawBatchMeta: Equatable {
    public let batchId: String
    public let deviceId: String
    public let clockRef: ClockRef
    public let capturedAt: Int
    public let startTs: Int
    public let endTs: Int
    public let frameCount: Int
    public let byteSize: Int
    public init(batchId: String, deviceId: String, clockRef: ClockRef, capturedAt: Int,
                startTs: Int, endTs: Int, frameCount: Int, byteSize: Int) {
        self.batchId = batchId; self.deviceId = deviceId; self.clockRef = clockRef
        self.capturedAt = capturedAt; self.startTs = startTs; self.endTs = endTs
        self.frameCount = frameCount; self.byteSize = byteSize
    }
}

extension WhoopStore {
    // MARK: - frame (de)serialization
    // Layout: [count u32 LE]{ [len u32 LE][bytes] } x count. zlib-compressed as a whole.

    static func packFrames(_ frames: [[UInt8]]) -> Data {
        var buf = Data()
        func appendU32(_ v: Int) {
            let u = UInt32(v)
            buf.append(UInt8(u & 0xFF)); buf.append(UInt8((u >> 8) & 0xFF))
            buf.append(UInt8((u >> 16) & 0xFF)); buf.append(UInt8((u >> 24) & 0xFF))
        }
        appendU32(frames.count)
        for f in frames {
            appendU32(f.count)
            buf.append(contentsOf: f)
        }
        return buf
    }

    static func unpackFrames(_ data: Data) -> [[UInt8]] {
        let bytes = [UInt8](data)
        var off = 0
        func readU32() -> Int? {
            guard off + 4 <= bytes.count else { return nil }
            let v = Int(bytes[off]) | (Int(bytes[off + 1]) << 8)
                | (Int(bytes[off + 2]) << 16) | (Int(bytes[off + 3]) << 24)
            off += 4
            return v
        }
        guard let count = readU32() else { return [] }
        var out: [[UInt8]] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            guard let len = readU32(), off + len <= bytes.count else { break }
            out.append(Array(bytes[off..<off + len]))
            off += len
        }
        return out
    }

    /// Compress raw frames into the outbox and store batch meta.
    public func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) throws {
        let blob = try WhoopStore.packFrames(frames).compressed(using: .zlib)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO rawBatch
                    (batchId, deviceId, capturedAt, deviceClockRef, wallClockRef,
                     startTs, endTs, frameCount, byteSize, framesBlob, syncedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                ON CONFLICT(batchId) DO NOTHING
                """, arguments: [
                    meta.batchId, meta.deviceId, meta.capturedAt,
                    meta.clockRef.device, meta.clockRef.wall,
                    meta.startTs, meta.endTs, meta.frameCount, meta.byteSize, blob])
        }
    }

    /// Decompress and return the exact frame bytes for a batch (empty if unknown).
    public func rawFrames(batchId: String) throws -> [[UInt8]] {
        let blob: Data? = try dbQueue.read { db in
            try Data.fetchOne(db,
                sql: "SELECT framesBlob FROM rawBatch WHERE batchId = ?", arguments: [batchId])
        }
        guard let blob = blob else { return [] }
        let raw = try blob.decompressed(from: .zlib)
        return WhoopStore.unpackFrames(raw)
    }

    private static func metaFromRow(_ row: Row) -> RawBatchMeta {
        RawBatchMeta(
            batchId: row["batchId"], deviceId: row["deviceId"],
            clockRef: ClockRef(device: row["deviceClockRef"], wall: row["wallClockRef"]),
            capturedAt: row["capturedAt"], startTs: row["startTs"], endTs: row["endTs"],
            frameCount: row["frameCount"], byteSize: row["byteSize"])
    }

    /// Un-synced batches (syncedAt IS NULL), oldest first, capped at `limit`.
    public func pendingRawBatches(limit: Int) throws -> [RawBatchMeta] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT batchId, deviceId, capturedAt, deviceClockRef, wallClockRef,
                       startTs, endTs, frameCount, byteSize
                FROM rawBatch
                WHERE syncedAt IS NULL
                ORDER BY capturedAt ASC
                LIMIT ?
                """, arguments: [limit]).map(WhoopStore.metaFromRow)
        }
    }

    /// Mark a batch synced (timestamp in unix seconds).
    public func markRawBatchSynced(batchId: String, at: Int) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE rawBatch SET syncedAt = ? WHERE batchId = ?",
                           arguments: [at, batchId])
        }
    }
}
```
Note for the engineer: GRDB re-exports zlib via `Data.compressed(using:)` / `Data.decompressed(from:)` (the `.zlib` algorithm). If the toolchain instead surfaces these only through `import Compression` (Apple's framework), add `import Compression` at the top of this file — both expose the same `.zlib` round-trip. Verify in Step 4 before assuming.
- [ ] **Step 4: Run test to verify it passes** Run: `swift test --package-path Packages/WhoopStore --filter RawOutboxTests` Expected: PASS (4 tests). If compression APIs don't resolve, add `import Compression` and re-run before changing anything else.
- [ ] **Step 5: Commit**
```bash
git add Packages/WhoopStore/Sources/WhoopStore/RawOutbox.swift Packages/WhoopStore/Tests/WhoopStoreTests/RawOutboxTests.swift ; git commit -m "D6: raw outbox enqueue/decompress/pending/markSynced" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task D7: `pruneRaw` — aged-synced prune + unsynced byte cap
**Files:** Modify: `Packages/WhoopStore/Sources/WhoopStore/RawOutbox.swift` · Create Test: `Packages/WhoopStore/Tests/WhoopStoreTests/PruneTests.swift`

Add `pruneRaw(now:keepWindowSeconds:maxUnsyncedBytes:)`. Two policies, both safe because decoded streams are already persisted:
1. Delete `rawBatch` rows where `syncedAt IS NOT NULL AND syncedAt < now - keepWindowSeconds`.
2. After that, if total UNSYNCED `byteSize` exceeds `maxUnsyncedBytes`, delete the OLDEST unsynced batches (by `capturedAt`) until the unsynced total is within the cap.

Returns the number of rows pruned. Decoded tables are never touched.

- [ ] **Step 1: Write the failing test**
```swift
import XCTest
import WhoopProtocol
@testable import WhoopStore

final class PruneTests: XCTestCase {
    private let frames: [[UInt8]] = [[0xAA, 0x00, 0x01, 0x02]]
    private func meta(_ id: String, capturedAt: Int, bytes: Int) -> RawBatchMeta {
        RawBatchMeta(batchId: id, deviceId: "dev1",
                     clockRef: ClockRef(device: 0, wall: 0),
                     capturedAt: capturedAt, startTs: 0, endTs: 0,
                     frameCount: frames.count, byteSize: bytes)
    }

    func testPrunesAgedSyncedBatches() throws {
        let store = try WhoopStore.inMemory()
        try store.upsertDevice(id: "dev1", mac: nil, name: nil)
        // synced long ago → pruned; synced recently → kept; unsynced → kept.
        try store.enqueueRawBatch(meta("aged", capturedAt: 10, bytes: 100), frames: frames)
        try store.enqueueRawBatch(meta("fresh", capturedAt: 20, bytes: 100), frames: frames)
        try store.enqueueRawBatch(meta("unsynced", capturedAt: 30, bytes: 100), frames: frames)
        try store.markRawBatchSynced(batchId: "aged", at: 1000)
        try store.markRawBatchSynced(batchId: "fresh", at: 9500)

        let pruned = try store.pruneRaw(now: 10000, keepWindowSeconds: 1000,
                                        maxUnsyncedBytes: 1_000_000)
        XCTAssertEqual(pruned, 1)                                  // only "aged"
        let remaining = try store.allBatchIdsForTest()
        XCTAssertEqual(remaining, ["fresh", "unsynced"])
    }

    func testCapsUnsyncedBytesByDroppingOldest() throws {
        let store = try WhoopStore.inMemory()
        try store.upsertDevice(id: "dev1", mac: nil, name: nil)
        try store.enqueueRawBatch(meta("u1", capturedAt: 10, bytes: 500), frames: frames)
        try store.enqueueRawBatch(meta("u2", capturedAt: 20, bytes: 500), frames: frames)
        try store.enqueueRawBatch(meta("u3", capturedAt: 30, bytes: 500), frames: frames)
        // cap = 1000 → must drop oldest until <= 1000 → drop u1 (1500→1000).
        let pruned = try store.pruneRaw(now: 100, keepWindowSeconds: 0, maxUnsyncedBytes: 1000)
        XCTAssertEqual(pruned, 1)
        XCTAssertEqual(try store.allBatchIdsForTest(), ["u2", "u3"])
    }

    func testPruneNeverTouchesDecodedTables() throws {
        let store = try WhoopStore.inMemory()
        try store.upsertDevice(id: "dev1", mac: nil, name: nil)
        _ = try store.insert(Streams(hr: [HRSample(ts: 1, bpm: 60)]), deviceId: "dev1")
        try store.enqueueRawBatch(meta("aged", capturedAt: 10, bytes: 100), frames: frames)
        try store.markRawBatchSynced(batchId: "aged", at: 1)
        _ = try store.pruneRaw(now: 100000, keepWindowSeconds: 10, maxUnsyncedBytes: 0)
        XCTAssertEqual(try store.storageStats_rowCountsForTest().hr, 1)   // decoded untouched
    }

    func testNothingToPruneReturnsZero() throws {
        let store = try WhoopStore.inMemory()
        try store.upsertDevice(id: "dev1", mac: nil, name: nil)
        try store.enqueueRawBatch(meta("u1", capturedAt: 10, bytes: 100), frames: frames)
        let pruned = try store.pruneRaw(now: 100, keepWindowSeconds: 1000,
                                        maxUnsyncedBytes: 1_000_000)
        XCTAssertEqual(pruned, 0)
    }
}
```
- [ ] **Step 2: Run test to verify it fails** Run: `swift test --package-path Packages/WhoopStore --filter PruneTests` Expected: FAIL — compile error: `pruneRaw` and `allBatchIdsForTest` undefined.
- [ ] **Step 3: Implement** — append to `Packages/WhoopStore/Sources/WhoopStore/RawOutbox.swift`:
```swift
extension WhoopStore {
    /// Prune raw outbox rows. Safe to drop raw at any time: decoded streams are persisted
    /// separately. Returns the number of rawBatch rows deleted.
    /// 1) Delete synced batches older than the keep window (syncedAt < now - keepWindow).
    /// 2) If unsynced bytes exceed the cap, drop oldest unsynced batches until within cap.
    @discardableResult
    public func pruneRaw(now: Int, keepWindowSeconds: Int, maxUnsyncedBytes: Int) throws -> Int {
        try dbQueue.write { db in
            var pruned = 0
            // Policy 1: aged synced batches.
            let cutoff = now - keepWindowSeconds
            try db.execute(sql: """
                DELETE FROM rawBatch WHERE syncedAt IS NOT NULL AND syncedAt < ?
                """, arguments: [cutoff])
            pruned += db.changesCount

            // Policy 2: unsynced byte cap — drop oldest unsynced until total <= cap.
            var unsyncedTotal = try Int.fetchOne(db,
                sql: "SELECT COALESCE(SUM(byteSize), 0) FROM rawBatch WHERE syncedAt IS NULL") ?? 0
            if unsyncedTotal > maxUnsyncedBytes {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT batchId, byteSize FROM rawBatch
                    WHERE syncedAt IS NULL
                    ORDER BY capturedAt ASC
                    """)
                for row in rows {
                    if unsyncedTotal <= maxUnsyncedBytes { break }
                    let batchId: String = row["batchId"]
                    let size: Int = row["byteSize"]
                    try db.execute(sql: "DELETE FROM rawBatch WHERE batchId = ?",
                                   arguments: [batchId])
                    pruned += db.changesCount
                    unsyncedTotal -= size
                }
            }
            return pruned
        }
    }

    // MARK: - Test helper
    public func allBatchIdsForTest() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT batchId FROM rawBatch ORDER BY capturedAt ASC")
        }
    }
}
```
- [ ] **Step 4: Run test to verify it passes** Run: `swift test --package-path Packages/WhoopStore --filter PruneTests` Expected: PASS (4 tests).
- [ ] **Step 5: Commit**
```bash
git add Packages/WhoopStore/Sources/WhoopStore/RawOutbox.swift Packages/WhoopStore/Tests/WhoopStoreTests/PruneTests.swift ; git commit -m "D7: pruneRaw (aged-synced + unsynced byte cap)" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task D8: read queries + `storageStats`
**Files:** Create: `Packages/WhoopStore/Sources/WhoopStore/Reads.swift` · Create Test: `Packages/WhoopStore/Tests/WhoopStoreTests/ReadTests.swift`

Add `hrSamples` / `rrIntervals` / `events` / `batterySamples` (by `deviceId`, `ts` in `[from, to]` inclusive, ordered by `ts` ascending — RR breaks ties by `rrMs`, events by `kind` — limited) and `storageStats()` returning `(decodedRows, rawBatches, rawBytes)` where `decodedRows = hr + rr + events + battery` row counts and `rawBytes = SUM(byteSize)` over all rawBatch rows. Event payloads decode from `payloadJSON` back into `[String: ParsedValue]`.

- [ ] **Step 1: Write the failing test**
```swift
import XCTest
import WhoopProtocol
@testable import WhoopStore

final class ReadTests: XCTestCase {
    private func seeded() throws -> WhoopStore {
        let store = try WhoopStore.inMemory()
        try store.upsertDevice(id: "dev1", mac: nil, name: nil)
        try store.upsertDevice(id: "other", mac: nil, name: nil)
        let s = Streams(
            hr: [HRSample(ts: 100, bpm: 60), HRSample(ts: 200, bpm: 61),
                 HRSample(ts: 300, bpm: 62)],
            rr: [RRInterval(ts: 100, rrMs: 800), RRInterval(ts: 100, rrMs: 820)],
            events: [WhoopEvent(ts: 150, kind: "BLE_CONNECTION_DOWN(12)",
                                payload: ["k": .int(9)])],
            battery: [BatterySample(ts: 120, soc: 88.0, mv: 3900)])
        _ = try store.insert(s, deviceId: "dev1")
        // Decoy on another device — must never appear in dev1 reads.
        _ = try store.insert(Streams(hr: [HRSample(ts: 200, bpm: 99)]), deviceId: "other")
        return store
    }

    func testHrSamplesRangeOrderLimitAndDeviceScope() throws {
        let store = try seeded()
        let all = try store.hrSamples(deviceId: "dev1", from: 0, to: 1000, limit: 100)
        XCTAssertEqual(all, [HRSample(ts: 100, bpm: 60), HRSample(ts: 200, bpm: 61),
                             HRSample(ts: 300, bpm: 62)])
        let windowed = try store.hrSamples(deviceId: "dev1", from: 150, to: 250, limit: 100)
        XCTAssertEqual(windowed, [HRSample(ts: 200, bpm: 61)])     // inclusive range
        let limited = try store.hrSamples(deviceId: "dev1", from: 0, to: 1000, limit: 2)
        XCTAssertEqual(limited.count, 2)                            // ascending, first 2
        XCTAssertEqual(limited.first?.ts, 100)
    }

    func testRrIntervalsReturnsBothTiedRows() throws {
        let store = try seeded()
        let rr = try store.rrIntervals(deviceId: "dev1", from: 0, to: 1000, limit: 100)
        XCTAssertEqual(rr, [RRInterval(ts: 100, rrMs: 800), RRInterval(ts: 100, rrMs: 820)])
    }

    func testEventsDecodePayload() throws {
        let store = try seeded()
        let evs = try store.events(deviceId: "dev1", from: 0, to: 1000, limit: 100)
        XCTAssertEqual(evs, [WhoopEvent(ts: 150, kind: "BLE_CONNECTION_DOWN(12)",
                                        payload: ["k": .int(9)])])
    }

    func testBatterySamples() throws {
        let store = try seeded()
        let bat = try store.batterySamples(deviceId: "dev1", from: 0, to: 1000, limit: 100)
        XCTAssertEqual(bat, [BatterySample(ts: 120, soc: 88.0, mv: 3900)])
    }

    func testStorageStats() throws {
        let store = try seeded()
        try store.enqueueRawBatch(
            RawBatchMeta(batchId: "b1", deviceId: "dev1",
                         clockRef: ClockRef(device: 0, wall: 0), capturedAt: 1,
                         startTs: 0, endTs: 0, frameCount: 1, byteSize: 4),
            frames: [[0xAA, 0x00, 0x01, 0x02]])
        let stats = try store.storageStats()
        // dev1: 3 hr + 2 rr + 1 event + 1 battery = 7 ; other: 1 hr = 1 → 8 decoded rows.
        XCTAssertEqual(stats.decodedRows, 8)
        XCTAssertEqual(stats.rawBatches, 1)
        XCTAssertEqual(stats.rawBytes, 4)
    }
}
```
- [ ] **Step 2: Run test to verify it fails** Run: `swift test --package-path Packages/WhoopStore --filter ReadTests` Expected: FAIL — compile error: `hrSamples`, `rrIntervals`, `events`, `batterySamples`, `storageStats` undefined.
- [ ] **Step 3: Implement** — create `Packages/WhoopStore/Sources/WhoopStore/Reads.swift`:
```swift
import Foundation
import GRDB
import WhoopProtocol

extension WhoopStore {
    public func hrSamples(deviceId: String, from: Int, to: Int, limit: Int) throws -> [HRSample] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, bpm FROM hrSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { HRSample(ts: $0["ts"], bpm: $0["bpm"]) }
        }
    }

    public func rrIntervals(deviceId: String, from: Int, to: Int, limit: Int) throws -> [RRInterval] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, rrMs FROM rrInterval
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC, rrMs ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { RRInterval(ts: $0["ts"], rrMs: $0["rrMs"]) }
        }
    }

    public func events(deviceId: String, from: Int, to: Int, limit: Int) throws -> [WhoopEvent] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, kind, payloadJSON FROM event
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC, kind ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { row in
                    let json: String = row["payloadJSON"]
                    let payload = (try? JSONDecoder().decode(
                        [String: ParsedValue].self,
                        from: Data(json.utf8))) ?? [:]
                    return WhoopEvent(ts: row["ts"], kind: row["kind"], payload: payload)
                }
        }
    }

    public func batterySamples(deviceId: String, from: Int, to: Int, limit: Int) throws -> [BatterySample] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, soc, mv FROM battery
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { BatterySample(ts: $0["ts"], soc: $0["soc"], mv: $0["mv"]) }
        }
    }

    /// Aggregate storage footprint: total decoded rows, raw batch count, total raw byteSize.
    public func storageStats() throws -> (decodedRows: Int, rawBatches: Int, rawBytes: Int) {
        try dbQueue.read { db in
            let hr = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hrSample") ?? 0
            let rr = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rrInterval") ?? 0
            let ev = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event") ?? 0
            let bat = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM battery") ?? 0
            let batches = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rawBatch") ?? 0
            let bytes = try Int.fetchOne(db,
                sql: "SELECT COALESCE(SUM(byteSize), 0) FROM rawBatch") ?? 0
            return (hr + rr + ev + bat, batches, bytes)
        }
    }
}
```
- [ ] **Step 4: Run test to verify it passes** Run: `swift test --package-path Packages/WhoopStore --filter ReadTests` Expected: PASS (5 tests). Then run the whole package suite to confirm no regression: `swift test --package-path Packages/WhoopStore` Expected: PASS (all WhoopStore tests).
- [ ] **Step 5: Commit**
```bash
git add Packages/WhoopStore/Sources/WhoopStore/Reads.swift Packages/WhoopStore/Tests/WhoopStoreTests/ReadTests.swift ; git commit -m "D8: read queries + storageStats" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```
## Phase E — App integration: clock correlation, Collector, background collection (M3)

This phase wires the Phase D local store into the live BLE path so that **decoded streams are persisted and raw is queued continuously while connected**, survives backgrounding/relaunch, and is bounded on disk. It assumes Phase D shipped `WhoopStore` (new package at `Packages/WhoopStore`) and `extractStreams`/`Streams` in `WhoopProtocol`.

**Conventions for this phase**
- iOS sim is `iPhone 17`. App is XcodeGen-generated: after editing `ios/project.yml` always `cd ios && xcodegen generate` before building. **Never `git add` `ios/OpenWhoop.xcodeproj` or `ios/OpenWhoop/Info.plist`** (both git-ignored).
- Build: `cd ios && xcodegen generate && xcodebuild -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' build`
- Test: `cd ios && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17'`
- **Concurrency (Swift 6.3):** `BLEManager`, `Collector`, `LiveState`, `LiveViewModel` are all `@MainActor`. `WhoopStore` does synchronous SQLite file I/O. **v1 decision: run `WhoopStore` calls on the main actor** (cadence batches are small — a few hundred frames at most per flush — and SQLite writes are sub-millisecond). This keeps the contract simple and avoids `Sendable` boxing of `Streams`/frame buffers. **Flagged for M5:** when sync + historical backfill land, move `WhoopStore` behind a serial background executor (an `actor` wrapper or a dedicated `DispatchQueue`) so large backfill writes never block the main thread.
- **The core invariant (E2):** on every flush we `store.insert(streams)` **before** `store.enqueueRawBatch(...)`. Decoded streams are the durable local record; raw is the transient outbox. Persisting decoded first means raw pruning (E5) can never cause loss of a decoded metric.

> **Note on the Phase D contract:** the steps below assume the Phase D `Streams` row types expose `.ts` (HRSample/RRInterval/WhoopEvent/BatterySample) and the `WhoopStore` API from this plan's header. If Phase D named a field differently, adjust the `tsValues`/accessor lines to match — confirm against the built `WhoopProtocol.Streams`.

---

### Task E1: Clock correlation helper (testable core) + capture on bond
**Files:** Create: `ios/OpenWhoop/Collect/ClockCorrelation.swift` · Test: `ios/OpenWhoopTests/ClockCorrelationTests.swift` · Modify: `ios/OpenWhoop/BLE/BLEManager.swift`

A pure helper turns a decoded `GET_CLOCK` COMMAND_RESPONSE `ParsedFrame` + a wall time into a `ClockRef`. The `BLEManager` wiring (send `.getClock` after bond, capture the ref on response) is a build-verify.

- [ ] **Step 1: Add the `WhoopStore` package to the app (XcodeGen).** `WhoopStore` is consumed starting in E2; add it now so the project regenerates cleanly. Edit `ios/project.yml` — add to `packages:` and to BOTH target `dependencies:` lists.
  ```yaml
  packages:
    WhoopProtocol:
      path: ../Packages/WhoopProtocol
    WhoopStore:
      path: ../Packages/WhoopStore
  targets:
    OpenWhoop:
      # ...
      dependencies:
        - package: WhoopProtocol
        - package: WhoopStore
    OpenWhoopTests:
      # ...
      dependencies:
        - target: OpenWhoop
        - package: WhoopProtocol
        - package: WhoopStore
  ```
  Then regenerate: `cd ios && xcodegen generate`.

- [ ] **Step 2: Write the failing test (RED).** Build a real GET_CLOCK COMMAND_RESPONSE frame with `frameFromPayload` (matches `PostHooksTests.testCommandResponseGetClock`: payload `[0x0a, 0x01]` + LE32 clock, `type: 36`, `cmd: 11`). Assert the helper extracts `device` from `parsed["clock"]` and uses the supplied wall time; assert it returns `nil` for a non-clock frame.
  ```swift
  import XCTest
  import WhoopProtocol
  import WhoopStore
  @testable import OpenWhoop

  final class ClockCorrelationTests: XCTestCase {

      /// Build a real GET_CLOCK COMMAND_RESPONSE frame (type 36, cmd 11).
      private func clockFrame(device: UInt32) -> [UInt8] {
          var pay: [UInt8] = [0x0a, 0x01]
          pay += [UInt8(device & 0xFF), UInt8((device >> 8) & 0xFF),
                  UInt8((device >> 16) & 0xFF), UInt8((device >> 24) & 0xFF)]
          return frameFromPayload(pay, type: 36, seq: 1, cmd: 11)
      }

      func testClockRefFromGetClockResponse() {
          let parsed = parseFrame(clockFrame(device: 1_700_000_000))
          XCTAssertEqual(parsed.parsed["clock"]?.intValue, 1_700_000_000,
                         "fixture must decode a GET_CLOCK clock value")
          let ref = ClockCorrelation.clockRef(from: parsed, wall: 1_716_400_000)
          XCTAssertEqual(ref, ClockRef(device: 1_700_000_000, wall: 1_716_400_000))
      }

      func testNonClockFrameReturnsNil() {
          // A frame with no "clock" key → nil.
          let ref = ClockCorrelation.clockRef(
              from: parseFrame([0x00, 0x01, 0x02]), wall: 1_716_400_000)
          XCTAssertNil(ref)
      }
  }
  ```

- [ ] **Step 3: Implement the helper (GREEN).**
  ```swift
  import Foundation
  import WhoopProtocol
  import WhoopStore

  /// Pure helper: correlate the strap's monotonic device clock to wall time.
  /// REALTIME_DATA timestamps are a device monotonic epoch; the server/app maps them to
  /// unix time using the (device, wall) pair captured at connect via GET_CLOCK + now.
  /// No CoreBluetooth, no I/O — fully unit-testable.
  enum ClockCorrelation {
      /// Build a `ClockRef` from a decoded GET_CLOCK COMMAND_RESPONSE frame and the wall
      /// time observed when the response arrived. Returns nil unless the frame parsed OK,
      /// passed CRC, and carries a `clock` value.
      static func clockRef(from parsed: ParsedFrame, wall: Int) -> ClockRef? {
          guard parsed.ok, parsed.crcOK != false,
                let device = parsed.parsed["clock"]?.intValue else { return nil }
          return ClockRef(device: device, wall: wall)
      }
  }
  ```

- [ ] **Step 4: Wire `BLEManager` to request + capture the clock (build-verify).** Add a configurable `deviceId` (default the server's existing id `"my-whoop"`), a captured `clockRef`, send `.getClock` right after bonding, and capture the ref when the response arrives. Edit `BLEManager.swift`:
  - Add stored properties near the other state:
    ```swift
    /// Stable device id; matches the server's existing device for sync parity. Overridable.
    let deviceId: String
    /// Captured (device↔wall) correlation from GET_CLOCK; nil until the response lands.
    private(set) var clockRef: ClockRef?
    ```
  - Extend `init` (keep the existing zero-arg-friendly call site working):
    ```swift
    public init(state: LiveState, deviceId: String = "my-whoop") {
        self.state = state
        self.deviceId = deviceId
        self.router = FrameRouter(state: state)
        super.init()
        central = CBCentralManager(
            delegate: self, queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: BLEManager.restoreID])
    }
    ```
  - In `didWriteValueFor` (the confirmed-write/bond success path), after `state.bonded = true`, request the clock:
    ```swift
    if !didBond {
        didBond = true
        state.bonded = true
        log("BONDED (confirmed write acknowledged) — custom channels should now flow")
        send(.getClock)   // capture the device↔wall correlation for REALTIME_DATA ts mapping
    }
    ```
  - In `didUpdateValueFor`, capture the ref from the reassembled custom-char frames (this is superseded/extended in E3 to also feed the Collector):
    ```swift
    case BLEManager.dataNotifyChar, BLEManager.cmdNotifyChar, BLEManager.eventNotifyChar:
        for frame in reassembler.feed(bytes) {
            router.handle(frame: frame)
            if clockRef == nil {
                let parsed = parseFrame(frame)
                if let ref = ClockCorrelation.clockRef(from: parsed, wall: Int(Date().timeIntervalSince1970)) {
                    clockRef = ref
                    log("Clock correlated: device=\(ref.device) wall=\(ref.wall)")
                }
            }
        }
    ```
  Build-verify + run the new tests: `cd ios && xcodegen generate && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OpenWhoopTests/ClockCorrelationTests`.

- [ ] **Step 5: Commit.**
  ```bash
  git add ios/project.yml ios/OpenWhoop/Collect/ClockCorrelation.swift ios/OpenWhoopTests/ClockCorrelationTests.swift ios/OpenWhoop/BLE/BLEManager.swift
  git commit -m "E1: clock correlation helper + capture GET_CLOCK on bond; add WhoopStore package" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

### Task E2: Collector (testable core)
**Files:** Create: `ios/OpenWhoop/Collect/Collector.swift` · Test: `ios/OpenWhoopTests/CollectorTests.swift`

A `@MainActor` `Collector` buffers complete frames and, on a cadence (every N frames OR T seconds, plus explicit `flush()`), parses the buffer → `extractStreams(parsed, clockRef)` → `store.insert(streams)` (decoded first) → `store.enqueueRawBatch(meta, frames)` (raw second) → clears the buffer. Before a `ClockRef` exists it buffers without persisting. Fully testable with an in-memory `WhoopStore` (`path: ":memory:"`) and fixture frames.

- [ ] **Step 1: Write the failing tests (RED).** Use the real REALTIME_DATA HR fixture so `extractStreams` produces decoded rows. Cover: (a) no persist before a clock ref; (b) after setting the ref, frames at the N-frame threshold persist decoded rows AND enqueue exactly one raw batch; (c) `flush()` drains a partial buffer; (d) ordering — decoded inserted before raw enqueued (a `SpyStore` that fails raw enqueue still has decoded rows); (e) buffer cleared after flush. Verify via `storageStats()`.
  ```swift
  import XCTest
  import WhoopProtocol
  import WhoopStore
  @testable import OpenWhoop

  @MainActor
  final class CollectorTests: XCTestCase {
      private func hex(_ s: String) -> [UInt8] {
          var out = [UInt8](); out.reserveCapacity(s.count / 2)
          var i = s.startIndex
          while i < s.endIndex { let j = s.index(i, offsetBy: 2)
              out.append(UInt8(s[i..<j], radix: 16)!); i = j }
          return out
      }
      // Real REALTIME_DATA frame (HR=60) — produces one HR decoded sample.
      private let hr60 = "aa1800ff28020f3de10128663c00000000000000000001010d844e7c"

      private func makeStore() throws -> WhoopStore {
          let store = try WhoopStore(path: ":memory:")
          try store.upsertDevice(id: "my-whoop", mac: nil, name: "test")
          return store
      }

      func testBuffersWithoutPersistingUntilClockRefSet() throws {
          let store = try makeStore()
          let c = Collector(store: store, deviceId: "my-whoop",
                            policy: .init(maxFrames: 1, maxInterval: 60))
          c.ingest(hex(hr60))
          XCTAssertEqual(try store.storageStats().decodedRows, 0, "no persist before a ClockRef")
          XCTAssertEqual(try store.storageStats().rawBatches, 0)
          XCTAssertEqual(c.bufferedCount, 1)
      }

      func testFrameThresholdPersistsDecodedAndEnqueuesRaw() throws {
          let store = try makeStore()
          let c = Collector(store: store, deviceId: "my-whoop",
                            policy: .init(maxFrames: 2, maxInterval: 60))
          c.clockRef = ClockRef(device: 1_700_000_000, wall: 1_716_400_000)
          c.ingest(hex(hr60))
          XCTAssertEqual(try store.storageStats().rawBatches, 0, "below threshold")
          c.ingest(hex(hr60))   // hits maxFrames=2 → auto-flush
          let stats = try store.storageStats()
          XCTAssertGreaterThan(stats.decodedRows, 0, "decoded HR samples persisted")
          XCTAssertEqual(stats.rawBatches, 1, "one raw batch enqueued")
          XCTAssertEqual(c.bufferedCount, 0, "buffer cleared after flush")
      }

      func testFlushDrainsPartialBuffer() throws {
          let store = try makeStore()
          let c = Collector(store: store, deviceId: "my-whoop",
                            policy: .init(maxFrames: 100, maxInterval: 3600))
          c.clockRef = ClockRef(device: 1_700_000_000, wall: 1_716_400_000)
          c.ingest(hex(hr60))
          c.flush()
          XCTAssertEqual(try store.storageStats().rawBatches, 1)
          XCTAssertGreaterThan(try store.storageStats().decodedRows, 0)
      }

      func testDecodedPersistedBeforeRawEnqueued() throws {
          // Ordering invariant: a store that fails raw enqueue must still have decoded rows.
          let real = try makeStore()
          let spy = SpyStore(wrapping: real, failRawEnqueue: true)
          let c = Collector(store: spy, deviceId: "my-whoop",
                            policy: .init(maxFrames: 1, maxInterval: 60))
          c.clockRef = ClockRef(device: 1_700_000_000, wall: 1_716_400_000)
          c.ingest(hex(hr60))   // insert succeeds, enqueueRawBatch throws
          XCTAssertGreaterThan(try real.storageStats().decodedRows, 0,
                               "decoded committed before raw attempted")
      }
  }

  /// Test double proving decoded-before-raw ordering (WhoopStore is final → protocol seam).
  @MainActor
  final class SpyStore: StoreWriting {
      private let wrapped: WhoopStore
      private let failRawEnqueue: Bool
      init(wrapping: WhoopStore, failRawEnqueue: Bool) {
          self.wrapped = wrapping; self.failRawEnqueue = failRawEnqueue
      }
      func insert(_ streams: Streams, deviceId: String) throws
          -> (hr: Int, rr: Int, events: Int, battery: Int) {
          try wrapped.insert(streams, deviceId: deviceId)
      }
      func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) throws {
          struct RawEnqueueFailed: Error {}
          if failRawEnqueue { throw RawEnqueueFailed() }
          try wrapped.enqueueRawBatch(meta, frames: frames)
      }
  }
  ```

- [ ] **Step 2: Implement the Collector + a `StoreWriting` seam (GREEN).**
  ```swift
  import Foundation
  import WhoopProtocol
  import WhoopStore

  /// The subset of WhoopStore the Collector needs. A protocol so tests can inject a spy
  /// (WhoopStore is `final`). WhoopStore conforms via the extension below.
  @MainActor
  protocol StoreWriting: AnyObject {
      @discardableResult
      func insert(_ streams: Streams, deviceId: String) throws -> (hr: Int, rr: Int, events: Int, battery: Int)
      func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) throws
  }
  extension WhoopStore: StoreWriting {}

  /// Cadence: flush after this many buffered frames OR this many seconds since the last
  /// flush — whichever first. Also flushed explicitly on disconnect/foreground.
  struct CollectorPolicy {
      var maxFrames: Int
      var maxInterval: TimeInterval
      static let `default` = CollectorPolicy(maxFrames: 64, maxInterval: 30)
  }

  /// Buffers complete (reassembled) frames and periodically persists them:
  /// parse → extractStreams(clockRef) → store.insert (DECODED FIRST, durable) →
  /// store.enqueueRawBatch (raw, transient outbox) → clear buffer.
  /// Because decoded is committed before raw is queued, pruning raw never loses a metric.
  @MainActor
  final class Collector {
      private let store: StoreWriting
      private let deviceId: String
      private let policy: CollectorPolicy
      private let now: () -> Int
      private let monotonic: () -> TimeInterval

      /// Set once the GET_CLOCK correlation lands (E1). Until then, frames buffer un-persisted.
      var clockRef: ClockRef?
      private var buffer: [[UInt8]] = []
      private var batchStartedAt: TimeInterval
      var bufferedCount: Int { buffer.count }

      init(store: StoreWriting, deviceId: String,
           policy: CollectorPolicy = .default,
           now: @escaping () -> Int = { Int(Date().timeIntervalSince1970) },
           monotonic: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
          self.store = store; self.deviceId = deviceId; self.policy = policy
          self.now = now; self.monotonic = monotonic
          self.batchStartedAt = monotonic()
      }

      /// Buffer one complete frame; auto-flush if the cadence threshold is hit.
      func ingest(_ frame: [UInt8]) {
          buffer.append(frame)
          guard clockRef != nil else { return }   // can't correlate ts yet → keep buffering
          if buffer.count >= policy.maxFrames || (monotonic() - batchStartedAt) >= policy.maxInterval {
              flush()
          }
      }

      /// Persist + queue everything buffered. No-op when empty or before a clock ref exists.
      func flush() {
          guard let ref = clockRef, !buffer.isEmpty else { return }
          let frames = buffer
          buffer.removeAll(keepingCapacity: true)
          batchStartedAt = monotonic()

          let parsed = frames.map { parseFrame($0) }
          let streams = extractStreams(parsed, deviceClockRef: ref.device, wallClockRef: ref.wall)
          do {
              try store.insert(streams, deviceId: deviceId)   // DECODED FIRST (durable)
          } catch {
              buffer.insert(contentsOf: frames, at: 0)         // retry next cadence
              return
          }
          // RAW SECOND (transient outbox). Failure is non-fatal — decoded is already durable.
          let wall = now()
          let tsValues = streams.hr.map(\.ts) + streams.rr.map(\.ts)
              + streams.events.map(\.ts) + streams.battery.map(\.ts)
          let meta = RawBatchMeta(
              batchId: UUID().uuidString, deviceId: deviceId, clockRef: ref, capturedAt: wall,
              startTs: tsValues.min() ?? wall, endTs: tsValues.max() ?? wall,
              frameCount: frames.count, byteSize: frames.reduce(0) { $0 + $1.count })
          try? store.enqueueRawBatch(meta, frames: frames)
      }
  }
  ```

- [ ] **Step 3: Run the tests green.** `cd ios && xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:OpenWhoopTests/CollectorTests`

- [ ] **Step 4: Commit.**
  ```bash
  git add ios/OpenWhoop/Collect/Collector.swift ios/OpenWhoopTests/CollectorTests.swift
  git commit -m "E2: Collector buffers frames, persists decoded-before-raw on cadence/flush" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

### Task E3: Wire the Collector into the BLE path (build-verify)
**Files:** Modify: `ios/OpenWhoop/BLE/BLEManager.swift` · Create: `ios/OpenWhoop/Collect/StorePaths.swift`

`BLEManager` owns a `Collector`, feeds every complete custom-char frame to BOTH `FrameRouter` (UI) and `Collector` (persistence), pushes the captured `ClockRef` into the Collector, and `flush()`es on disconnect. CoreBluetooth → complete-code + build-verify.

- [ ] **Step 1: Add a store-path helper.**
  ```swift
  import Foundation
  enum StorePaths {
      /// `<AppSupport>/OpenWhoop/whoop.sqlite`, creating the directory if needed.
      static func defaultDatabasePath() throws -> String {
          let fm = FileManager.default
          let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)
              .appendingPathComponent("OpenWhoop", isDirectory: true)
          try fm.createDirectory(at: base, withIntermediateDirectories: true)
          return base.appendingPathComponent("whoop.sqlite").path
      }
  }
  ```

- [ ] **Step 2: Give `BLEManager` a `Collector` and feed it.** Edit `BLEManager.swift` (add `import WhoopStore`):
  - Add `private let collector: Collector?` near `router`.
  - Extend `init` to build a store + collector (non-fatal on failure — app still runs live-only):
    ```swift
    public init(state: LiveState, deviceId: String = "my-whoop", collector: Collector? = nil) {
        self.state = state
        self.deviceId = deviceId
        self.router = FrameRouter(state: state)
        if let collector {
            self.collector = collector
        } else if let store = try? WhoopStore(path: try StorePaths.defaultDatabasePath()) {
            try? store.upsertDevice(id: deviceId, mac: nil, name: "WHOOP 4.0")
            self.collector = Collector(store: store, deviceId: deviceId)
        } else {
            self.collector = nil
        }
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: BLEManager.restoreID])
    }
    ```
  - In `didUpdateValueFor`, feed each complete custom-char frame to the Collector AND propagate the captured clock ref (this replaces the inline capture from E1/Step-4):
    ```swift
    case BLEManager.dataNotifyChar, BLEManager.cmdNotifyChar, BLEManager.eventNotifyChar:
        for frame in reassembler.feed(bytes) {
            router.handle(frame: frame)                       // UI
            if clockRef == nil {
                let parsed = parseFrame(frame)
                if let ref = ClockCorrelation.clockRef(from: parsed, wall: Int(Date().timeIntervalSince1970)) {
                    clockRef = ref
                    collector?.clockRef = ref                  // unblocks buffered persistence
                    log("Clock correlated: device=\(ref.device) wall=\(ref.wall)")
                }
            }
            collector?.ingest(frame)                           // persistence
        }
    ```
  - In `didDisconnectPeripheral`, add as the first line: `collector?.flush()`.

- [ ] **Step 3: Build + full existing test suite green.**
  ```bash
  cd ios && xcodegen generate && \
  xcodebuild -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' build && \
  xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17'
  ```

- [ ] **Step 4: Commit.**
  ```bash
  git add ios/OpenWhoop/Collect/StorePaths.swift ios/OpenWhoop/BLE/BLEManager.swift
  git commit -m "E3: feed complete frames to Collector + FrameRouter; flush on disconnect" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

### Task E4: Complete background state restoration (build-verify; folds in deferred Plan-1 review items 1.3/1.4)
**Files:** Modify: `ios/OpenWhoop/BLE/BLEManager.swift`

Finish `willRestoreState` so background relaunch actually resumes collection. The current stub stores the restored peripheral + delegate but never re-discovers services — so `cmdCharacteristic` is nil after relaunch and `send()` silently no-ops. Re-discover (or reconnect, then discover) and reconnect the restored peripheral on power-on instead of a fresh scan.

- [ ] **Step 1: Track the restored peripheral and complete `willRestoreState`.** Add `private var restoredPeripheral: CBPeripheral?` near the CoreBluetooth state. Replace the `willRestoreState` body:
  ```swift
  public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
      guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
            let p = peripherals.first else { log("Restore: no peripherals"); return }
      self.peripheral = p
      self.restoredPeripheral = p
      p.delegate = self
      // Collection only runs post-bond, so a restored link was bonded; seed it (a BLE_BONDED
      // event re-confirms). didWriteValueFor won't re-fire on its own.
      state.bonded = true; didBond = true
      if p.state == .connected {
          state.connected = true
          // CRITICAL: re-discover services so cmdCharacteristic is re-acquired — otherwise
          // send() no-ops forever after relaunch and notifications aren't re-routed.
          log("Restored CONNECTED peripheral \(p.identifier) — re-discovering services")
          p.discoverServices([BLEManager.customService, BLEManager.heartRateService, BLEManager.batteryService])
      } else {
          state.connected = false
          log("Restored DISCONNECTED peripheral \(p.identifier) — reconnect on poweredOn")
          if central.state == .poweredOn { central.connect(p, options: nil) }
      }
  }
  ```
  (On restore, the existing `didDiscoverCharacteristicsFor` re-acquires `cmdCharacteristic` and will re-issue the bonding confirmed write — harmless on an already-bonded strap. Acceptable for v1.)

- [ ] **Step 2: On power-on, reconnect the restored peripheral instead of scanning.** Replace `centralManagerDidUpdateState`:
  ```swift
  public func centralManagerDidUpdateState(_ central: CBCentralManager) {
      log("Central state: \(central.state.rawValue) (5 = poweredOn)")
      guard central.state == .poweredOn else { return }
      if let p = restoredPeripheral {
          log("poweredOn with restored peripheral — reconnecting \(p.identifier)")
          if p.state != .connected { central.connect(p, options: nil) }
          else { p.discoverServices([BLEManager.customService, BLEManager.heartRateService, BLEManager.batteryService]) }
      } else {
          connect()
      }
  }
  ```
  Add `restoredPeripheral = nil` at the top of `didConnect`.

- [ ] **Step 3: Build + existing tests green.** (same build/test commands as E3)

- [ ] **Step 4: Document the manual on-device background-collection check.** Append a "Background collection (M3)" section to the on-device checklist in `re/FINDINGS.md` (or wherever the C6 checklist lives — don't create a new doc):
  - Run on a real iPhone, connect + bond, confirm live HR + a non-zero storage line (E6).
  - Lock the phone, leave it backgrounded ~5–10 min with the strap worn.
  - Reopen: confirm the "stored: N samples" count increased while backgrounded.
  - Force-quit, relaunch: confirm `willRestoreState` reconnects (log "poweredOn with restored peripheral") and collection resumes WITHOUT pressing Connect.

- [ ] **Step 5: Commit.**
  ```bash
  git add ios/OpenWhoop/BLE/BLEManager.swift re/FINDINGS.md
  git commit -m "E4: complete BLE state restoration (re-discover/reconnect restored peripheral)" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

### Task E5: Periodic raw prune (wire + build-verify)
**Files:** Create: `ios/OpenWhoop/Collect/PrunePolicy.swift` · Modify: `ios/OpenWhoop/Collect/Collector.swift`, `ios/OpenWhoop/BLE/BLEManager.swift`, `ios/OpenWhoop/Live/LiveViewModel.swift`, `ios/OpenWhoop/App/OpenWhoopApp.swift`

Wire `store.pruneRaw(...)` to run when the app backgrounds, with retention constants made visible. The policy arithmetic is tested in Phase D (D7); this is wiring + build-verify.

- [ ] **Step 1: Expose the retention constants.**
  ```swift
  import Foundation
  /// Raw-outbox retention (raw is transient on the phone; the server is the durable archive).
  /// Pruning never loses a decoded metric — decoded is persisted first (E2 invariant).
  enum PrunePolicy {
      static let keepWindowSeconds = 24 * 3600        // keep synced raw browsable ~24h
      static let maxUnsyncedBytes = 50 * 1024 * 1024  // drop oldest un-synced beyond ~50MB
  }
  ```

- [ ] **Step 2: Hold a concrete store reference for prune/stats + add `prune()` to `Collector`.** So the Collector can prune/report without an awkward protocol downcast, give it the concrete store alongside the `StoreWriting` seam. Add to `Collector`:
  ```swift
  /// Concrete store for prune + stats (the StoreWriting seam covers the hot insert/enqueue path;
  /// prune/stats are infrequent so a direct reference is clearer than widening the protocol).
  private let concreteStore: WhoopStore?
  // In init, after assigning `store`:  self.concreteStore = store as? WhoopStore
  ```
  Then:
  ```swift
  /// Apply the raw-retention policy. Returns rows pruned (0 if no concrete store).
  @discardableResult
  func prune() -> Int {
      guard let s = concreteStore else { return 0 }
      return (try? s.pruneRaw(now: now(),
                              keepWindowSeconds: PrunePolicy.keepWindowSeconds,
                              maxUnsyncedBytes: PrunePolicy.maxUnsyncedBytes)) ?? 0
  }
  ```
  Add a passthrough on `BLEManager`: `public func pruneRaw() { collector?.prune() }`.

- [ ] **Step 3: Prune on app background.** Add to `LiveViewModel`: `public func onEnterBackground() { ble.pruneRaw() }`. Wire `OpenWhoopApp.swift` (read it first) to observe `scenePhase` and call it:
  ```swift
  // @Environment(\.scenePhase) private var scenePhase  (on the App)
  // host the model at the App level (or via the existing LiveView's model) and:
  // .onChange(of: scenePhase) { _, phase in if phase == .background { model.onEnterBackground() } }
  ```
  (Flush already happens on disconnect; pruning on background keeps disk bounded during long-running background collection. A periodic in-app timer for prune is optional for v1.)

- [ ] **Step 4: Build + existing tests green.** (same build/test commands)

- [ ] **Step 5: Commit.**
  ```bash
  git add ios/OpenWhoop/Collect/PrunePolicy.swift ios/OpenWhoop/Collect/Collector.swift ios/OpenWhoop/BLE/BLEManager.swift ios/OpenWhoop/Live/LiveViewModel.swift ios/OpenWhoop/App/OpenWhoopApp.swift
  git commit -m "E5: prune raw outbox on background per 24h/50MB retention policy" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

### Task E6: Light storage status in the UI (build-verify)
**Files:** Modify: `ios/OpenWhoop/Collect/Collector.swift`, `ios/OpenWhoop/BLE/BLEManager.swift`, `ios/OpenWhoop/Live/LiveViewModel.swift`, `ios/OpenWhoop/Live/LiveView.swift`

Add one small line to `LiveView` showing `storageStats()` ("stored: N samples · M raw batches · X MB"), refreshed periodically. Minimal — full History/charts is M7.

- [ ] **Step 1: Surface stats.** Add to `Collector`:
  ```swift
  func storageStats() -> (decodedRows: Int, rawBatches: Int, rawBytes: Int)? {
      try? concreteStore?.storageStats()
  }
  ```
  Add to `BLEManager`: `public func storageStats() -> (decodedRows: Int, rawBatches: Int, rawBytes: Int)? { collector?.storageStats() ?? nil }`.
  Add to `LiveViewModel`:
  ```swift
  @Published public var storageSummary: String = "stored: —"
  public func refreshStorage() {
      guard let s = ble.storageStats() else { storageSummary = "stored: —"; return }
      let mb = Double(s.rawBytes) / (1024 * 1024)
      storageSummary = String(format: "stored: %d samples · %d raw batches · %.1f MB",
                              s.decodedRows, s.rawBatches, mb)
  }
  ```

- [ ] **Step 2: Add the line to `LiveView` and refresh it.** In `LiveContentView`, after `chips`, add:
  ```swift
  Text(model.storageSummary)
      .font(.caption2).foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
  ```
  Drive refresh from `LiveView` (owns the `@StateObject model`):
  ```swift
  .task {
      while !Task.isCancelled { model.refreshStorage(); try? await Task.sleep(for: .seconds(5)) }
  }
  ```

- [ ] **Step 3: Build + existing tests green.** (same build/test commands)

- [ ] **Step 4: Commit.**
  ```bash
  git add ios/OpenWhoop/Collect/Collector.swift ios/OpenWhoop/BLE/BLEManager.swift ios/OpenWhoop/Live/LiveViewModel.swift ios/OpenWhoop/Live/LiveView.swift
  git commit -m "E6: show storage stats line in LiveView, refreshed every 5s" -m "Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

**Phase E exit criteria:** while connected+bonded, decoded HR/RR/events/battery are persisted to the on-device SQLite store and raw is queued in the outbox (decoded committed first); a `ClockRef` is captured at bond and gates persistence; the app resumes collection after backgrounding and after a CoreBluetooth background relaunch (manual on-device check documented); the raw outbox is bounded (24 h / 50 MB) by a background prune; and the Live view shows a live storage-stats line. Push/pull sync to the server is **M5**; History charts are **M7**.
