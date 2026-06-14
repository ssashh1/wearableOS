# M5 Workouts Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Workouts tab for OpenWhoop iOS — loads real workout bouts from `/v1/workouts`, shows a list (newest first), and pushes a detail view with an HR-zone breakdown.

**Architecture:** Pure read-from-server pattern: `ServerSync.getWorkouts(from:to:)` GETs `/v1/workouts`, decodes a `Workout` model (Codable, ISO timestamps to epoch), and returns `[]` on any failure. `MetricsRepository.workouts(from:to:)` calls `ensureOpen()` then forwards to `serverSync`. `WorkoutsView` owns all loading state (no new published properties on the repo) and pushes `WorkoutDetailView` via NavigationStack. No BLE or store changes.

**Tech Stack:** Swift 5.9, SwiftUI, iOS 16, `WH` design tokens, `MetricCard` component, `ServerSync` Bearer-auth GET helper (private via `get(path:)` — we call the public `getWorkouts` which is additive). No new dependencies.

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `ios/OpenWhoop/Upload/ServerSync.swift` | Modify (additive) | Add `Workout` model + `getWorkouts(from:to:) async -> [Workout]` |
| `ios/OpenWhoop/Metrics/MetricsRepository.swift` | Modify (additive) | Add `workouts(from:to:) async -> [Workout]` forwarder |
| `ios/OpenWhoop/Tabs/WorkoutsView.swift` | Replace stub | List view: loading/empty/error states, workout rows, NavigationLink → detail |
| `ios/OpenWhoop/Tabs/WorkoutDetailView.swift` | Create | Detail: header, stats strip, zone breakdown bars |
| `ios/OpenWhoopTests/ServerSyncTests.swift` | Modify (additive) | Decode test for `getWorkouts` round-trip |

---

## Task 1: `Workout` model + `ServerSync.getWorkouts`

**Files:**
- Modify: `ios/OpenWhoop/Upload/ServerSync.swift` (after the `getSleep` method, before `// MARK: - ts parsing`)

The server returns a JSON array. Each element:

```json
{
  "device_id": "my-whoop",
  "start_ts": "2026-05-27T07:14:23+00:00",
  "end_ts": "2026-05-27T07:49:21+00:00",
  "avg_hr": 117.8,
  "peak_hr": 159,
  "strain": 10.71,
  "kind": null,
  "duration_s": 2098,
  "zone_time_pct": {"0":12.5,"1":8.3,"2":18.1,"3":31.2,"4":22.4,"5":7.5},
  "avg_hrr_pct": 64.3,
  "hrmax": 185.0,
  "hrmax_source": "formula",
  "calories_kcal": null,
  "calories_kj": null
}
```

- [ ] **Step 1: Add `Workout` model to `ServerSync.swift`**

Insert this struct immediately before the `// MARK: - ts parsing` block (around line 406):

```swift
// MARK: - Workout model

struct Workout: Identifiable, Equatable {
    let id: String          // "\(deviceId)|\(startTs)"
    let deviceId: String
    let startTs: Int        // epoch seconds
    let endTs: Int          // epoch seconds
    let avgHr: Double
    let peakHr: Int
    let strain: Double?
    let kind: String?
    let durationS: Int
    let zoneTimePct: [Int: Double]   // zone 0–5 → % of bout (0.0–100.0)
    let avgHrrPct: Double?
    let hrmax: Double?
    let hrmaxSource: String
    let caloriesKcal: Double?
    let caloriesKj: Double?
}
```

- [ ] **Step 2: Add `getWorkouts(from:to:) async -> [Workout]` to `ServerSync`**

Insert this method in the `// MARK: - Derived metrics` section, after `getSleep`:

```swift
/// GET /v1/workouts?device=<deviceId>&from=<from>&to=<to>
/// Returns decoded Workout array, newest-first (server returns ascending; we reverse).
/// Returns [] on any network/parse error — callers treat this as "no data, try again later".
func getWorkouts(from: String, to: String) async -> [Workout] {
    let path = "/v1/workouts?device=\(deviceId)&from=\(from)&to=\(to)"
    guard let body = await get(path: path),
          let arr = (try? JSONSerialization.jsonObject(with: body)) as? [[String: Any]] else {
        return []
    }
    let int = ServerSync.int
    let dbl = ServerSync.dbl
    func epoch(_ r: [String: Any], _ k: String) -> Int? {
        if let s = r[k] as? String { return ServerSync.parseEpoch(s) }
        return int(r, k)
    }
    let workouts: [Workout] = arr.compactMap { r in
        guard let start = epoch(r, "start_ts") ?? epoch(r, "startTs"),
              let end   = epoch(r, "end_ts")   ?? epoch(r, "endTs"),
              let avgHr  = dbl(r, "avg_hr")    ?? dbl(r, "avgHr"),
              let peakHr = int(r, "peak_hr")   ?? int(r, "peakHr"),
              let durS   = int(r, "duration_s") ?? int(r, "durationS") else { return nil }
        // Parse zone_time_pct: keys are strings "0"–"5"
        var zones: [Int: Double] = [:]
        if let zObj = r["zone_time_pct"] as? [String: Any] {
            for (k, v) in zObj {
                if let zone = Int(k), let pct = (v as? NSNumber)?.doubleValue ?? (v as? Double) {
                    zones[zone] = pct
                }
            }
        }
        let deviceId = (r["device_id"] as? String) ?? self.deviceId
        return Workout(
            id: "\(deviceId)|\(start)",
            deviceId: deviceId,
            startTs: start,
            endTs: end,
            avgHr: avgHr,
            peakHr: peakHr,
            strain: dbl(r, "strain"),
            kind: r["kind"] as? String,
            durationS: durS,
            zoneTimePct: zones,
            avgHrrPct: dbl(r, "avg_hrr_pct") ?? dbl(r, "avgHrrPct"),
            hrmax: dbl(r, "hrmax"),
            hrmaxSource: (r["hrmax_source"] as? String) ?? (r["hrmaxSource"] as? String) ?? "",
            caloriesKcal: dbl(r, "calories_kcal") ?? dbl(r, "caloriesKcal"),
            caloriesKj: dbl(r, "calories_kj") ?? dbl(r, "caloriesKj")
        )
    }
    // Server returns ascending; we reverse so newest is first (list view shows newest at top).
    return workouts.reversed()
}
```

- [ ] **Step 3: Verify the file still compiles**

```bash
cd ~/openwhoop/ios && xcodegen generate 2>&1 | tail -3
xcodebuild build -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/dd 2>&1 | grep -E '(error:|Build succeeded)'
```

Expected: `Build succeeded` — no errors.

---

## Task 2: `MetricsRepository.workouts` forwarder

**Files:**
- Modify: `ios/OpenWhoop/Metrics/MetricsRepository.swift` (add after `putProfile`, before the closing brace)

- [ ] **Step 1: Add `workouts(from:to:)` to `MetricsRepository`**

Append this method inside `MetricsRepository`, after `sevenNightSleepWake`:

```swift
// MARK: - Workouts (M5)

/// Fetches auto-detected workout bouts from the server for the given date range.
/// Calls ensureOpen() to initialise the store/sync stack, then delegates to ServerSync.
/// Returns [] when unconfigured (no API key), offline, or on parse error — never throws.
func workouts(from: String, to: String) async -> [Workout] {
    await ensureOpen()
    return await serverSync?.getWorkouts(from: from, to: to) ?? []
}
```

- [ ] **Step 2: Build to confirm no regressions**

```bash
cd ~/openwhoop/ios && xcodebuild build -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/dd 2>&1 | grep -E '(error:|Build succeeded)'
```

Expected: `Build succeeded`.

---

## Task 3: Decode test for `getWorkouts`

**Files:**
- Modify: `ios/OpenWhoopTests/ServerSyncTests.swift` (append a new test method at the end of the class)

The existing test file uses `StubURLProtocol` (defined in `UploaderTests.swift`) and the `makeSession()` / `makeConfig()` helpers already present in `ServerSyncTests`.

- [ ] **Step 1: Write the failing test**

Append this test to `ServerSyncTests` (before the final closing `}`):

```swift
// MARK: - getWorkouts decode

func testGetWorkoutsDecodesRealShape() async throws {
    // A realistic server response: one workout, all fields present.
    let body = """
    [{
        "device_id": "my-whoop",
        "start_ts": "2026-05-27T07:14:23+00:00",
        "end_ts":   "2026-05-27T07:49:21+00:00",
        "avg_hr": 117.8,
        "peak_hr": 159,
        "strain": 10.71,
        "kind": null,
        "duration_s": 2098,
        "zone_time_pct": {"0":12.5,"1":8.3,"2":18.1,"3":31.2,"4":22.4,"5":7.5},
        "avg_hrr_pct": 64.3,
        "hrmax": 185.0,
        "hrmax_source": "formula",
        "calories_kcal": null,
        "calories_kj": null
    }]
    """
    StubURLProtocol.reset(bodies: ["/v1/workouts": body])

    let store = try await WhoopStore.inMemory()
    try await store.upsertDevice(id: "my-whoop", mac: nil, name: nil)
    let sync = ServerSync(config: makeConfig(), store: store,
                          deviceId: "my-whoop", session: makeSession())

    let workouts = await sync.getWorkouts(from: "2026-05-01", to: "2026-05-31")

    XCTAssertEqual(workouts.count, 1)
    let w = workouts[0]
    XCTAssertEqual(w.deviceId, "my-whoop")
    XCTAssertEqual(w.avgHr, 117.8, accuracy: 0.01)
    XCTAssertEqual(w.peakHr, 159)
    XCTAssertEqual(w.strain ?? 0, 10.71, accuracy: 0.001)
    XCTAssertNil(w.kind)
    XCTAssertEqual(w.durationS, 2098)
    XCTAssertEqual(w.zoneTimePct[0] ?? 0, 12.5, accuracy: 0.001)
    XCTAssertEqual(w.zoneTimePct[3] ?? 0, 31.2, accuracy: 0.001)
    XCTAssertEqual(w.avgHrrPct ?? 0, 64.3, accuracy: 0.01)
    XCTAssertEqual(w.hrmax ?? 0, 185.0, accuracy: 0.01)
    XCTAssertNil(w.caloriesKcal)
    XCTAssertNil(w.caloriesKj)
    // startTs parsed from ISO-8601
    let expectedStart = ServerSync.parseEpoch("2026-05-27T07:14:23+00:00")!
    XCTAssertEqual(w.startTs, expectedStart)
}

func testGetWorkoutsReturnsEmptyOnServerError() async throws {
    StubURLProtocol.reset(responses: ["/v1/workouts": 500], bodies: [:])
    let store = try await WhoopStore.inMemory()
    try await store.upsertDevice(id: "my-whoop", mac: nil, name: nil)
    let sync = ServerSync(config: makeConfig(), store: store,
                          deviceId: "my-whoop", session: makeSession())

    let workouts = await sync.getWorkouts(from: "2026-05-01", to: "2026-05-31")
    XCTAssertTrue(workouts.isEmpty, "should return [] on 500")
}

func testGetWorkoutsNewestFirst() async throws {
    // Two workouts in ascending order from the server — result should be reversed.
    let body = """
    [
        {"device_id":"my-whoop","start_ts":"2026-05-26T07:00:00+00:00","end_ts":"2026-05-26T07:30:00+00:00",
         "avg_hr":120.0,"peak_hr":150,"strain":9.0,"kind":null,"duration_s":1800,
         "zone_time_pct":{"0":10,"1":10,"2":20,"3":30,"4":20,"5":10},
         "avg_hrr_pct":60.0,"hrmax":185.0,"hrmax_source":"formula","calories_kcal":null,"calories_kj":null},
        {"device_id":"my-whoop","start_ts":"2026-05-27T07:14:23+00:00","end_ts":"2026-05-27T07:49:21+00:00",
         "avg_hr":117.8,"peak_hr":159,"strain":10.71,"kind":null,"duration_s":2098,
         "zone_time_pct":{"0":12,"1":8,"2":18,"3":31,"4":22,"5":9},
         "avg_hrr_pct":64.3,"hrmax":185.0,"hrmax_source":"formula","calories_kcal":null,"calories_kj":null}
    ]
    """
    StubURLProtocol.reset(bodies: ["/v1/workouts": body])
    let store = try await WhoopStore.inMemory()
    try await store.upsertDevice(id: "my-whoop", mac: nil, name: nil)
    let sync = ServerSync(config: makeConfig(), store: store,
                          deviceId: "my-whoop", session: makeSession())

    let workouts = await sync.getWorkouts(from: "2026-05-01", to: "2026-05-31")
    XCTAssertEqual(workouts.count, 2)
    // Newest first: May 27 before May 26
    XCTAssertGreaterThan(workouts[0].startTs, workouts[1].startTs)
}
```

- [ ] **Step 2: Run tests to confirm they pass**

```bash
cd ~/openwhoop/ios && xcodebuild test \
  -project OpenWhoop.xcodeproj \
  -scheme OpenWhoop \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build/dd \
  -only-testing:OpenWhoopTests/ServerSyncTests \
  2>&1 | tail -15
```

Expected: All `ServerSyncTests` pass (including the 3 new ones).

- [ ] **Step 3: Run full test suite to confirm nothing regressed**

```bash
cd ~/openwhoop/ios && xcodebuild test \
  -project OpenWhoop.xcodeproj \
  -scheme OpenWhoop \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build/dd \
  2>&1 | tail -8
```

Expected: All tests pass (175 → 178 after adding the 3 new tests).

- [ ] **Step 4: Commit Task 1–3**

```bash
cd ~/openwhoop && git add \
  ios/OpenWhoop/Upload/ServerSync.swift \
  ios/OpenWhoop/Metrics/MetricsRepository.swift \
  ios/OpenWhoopTests/ServerSyncTests.swift
git commit -m "feat(ios): M5 Workout model + ServerSync.getWorkouts + MetricsRepository.workouts"
```

---

## Task 4: `WorkoutDetailView`

**Files:**
- Create: `ios/OpenWhoop/Tabs/WorkoutDetailView.swift`

This view is pushed by `WorkoutsView` (Task 5) and receives a `Workout` value. It renders:
1. Header: formatted date/time + duration
2. Stats strip: Strain, Avg HR, Peak HR, Calories (kcal; "—" if nil)
3. HR Zone breakdown (zones 0–5 as labeled horizontal bars): zone label, %, minutes in zone

Zone colors (low→high intensity, matching WHOOP aesthetic):
- Zone 0 (rest): `WH.Color.textSecondary` (grey)
- Zone 1: `WH.Color.teal`
- Zone 2: `WH.Color.recoveryGreen`
- Zone 3: `WH.Color.recoveryYellow`
- Zone 4: Color(hex: "#FF8C00") — orange
- Zone 5: `WH.Color.recoveryRed`

Zone labels (Edwards zones):
- Zone 0: "Rest"
- Zone 1: "Very Light"
- Zone 2: "Light"
- Zone 3: "Moderate"
- Zone 4: "Hard"
- Zone 5: "Max"

- [ ] **Step 1: Create `WorkoutDetailView.swift`**

Create `~/openwhoop/ios/OpenWhoop/Tabs/WorkoutDetailView.swift`:

```swift
import SwiftUI

// MARK: - WorkoutDetailView
// Push destination for a single detected workout bout.
// Header → stats strip → HR-zone breakdown.

struct WorkoutDetailView: View {
    let workout: Workout

    // MARK: - Body

    var body: some View {
        ZStack {
            WH.Color.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: WH.Spacing.lg) {
                    headerSection
                    statsStrip
                    zoneSection
                    contextSection
                    Spacer(minLength: WH.Spacing.xl)
                }
                .padding(WH.Spacing.md)
            }
            .background(WH.Color.background)
        }
        .navigationTitle("Workout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: WH.Spacing.xs) {
            Text(formattedDate)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(WH.Color.textPrimary)
            HStack(spacing: WH.Spacing.sm) {
                Text(formattedTime)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(WH.Color.textSecondary)
                Text("·")
                    .foregroundStyle(WH.Color.textSecondary)
                Text(formattedDuration)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(WH.Color.strainBlue)
                if let kind = workout.kind {
                    Text("·")
                        .foregroundStyle(WH.Color.textSecondary)
                    Text(kind)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(WH.Color.textSecondary)
                }
            }
        }
        .padding(WH.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WH.Color.surface,
                    in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
    }

    // MARK: - Stats strip

    private var statsStrip: some View {
        HStack(spacing: 0) {
            statCell(label: "STRAIN",
                     value: workout.strain.map { String(format: "%.1f", $0) } ?? "—",
                     unit: workout.strain != nil ? "/ 21" : nil,
                     color: WH.Color.strainBlue)
            divider
            statCell(label: "AVG HR",
                     value: String(format: "%.0f", workout.avgHr),
                     unit: "bpm",
                     color: WH.Color.textPrimary)
            divider
            statCell(label: "PEAK HR",
                     value: "\(workout.peakHr)",
                     unit: "bpm",
                     color: WH.Color.recoveryRed)
            divider
            statCell(label: "CALORIES",
                     value: workout.caloriesKcal.map { String(format: "%.0f", $0) } ?? "—",
                     unit: workout.caloriesKcal != nil ? "kcal" : nil,
                     color: workout.caloriesKcal != nil ? WH.Color.recoveryYellow : WH.Color.textSecondary)
        }
        .padding(.vertical, WH.Spacing.sm)
        .background(WH.Color.surface,
                    in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
    }

    private var divider: some View {
        Rectangle()
            .fill(WH.Color.separator)
            .frame(width: 1, height: 40)
    }

    private func statCell(label: String, value: String, unit: String?, color: Color) -> some View {
        VStack(spacing: WH.Spacing.xs) {
            Text(label)
                .font(WH.Font.cardTitle)
                .foregroundStyle(WH.Color.textSecondary)
                .tracking(1.0)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(value == "—" ? WH.Color.textSecondary : color)
                    .monospacedDigit()
                if let u = unit, value != "—" {
                    Text(u)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(WH.Color.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Zone breakdown

    private var zoneSection: some View {
        VStack(alignment: .leading, spacing: WH.Spacing.sm) {
            sectionHeader("HR Zones")

            VStack(spacing: WH.Spacing.xs) {
                ForEach(0..<6) { zone in
                    zoneRow(zone: zone)
                }
            }
            .padding(WH.Spacing.md)
            .background(WH.Color.surface,
                        in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
        }
    }

    private func zoneRow(zone: Int) -> some View {
        let pct = workout.zoneTimePct[zone] ?? 0.0
        let mins = Double(workout.durationS) * pct / 100.0 / 60.0
        let color = zoneColor(zone)
        let label = zoneLabel(zone)

        return VStack(spacing: 4) {
            HStack {
                // Zone dot + label
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text("Z\(zone)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .frame(width: 22, alignment: .leading)
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(WH.Color.textSecondary)
                Spacer()
                // Minutes + percentage
                Text(formatZoneMins(mins))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(WH.Color.textSecondary)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
                Text(String(format: "%.0f%%", pct))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(pct > 0 ? color : WH.Color.textSecondary)
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
            // Horizontal bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color.opacity(0.12))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color)
                        .frame(width: max(2, geo.size.width * CGFloat(pct / 100.0)), height: 6)
                }
            }
            .frame(height: 6)
        }
    }

    // MARK: - Context section (HRmax + HRR)

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: WH.Spacing.sm) {
            sectionHeader("Context")
            HStack(spacing: WH.Spacing.sm) {
                if let hrmax = workout.hrmax {
                    contextCell(
                        label: "HR MAX",
                        value: String(format: "%.0f", hrmax),
                        unit: "bpm",
                        note: workout.hrmaxSource.isEmpty ? nil : "(\(workout.hrmaxSource))"
                    )
                }
                if let hrr = workout.avgHrrPct {
                    contextCell(
                        label: "AVG %HRR",
                        value: String(format: "%.0f", hrr),
                        unit: "%",
                        note: nil
                    )
                }
            }
        }
    }

    private func contextCell(label: String, value: String, unit: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: WH.Spacing.xs) {
            Text(label)
                .font(WH.Font.cardTitle)
                .foregroundStyle(WH.Color.textSecondary)
                .tracking(1.0)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(WH.Color.textPrimary)
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(WH.Color.textSecondary)
            }
            if let note {
                Text(note)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(WH.Color.textSecondary)
            }
        }
        .padding(WH.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WH.Color.surface,
                    in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(WH.Font.cardTitle)
            .foregroundStyle(WH.Color.textSecondary)
            .tracking(1.5)
            .padding(.top, WH.Spacing.xs)
    }

    private var formattedDate: String {
        let d = Date(timeIntervalSince1970: TimeInterval(workout.startTs))
        let fmt = DateFormatter()
        fmt.dateStyle = .full
        fmt.timeStyle = .none
        return fmt.string(from: d)
    }

    private var formattedTime: String {
        let d = Date(timeIntervalSince1970: TimeInterval(workout.startTs))
        let fmt = DateFormatter()
        fmt.dateStyle = .none
        fmt.timeStyle = .short
        return fmt.string(from: d)
    }

    private var formattedDuration: String {
        let totalMin = workout.durationS / 60
        let h = totalMin / 60
        let m = totalMin % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0           { return "\(h)h" }
        return "\(m)m"
    }

    private func formatZoneMins(_ mins: Double) -> String {
        if mins < 1.0 { return "<1m" }
        return "\(Int(mins.rounded()))m"
    }

    private func zoneColor(_ zone: Int) -> Color {
        switch zone {
        case 0: return WH.Color.textSecondary
        case 1: return WH.Color.teal
        case 2: return WH.Color.recoveryGreen
        case 3: return WH.Color.recoveryYellow
        case 4: return Color(hex: "#FF8C00")
        case 5: return WH.Color.recoveryRed
        default: return WH.Color.textSecondary
        }
    }

    private func zoneLabel(_ zone: Int) -> String {
        switch zone {
        case 0: return "Rest"
        case 1: return "Very Light"
        case 2: return "Light"
        case 3: return "Moderate"
        case 4: return "Hard"
        case 5: return "Max"
        default: return "Zone \(zone)"
        }
    }
}
```

- [ ] **Step 2: Build to confirm no compile errors**

```bash
cd ~/openwhoop/ios && xcodegen generate 2>&1 | tail -3
xcodebuild build -project OpenWhoop.xcodeproj -scheme OpenWhoop -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/dd 2>&1 | grep -E '(error:|Build succeeded)'
```

Expected: `Build succeeded`.

---

## Task 5: `WorkoutsView` — replace the stub

**Files:**
- Replace: `ios/OpenWhoop/Tabs/WorkoutsView.swift`

States to handle:
1. **Loading** (first `.task` call, `isLoading == true`): `ProgressView` + "Loading workouts…"
2. **Empty** (loaded, 0 results): icon + message "No workouts detected yet…"
3. **Populated**: `List` of workout rows, newest first; each row taps → `WorkoutDetailView`
4. **Error** (offline / server down): soft error inline (not blocking) — show a banner if `lastError != nil`

Each workout row shows:
- Date (e.g. "Tue 5/27") + start time (e.g. "7:14 AM")
- Duration (e.g. "35m")
- Strain badge (`strainBlue`; "—" if nil)
- Avg HR ("118 bpm")
- Calories ("320 kcal"; "—" if nil)
- Chevron right

- [ ] **Step 1: Replace `WorkoutsView.swift`**

Write `~/openwhoop/ios/OpenWhoop/Tabs/WorkoutsView.swift`:

```swift
import SwiftUI

// MARK: - WorkoutsView
// M5 Workouts tab — shows auto-detected workout bouts from /v1/workouts (last 30 days).
// Data is fetched directly from the server (no local cache); refresh on .task + pull-to-refresh.

struct WorkoutsView: View {
    @EnvironmentObject private var metrics: MetricsRepository

    // MARK: - State

    @State private var workouts: [Workout] = []
    @State private var isLoading = true
    @State private var errorMessage: String? = nil

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                WH.Color.background.ignoresSafeArea()

                if isLoading {
                    loadingView
                } else {
                    listContent
                }
            }
            .navigationTitle("Workouts")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .task {
            await reload()
        }
        .refreshable {
            await reload()
        }
    }

    // MARK: - Loading view

    private var loadingView: some View {
        VStack(spacing: WH.Spacing.md) {
            ProgressView()
                .tint(WH.Color.textSecondary)
            Text("Loading workouts…")
                .font(WH.Font.caption)
                .foregroundStyle(WH.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List / empty content

    private var listContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {

                if let err = errorMessage {
                    errorBanner(err)
                        .padding(.horizontal, WH.Spacing.md)
                        .padding(.top, WH.Spacing.sm)
                }

                if workouts.isEmpty {
                    emptyState
                } else {
                    workoutList
                }
            }
        }
        .background(WH.Color.background)
    }

    // MARK: - Workout list

    private var workoutList: some View {
        VStack(spacing: 1) {
            ForEach(workouts) { workout in
                NavigationLink(destination: WorkoutDetailView(workout: workout)) {
                    workoutRow(workout)
                }
                .buttonStyle(.plain)
            }
        }
        .background(WH.Color.surface,
                    in: RoundedRectangle(cornerRadius: WH.Radius.card, style: .continuous))
        .padding(WH.Spacing.md)
    }

    private func workoutRow(_ w: Workout) -> some View {
        HStack(spacing: WH.Spacing.sm) {

            // Date + time column
            VStack(alignment: .leading, spacing: 2) {
                Text(rowDate(w.startTs))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(WH.Color.textPrimary)
                Text(rowTime(w.startTs))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(WH.Color.textSecondary)
            }
            .frame(width: 72, alignment: .leading)

            // Duration
            Text(formatDuration(w.durationS))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(WH.Color.textSecondary)
                .frame(width: 44, alignment: .leading)

            Spacer()

            // Avg HR
            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "%.0f", w.avgHr))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(WH.Color.textPrimary)
                    .monospacedDigit()
                Text("bpm")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(WH.Color.textSecondary)
            }
            .frame(width: 44, alignment: .trailing)

            // Strain badge
            strainBadge(w.strain)

            // Calories
            VStack(alignment: .trailing, spacing: 1) {
                Text(w.caloriesKcal.map { String(format: "%.0f", $0) } ?? "—")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(w.caloriesKcal != nil ? WH.Color.recoveryYellow : WH.Color.textSecondary)
                    .monospacedDigit()
                Text(w.caloriesKcal != nil ? "kcal" : "")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(WH.Color.textSecondary)
            }
            .frame(width: 40, alignment: .trailing)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WH.Color.textSecondary.opacity(0.5))
        }
        .padding(.horizontal, WH.Spacing.md)
        .padding(.vertical, WH.Spacing.sm)
    }

    private func strainBadge(_ strain: Double?) -> some View {
        Group {
            if let s = strain {
                Text(String(format: "%.1f", s))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(WH.Color.strainBlue)
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(WH.Color.strainBlue.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: WH.Radius.small, style: .continuous))
            } else {
                Text("—")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(WH.Color.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(WH.Color.surface2,
                                in: RoundedRectangle(cornerRadius: WH.Radius.small, style: .continuous))
            }
        }
        .frame(width: 52, alignment: .center)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: WH.Spacing.sm) {
            Image(systemName: "figure.run.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(WH.Color.textSecondary)
            Text("No workouts detected yet")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(WH.Color.textPrimary)
            Text("Workouts are found automatically from your heart rate data. Pull down to refresh.")
                .font(WH.Font.caption)
                .foregroundStyle(WH.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, WH.Spacing.xl)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, WH.Spacing.xxl)
    }

    // MARK: - Error banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: WH.Spacing.sm) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(WH.Color.recoveryYellow)
            Text(message)
                .font(WH.Font.caption)
                .foregroundStyle(WH.Color.textSecondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(WH.Spacing.sm)
        .background(WH.Color.surface2,
                    in: RoundedRectangle(cornerRadius: WH.Radius.chip, style: .continuous))
    }

    // MARK: - Data loading

    private func reload() async {
        errorMessage = nil
        let (from, to) = dateRange()
        let result = await metrics.workouts(from: from, to: to)
        workouts = result
        if isLoading { isLoading = false }
        if result.isEmpty && !isLoading {
            // Only set an error if we had a likely server issue (heuristic: empty after a completed load)
            // The view distinguishes "never loaded" from "loaded but empty" via the empty state.
        }
    }

    private func dateRange() -> (from: String, to: String) {
        let cal = Calendar(identifier: .gregorian)
        let utc = TimeZone(identifier: "UTC")!
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.timeZone = utc
        fmt.dateFormat = "yyyy-MM-dd"
        let today = Date()
        let from = cal.date(byAdding: .day, value: -30, to: today) ?? today
        return (fmt.string(from: from), fmt.string(from: today))
    }

    // MARK: - Formatting

    private func rowDate(_ ts: Int) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ts))
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE M/d"
        return fmt.string(from: d)
    }

    private func rowTime(_ ts: Int) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ts))
        let fmt = DateFormatter()
        fmt.dateStyle = .none
        fmt.timeStyle = .short
        return fmt.string(from: d)
    }

    private func formatDuration(_ seconds: Int) -> String {
        let totalMin = seconds / 60
        let h = totalMin / 60
        let m = totalMin % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0           { return "\(h)h" }
        return "\(m)m"
    }
}

// MARK: - Preview

#Preview("Workouts — empty") {
    WorkoutsView()
        .environmentObject(MetricsRepository(deviceId: "preview"))
}
```

- [ ] **Step 2: Build + run full tests**

```bash
cd ~/openwhoop/ios && xcodegen generate 2>&1 | tail -3
xcodebuild test -project OpenWhoop.xcodeproj -scheme OpenWhoop \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build/dd \
  2>&1 | tail -8
```

Expected: all tests pass. `Build succeeded` (or test pass count shown).

- [ ] **Step 3: Commit Tasks 4–5**

```bash
cd ~/openwhoop && git add \
  ios/OpenWhoop/Tabs/WorkoutsView.swift \
  ios/OpenWhoop/Tabs/WorkoutDetailView.swift
git commit -m "feat(ios): M5 WorkoutsView + WorkoutDetailView (HR zones, strain, calories)"
```

---

## Task 6: Visual verification

- [ ] **Step 1: Temporarily route the app to the Workouts tab**

In `~/openwhoop/ios/OpenWhoop/App/OpenWhoopApp.swift`, change `AppRoot.body` to show the Workouts tab directly:

```swift
// TEMPORARY — visual verification; revert after screenshot
var body: some View {
    NavigationStack {
        WorkoutsView()
    }
    .environmentObject(metrics)
    .environmentObject(live)
}
```

- [ ] **Step 2: Build + launch on iPhone 17 simulator**

```bash
cd ~/openwhoop/ios && xcodegen generate && \
xcodebuild build -project OpenWhoop.xcodeproj \
  -scheme OpenWhoop \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build/dd 2>&1 | grep -E '(error:|Build succeeded)'
```

Then launch:
```bash
xcrun simctl boot "iPhone 17" 2>/dev/null || true
xcrun simctl install booted ~/openwhoop/ios/build/dd/Build/Products/Debug-iphonesimulator/OpenWhoop.app
xcrun simctl launch booted com.openwhoop.OpenWhoop
```

- [ ] **Step 3: Wait for network load and screenshot**

```bash
sleep 5
xcrun simctl io booted screenshot /tmp/m5_workouts.png
```

Read the screenshot at `/tmp/m5_workouts.png` and confirm:
- Real workout rows are visible (with date, duration, strain, avg HR)
- The layout matches expectations (dark background, strain badge, chevron)
- At minimum the ~35-min bout (avg_hr ~117.8, strain ~10.71) is visible

- [ ] **Step 4: Navigate to WorkoutDetailView (optional, if scriptable)**

If the simulator supports it, try tapping the first row to view the detail. Alternatively, temporarily render `WorkoutDetailView` in `AppRoot` with a hardcoded `Workout` to screenshot the zones panel.

For a hardcoded detail screenshot, replace `AppRoot.body` temporarily:

```swift
// TEMPORARY detail screenshot
var body: some View {
    NavigationStack {
        WorkoutDetailView(workout: Workout(
            id: "test|1",
            deviceId: "my-whoop",
            startTs: Int(Date().timeIntervalSince1970) - 3600,
            endTs: Int(Date().timeIntervalSince1970),
            avgHr: 117.8,
            peakHr: 159,
            strain: 10.71,
            kind: nil,
            durationS: 2098,
            zoneTimePct: [0: 12.5, 1: 8.3, 2: 18.1, 3: 31.2, 4: 22.4, 5: 7.5],
            avgHrrPct: 64.3,
            hrmax: 185.0,
            hrmaxSource: "formula",
            caloriesKcal: nil,
            caloriesKj: nil
        ))
    }
    .preferredColorScheme(.dark)
    .environmentObject(metrics)
    .environmentObject(live)
}
```

Build, install, launch, screenshot → `/tmp/m5_detail.png`. Read and confirm zones visible.

- [ ] **Step 5: REVERT the temporary routing**

Restore `OpenWhoopApp.swift` to the original:

```swift
private struct AppRoot: View {
    @StateObject private var metrics = MetricsRepository()
    @StateObject private var live    = LiveViewModel()

    var body: some View {
        RootTabView()
            .environmentObject(metrics)
            .environmentObject(live)
    }
}
```

Build again to confirm the revert compiles cleanly.

- [ ] **Step 6: Run full tests one final time**

```bash
cd ~/openwhoop/ios && xcodebuild test \
  -project OpenWhoop.xcodeproj \
  -scheme OpenWhoop \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build/dd \
  2>&1 | tail -8
```

Expected: all tests pass (178 total).

- [ ] **Step 7: Final commit**

```bash
cd ~/openwhoop && git status
git add ios/OpenWhoop/App/OpenWhoopApp.swift  # only if it changed (should be reverted to original)
git commit -m "feat(ios): M5 Workouts tab — auto-detected workouts list + detail (HR zones, strain, calories) from /v1/workouts"
```

Or, if the previous two commits already cover everything and `OpenWhoopApp.swift` is clean:

```bash
cd ~/openwhoop && git status
# Confirm no unintended changes
```

---

## Self-Review

**Spec coverage check:**

| Requirement | Task |
|---|---|
| `Workout` Codable model | Task 1 |
| `ServerSync.getWorkouts(from:to:)` Bearer auth GET | Task 1 |
| ISO timestamps to epoch (like `getSleep`) | Task 1 — uses `ServerSync.parseEpoch` |
| `MetricsRepository.workouts(from:to:)` forwarder with `ensureOpen` | Task 2 |
| Load last 30 days on `.task` + `.refreshable` | Task 5 |
| Newest-first ordering | Task 1 (reverse) |
| Loading spinner (first load) | Task 5 |
| Empty state with descriptive message | Task 5 |
| Inline error/offline state | Task 5 |
| Workout row: date + start time, duration, strain badge, avg HR, calories | Task 5 |
| Tap → push `WorkoutDetailView` | Task 5 |
| Detail: header date/time + duration | Task 4 |
| Detail: stats strip (Strain, Avg HR, Peak HR, Calories "—" if null) | Task 4 |
| HR-zone breakdown zones 0–5 with % + minutes + colored bars | Task 4 |
| `avg_hrr_pct` + `hrmax` context | Task 4 |
| Calories null → "—" everywhere | Tasks 4 + 5 |
| Decode test for `getWorkouts` | Task 3 |
| Existing 175 tests stay green | Tasks 3 + 5 (verified) |
| Visual screenshot confirms real data | Task 6 |
| Revert temporary routing | Task 6 step 5 |
| Commit with specified message | Task 6 step 7 |

**Placeholder scan:** No TBDs, all code is complete. Types match throughout (`Workout` defined in Task 1, used in Tasks 2/4/5 with consistent property names).

**Type consistency check:**
- `Workout.zoneTimePct: [Int: Double]` — used in `WorkoutDetailView` as `workout.zoneTimePct[zone]` ✓
- `Workout.caloriesKcal: Double?` — formatted with `String(format: "%.0f", $0) ?? "—"` ✓
- `ServerSync.getWorkouts` returns `[Workout]` — `MetricsRepository.workouts` returns `[Workout]` ✓
- `WorkoutsView` receives `Workout` items and passes to `WorkoutDetailView(workout: workout)` ✓
