import Foundation
import CastrCore

let t0 = Date(timeIntervalSince1970: 1_700_000_000)

func runFrameParserTests() {
    print("FrameParser")

    // MARK: - Scaling

    test("decodes known physical values") {
        let bytes = SyntheticSource.frame(
            accX: 0.5, accY: -1.0, accZ: 1.0,
            gyroX: 250.0, gyroY: -500.0, gyroZ: 0,
            angleX: 90.0, angleY: -45.0, angleZ: 135.0
        )
        var parser = FrameParser()
        let readings = parser.feed(bytes, at: t0)

        Check.equal(readings.count, 1, "frame count")
        guard let r = readings.first else { return }

        // Tolerance is one LSB of the 16-bit encoding for each channel.
        Check.close(r.accX, 0.5, 16.0 / 32768.0, "accX")
        Check.close(r.accY, -1.0, 16.0 / 32768.0, "accY")
        Check.close(r.accZ, 1.0, 16.0 / 32768.0, "accZ")
        Check.close(r.gyroX, 250.0, 2000.0 / 32768.0, "gyroX")
        Check.close(r.gyroY, -500.0, 2000.0 / 32768.0, "gyroY")
        Check.close(r.angleX, 90.0, 180.0 / 32768.0, "angleX")
        Check.close(r.angleY, -45.0, 180.0 / 32768.0, "angleY")
        Check.close(r.angleZ, 135.0, 180.0 / 32768.0, "angleZ")
        Check.equal(r.timestamp, t0, "timestamp")
    }

    test("resting sensor reads 1 g") {
        var parser = FrameParser()
        let readings = parser.feed(SyntheticSource.frame(accX: 0, accY: 0, accZ: 1.0), at: t0)
        Check.close(readings.first?.accMagnitude ?? 0, 1.0, 0.001, "|acc|")
    }

    // MARK: - Framing

    test("parses multiple frames in one packet") {
        var parser = FrameParser()
        let packet = SyntheticSource.frame(accZ: 1.0)
            + SyntheticSource.frame(accZ: 0.5)
            + SyntheticSource.frame(accZ: 0.25)

        let readings = parser.feed(packet, at: t0)
        Check.equal(readings.count, 3, "frames")
        Check.equal(parser.stats.accepted, 3, "accepted")
        Check.equal(parser.stats.rejected, 0, "rejected")
    }

    test("reassembles a frame split across packets") {
        var parser = FrameParser()
        let frame = SyntheticSource.frame(accX: 0.25, accZ: 1.0)

        // Split at every possible boundary; only the final chunk should yield it.
        for splitPoint in 1..<frame.count {
            parser.reset()
            parser.resetStats()

            let first = parser.feed(Array(frame[0..<splitPoint]), at: t0)
            Check.isTrue(first.isEmpty, "unexpected reading at split \(splitPoint)")

            let second = parser.feed(Array(frame[splitPoint...]), at: t0)
            Check.equal(second.count, 1, "lost frame at split \(splitPoint)")
            Check.close(second.first?.accX ?? 0, 0.25, 0.001, "accX at split \(splitPoint)")
        }
    }

    test("skips leading garbage") {
        var parser = FrameParser()
        let junk: [UInt8] = [0x00, 0xFF, 0x12, 0x34, 0xAB]
        let readings = parser.feed(junk + SyntheticSource.frame(accZ: 1.0), at: t0)

        Check.equal(readings.count, 1, "frames")
        Check.equal(parser.stats.skippedBytes, junk.count, "skipped bytes")
    }

    test("ignores other WitMotion frame types") {
        var parser = FrameParser()
        // A magnetometer reply (0x55 0x71) ahead of the frame we want.
        let magnetometer: [UInt8] = [0x55, 0x71] + [UInt8](repeating: 0x00, count: 18)
        let readings = parser.feed(magnetometer + SyntheticSource.frame(accZ: 1.0), at: t0)

        Check.equal(readings.count, 1, "frames")
        Check.close(readings.first?.accZ ?? 0, 1.0, 0.001, "accZ")
    }

    test("does not desync on a 55 61 pair inside a payload") {
        var frame = SyntheticSource.frame(accZ: 1.0)
        frame[6] = 0x55
        frame[7] = 0x61

        var parser = FrameParser()
        let readings = parser.feed(frame + SyntheticSource.frame(accX: 0.75, accZ: 1.0), at: t0)

        // Both frames still decode: the first header is intact, and the embedded
        // pair must not have shifted alignment for the one behind it.
        Check.equal(readings.count, 2, "frames")
        Check.close(readings.last?.accX ?? 0, 0.75, 0.001, "accX of second frame")
    }

    test("holds a truncated trailing frame instead of dropping it") {
        var parser = FrameParser()
        let full = SyntheticSource.frame(accZ: 1.0)
        let target = SyntheticSource.frame(accX: 0.5, accZ: 1.0)

        let first = parser.feed(full + Array(target.prefix(9)), at: t0)
        Check.equal(first.count, 1, "first batch")

        let second = parser.feed(Array(target.dropFirst(9)), at: t0)
        Check.equal(second.count, 1, "second batch")
        Check.close(second.first?.accX ?? 0, 0.5, 0.001, "accX")
    }

    test("reset discards a partial frame") {
        var parser = FrameParser()
        let frame = SyntheticSource.frame(accZ: 1.0)

        _ = parser.feed(Array(frame.prefix(10)), at: t0)
        parser.reset()

        // Without reset these trailing bytes would fuse with the stale prefix and
        // produce a corrupt first sample on the next connection.
        let readings = parser.feed(Array(frame.dropFirst(10)), at: t0)
        Check.isTrue(readings.isEmpty, "stale bytes leaked into a new session")
    }

    test("rejects out-of-range pitch") {
        // AngleY is pitch, defined only over -90...90, though the encoding spans
        // ±180. A value beyond that means we're decoding misaligned bytes.
        var parser = FrameParser()
        let readings = parser.feed(SyntheticSource.frame(accZ: 1.0, angleY: 150.0), at: t0)

        Check.isTrue(readings.isEmpty, "implausible pitch was accepted")
        Check.equal(parser.stats.rejected, 1, "rejected")
    }

    test("random noise produces almost no readings") {
        var noise = [UInt8]()
        for _ in 0..<20_000 { noise.append(UInt8.random(in: 0...255)) }

        var parser = FrameParser()
        let readings = parser.feed(noise, at: t0)

        // Without a checksum the heuristics can't be perfect, but they should
        // reject the overwhelming majority of random data.
        Check.lessThan(readings.count, 5, "too many false frames from noise")
    }
}
