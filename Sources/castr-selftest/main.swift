import Foundation
import CastrCore

let args = Array(CommandLine.arguments.dropFirst())

// `--emit-fixture <path> [samples]` writes a synthetic hex fixture that
// `castr-collect --replay` can consume. Keeps fixture generation next to the
// code that defines the wire format.
if let flagIndex = args.firstIndex(of: "--emit-fixture") {
    guard flagIndex + 1 < args.count else {
        print("usage: castr-selftest --emit-fixture <path> [sampleCount]")
        exit(2)
    }
    let path = args[flagIndex + 1]
    let sampleCount = flagIndex + 2 < args.count ? (Int(args[flagIndex + 2]) ?? 400) : 400

    let bytes = SyntheticSource.session(sampleCount: sampleCount)
    var text = "# Synthetic WT901BLE stream: \(sampleCount) frames of 0x55 0x61\n"
    text += "# Simulates a cast — at rest, one burst of acceleration, back to rest.\n"
    // One frame per line keeps the fixture legible and diffable.
    for start in stride(from: 0, to: bytes.count, by: FrameParser.frameLength) {
        let end = min(start + FrameParser.frameLength, bytes.count)
        text += SyntheticSource.hexString(Array(bytes[start..<end])) + "\n"
    }

    do {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        print("Wrote \(sampleCount) frames (\(bytes.count) bytes) to \(path)")
        exit(0)
    } catch {
        print("error: \(error)")
        exit(1)
    }
}

// `--emit-csv <path> [strokes]` writes a small multi-stroke session. It is the
// shared fixture for the web parity check: the browser port of the analysis is
// asserted against Swift's own output on this exact file.
if let flagIndex = args.firstIndex(of: "--emit-csv") {
    guard flagIndex + 1 < args.count else {
        print("usage: castr-selftest --emit-csv <path> [strokeCount]")
        exit(2)
    }
    let path = args[flagIndex + 1]
    let count = flagIndex + 2 < args.count ? (Int(args[flagIndex + 2]) ?? 5) : 5
    let hz = 200.0
    let base = Date(timeIntervalSince1970: 1_700_000_000)

    var readings: [SensorReading] = []
    var clock = 0.0
    func rest(_ seconds: Double) {
        for _ in 0..<Int(seconds * hz) {
            readings.append(SensorReading(
                timestamp: base.addingTimeInterval(clock),
                accX: 0.01, accY: -0.02, accZ: 1.0,
                gyroX: 0.3, gyroY: -0.2, gyroZ: 0.1,
                angleX: 0, angleY: 0, angleZ: 0))
            clock += 1 / hz
        }
    }
    rest(0.6)
    for k in 0..<count {
        // Vary peak and duration so the spread statistics have something to chew on.
        let peak = 380.0 + Double(k) * 55.0
        let dur = 0.40 + Double(k % 3) * 0.06
        let n = Int(dur * hz)
        for i in 0..<n {
            let u = Double(i) / Double(n)
            let rate = peak * exp(-pow((u - 0.5) / 0.22, 2))
            readings.append(SensorReading(
                timestamp: base.addingTimeInterval(clock),
                accX: 0.01 + rate / 900, accY: -0.02, accZ: 1.0 + rate / 1400,
                gyroX: rate, gyroY: rate * 0.04, gyroZ: -rate * 0.02,
                angleX: 0, angleY: 0, angleZ: 0))
            clock += 1 / hz
        }
        rest(0.7)
    }

    do {
        let url = URL(fileURLWithPath: path)
        let w = try CSVWriter(url: url, deviceName: "WT901BLE-FIXTURE")
        w.write(readings)
        w.close()
        print("Wrote \(readings.count) rows (\(count) strokes) to \(path)")
        exit(0)
    } catch {
        print("error: \(error)")
        exit(1)
    }
}

print("castr-selftest — parser and CSV checks, no hardware required\n")

runFrameParserTests()
print("")
runCSVTests()
print("")
runStaticCheckTests()
print("")
runSaturationTests()
print("")
runGlitchFilterTests()
print("")
runStrokeAnalysisTests()
print("")
runEventTaggingTests()

print("")
if Check.failed == 0 {
    print("PASS — \(Check.passed) checks")
    exit(0)
} else {
    print("FAIL — \(Check.failed) failed, \(Check.passed) passed")
    exit(1)
}
