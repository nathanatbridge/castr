import Foundation
import CastrCore

private func sample(acc: (Double, Double, Double) = (0, 0, 1),
                    gyro: (Double, Double, Double) = (0, 0, 0)) -> SensorReading {
    SensorReading(timestamp: t0,
                  accX: acc.0, accY: acc.1, accZ: acc.2,
                  gyroX: gyro.0, gyroY: gyro.1, gyroZ: gyro.2,
                  angleX: 0, angleY: 0, angleZ: 0)
}

func runSaturationTests() {
    print("Saturation")

    test("a normal cast does not flag") {
        var s = SaturationCounter()
        s.observe([sample(acc: (2, 1, 3), gyro: (400, 200, 100)),
                   sample(acc: (0, 0, 1))])
        Check.isFalse(s.didClip, "should not clip")
        Check.isFalse(s.isNearLimit, "should not be near limit")
        Check.equal(s.total, 2, "total")
    }

    test("acceleration pinned at full scale is caught") {
        var s = SaturationCounter()
        // What the sensor actually emits when it saturates: int16 max maps to
        // exactly +16 g.
        s.observe([sample(acc: (16.0, 0, 1)), sample(acc: (0, 0, 1))])
        Check.isTrue(s.didClip, "should clip")
        Check.equal(s.accClipped, 1, "acc clipped")
        Check.equal(s.gyroClipped, 0, "gyro clipped")
        Check.close(s.accClippedPercent, 50.0, 0.01, "percent")
    }

    test("rotation pinned at full scale is caught") {
        var s = SaturationCounter()
        s.observe([sample(gyro: (0, -2000.0, 0))])
        Check.isTrue(s.didClip, "should clip")
        Check.equal(s.gyroClipped, 1, "gyro clipped")
    }

    test("peaks are tracked") {
        var s = SaturationCounter()
        s.observe([sample(acc: (3, 4, 0), gyro: (300, 400, 0)),
                   sample(acc: (0, 0, 1))])
        Check.close(s.peakAccMagnitude, 5.0, 1e-9, "peak |acc|")
        Check.close(s.peakGyroMagnitude, 500.0, 1e-9, "peak |gyro|")
    }

    test("approaching the limit warns before it clips") {
        var s = SaturationCounter()
        // 85% of the 2000 °/s range: nothing lost yet, but a harder swing would.
        s.observe([sample(gyro: (1700, 0, 0))])
        Check.isFalse(s.didClip, "should not have clipped")
        Check.isTrue(s.isNearLimit, "should warn about headroom")
    }

    test("an empty session reports nothing") {
        let s = SaturationCounter()
        Check.equal(s.total, 0, "total")
        Check.isFalse(s.didClip, "no clipping")
        Check.close(s.accClippedPercent, 0, 1e-9, "percent with no samples")
    }
}
