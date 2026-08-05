import Foundation

/// One parsed sample from the WT901BLE sensor.
///
/// Deliberately a plain value type with no `Identifiable` conformance: at 200 Hz
/// a per-sample `UUID()` is pure overhead, and nothing displays readings in a list.
public struct SensorReading: Equatable {
    public let timestamp: Date

    public let accX: Double   // g
    public let accY: Double
    public let accZ: Double

    public let gyroX: Double  // deg/s
    public let gyroY: Double
    public let gyroZ: Double

    public let angleX: Double // deg, roll   (-180...180)
    public let angleY: Double // deg, pitch  (-90...90)
    public let angleZ: Double // deg, yaw    (-180...180)

    public init(
        timestamp: Date,
        accX: Double, accY: Double, accZ: Double,
        gyroX: Double, gyroY: Double, gyroZ: Double,
        angleX: Double, angleY: Double, angleZ: Double
    ) {
        self.timestamp = timestamp
        self.accX = accX; self.accY = accY; self.accZ = accZ
        self.gyroX = gyroX; self.gyroY = gyroY; self.gyroZ = gyroZ
        self.angleX = angleX; self.angleY = angleY; self.angleZ = angleZ
    }

    /// Magnitude of the acceleration vector in g. Should read ~1.0 at rest —
    /// the quickest check that scaling and framing are both correct.
    public var accMagnitude: Double {
        (accX * accX + accY * accY + accZ * accZ).squareRoot()
    }
}

public extension SensorReading {
    /// Shared formatter matching the WitMotion app's export ("2025-02-10 20:40:46.710").
    ///
    /// Pinned to `en_US_POSIX` with an explicit calendar: a device set to a region
    /// that prefers 12-hour time will otherwise reinterpret `HH` and emit a string
    /// that doesn't match the declared format. Created once — building a
    /// `DateFormatter` per row is expensive and this runs per sample.
    static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone.current
        return f
    }()

    var timeString: String {
        Self.timestampFormatter.string(from: timestamp)
    }

    /// Every timestamp shape that turns up in a file we're expected to read,
    /// most specific first. WitMotion exports sometimes carry microseconds;
    /// ours are always milliseconds.
    static let timestampParsers: [DateFormatter] = {
        ["yyyy-MM-dd HH:mm:ss.SSSSSS",
         "yyyy-MM-dd HH:mm:ss.SSS",
         "yyyy-MM-dd HH:mm:ss"].map { format in
            let d = DateFormatter()
            d.dateFormat = format
            d.locale = Locale(identifier: "en_US_POSIX")
            d.calendar = Calendar(identifier: .gregorian)
            return d
        }
    }()

    /// Shared by the CSV reader and the event-log reader, so a sidecar and its
    /// recording can never disagree about what a timestamp means.
    static func parseTimestamp(_ s: String) -> Date? {
        for p in Self.timestampParsers {
            if let d = p.date(from: s) { return d }
        }
        return nil
    }
}
