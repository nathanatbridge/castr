import Foundation
import CastrCore

private func makeReading(accX: Double = 0, seconds: Double = 0) -> SensorReading {
    SensorReading(
        timestamp: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
        accX: accX, accY: 0, accZ: 1,
        gyroX: 0, gyroY: 0, gyroZ: 0,
        angleX: 0, angleY: 0, angleZ: 0)
}

func runCSVTests() {
    print("CSV")

    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("castr-selftest-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    func path(_ name: String) -> URL { tempDir.appendingPathComponent(name) }

    test("header matches the WitMotion column names") {
        Check.equal(
            CSVFormat.header,
            "time,DeviceName,AccX(g),AccY(g),AccZ(g),AsX(°/s),AsY(°/s),AsZ(°/s),"
            + "AngleX(°),AngleY(°),AngleZ(°)",
            "header")
        Check.equal(CSVFormat.columns.count, 11, "column count")
    }

    test("file is valid before close is called") {
        // The whole point of streaming: a session killed mid-recording still
        // leaves a readable CSV on disk.
        let destination = path("partial.csv")
        guard let writer = try? CSVWriter(url: destination,
                                          deviceName: "WT901BLE",
                                          flushEveryRows: 2) else {
            Check.isTrue(false, "could not open writer")
            return
        }

        for i in 0..<10 { writer.write(makeReading(seconds: Double(i))) }
        // Deliberately no close().

        let text = (try? String(contentsOf: destination, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n")
        Check.equal(lines.first.map(String.init) ?? "", CSVFormat.header, "header on disk")
        Check.atLeast(lines.count, 9, "flushed rows should already be on disk")
        writer.close()
    }

    test("round-trips frames through the parser and CSV") {
        let destination = path("roundtrip.csv")
        let expected: [(Double, Double, Double)] = [
            (0.0, 0.0, 1.0),
            (0.5, -0.25, 0.75),
            (-1.5, 2.0, 0.5),
        ]

        var stream = [UInt8]()
        for (x, y, z) in expected {
            stream += SyntheticSource.frame(accX: x, accY: y, accZ: z)
        }

        var parser = FrameParser()
        let readings = parser.feed(stream, at: t0)
        Check.equal(readings.count, expected.count, "parsed frames")

        guard let writer = try? CSVWriter(url: destination, deviceName: "WT901BLE") else {
            Check.isTrue(false, "could not open writer")
            return
        }
        writer.write(readings)
        writer.close()

        let text = (try? String(contentsOf: destination, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n").map(String.init)
        Check.equal(lines.count, expected.count + 1, "line count")
        guard lines.count == expected.count + 1 else { return }
        Check.equal(lines[0], CSVFormat.header, "header")

        for (index, (x, y, z)) in expected.enumerated() {
            let fields = lines[index + 1]
                .split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            Check.equal(fields.count, CSVFormat.columns.count, "field count row \(index)")
            guard fields.count == CSVFormat.columns.count else { continue }
            Check.equal(fields[1], "WT901BLE", "device name")
            Check.close(Double(fields[2]) ?? .nan, x, 0.001, "accX row \(index)")
            Check.close(Double(fields[3]) ?? .nan, y, 0.001, "accY row \(index)")
            Check.close(Double(fields[4]) ?? .nan, z, 0.001, "accZ row \(index)")
        }
    }

    test("numbers use fixed precision, not float noise") {
        let destination = path("precision.csv")
        guard let writer = try? CSVWriter(url: destination, deviceName: "d") else {
            Check.isTrue(false, "could not open writer")
            return
        }
        // 0.47900390625 is exactly representable from a 16-bit code and would
        // otherwise print with a long tail of digits.
        writer.write(makeReading(accX: 0.47900390625))
        writer.close()

        let text = (try? String(contentsOf: destination, encoding: .utf8)) ?? ""
        Check.isTrue(text.contains("0.4790"), "expected 4-decimal formatting")
        Check.isFalse(text.contains("0.47900390625"), "raw float precision leaked into CSV")
    }

    test("timestamp format is stable regardless of locale") {
        let text = makeReading().timeString
        Check.isFalse(text.contains("AM"), "12-hour clock leaked in")
        Check.isFalse(text.contains("PM"), "12-hour clock leaked in")
        Check.equal(text.count, 23, "expected yyyy-MM-dd HH:mm:ss.SSS")
    }

    test("hex fixtures round-trip") {
        let frames = SyntheticSource.session(sampleCount: 20)
        let hex = SyntheticSource.hexString(frames)
        Check.equal(SyntheticSource.bytes(fromHex: hex), frames, "hex round-trip")
    }

    test("hex parser ignores comments and whitespace") {
        let text = """
        # a comment
        5561 0000   # inline comment
        FFFF
        """
        Check.equal(SyntheticSource.bytes(fromHex: text),
                    [0x55, 0x61, 0x00, 0x00, 0xFF, 0xFF], "hex parse")
    }

    test("a synthetic session parses cleanly end to end") {
        let stream = SyntheticSource.session(sampleCount: 500)
        var parser = FrameParser()
        let readings = parser.feed(stream, at: Date())

        Check.equal(readings.count, 500, "frames")
        Check.equal(parser.stats.rejected, 0, "rejected")
        Check.equal(parser.stats.skippedBytes, 0, "stray bytes")
    }
}
