import Foundation
import CastrCore

/// Builds a still-sensor sample stream whose gravity magnitude is `magnitude`,
/// tilted so the reading isn't trivially axis-aligned.
private func restingSamples(magnitude: Double,
                            gyro: Double = 0.0,
                            count: Int = 400,
                            rateHz: Double = 200) -> [SensorReading] {
    // A unit vector at a plausible resting tilt, then scaled.
    let ux = 0.2, uy = -0.3
    let uz = (1.0 - ux * ux - uy * uy).squareRoot()
    return (0..<count).map { i in
        SensorReading(
            timestamp: t0.addingTimeInterval(Double(i) / rateHz),
            accX: ux * magnitude, accY: uy * magnitude, accZ: uz * magnitude,
            gyroX: gyro, gyroY: 0, gyroZ: 0,
            angleX: 0, angleY: 0, angleZ: 0)
    }
}

func runStaticCheckTests() {
    print("StaticCheck")

    test("a healthy resting sensor passes") {
        let r = StaticCheck.evaluate(restingSamples(magnitude: 1.0))
        guard let r else { Check.isTrue(false, "no result"); return }
        Check.equal(r.calibration, .pass, "calibration")
        Check.equal(r.stillness, .pass, "stillness")
        Check.equal(r.overall, .pass, "overall")
        Check.close(r.medianAccMagnitude, 1.0, 1e-9, "|acc|")
        Check.close(r.effectiveRateHz, 200.0, 1.0, "rate")
    }

    test("the February oven reading fails") {
        // The exact median measured across 794 static rows of Oven Test WM.xlsx.
        let r = StaticCheck.evaluate(restingSamples(magnitude: 1.756))
        guard let r else { Check.isTrue(false, "no result"); return }
        Check.equal(r.calibration, .fail, "calibration")
        Check.equal(r.overall, .fail, "overall")
        Check.close(r.calibrationErrorPercent, 75.6, 0.1, "error %")
    }

    test("the May oven reading passes") {
        // Median across 5149 static rows of the 256hz session.
        let r = StaticCheck.evaluate(restingSamples(magnitude: 1.025))
        guard let r else { Check.isTrue(false, "no result"); return }
        Check.equal(r.calibration, .pass, "calibration")
        Check.equal(r.overall, .pass, "overall")
    }

    test("a borderline reading warns rather than failing") {
        let r = StaticCheck.evaluate(restingSamples(magnitude: 1.06))
        guard let r else { Check.isTrue(false, "no result"); return }
        Check.equal(r.calibration, .warn, "calibration")
        Check.equal(r.overall, .warn, "overall")
    }

    test("a moving sensor is reported as moving, not miscalibrated") {
        // Gravity looks fine but the sensor was being handled — the 1 g
        // assumption doesn't hold, so the result must not be read as a pass.
        let r = StaticCheck.evaluate(restingSamples(magnitude: 1.0, gyro: 45.0))
        guard let r else { Check.isTrue(false, "no result"); return }
        Check.equal(r.stillness, .fail, "stillness")
        Check.equal(r.overall, .fail, "overall")
    }

    test("rejected frames downgrade an otherwise clean pass") {
        let r = StaticCheck.evaluate(restingSamples(magnitude: 1.0), rejectedFrames: 3)
        guard let r else { Check.isTrue(false, "no result"); return }
        Check.equal(r.calibration, .pass, "calibration")
        Check.equal(r.overall, .warn, "overall should warn on framing errors")
    }

    test("too few samples yields no verdict") {
        Check.isTrue(StaticCheck.evaluate([]) == nil, "empty should be nil")
        Check.isTrue(StaticCheck.evaluate(restingSamples(magnitude: 1.0, count: 1)) == nil,
                     "single sample should be nil")
    }
}
