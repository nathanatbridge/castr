import Foundation
import CastrCore

/// Builds a stroke: rotation about one axis with a smooth bell-shaped rate
/// profile, which is roughly the shape of a real casting stroke.
private func stroke(peakDPS: Double, duration: Double, axis: Int = 0,
                    rateHz: Double = 200, at start: Double = 0,
                    restBefore: Double = 0.5, restAfter: Double = 0.5) -> [SensorReading] {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    var out = [SensorReading]()
    let total = restBefore + duration + restAfter
    let n = Int(total * rateHz)

    for i in 0..<n {
        let t = Double(i) / rateHz
        var rate = 0.0
        if t >= restBefore && t <= restBefore + duration {
            let u = (t - restBefore) / duration              // 0...1
            rate = peakDPS * exp(-pow((u - 0.5) / 0.22, 2))  // bell
        }
        var g = [0.0, 0.0, 0.0]
        g[axis] = rate
        out.append(SensorReading(
            timestamp: base.addingTimeInterval(start + t),
            accX: 0, accY: 0, accZ: 1,
            gyroX: g[0], gyroY: g[1], gyroZ: g[2],
            angleX: 0, angleY: 0, angleZ: 0))
    }
    return out
}

private func concat(_ groups: [[SensorReading]]) -> [SensorReading] {
    groups.flatMap { $0 }
}

func runStrokeAnalysisTests() {
    print("StrokeAnalysis")

    test("finds a single stroke in a quiet session") {
        let r = stroke(peakDPS: 600, duration: 0.5)
        let spans = StrokeDetector().detect(r)
        Check.equal(spans.count, 1, "strokes")
    }

    test("a still session yields no strokes") {
        var r = [SensorReading]()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<400 {
            r.append(SensorReading(timestamp: base.addingTimeInterval(Double(i)/200),
                                   accX: 0, accY: 0, accZ: 1,
                                   gyroX: 0.4, gyroY: -0.2, gyroZ: 0.1,
                                   angleX: 0, angleY: 0, angleZ: 0))
        }
        Check.equal(StrokeDetector().detect(r).count, 0, "strokes")
    }

    test("separate strokes stay separate") {
        // Two bells with a full second of rest between them.
        let r = concat([stroke(peakDPS: 500, duration: 0.4, restAfter: 1.0),
                        stroke(peakDPS: 500, duration: 0.4, at: 1.9, restBefore: 0.0)])
        Check.equal(StrokeDetector().detect(r).count, 2, "strokes")
    }

    test("an over-long span is split, not reported as one stroke") {
        // Continuous motion that never settles — two bells with no rest between.
        var d = StrokeDetector()
        d.maxDuration = 1.0
        let r = concat([stroke(peakDPS: 400, duration: 1.2, restAfter: 0.0),
                        stroke(peakDPS: 400, duration: 1.2, at: 1.7, restBefore: 0.0)])
        let spans = d.detect(r)
        Check.atLeast(spans.count, 2, "should split a continuous span")
        for s in spans {
            let dur = r[s.upperBound-1].timestamp.timeIntervalSince(r[s.lowerBound].timestamp)
            Check.isTrue(dur <= d.maxDuration * 1.05, "span still too long: \(dur)")
        }
    }

    test("arc matches the rotation actually applied") {
        // Integral of the bell, computed independently of the code under test.
        let peak = 600.0, dur = 0.5, hz = 200.0
        var expected = 0.0
        for i in 0..<Int(dur*hz) {
            let u = Double(i)/(dur*hz)
            expected += peak * exp(-pow((u - 0.5)/0.22, 2)) / hz
        }
        let r = stroke(peakDPS: peak, duration: dur, rateHz: hz)
        guard let m = StrokeAnalyzer.analyze(r).first else {
            Check.isTrue(false, "no stroke"); return
        }
        Check.close(m.arcDeg, expected, expected * 0.06, "arc")
    }

    test("peak rate and its position are found") {
        let r = stroke(peakDPS: 750, duration: 0.6)
        guard let m = StrokeAnalyzer.analyze(r).first else {
            Check.isTrue(false, "no stroke"); return
        }
        Check.close(m.peakRateDPS, 750, 5, "peak rate")
        // The bell is symmetric, so the peak sits mid-stroke.
        Check.close(m.peakRateAtPct, 50, 12, "peak position")
    }

    test("single-axis rotation reads as fully planar") {
        let r = stroke(peakDPS: 500, duration: 0.5, axis: 1)
        guard let m = StrokeAnalyzer.analyze(r).first else {
            Check.isTrue(false, "no stroke"); return
        }
        Check.close(m.planarityPct, 100, 0.5, "planarity")
        Check.equal(m.dominantAxis, "Y", "dominant axis")
    }

    test("a harder stop registers a larger deceleration") {
        // Same peak rate, half the duration: the stop must be sharper.
        let slow = StrokeAnalyzer.analyze(stroke(peakDPS: 600, duration: 0.8)).first
        let fast = StrokeAnalyzer.analyze(stroke(peakDPS: 600, duration: 0.3)).first
        guard let s = slow, let f = fast else { Check.isTrue(false, "missing"); return }
        Check.isTrue(f.peakDecelDPS2 > s.peakDecelDPS2 * 1.5,
                     "expected a sharper stop: \(f.peakDecelDPS2) vs \(s.peakDecelDPS2)")
    }

    test("spread statistics are correct") {
        let sp = Spread(name: "t", unit: "u", values: [2, 4, 4, 4, 5, 5, 7, 9])
        Check.close(sp.mean, 5.0, 1e-9, "mean")
        Check.close(sp.sd, 2.13809, 1e-4, "sample sd")
        Check.close(sp.cvPct, 42.7618, 1e-3, "cv")
        Check.close(sp.min, 2, 1e-9, "min")
        Check.close(sp.max, 9, 1e-9, "max")
    }

    test("an outlier is flagged") {
        var v = [Double](repeating: 100, count: 12)
        v[0] = 101; v[1] = 99          // a little natural spread
        v[5] = 300                     // the outlier
        let sp = Spread(name: "t", unit: "u", values: v)
        Check.isTrue(sp.outliers.contains(5), "should flag index 5")
    }

    test("CSV round-trips through writer and reader") {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("castr-rt-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s.csv")

        let original = stroke(peakDPS: 480, duration: 0.4)
        guard let w = try? CSVWriter(url: url, deviceName: "WT901BLE") else {
            Check.isTrue(false, "writer"); return
        }
        w.write(original)
        w.close()

        guard let session = try? CSVReader.read(contentsOf: url) else {
            Check.isTrue(false, "reader"); return
        }
        Check.equal(session.readings.count, original.count, "row count")
        Check.equal(session.deviceName, "WT901BLE", "device")
        Check.close(session.sampleRateHz, 200, 2, "rate")

        let a = StrokeAnalyzer.analyze(original).first
        let b = StrokeAnalyzer.analyze(session.readings).first
        guard let ma = a, let mb = b else { Check.isTrue(false, "no strokes"); return }
        Check.close(mb.arcDeg, ma.arcDeg, 0.5, "arc survives the round trip")
        Check.close(mb.peakRateDPS, ma.peakRateDPS, 0.5, "peak survives the round trip")
    }

    test("a file missing required columns is rejected clearly") {
        let text = "time,AccX(g),AccY(g)\n2026-08-03 10:00:00.000,0,0\n"
        do {
            _ = try CSVReader.parse(text, name: "bad")
            Check.isTrue(false, "should have thrown")
        } catch let e as CSVReader.ReadError {
            Check.isTrue("\(e)".contains("AccZ(g)"), "should name the missing column")
        } catch {
            Check.isTrue(false, "wrong error type")
        }
    }

    test("microsecond timestamps are accepted") {
        // WitMotion's own exports carry six decimal places.
        let text = CSVFormat.header + "\n" +
            "2026-08-03 10:00:00.123456,WT,0,0,1,0,0,0,0,0,0,,,,,,,,,,\n"
        guard let s = try? CSVReader.parse(text, name: "us") else {
            Check.isTrue(false, "should parse microseconds"); return
        }
        Check.equal(s.readings.count, 1, "rows")
    }
}
