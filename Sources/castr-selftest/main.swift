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

    // The rotation schedule comes first; acceleration is then derived from it,
    // rather than invented. An earlier version of this fixture wrote a made-up
    // acceleration (`0.01 + rate/900`) that no rotating body could produce, and
    // fitting a lever arm to it returned 125 m. Data that can't happen is worse
    // than no data — the same reason the ten unpopulated CSV columns are left
    // blank instead of filled in.
    var omega: [(t: Double, w: [Double])] = []
    var clock = 0.0
    func rest(_ seconds: Double) {
        for _ in 0..<Int(seconds * hz) {
            // A small constant offset, i.e. gyro bias: the reconstruction is
            // expected to measure it and take it out.
            omega.append((clock, [0.3, -0.2, 0.1]))
            clock += 1 / hz
        }
    }
    func bell(peak: Double, dur: Double) {
        let n = Int(dur * hz)
        for i in 0..<n {
            let u = Double(i) / Double(n)
            let rate = peak * exp(-pow((u - 0.5) / 0.22, 2))
            omega.append((clock, [rate, rate * 0.04, -rate * 0.02]))
            clock += 1 / hz
        }
    }

    rest(0.6)
    for k in 0..<count {
        // Vary peak and duration so the spread statistics have something to chew on.
        bell(peak: 380.0 + Double(k) * 55.0, dur: 0.40 + Double(k % 3) * 0.06)
        rest(0.7)
    }
    // A back-to-back reversal, the shape real casting makes: the rod turns
    // around without ever settling. Nothing else in this fixture exercises
    // reversal splitting, and that is where the two ports can silently drift.
    bell(peak: 430, dur: 0.40)
    bell(peak: -430, dur: 0.40)
    rest(0.7)

    // --- derive acceleration from rotation about a rigid arm ---
    //
    // The sensor sits at a fixed offset from a stationary pivot, so what the
    // accelerometer reads is gravity plus the centripetal and tangential terms
    // of turning: a = g_body + (w x (w x r) + alpha x r) / G. Ground truth for
    // tools/verify-reconstruction.js, which has to recover ARM_M from the CSV.
    let armBody = [0.08, -0.10, -0.26]        // 29.0 cm from the pivot
    let gravity = 9.80665
    let deg = Double.pi / 180

    func qmul(_ a: [Double], _ b: [Double]) -> [Double] {
        [a[0]*b[0] - a[1]*b[1] - a[2]*b[2] - a[3]*b[3],
         a[0]*b[1] + a[1]*b[0] + a[2]*b[3] - a[3]*b[2],
         a[0]*b[2] - a[1]*b[3] + a[2]*b[0] + a[3]*b[1],
         a[0]*b[3] + a[1]*b[2] - a[2]*b[1] + a[3]*b[0]]
    }
    func qnorm(_ q: [Double]) -> [Double] {
        let n = (q[0]*q[0] + q[1]*q[1] + q[2]*q[2] + q[3]*q[3]).squareRoot()
        return q.map { $0 / n }
    }
    /// Rotate `v` by the conjugate of `q` — world into body.
    func qrotInv(_ q: [Double], _ v: [Double]) -> [Double] {
        let w = q[0], x = -q[1], y = -q[2], z = -q[3]
        let tx = 2*(y*v[2] - z*v[1]), ty = 2*(z*v[0] - x*v[2]), tz = 2*(x*v[1] - y*v[0])
        return [v[0] + w*tx + (y*tz - z*ty),
                v[1] + w*ty + (z*tx - x*tz),
                v[2] + w*tz + (x*ty - y*tx)]
    }
    func cross(_ a: [Double], _ b: [Double]) -> [Double] {
        [a[1]*b[2] - a[2]*b[1], a[2]*b[0] - a[0]*b[2], a[0]*b[1] - a[1]*b[0]]
    }

    let n = omega.count
    // Angular acceleration by central difference, matching how the analysis
    // estimates it — a one-sample difference is mostly quantisation.
    func alpha(_ i: Int) -> [Double] {
        let a = Swift.max(0, i - 2), b = Swift.min(n - 1, i + 2)
        let dt = omega[b].t - omega[a].t
        guard dt > 0 else { return [0, 0, 0] }
        return (0..<3).map { (omega[b].w[$0] - omega[a].w[$0]) * deg / dt }
    }

    var readings: [SensorReading] = []
    var q = [1.0, 0.0, 0.0, 0.0]              // starts level, so at rest acc reads +Z
    for i in 0..<n {
        let w = omega[i].w.map { $0 * deg }   // rad/s
        let gBody = qrotInv(q, [0, 0, 1])
        let dyn = zip(cross(w, cross(w, armBody)), cross(alpha(i), armBody)).map { $0 + $1 }
        readings.append(SensorReading(
            timestamp: base.addingTimeInterval(omega[i].t),
            accX: gBody[0] + dyn[0] / gravity,
            accY: gBody[1] + dyn[1] / gravity,
            accZ: gBody[2] + dyn[2] / gravity,
            gyroX: omega[i].w[0], gyroY: omega[i].w[1], gyroZ: omega[i].w[2],
            angleX: 0, angleY: 0, angleZ: 0))
        if i < n - 1 {
            let dt = omega[i + 1].t - omega[i].t
            let mag = (w[0]*w[0] + w[1]*w[1] + w[2]*w[2]).squareRoot()
            let ang = mag * dt
            if ang > 1e-12 {
                let s = sin(ang / 2) / mag
                q = qnorm(qmul(q, [cos(ang / 2), w[0]*s, w[1]*s, w[2]*s]))
            }
        }
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
