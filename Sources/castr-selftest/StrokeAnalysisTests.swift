import Foundation
import CastrCore

/// Builds a stroke: rotation about one axis with a smooth bell-shaped rate
/// profile, which is roughly the shape of a real casting stroke.
///
/// `turning` makes the accelerometer follow the rotation instead of reading a
/// constant +Z, which is what the stopping-point tests need: without it the
/// sensor's attitude never changes and every stroke stops in the same place by
/// construction. The body is treated as pivoting with no lever arm, so
/// acceleration is gravity alone — enough to carry an attitude, and it keeps
/// the reading inside the stillness bounds where the rotation stops.
private func stroke(peakDPS: Double, duration: Double, axis: Int = 0,
                    rateHz: Double = 200, at start: Double = 0,
                    restBefore: Double = 0.5, restAfter: Double = 0.5,
                    turning: Bool = false) -> [SensorReading] {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    var out = [SensorReading]()
    let total = restBefore + duration + restAfter
    let n = Int(total * rateHz)
    let deg = Double.pi / 180
    var up = [0.0, 0.0, 1.0]

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
            accX: turning ? up[0] : 0,
            accY: turning ? up[1] : 0,
            accZ: turning ? up[2] : 1,
            gyroX: g[0], gyroY: g[1], gyroZ: g[2],
            angleX: 0, angleY: 0, angleZ: 0))
        if turning {
            // A world-fixed vector seen from the rotating body: dv/dt = −w × v.
            let ang = -rate * deg / rateHz
            var n0 = [0.0, 0.0, 0.0]; n0[axis] = 1
            let c = cos(ang), s = sin(ang)
            let cr = [n0[1]*up[2] - n0[2]*up[1],
                      n0[2]*up[0] - n0[0]*up[2],
                      n0[0]*up[1] - n0[1]*up[0]]
            let dt = n0[0]*up[0] + n0[1]*up[1] + n0[2]*up[2]
            up = (0..<3).map { up[$0]*c + cr[$0]*s + n0[$0]*dt*(1 - c) }
        }
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

    test("a back-and-forward pair with no rest between them splits in two") {
        // The fish1 case: at tempo the rod never settles between the back cast
        // and the forward cast, so rate alone leaves them as one stroke.
        let r = concat([stroke(peakDPS: 500, duration: 0.4, restAfter: 0.0),
                        stroke(peakDPS: -500, duration: 0.4, at: 0.9, restBefore: 0.0)])
        Check.equal(StrokeDetector().detect(r).count, 2, "strokes")
    }

    test("a split pair recovers its arc instead of cancelling") {
        // Undetected, the two halves net to nothing — fish1 #22 read 18.9° of
        // arc off 242° of path. Each half must carry its own rotation.
        let alone = StrokeAnalyzer.analyze(stroke(peakDPS: 500, duration: 0.4)).first
        guard let single = alone else { Check.isTrue(false, "no lone stroke"); return }

        let r = concat([stroke(peakDPS: 500, duration: 0.4, restAfter: 0.0),
                        stroke(peakDPS: -500, duration: 0.4, at: 0.9, restBefore: 0.0)])
        let m = StrokeAnalyzer.analyze(r)
        Check.equal(m.count, 2, "strokes")
        for s in m {
            Check.close(s.arcDeg, single.arcDeg, single.arcDeg * 0.1, "arc of each half")
        }
    }

    test("two bursts in the same direction stay one stroke") {
        // Only a reversal ends a stroke. Same-direction motion that never
        // settles is one continuous sweep, and stays the duration guard's job.
        let r = concat([stroke(peakDPS: 500, duration: 0.4, restAfter: 0.0),
                        stroke(peakDPS: 500, duration: 0.4, at: 0.9, restBefore: 0.0)])
        Check.equal(StrokeDetector().detect(r).count, 1, "strokes")
    }

    test("a small reversal inside a stroke does not split it") {
        // A wobble is not a cast. The test is relative — PLAN.md §4c showed no
        // constant arc threshold survives the corpus.
        let r = concat([stroke(peakDPS: 500, duration: 0.4, restAfter: 0.0),
                        stroke(peakDPS: -90, duration: 0.12, at: 0.9, restBefore: 0.0)])
        Check.equal(StrokeDetector().detect(r).count, 1, "strokes")
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

    test("drive acceleration and stop deceleration are separate readings") {
        // The bell is symmetric, so a stroke driven and stopped over the same
        // span must read the same either side of the peak. Anything else means
        // one of the two is picking up the other's half of the stroke.
        guard let m = StrokeAnalyzer.analyze(stroke(peakDPS: 600, duration: 0.5)).first else {
            Check.isTrue(false, "no stroke"); return
        }
        Check.isTrue(m.peakAccelDPS2 > 0, "drive acceleration should be positive")
        Check.close(m.peakAccelDPS2, m.peakDecelDPS2, m.peakDecelDPS2 * 0.1,
                    "a symmetric stroke drives as hard as it stops")
    }

    test("an unbroken build reads as a smooth drive") {
        guard let m = StrokeAnalyzer.analyze(stroke(peakDPS: 600, duration: 0.5)).first else {
            Check.isTrue(false, "no stroke"); return
        }
        Check.close(m.driveSmoothPct, 100, 2, "one continuous bell never stops rising")
    }

    test("a stall in the drive shows up as a rougher one") {
        // Two humps run together: the rate rises, falls back, then rises again
        // to the real peak. The build is no longer continuous and the figure
        // has to see it, because that shove is what a caster is told not to do.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var r = [SensorReading]()
        for i in 0..<Int(1.4 * 200) {
            let t = Double(i) / 200
            var rate = 0.0
            if t >= 0.5 && t <= 1.0 {
                let u = (t - 0.5) / 0.5
                rate = 300 * exp(-pow((u - 0.22) / 0.10, 2))
                     + 600 * exp(-pow((u - 0.62) / 0.14, 2))
            }
            r.append(SensorReading(timestamp: base.addingTimeInterval(t),
                                   accX: 0, accY: 0, accZ: 1,
                                   gyroX: rate, gyroY: 0, gyroZ: 0,
                                   angleX: 0, angleY: 0, angleZ: 0))
        }
        guard let m = StrokeAnalyzer.analyze(r).first else {
            Check.isTrue(false, "no stroke"); return
        }
        Check.isTrue(m.driveSmoothPct < 85,
                     "a stalled drive should read below a clean one: \(m.driveSmoothPct)")
    }

    test("rotation about one axis leaves nothing out of plane") {
        let r = stroke(peakDPS: 500, duration: 0.5, axis: 1)
        guard let m = StrokeAnalyzer.analyze(r).first else {
            Check.isTrue(false, "no stroke"); return
        }
        Check.close(m.offPlaneDeg, 0, 0.5, "off-plane rotation")
        Check.close(m.inPlanePct, 100, 0.5, "in-plane share")
    }

    test("off-plane rotation is measured against the stroke's own axis") {
        // Equal rotation about two axes at once. The movement is still planar —
        // it turns about the single diagonal axis between them — so a measure
        // taken against the stroke's own axis has to say so, even though
        // planarity, which asks about the largest *sensor* axis, reads 71%.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var r = [SensorReading]()
        for i in 0..<Int(1.4 * 200) {
            let t = Double(i) / 200
            var rate = 0.0
            if t >= 0.5 && t <= 1.0 {
                rate = 500 * exp(-pow(((t - 0.5) / 0.5 - 0.5) / 0.22, 2))
            }
            r.append(SensorReading(timestamp: base.addingTimeInterval(t),
                                   accX: 0, accY: 0, accZ: 1,
                                   gyroX: rate, gyroY: rate, gyroZ: 0,
                                   angleX: 0, angleY: 0, angleZ: 0))
        }
        guard let m = StrokeAnalyzer.analyze(r).first else {
            Check.isTrue(false, "no stroke"); return
        }
        Check.close(m.inPlanePct, 100, 0.5, "in-plane share of a diagonal-axis stroke")
        Check.isTrue(m.planarityPct < 80,
                     "planarity should be the one fooled here: \(m.planarityPct)")
    }

    test("the stopping point is read where the rotation stopped") {
        // Rotating about X by a known arc from level, the up vector must have
        // turned by that same arc when the rod comes to rest.
        let r = stroke(peakDPS: 400, duration: 0.5, restAfter: 1.0, turning: true)
        guard let m = StrokeAnalyzer.analyze(r).first else {
            Check.isTrue(false, "no stroke"); return
        }
        guard let up = Check.notNil(m.stopUp, "stopping point") else { return }
        let tilt = acos(Swift.max(-1, Swift.min(1, up[2]))) * 180 / .pi
        // Not exactly the arc: the bell's leading tail sits below the rate that
        // opens a stroke, so the rod turns a little further than the stroke the
        // detector saw. Close is the assertion — the attitude is real.
        Check.close(tilt, m.arcDeg, m.arcDeg * 0.05, "tilt at the stop tracks the arc swept")
        Check.isTrue(m.stopStillSamples >= StrokeAnalyzer.stopStillMinSamples,
                     "should have averaged a real window")
    }

    test("a stroke the rod never settles after has no stopping point") {
        // The fish1 #22 case: the back cast runs straight into the forward cast.
        // Two bells superposed rather than laid end to end, so the rate passes
        // through zero on its way past instead of resting there — which is what
        // real casting tempo does, and what leaves nothing to read gravity off.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var r = [SensorReading]()
        let deg = Double.pi / 180
        var up = [0.0, 0.0, 1.0]
        for i in 0..<Int(2.0 * 200) {
            let t = Double(i) / 200
            let rate = 500 * exp(-pow((t - 0.55) / 0.10, 2))
                     - 500 * exp(-pow((t - 0.90) / 0.10, 2))
            r.append(SensorReading(timestamp: base.addingTimeInterval(t),
                                   accX: up[0], accY: up[1], accZ: up[2],
                                   gyroX: rate, gyroY: 0, gyroZ: 0,
                                   angleX: 0, angleY: 0, angleZ: 0))
            let ang = -rate * deg / 200
            up = [up[0],
                  up[1]*cos(ang) - up[2]*sin(ang),
                  up[1]*sin(ang) + up[2]*cos(ang)]
        }
        let m = StrokeAnalyzer.analyze(r)
        Check.equal(m.count, 2, "strokes")
        Check.isTrue(m[0].stopUp == nil, "the first half should report no stopping point")
        Check.isTrue(m[1].stopUp != nil, "but the second one does settle afterwards")
    }

    test("a slow moment that isn't a still one is not a stopping point") {
        // Rotation stops but the hand keeps accelerating, which is what the
        // continuous false-cast sessions do: none of sam-falsecast's 20 strokes
        // has a still moment, and the acceleration where they slow runs
        // 0.2-0.6 g off gravity. That is not gravity and must not be read as it.
        var r = stroke(peakDPS: 400, duration: 0.5, restAfter: 1.0, turning: true)
        // From just before the rod slows, so the whole of the moment the stop
        // would be read from is contaminated — as it is when a caster drifts.
        for i in r.indices where r[i].timestamp.timeIntervalSince(r[0].timestamp) > 0.9 {
            r[i] = SensorReading(timestamp: r[i].timestamp,
                                 accX: r[i].accX, accY: r[i].accY + 0.4, accZ: r[i].accZ,
                                 gyroX: r[i].gyroX, gyroY: r[i].gyroY, gyroZ: r[i].gyroZ,
                                 angleX: 0, angleY: 0, angleZ: 0)
        }
        guard let m = StrokeAnalyzer.analyze(r).first else {
            Check.isTrue(false, "no stroke"); return
        }
        Check.isTrue(m.stopUp == nil, "0.4 g of hand movement is not gravity")
    }

    test("strokes that stop in the same place read as repeatable") {
        // Out and back, three times over, each returning to level. Every stroke
        // in a direction ends where the others in that direction did.
        var r = [SensorReading]()
        var at = 0.0
        for _ in 0..<3 {
            r += stroke(peakDPS: 300, duration: 0.4, at: at,
                        restBefore: 0.0, restAfter: 0.6, turning: true)
            at += 1.0
            r += stroke(peakDPS: -300, duration: 0.4, at: at,
                        restBefore: 0.0, restAfter: 0.6, turning: true)
            at += 1.0
        }
        let m = StrokeAnalyzer.analyze(r)
        Check.equal(m.count, 6, "strokes")
        let rep = SessionStats.repeatability(m)
        Check.equal(rep.stops.count, 2, "one group each way")
        for s in rep.stops {
            Check.isTrue(s.sdDeg < 1.0, "\(s.name) should be tight: \(s.sdDeg)°")
        }
        guard let plane = Check.notNil(rep.plane, "plane spread") else { return }
        Check.isTrue(plane.sdDeg < 1.0, "one axis throughout is one plane: \(plane.sdDeg)°")
    }

    test("a stroke out of the casting plane is what the plane spread reports") {
        // Five strokes about X and one about Y. The odd one is 90° off, and it
        // is the one that has to be named.
        var r = [SensorReading]()
        var at = 0.0
        for k in 0..<6 {
            r += stroke(peakDPS: 300, duration: 0.4, axis: k == 3 ? 1 : 0,
                        at: at, restBefore: 0.0, restAfter: 0.6, turning: true)
            at += 1.0
        }
        let m = StrokeAnalyzer.analyze(r)
        Check.equal(m.count, 6, "strokes")
        guard let plane = Check.notNil(SessionStats.planeSpread(m), "plane spread") else { return }
        Check.equal(plane.worstStroke, 4, "stroke #4 is the one off the plane")
        // Not the full 90°: the mean axis is the strokes' own average, and the
        // odd one pulls it a little of the way towards itself. That is honest —
        // the session's plane really is the one its strokes describe.
        Check.isTrue(plane.maxDeg > 70, "and it is most of a right angle off: \(plane.maxDeg)")
    }

    test("the casting frame separates the two directions") {
        let r = concat([stroke(peakDPS: 400, duration: 0.4, restAfter: 0.6),
                        stroke(peakDPS: -400, duration: 0.4, at: 1.0, restBefore: 0.0,
                               restAfter: 0.6),
                        stroke(peakDPS: 400, duration: 0.4, at: 2.0, restBefore: 0.0)])
        let m = StrokeAnalyzer.analyze(r)
        Check.equal(m.count, 3, "strokes")
        guard let frame = Check.notNil(SessionStats.castingFrame(m), "casting frame") else { return }
        // Which way is which is not in the data — PLAN.md Stage 2 is open on
        // the sign anchor — so what is asserted is that the two are told apart.
        Check.isTrue(frame.signs[0] != frame.signs[1] && frame.signs[1] != frame.signs[2],
                     "back and forward should alternate: \(frame.signs)")
    }

    test("a plane spread is blind to which way the stroke went") {
        // A back cast and the forward cast after it turn about the same line in
        // opposite senses. Their rotation vectors are 180° apart and they are
        // in the same plane, so the spread must read zero, not 180.
        let r = concat([stroke(peakDPS: 400, duration: 0.4, restAfter: 0.6),
                        stroke(peakDPS: -400, duration: 0.4, at: 1.0, restBefore: 0.0)])
        let m = StrokeAnalyzer.analyze(r)
        Check.equal(m.count, 2, "strokes")
        guard let plane = Check.notNil(SessionStats.planeSpread(m), "plane spread") else { return }
        Check.close(plane.sdDeg, 0, 1.0, "opposite directions, one plane")
    }

    test("identical rate curves agree, and a different one does not") {
        let same = concat([stroke(peakDPS: 400, duration: 0.4, restAfter: 0.6),
                           stroke(peakDPS: 700, duration: 0.4, at: 1.0, restBefore: 0.0)])
        let m = StrokeAnalyzer.analyze(same)
        Check.equal(m.count, 2, "strokes")
        guard let a = Check.notNil(SessionStats.profileAgreement(m, name: "d"), "agreement")
        else { return }
        // Same bell, different size: shape is what is being compared, so
        // dividing out the peak has to make these the same stroke.
        // Not quite 100: the detector opens and closes on a rate threshold, so
        // the faster stroke keeps a little more of the bell's tails and the two
        // spans aren't the same slice of the same curve.
        Check.isTrue(a.agreementPct > 95,
                     "same shape at two sizes should agree: \(a.agreementPct)%")

        // A ramp that peaks at the very end is a different shape entirely.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var ramp = [SensorReading]()
        for i in 0..<Int(1.0 * 200) {
            let t = Double(i) / 200
            let rate = t >= 0.5 ? 600 * ((t - 0.5) / 0.5) : 0
            ramp.append(SensorReading(timestamp: base.addingTimeInterval(t),
                                      accX: 0, accY: 0, accZ: 1,
                                      gyroX: rate, gyroY: 0, gyroZ: 0,
                                      angleX: 0, angleY: 0, angleZ: 0))
        }
        let mixed = StrokeAnalyzer.analyze(same) + StrokeAnalyzer.analyze(ramp)
        guard let b = Check.notNil(SessionStats.profileAgreement(mixed, name: "d"), "agreement")
        else { return }
        Check.isTrue(b.agreementPct < a.agreementPct - 10,
                     "a ramp among bells should pull agreement down: \(b.agreementPct)%")
    }

    test("small strokes are set aside before repeatability is measured") {
        // A lift among casts. It travels in its own plane, and counting it
        // reads as a caster whose plane wanders — PLAN.md §6's relative rule
        // is what keeps it out.
        var r = [SensorReading]()
        var at = 0.0
        for _ in 0..<5 {
            r += stroke(peakDPS: 400, duration: 0.4, at: at, restBefore: 0.0, restAfter: 0.6)
            at += 1.0
        }
        r += stroke(peakDPS: 90, duration: 0.35, axis: 1, at: at, restBefore: 0.0)
        let m = StrokeAnalyzer.analyze(r)
        Check.equal(m.count, 6, "strokes")
        Check.equal(SessionStats.casts(m).count, 5, "the small one is not a cast")
        Check.equal(SessionStats.repeatability(m).setAside, 1, "and is reported as set aside")
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
