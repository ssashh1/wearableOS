import XCTest
@testable import OpenWhoop

/// Unit tests for ProfileUnits imperial ↔ metric conversion helpers.
/// These are pure math functions with no I/O, so no stubs needed.
final class ProfileUnitsTests: XCTestCase {

    // MARK: - Height: ft/in → cm

    func testHeightFtInToCm_typicalMale() {
        // 6 ft 1 in = 73 in = 185.42 cm → rounded to 1dp = 185.4
        let cm = ProfileUnits.heightCm(feet: 6, inches: 1)
        XCTAssertEqual(cm, 185.4, accuracy: 0.05)
    }

    func testHeightFtInToCm_exactFeet() {
        // 5 ft 0 in = 60 in = 152.4 cm
        let cm = ProfileUnits.heightCm(feet: 5, inches: 0)
        XCTAssertEqual(cm, 152.4, accuracy: 0.05)
    }

    func testHeightFtInToCm_fractionalInches() {
        // 5 ft 10.5 in = 70.5 in = 179.07 cm → ~179.1
        let cm = ProfileUnits.heightCm(feet: 5, inches: 10.5)
        XCTAssertEqual(cm, 179.1, accuracy: 0.1)
    }

    // MARK: - Height: cm → ft/in

    func testHeightCmToFtIn_roundTrip() {
        // 180 cm → ft+in → back to cm: must be within 0.5 cm (1 decimal rounding).
        let original: Double = 180.0
        let (ft, ins) = ProfileUnits.heightFtIn(cm: original)
        let roundTripped = ProfileUnits.heightCm(feet: ft, inches: ins)
        XCTAssertEqual(roundTripped, original, accuracy: 0.6,
                       "cm → ft/in → cm round-trip should be within rounding tolerance")
    }

    func testHeightCmToFtIn_typicalValue() {
        // 175 cm ≈ 5 ft 8.9 in
        let (ft, _) = ProfileUnits.heightFtIn(cm: 175)
        XCTAssertEqual(ft, 5, "175 cm is 5 feet")
    }

    // MARK: - Weight: lbs → kg

    func testWeightLbsToKg_typical() {
        // 185 lbs = 83.915 kg → rounded to 83.9
        let kg = ProfileUnits.weightKg(lbs: 185)
        XCTAssertEqual(kg, 83.9, accuracy: 0.1)
    }

    func testWeightLbsToKg_100lbs() {
        // 100 lbs = 45.359 kg → 45.4
        let kg = ProfileUnits.weightKg(lbs: 100)
        XCTAssertEqual(kg, 45.4, accuracy: 0.1)
    }

    // MARK: - Weight: kg → lbs

    func testWeightKgToLbs_typical() {
        // 75 kg = 165.3 lbs
        let lbs = ProfileUnits.weightLbs(kg: 75)
        XCTAssertEqual(lbs, 165.3, accuracy: 0.2)
    }

    func testWeightKgToLbs_roundTrip() {
        // 80 kg → lbs → kg: must be within 0.1 kg (1-decimal rounding).
        let original: Double = 80.0
        let lbs = ProfileUnits.weightLbs(kg: original)
        let roundTripped = ProfileUnits.weightKg(lbs: lbs)
        XCTAssertEqual(roundTripped, original, accuracy: 0.2,
                       "kg → lbs → kg round-trip should be within rounding tolerance")
    }

    // MARK: - Edge cases

    func testHeightZeroIsZero() {
        XCTAssertEqual(ProfileUnits.heightCm(feet: 0, inches: 0), 0)
    }

    func testWeightZeroIsZero() {
        XCTAssertEqual(ProfileUnits.weightKg(lbs: 0), 0)
        XCTAssertEqual(ProfileUnits.weightLbs(kg: 0), 0)
    }
}
