import Foundation

// Counts walking/running steps from a single REALTIME_RAW_DATA (type 43) IMU packet.
//
// Algorithm: compute vector magnitude per sample, remove gravity with an adaptive
// threshold, count positive peaks. Returns 0 rather than guessing when the signal
// is too quiet to distinguish motion from noise.
//
// Sensor layout (Gen4-VERIFIED, motion_capture.jsonl):
//   frame[89..288]  = accelX (100 × i16 LE)
//   frame[289..488] = accelY (100 × i16 LE)
//   frame[489..688] = accelZ (100 × i16 LE)
//   scale: 1/4096 LSB/g  (±8 g full-scale, 100 samples ≈ 1 second at ~100 Hz)
enum WhoopPedometer {
    // IMU variant frame size: SOF(1)+len(2)+crc8(1)+type(1)+seq(1)+cmd(1)+payload(1917)+crc32(4)
    private static let imuFrameSize = 1928
    // Min peak-to-peak range to count any steps.  ~0.15 g; typical still-wrist noise is below.
    private static let minRange = 600.0
    // Adaptive threshold fraction: peaks above (min + range × this) count as steps.
    private static let thresholdFraction = 0.60
    // At ~100 Hz, 100 samples ≈ 1 s; even elite sprinters stay below 3.5 steps/s.
    private static let maxStepsPerWindow = 3

    // Count steps in one REALTIME_RAW_DATA IMU frame. Returns 0 on any ambiguity.
    static func countSteps(frame: [UInt8]) -> Int {
        guard frame.count == imuFrameSize else { return 0 }

        var mag = [Double](repeating: 0, count: 100)
        for i in 0..<100 {
            let xp = 89 + i * 2
            let yp = 289 + i * 2
            let zp = 489 + i * 2
            let ax = Double(Int16(bitPattern: UInt16(frame[xp])     | (UInt16(frame[xp + 1]) << 8)))
            let ay = Double(Int16(bitPattern: UInt16(frame[yp])     | (UInt16(frame[yp + 1]) << 8)))
            let az = Double(Int16(bitPattern: UInt16(frame[zp])     | (UInt16(frame[zp + 1]) << 8)))
            mag[i] = (ax * ax + ay * ay + az * az).squareRoot()
        }

        guard let minV = mag.min(), let maxV = mag.max() else { return 0 }
        let range = maxV - minV
        guard range > minRange else { return 0 }

        let threshold = minV + range * thresholdFraction
        var count = 0
        for i in 1..<(mag.count - 1) {
            if mag[i] > threshold && mag[i] >= mag[i - 1] && mag[i] > mag[i + 1] {
                count += 1
            }
        }
        return min(count, maxStepsPerWindow)
    }
}
