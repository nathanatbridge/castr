import Foundation

/// Builds byte streams in the sensor's wire format.
///
/// This is what makes the whole pipeline testable with no hardware present: it
/// encodes known physical values, so a test can assert that what comes out of
/// `FrameParser` is what went in.
public enum SyntheticSource {

    /// Inverse of the parser's scaling, with saturation at full scale.
    static func encode(_ value: Double, fullScale: Double) -> Int16 {
        let raw = (value / fullScale * 32768.0).rounded()
        return Int16(max(-32768.0, min(32767.0, raw)))
    }

    static func appendLE(_ value: Int16, to bytes: inout [UInt8]) {
        let u = UInt16(bitPattern: value)
        bytes.append(UInt8(u & 0xFF))
        bytes.append(UInt8((u >> 8) & 0xFF))
    }

    /// One 20-byte `0x55 0x61` frame carrying the given physical values.
    public static func frame(
        accX: Double = 0, accY: Double = 0, accZ: Double = 1,
        gyroX: Double = 0, gyroY: Double = 0, gyroZ: Double = 0,
        angleX: Double = 0, angleY: Double = 0, angleZ: Double = 0
    ) -> [UInt8] {
        var bytes: [UInt8] = [FrameParser.header, FrameParser.flagAccGyroAngle]
        bytes.reserveCapacity(FrameParser.frameLength)

        let g = FrameParser.accelFullScaleG
        let d = FrameParser.gyroFullScaleDPS
        let a = FrameParser.angleFullScaleDeg

        appendLE(encode(accX, fullScale: g), to: &bytes)
        appendLE(encode(accY, fullScale: g), to: &bytes)
        appendLE(encode(accZ, fullScale: g), to: &bytes)
        appendLE(encode(gyroX, fullScale: d), to: &bytes)
        appendLE(encode(gyroY, fullScale: d), to: &bytes)
        appendLE(encode(gyroZ, fullScale: d), to: &bytes)
        appendLE(encode(angleX, fullScale: a), to: &bytes)
        appendLE(encode(angleY, fullScale: a), to: &bytes)
        appendLE(encode(angleZ, fullScale: a), to: &bytes)

        return bytes
    }

    /// A stream resembling a cast: mostly at rest, with a burst of acceleration
    /// and rotation in the middle. Useful for exercising the full pipeline and
    /// for producing a CSV of known shape to develop analysis against.
    public static func session(sampleCount: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(sampleCount * FrameParser.frameLength)

        for i in 0..<sampleCount {
            let t = Double(i) / Double(max(sampleCount - 1, 1))
            // A single smooth burst centred at t = 0.5.
            let burst = exp(-pow((t - 0.5) / 0.08, 2))
            let swing = sin(t * .pi * 2) * burst

            out.append(contentsOf: frame(
                accX: 4.0 * swing,
                accY: 1.5 * burst,
                accZ: 1.0 + 2.0 * burst,
                gyroX: 600.0 * swing,
                gyroY: 120.0 * burst,
                gyroZ: 90.0 * swing,
                angleX: 45.0 * swing,
                angleY: 30.0 * burst,
                angleZ: 60.0 * swing
            ))
        }
        return out
    }

    // MARK: - Hex fixtures

    public static func hexString(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }

    /// Parses a hex fixture, ignoring whitespace, newlines and `#` comments.
    public static func bytes(fromHex text: String) -> [UInt8] {
        var digits = [Character]()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let body = line.split(separator: "#", maxSplits: 1,
                                  omittingEmptySubsequences: false).first ?? ""
            for ch in body where ch.isHexDigit { digits.append(ch) }
        }

        var out = [UInt8]()
        out.reserveCapacity(digits.count / 2)
        var index = 0
        while index + 1 < digits.count {
            if let byte = UInt8(String([digits[index], digits[index + 1]]), radix: 16) {
                out.append(byte)
            }
            index += 2
        }
        return out
    }
}
