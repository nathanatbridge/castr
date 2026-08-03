import Foundation

/// One parsed sample from the WT901BLE sensor.
/// Column names mirror the WitMotion app's own CSV export so that
/// existing analysis code (cast_analysis.py) can read files produced
/// by either app without changes.
struct SensorReading: Identifiable {
    let id = UUID()
    let timestamp: Date

    let accX: Double   // g
    let accY: Double
    let accZ: Double

    let gyroX: Double  // deg/s
    let gyroY: Double
    let gyroZ: Double

    let angleX: Double // deg
    let angleY: Double
    let angleZ: Double

    /// ISO-8601-ish timestamp with milliseconds, matching the WitMotion
    /// app's own export format (e.g. "2025-02-10 20:40:46.710").
    var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }

    /// CSV row matching cast_analysis.py's expected columns.
    static let csvHeader = "time,DeviceName,AccX(g),AccY(g),AccZ(g),AsX(°/s),AsY(°/s),AsZ(°/s),AngleX(°),AngleY(°),AngleZ(°)"

    func csvRow(deviceName: String) -> String {
        "\(timeString),\(deviceName),\(accX),\(accY),\(accZ),\(gyroX),\(gyroY),\(gyroZ),\(angleX),\(angleY),\(angleZ)"
    }
}
