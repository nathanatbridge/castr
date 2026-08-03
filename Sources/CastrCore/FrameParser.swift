import Foundation

/// Incremental parser for the WitMotion BLE 5.0 byte stream.
///
/// Frame layout (20 bytes, no checksum):
///
///     0x55 0x61 <9 x int16 little-endian: AccXYZ, GyroXYZ, AngleXYZ>
///
/// Pure Foundation and fully synchronous so it can be tested without hardware.
/// Feed it whatever arrives from BLE — frames split across packets, packets
/// carrying several frames, and leading garbage are all handled.
public struct FrameParser {

    // MARK: - Protocol constants

    public static let header: UInt8 = 0x55
    public static let flagAccGyroAngle: UInt8 = 0x61
    public static let frameLength = 20

    /// Full-scale ranges from the WitMotion datasheet.
    public static let accelFullScaleG = 16.0
    public static let gyroFullScaleDPS = 2000.0
    public static let angleFullScaleDeg = 180.0

    // MARK: - Diagnostics
    //
    // The 0x61 frame carries no checksum, so framing correctness cannot be
    // proven per-frame — only inferred. These counters are how you tell a clean
    // stream from a desynced one; a healthy session ends with rejected == 0.

    public struct Stats: Equatable {
        public var accepted = 0
        /// Candidate headers rejected by a validity check.
        public var rejected = 0
        /// Bytes discarded while hunting for a header.
        public var skippedBytes = 0

        public init() {}
    }

    public private(set) var stats = Stats()

    /// Bytes carried over between calls when a frame straddles two packets.
    private var buffer: [UInt8] = []

    public init() {}

    /// Discards any partial frame. Call on disconnect — otherwise a truncated
    /// frame from the previous session prefixes the next one and corrupts its
    /// first sample.
    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        lastTimestamp = nil
    }

    public mutating func resetStats() {
        stats = Stats()
    }

    /// Tells the parser what the last emitted timestamp was, so that readings
    /// respaced elsewhere (see `respace(_:endingAt:interval:startingAfter:)`)
    /// stay ordered with the ones it produces afterwards.
    public mutating func seedLastTimestamp(_ date: Date) {
        lastTimestamp = date
    }

    /// Assigns evenly spaced timestamps to a batch, ending at `time`.
    ///
    /// Exposed because the sample interval isn't known at the very start of a
    /// session: the first readings have to be held and spaced retroactively
    /// once the rate has been established.
    public static func respace(_ readings: [SensorReading],
                               endingAt time: Date,
                               interval: TimeInterval,
                               startingAfter previous: Date? = nil) -> [SensorReading] {
        guard !readings.isEmpty else { return [] }
        var start = time.addingTimeInterval(-interval * Double(readings.count - 1))
        if let previous, start <= previous {
            start = previous.addingTimeInterval(interval)
        }
        return readings.enumerated().map { index, r in
            SensorReading(
                timestamp: start.addingTimeInterval(interval * Double(index)),
                accX: r.accX, accY: r.accY, accZ: r.accZ,
                gyroX: r.gyroX, gyroY: r.gyroY, gyroZ: r.gyroZ,
                angleX: r.angleX, angleY: r.angleY, angleZ: r.angleZ)
        }
    }

    // MARK: - Parsing

    /// Last timestamp handed out, so reconstructed times stay strictly increasing.
    private var lastTimestamp: Date?

    /// Appends `bytes` and returns every complete frame now available.
    ///
    /// - Parameters:
    ///   - time: arrival timestamp of this batch.
    ///   - sampleInterval: nominal spacing between samples. When supplied, the
    ///     readings in a batch are spread backwards from `time` at this interval
    ///     instead of all sharing one timestamp.
    ///
    /// BLE delivers samples in bursts, so stamping every frame in a packet with
    /// its arrival time produces long runs of identical timestamps. Measured on
    /// a real 200 Hz WitMotion export: only 18% of timestamps were unique, up to
    /// 21 consecutive samples shared one, and some ran backwards. Any derivative
    /// taken against that column is meaningless. Spreading by the known interval
    /// gives a monotonic time base whose aggregate rate stays accurate.
    public mutating func feed(_ bytes: [UInt8],
                              at time: Date = Date(),
                              sampleInterval: TimeInterval? = nil) -> [SensorReading] {
        buffer.append(contentsOf: bytes)
        var readings: [SensorReading] = []

        while buffer.count >= Self.frameLength {
            guard let headerIndex = buffer.firstIndex(of: Self.header) else {
                // No header anywhere: the whole buffer is garbage. Keep the last
                // byte only if it could still be the start of one (it can't be —
                // we just proved there's no 0x55 — so drop everything).
                stats.skippedBytes += buffer.count
                buffer.removeAll(keepingCapacity: true)
                break
            }

            if headerIndex > 0 {
                stats.skippedBytes += headerIndex
                buffer.removeFirst(headerIndex)
                continue
            }

            guard buffer.count >= Self.frameLength else { break }

            guard buffer[1] == Self.flagAccGyroAngle else {
                // Some other WitMotion frame type (magnetometer replies are
                // 0x55 0x71, etc.). Skip this header and keep hunting.
                stats.rejected += 1
                stats.skippedBytes += 1
                buffer.removeFirst()
                continue
            }

            let candidate = Array(buffer.prefix(Self.frameLength))

            guard let reading = Self.decode(candidate, at: time),
                  isPlausible(reading, followedBy: buffer.count > Self.frameLength
                                                  ? buffer[Self.frameLength] : nil)
            else {
                // A `55 61` pair can occur inside a payload by chance. Advance one
                // byte rather than 20 so we don't skip a real frame behind it.
                stats.rejected += 1
                stats.skippedBytes += 1
                buffer.removeFirst()
                continue
            }

            buffer.removeFirst(Self.frameLength)
            stats.accepted += 1
            readings.append(reading)
        }

        guard let interval = sampleInterval, !readings.isEmpty else {
            if let last = readings.last { lastTimestamp = last.timestamp }
            return readings
        }
        let respaced = Self.respace(readings, endingAt: time,
                                    interval: interval, startingAfter: lastTimestamp)
        lastTimestamp = respaced.last?.timestamp
        return respaced
    }

    // MARK: - Validity

    /// Heuristic gate on a candidate frame.
    ///
    /// Note that a naive "is each value within full scale" check would be
    /// vacuous here: every int16 maps into range by construction, so it can
    /// never reject anything. These two checks can:
    ///
    /// 1. **Pitch bound.** `AngleY` is pitch, defined over -90...90, while the
    ///    encoding spans ±180. Random bytes land outside ±90 about half the time.
    /// 2. **Trailing byte.** Back-to-back frames mean the byte after a real frame
    ///    is the next header. Only checked when that byte has actually arrived,
    ///    so the common case of one frame per BLE packet is never penalised.
    private func isPlausible(_ reading: SensorReading, followedBy next: UInt8?) -> Bool {
        if abs(reading.angleY) > 90.0 { return false }
        if let next, next != Self.header { return false }
        return true
    }

    // MARK: - Decoding

    @inline(__always)
    static func int16LE(_ lo: UInt8, _ hi: UInt8) -> Int16 {
        Int16(bitPattern: UInt16(lo) | (UInt16(hi) << 8))
    }

    /// Decodes exactly one 20-byte frame. Returns nil if the header doesn't match.
    public static func decode(_ bytes: [UInt8], at time: Date) -> SensorReading? {
        guard bytes.count == frameLength,
              bytes[0] == header,
              bytes[1] == flagAccGyroAngle
        else { return nil }

        func scaled(_ lo: Int, _ hi: Int, _ fullScale: Double) -> Double {
            Double(int16LE(bytes[lo], bytes[hi])) / 32768.0 * fullScale
        }

        return SensorReading(
            timestamp: time,
            accX: scaled(2, 3, accelFullScaleG),
            accY: scaled(4, 5, accelFullScaleG),
            accZ: scaled(6, 7, accelFullScaleG),
            gyroX: scaled(8, 9, gyroFullScaleDPS),
            gyroY: scaled(10, 11, gyroFullScaleDPS),
            gyroZ: scaled(12, 13, gyroFullScaleDPS),
            angleX: scaled(14, 15, angleFullScaleDeg),
            angleY: scaled(16, 17, angleFullScaleDeg),
            angleZ: scaled(18, 19, angleFullScaleDeg)
        )
    }
}
