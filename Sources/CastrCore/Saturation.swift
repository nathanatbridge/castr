import Foundation

/// Counts samples that hit the sensor's measurement limits.
///
/// The WT901BLE reports ±16 g and ±2000 °/s. A rod-mounted sensor can exceed
/// both during the stop at the end of a cast — and when it does, the value is
/// silently pinned at full scale rather than flagged. Clipped samples look like
/// plausible data, so peak acceleration and peak rotation both read *low* and
/// nothing in the file says so. This is the one failure mode that quietly
/// invalidates a cast recording.
public struct SaturationCounter {

    /// Within one LSB of full scale counts as clipped.
    public static let accLimitG = FrameParser.accelFullScaleG - 0.05      // 15.95
    public static let gyroLimitDPS = FrameParser.gyroFullScaleDPS - 5.0   // 1995

    public private(set) var total = 0
    public private(set) var accClipped = 0
    public private(set) var gyroClipped = 0

    public private(set) var peakAccMagnitude = 0.0
    public private(set) var peakGyroMagnitude = 0.0

    public init() {}

    public mutating func observe(_ r: SensorReading) {
        total += 1

        if abs(r.accX) >= Self.accLimitG
            || abs(r.accY) >= Self.accLimitG
            || abs(r.accZ) >= Self.accLimitG {
            accClipped += 1
        }
        if abs(r.gyroX) >= Self.gyroLimitDPS
            || abs(r.gyroY) >= Self.gyroLimitDPS
            || abs(r.gyroZ) >= Self.gyroLimitDPS {
            gyroClipped += 1
        }

        peakAccMagnitude = max(peakAccMagnitude, r.accMagnitude)
        let gyroMag = (r.gyroX * r.gyroX + r.gyroY * r.gyroY + r.gyroZ * r.gyroZ).squareRoot()
        peakGyroMagnitude = max(peakGyroMagnitude, gyroMag)
    }

    public mutating func observe(_ readings: [SensorReading]) {
        for r in readings { observe(r) }
    }

    public var accClippedPercent: Double {
        total == 0 ? 0 : Double(accClipped) / Double(total) * 100
    }

    public var gyroClippedPercent: Double {
        total == 0 ? 0 : Double(gyroClipped) / Double(total) * 100
    }

    public var didClip: Bool { accClipped > 0 || gyroClipped > 0 }

    /// True when the peaks sit close enough to full scale that the next, harder
    /// cast would likely clip — worth knowing before collecting a whole session.
    public var isNearLimit: Bool {
        !didClip && (peakAccMagnitude > FrameParser.accelFullScaleG * 0.8
                     || peakGyroMagnitude > FrameParser.gyroFullScaleDPS * 0.8)
    }
}
