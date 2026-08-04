import Foundation

/// Reads a Castr or WitMotion CSV back into readings.
///
/// Columns are located by name rather than position, so files with the extra
/// magnetometer / quaternion / battery columns and files without them both work,
/// as do exports whose column order differs.
public enum CSVReader {

    public enum ReadError: Error, CustomStringConvertible {
        case unreadable(URL)
        case missingColumns([String])
        case noRows

        public var description: String {
            switch self {
            case .unreadable(let u):
                return "could not read \(u.lastPathComponent)"
            case .missingColumns(let c):
                return "missing required column\(c.count == 1 ? "" : "s"): " + c.joined(separator: ", ")
            case .noRows:
                return "file has a header but no data rows"
            }
        }
    }

    /// Columns the analysis needs. The rest are optional.
    static let required = [
        "time",
        "AccX(g)", "AccY(g)", "AccZ(g)",
        "AsX(°/s)", "AsY(°/s)", "AsZ(°/s)",
    ]

    public struct Session {
        public let readings: [SensorReading]
        public let deviceName: String
        public var name: String

        public var duration: TimeInterval {
            guard let f = readings.first, let l = readings.last else { return 0 }
            return l.timestamp.timeIntervalSince(f.timestamp)
        }
        public var sampleRateHz: Double {
            duration > 0 ? Double(readings.count) / duration : 0
        }
    }

    public static func read(contentsOf url: URL) throws -> Session {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            throw ReadError.unreadable(url)
        }
        return try parse(raw, name: url.deletingPathExtension().lastPathComponent)
    }

    public static func parse(_ text: String, name: String) throws -> Session {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
        lines.removeAll { $0.isEmpty }
        guard let headerLine = lines.first else { throw ReadError.noRows }

        let header = headerLine.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var index = [String: Int]()
        for (i, h) in header.enumerated() where index[h] == nil { index[h] = i }

        let missing = required.filter { index[$0] == nil }
        guard missing.isEmpty else { throw ReadError.missingColumns(missing) }

        // WitMotion exports sometimes carry microseconds; ours are milliseconds.
        let formats = ["yyyy-MM-dd HH:mm:ss.SSSSSS",
                       "yyyy-MM-dd HH:mm:ss.SSS",
                       "yyyy-MM-dd HH:mm:ss"]
        let parsers = formats.map { f -> DateFormatter in
            let d = DateFormatter()
            d.dateFormat = f
            d.locale = Locale(identifier: "en_US_POSIX")
            d.calendar = Calendar(identifier: .gregorian)
            return d
        }

        func date(_ s: String) -> Date? {
            for p in parsers { if let d = p.date(from: s) { return d } }
            return nil
        }

        let deviceIdx = index["DeviceName"]
        var device = ""
        var readings = [SensorReading]()
        readings.reserveCapacity(lines.count - 1)

        for line in lines.dropFirst() {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { String($0) }
            guard f.count >= required.count else { continue }

            func num(_ column: String) -> Double? {
                guard let i = index[column], i < f.count else { return nil }
                return Double(f[i].trimmingCharacters(in: .whitespaces))
            }
            guard let i0 = index["time"], i0 < f.count,
                  let t = date(f[i0].trimmingCharacters(in: .whitespaces)),
                  let ax = num("AccX(g)"), let ay = num("AccY(g)"), let az = num("AccZ(g)"),
                  let gx = num("AsX(°/s)"), let gy = num("AsY(°/s)"), let gz = num("AsZ(°/s)")
            else { continue }

            if device.isEmpty, let di = deviceIdx, di < f.count { device = f[di] }

            readings.append(SensorReading(
                timestamp: t,
                accX: ax, accY: ay, accZ: az,
                gyroX: gx, gyroY: gy, gyroZ: gz,
                angleX: num("AngleX(°)") ?? 0,
                angleY: num("AngleY(°)") ?? 0,
                angleZ: num("AngleZ(°)") ?? 0))
        }

        guard !readings.isEmpty else { throw ReadError.noRows }
        return Session(readings: readings,
                       deviceName: device.isEmpty ? "unknown" : device,
                       name: name)
    }
}
