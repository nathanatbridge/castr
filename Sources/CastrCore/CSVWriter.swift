import Foundation

/// The single definition of Castr's CSV format.
///
/// Column names mirror the WitMotion app's own export so that existing analysis
/// code reads files from either source unchanged. If downstream analysis needs a
/// different layout, this enum is the only place that needs to change.
///
/// The header is UTF-8 and contains `°` — a classic source of header-matching
/// failures in pandas when a file is read as latin-1.
public enum CSVFormat {
    /// The full 21-column layout, verified against real WitMotion exports
    /// (`Oven Test WM.xlsx`, `Oven Test 256hz.xlsx`).
    ///
    /// Everything past `AngleZ` is emitted **empty**: the 0x55/0x61 frame we
    /// decode simply doesn't carry magnetometer, quaternion, temperature,
    /// version or battery. They're present so that analysis code selecting
    /// these columns by name finds them rather than raising a KeyError — the
    /// values are blank, never fabricated.
    public static let columns = [
        "time", "DeviceName",
        "AccX(g)", "AccY(g)", "AccZ(g)",
        "AsX(°/s)", "AsY(°/s)", "AsZ(°/s)",
        "AngleX(°)", "AngleY(°)", "AngleZ(°)",
        "HX(uT)", "HY(uT)", "HZ(uT)",
        "Q0()", "Q1()", "Q2()", "Q3()",
        "Temperature(°C)", "Version()", "Battery level(%)",
    ]

    /// Columns we actually populate; the rest are blank placeholders.
    public static let populatedColumnCount = 11

    public static let header = columns.joined(separator: ",")

    /// Four decimals. The sensor is 16-bit, so `0.47900390625` carries no more
    /// information than `0.4790` — it just doubles the file size.
    public static func format(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    public static func row(_ r: SensorReading, deviceName: String) -> String {
        var parts = [String]()
        parts.reserveCapacity(columns.count)
        parts.append(r.timeString)
        parts.append(deviceName)
        parts.append(format(r.accX)); parts.append(format(r.accY)); parts.append(format(r.accZ))
        parts.append(format(r.gyroX)); parts.append(format(r.gyroY)); parts.append(format(r.gyroZ))
        parts.append(format(r.angleX)); parts.append(format(r.angleY)); parts.append(format(r.angleZ))
        // Trailing columns the 0x61 frame doesn't carry.
        parts.append(contentsOf:
            Array(repeating: "", count: columns.count - populatedColumnCount))
        return parts.joined(separator: ",")
    }
}

/// Appends readings to a CSV file as they arrive.
///
/// The previous design accumulated the whole session in memory and serialized it
/// only on export, so a crash or a dead battery lost everything. Here the file on
/// disk is valid at every instant: rows are buffered briefly for throughput, then
/// flushed, and the buffer is bounded.
public final class CSVWriter {

    public enum WriterError: Error, CustomStringConvertible {
        case couldNotCreateFile(URL)

        public var description: String {
            switch self {
            case .couldNotCreateFile(let url): return "could not create file at \(url.path)"
            }
        }
    }

    public let url: URL
    public let deviceName: String
    public private(set) var rowsWritten = 0

    private let handle: FileHandle
    private var pending = String()
    private var pendingRows = 0
    private let flushEveryRows: Int
    private var isClosed = false

    /// - Parameter flushEveryRows: rows buffered before hitting the disk. At 200 Hz
    ///   the default bounds worst-case data loss to roughly a quarter second.
    public init(url: URL, deviceName: String, flushEveryRows: Int = 50) throws {
        self.url = url
        self.deviceName = deviceName
        self.flushEveryRows = flushEveryRows

        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw WriterError.couldNotCreateFile(url)
        }
        guard let h = try? FileHandle(forWritingTo: url) else {
            throw WriterError.couldNotCreateFile(url)
        }
        self.handle = h

        pending = CSVFormat.header + "\n"
        flush()
    }

    public func write(_ reading: SensorReading) {
        guard !isClosed else { return }
        pending += CSVFormat.row(reading, deviceName: deviceName)
        pending += "\n"
        rowsWritten += 1
        pendingRows += 1
        if pendingRows >= flushEveryRows { flush() }
    }

    public func write(_ readings: [SensorReading]) {
        for r in readings { write(r) }
    }

    public func flush() {
        guard !pending.isEmpty, !isClosed else { return }
        if let data = pending.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
        pending.removeAll(keepingCapacity: true)
        pendingRows = 0
    }

    public func close() {
        guard !isClosed else { return }
        flush()
        isClosed = true
        try? handle.close()
    }

    deinit {
        if !isClosed {
            flush()
            try? handle.close()
        }
    }
}
