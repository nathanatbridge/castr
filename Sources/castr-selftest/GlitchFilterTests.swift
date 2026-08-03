import Foundation
import CastrCore

private func s(_ ax: Double, _ gx: Double = 0, at i: Int = 0) -> SensorReading {
    SensorReading(timestamp: t0.addingTimeInterval(Double(i) / 200.0),
                  accX: ax, accY: 0, accZ: 1,
                  gyroX: gx, gyroY: 0, gyroZ: 0,
                  angleX: 0, angleY: 0, angleZ: 0)
}

func runGlitchFilterTests() {
    print("GlitchFilter")

    test("the observed live corruption is caught") {
        // Rows 32-34 of the real recording: quiet, 6.05 g spike, quiet.
        var f = GlitchFilter()
        var out: [SensorReading] = []
        out += f.push(s(-0.016, 0.0, at: 0))
        out += f.push(s(6.049, 789.0, at: 1))
        out += f.push(s(-0.017, 0.0, at: 2))
        out += f.flush()

        Check.equal(f.glitchCount, 1, "glitches")
        Check.equal(out.count, 3, "kept by default")
    }

    test("dropping removes the spike but nothing else") {
        var f = GlitchFilter(dropsGlitches: true)
        var out: [SensorReading] = []
        for (i, v) in [-0.016, 6.049, -0.017].enumerated() {
            out += f.push(s(v, v > 1 ? 789 : 0, at: i))
        }
        out += f.flush()

        Check.equal(f.glitchCount, 1, "glitches")
        Check.equal(out.count, 2, "spike dropped")
        Check.isTrue(out.allSatisfy { $0.accX < 1.0 }, "spike still present")
    }

    test("a real cast transient is not mistaken for a glitch") {
        // A hard swing: every sample differs from the last, which is what
        // inertia looks like. Nothing here is isolated.
        var f = GlitchFilter()
        let ramp: [Double] = [0, 120, 340, 700, 1150, 1500, 1250, 800, 300, 40]
        for (i, g) in ramp.enumerated() { _ = f.push(s(1.0, g, at: i)) }
        _ = f.flush()
        Check.equal(f.glitchCount, 0, "should not flag real motion")
    }

    test("a steady stream is untouched") {
        var f = GlitchFilter()
        var out: [SensorReading] = []
        for i in 0..<50 { out += f.push(s(1.0, 0.5, at: i)) }
        out += f.flush()
        Check.equal(f.glitchCount, 0, "glitches")
        Check.equal(out.count, 50, "all samples emitted")
    }

    test("no samples are lost when nothing is dropped") {
        var f = GlitchFilter()
        var out: [SensorReading] = []
        let values: [Double] = [0.1, 0.2, 9.0, 0.2, 0.1, 0.3, 0.2]
        for (i, v) in values.enumerated() { out += f.push(s(v, at: i)) }
        out += f.flush()
        Check.equal(out.count, values.count, "every sample accounted for")
        Check.equal(f.totalCount, values.count, "total counted")
    }

    test("two adjacent bad samples are not treated as isolated") {
        // Consecutive corruption doesn't match the isolation signature, so it
        // is deliberately left alone rather than guessed at.
        var f = GlitchFilter()
        for (i, v) in [0.1, 9.0, 9.0, 0.1].enumerated() { _ = f.push(s(v, at: i)) }
        _ = f.flush()
        Check.equal(f.glitchCount, 0, "adjacent spikes are not isolated")
    }

    test("short input is handled") {
        var f = GlitchFilter()
        var out = f.push(s(1.0))
        out += f.flush()
        Check.equal(out.count, 1, "single sample survives")
    }
}
