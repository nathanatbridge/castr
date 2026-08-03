import Foundation

/// Health check for a sensor resting still.
///
/// A stationary accelerometer must measure exactly 1 g — that single fact catches
/// scale errors, zero-offset drift and framing bugs in one shot. The February
/// oven-test session read 1.756 g (+73%) for its entire duration, which would have
/// been caught in fifteen seconds by this check.
public struct StaticCheck {

    public enum Verdict: String {
        case pass = "PASS"
        case warn = "WARN"
        case fail = "FAIL"
    }

    public struct Result {
        public let sampleCount: Int
        public let duration: TimeInterval
        public let effectiveRateHz: Double

        public let medianAccMagnitude: Double
        public let meanAccX: Double
        public let meanAccY: Double
        public let meanAccZ: Double

        public let gyroMeanMagnitude: Double
        public let gyroMaxMagnitude: Double

        public let rejectedFrames: Int

        /// Whether the sensor was actually still enough for the reading to mean
        /// anything. A moving sensor invalidates the 1 g assumption.
        public let stillness: Verdict
        /// Whether the measured gravity magnitude is correct.
        public let calibration: Verdict

        public var overall: Verdict {
            if stillness == .fail { return .fail }
            for v in [calibration, stillness] where v == .fail { return .fail }
            for v in [calibration, stillness] where v == .warn { return .warn }
            return rejectedFrames > 0 ? .warn : .pass
        }

        /// Percentage error against the 1.000 g a resting sensor must read.
        public var calibrationErrorPercent: Double {
            (medianAccMagnitude - 1.0) * 100.0
        }
    }

    // Thresholds. Gravity varies by ~0.5% with latitude and the sensor quantises
    // at 16/32768 g, so a few percent is comfortably within "fine".
    public static let passErrorG = 0.03
    public static let warnErrorG = 0.10
    /// Above this the sensor was being handled and the check means nothing.
    public static let stillnessFailDPS = 20.0
    public static let stillnessWarnDPS = 5.0

    public static func evaluate(_ readings: [SensorReading],
                                rejectedFrames: Int = 0) -> Result? {
        guard readings.count >= 2,
              let first = readings.first,
              let last = readings.last
        else { return nil }

        let n = Double(readings.count)
        let duration = last.timestamp.timeIntervalSince(first.timestamp)

        var mags = readings.map(\.accMagnitude)
        mags.sort()
        let median = mags[mags.count / 2]

        let meanX = readings.reduce(0) { $0 + $1.accX } / n
        let meanY = readings.reduce(0) { $0 + $1.accY } / n
        let meanZ = readings.reduce(0) { $0 + $1.accZ } / n

        let gyroMags = readings.map {
            ($0.gyroX * $0.gyroX + $0.gyroY * $0.gyroY + $0.gyroZ * $0.gyroZ).squareRoot()
        }
        let gyroMean = gyroMags.reduce(0, +) / n
        let gyroMax = gyroMags.max() ?? 0

        let stillness: Verdict
        if gyroMax > stillnessFailDPS { stillness = .fail }
        else if gyroMax > stillnessWarnDPS { stillness = .warn }
        else { stillness = .pass }

        let error = abs(median - 1.0)
        let calibration: Verdict
        if error <= passErrorG { calibration = .pass }
        else if error <= warnErrorG { calibration = .warn }
        else { calibration = .fail }

        return Result(
            sampleCount: readings.count,
            duration: duration,
            effectiveRateHz: duration > 0 ? n / duration : 0,
            medianAccMagnitude: median,
            meanAccX: meanX, meanAccY: meanY, meanAccZ: meanZ,
            gyroMeanMagnitude: gyroMean, gyroMaxMagnitude: gyroMax,
            rejectedFrames: rejectedFrames,
            stillness: stillness,
            calibration: calibration)
    }
}
