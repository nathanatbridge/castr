import Foundation
import CastrCore

/// Rodrigues rotation of `v` about unit axis `k` by `deg`.
private func rotated(_ v: [Double], about k: [Double], deg: Double) -> [Double] {
    let t = deg * .pi / 180, c = cos(t), s = sin(t)
    let dot = k[0]*v[0] + k[1]*v[1] + k[2]*v[2]
    let cx = [k[1]*v[2] - k[2]*v[1], k[2]*v[0] - k[0]*v[2], k[0]*v[1] - k[1]*v[0]]
    return (0..<3).map { v[$0]*c + cx[$0]*s + k[$0]*dot*(1 - c) }
}

private func unit(_ v: [Double]) -> [Double] {
    let n = (v[0]*v[0] + v[1]*v[1] + v[2]*v[2]).squareRoot()
    return v.map { $0 / n }
}

private func angleBetweenDeg(_ a: [Double], _ b: [Double]) -> Double {
    let ua = unit(a), ub = unit(b)
    let dot = ua[0]*ub[0] + ua[1]*ub[1] + ua[2]*ub[2]
    return acos(Swift.min(1, Swift.max(-1, dot))) * 180 / .pi
}

/// Some direction perpendicular to `k`.
private func perpendicular(to k: [Double]) -> [Double] {
    let seed: [Double] = abs(k[0]) < 0.9 ? [1, 0, 0] : [0, 1, 0]
    return unit([k[1]*seed[2] - k[2]*seed[1],
                 k[2]*seed[0] - k[0]*seed[2],
                 k[0]*seed[1] - k[1]*seed[0]])
}

func runMountCalibrationTests() {
    print("MountCalibration — rod axis")

    // A mount that is not axis-aligned, so nothing passes by accident.
    let trueAxis = unit([0.31, -0.36, -0.88])
    // What a level hold reads: the sensor's up direction, square to the rod.
    let levelUp = perpendicular(to: trueAxis)
    // Tilting a hold about this swings it within the plane containing both.
    let tiltAxis = unit([trueAxis[1]*levelUp[2] - trueAxis[2]*levelUp[1],
                         trueAxis[2]*levelUp[0] - trueAxis[0]*levelUp[2],
                         trueAxis[0]*levelUp[1] - trueAxis[1]*levelUp[0]])

    test("two clean vertical holds recover the axis with a zero error bar") {
        let o = MountCalibration.rodAxis(vertical: [trueAxis, trueAxis], level: [levelUp])
        guard let a = Check.notNil(o.axis, "axis") else { return }
        Check.close(angleBetweenDeg(a.axis, trueAxis), 0, 0.01, "axis error")
        Check.close(a.errorDeg ?? -1, 0, 0.01, "error bar")
    }

    test("the axis is the mean of the two holds, and the error bar is half their gap") {
        // The caster is 3° off one way and 3° the other. The mean is the truth
        // and the error bar says 3° — which is the point of repeating the pose.
        let a1 = rotated(trueAxis, about: tiltAxis, deg: 3)
        let a2 = rotated(trueAxis, about: tiltAxis, deg: -3)
        let o = MountCalibration.rodAxis(vertical: [a1, a2], level: [levelUp])
        guard let a = Check.notNil(o.axis, "axis") else { return }
        Check.close(angleBetweenDeg(a.axis, trueAxis), 0, 0.01, "the mean is the truth")
        Check.close(a.errorDeg ?? -1, 3, 0.01, "error bar is half the disagreement")
    }

    test("a consistent lean is invisible, and that is stated not hidden") {
        // Both holds leaning the same way agree perfectly and are both wrong.
        // No pose fixes this; it is why the error bar is a floor, not a bound.
        let a1 = rotated(trueAxis, about: tiltAxis, deg: 4)
        let o = MountCalibration.rodAxis(vertical: [a1, a1], level: [levelUp])
        guard let a = Check.notNil(o.axis, "axis") else { return }
        Check.close(a.errorDeg ?? -1, 0, 0.01, "the error bar cannot see it")
        Check.close(angleBetweenDeg(a.axis, trueAxis), 4, 0.01, "but the axis is off by the lean")
    }

    test("the axis points butt to tip, not the other way") {
        let o = MountCalibration.rodAxis(vertical: [trueAxis, trueAxis], level: [levelUp])
        guard let a = Check.notNil(o.axis, "axis") else { return }
        let towardSky = a.axis[0]*trueAxis[0] + a.axis[1]*trueAxis[1] + a.axis[2]*trueAxis[2]
        Check.isTrue(towardSky > 0, "axis should agree with the tip-at-sky holds")
    }

    test("several mount orientations all recover their own axis") {
        for v in [[1.0, 0, 0], [0, 1.0, 0], [0, 0, 1.0], [0.5, 0.5, 0.7], [-0.2, 0.9, -0.3]] {
            let u = unit(v)
            let o = MountCalibration.rodAxis(vertical: [u, u], level: [perpendicular(to: u)])
            guard let a = o.axis else {
                Check.isTrue(false, "refused for axis \(v)")
                continue
            }
            Check.close(angleBetweenDeg(a.axis, u), 0, 0.01, "axis error for \(v)")
        }
    }

    test("clocking the housing about the blank leaves the axis alone") {
        // The claim that lets the tip projection ship before TRIAD: rotating
        // the housing about the rod maps the rod axis to itself.
        let o = MountCalibration.rodAxis(vertical: [trueAxis, trueAxis],
                                         level: [rotated(levelUp, about: trueAxis, deg: 40)])
        guard let a = Check.notNil(o.axis, "axis") else { return }
        Check.close(angleBetweenDeg(a.axis, trueAxis), 0, 0.01, "axis under clocking")
        Check.close(a.levelCheckDeg ?? -1, 0, 0.01, "clocking is not mistaken for error")
    }

    test("a level hold out of level is reported, not refused") {
        // The whole reason this was rewritten. A sloppy *check* pose must not
        // cost a good axis — 22-07-29 failed exactly that way.
        let o = MountCalibration.rodAxis(vertical: [trueAxis, trueAxis],
                                         level: [rotated(levelUp, about: tiltAxis, deg: 13)])
        guard let a = Check.notNil(o.axis, "a 13° level hold must not refuse") else { return }
        Check.close(angleBetweenDeg(a.axis, trueAxis), 0, 0.01, "the axis is untouched")
        Check.close(a.levelCheckDeg ?? -1, 13, 0.01, "and the smell is reported")
    }

    test("vertical holds too far apart are refused, with the figure") {
        let a1 = rotated(trueAxis, about: tiltAxis, deg: 13)
        let a2 = rotated(trueAxis, about: tiltAxis, deg: -13)
        let o = MountCalibration.rodAxis(vertical: [a1, a2], level: [levelUp])
        Check.isTrue(o.axis == nil, "26° apart should be refused")
        guard case .refused(let why) = o,
              case .verticalsDisagree(let d) = why else {
            Check.isTrue(false, "expected verticalsDisagree")
            return
        }
        Check.close(d, 26, 0.01, "the refusal reports the measured spread")
        Check.isTrue(why.reason.contains("26.0"), "reason text carries the number")
    }

    test("one vertical hold is accepted, with no error bar rather than a fake one") {
        let o = MountCalibration.rodAxis(vertical: [trueAxis], level: [levelUp])
        guard let a = Check.notNil(o.axis, "axis") else { return }
        Check.isTrue(a.errorDeg == nil, "one measurement has no error bar")
        Check.isTrue(a.tipUncertaintyCm(tipDistanceM: 2.54) == nil, "and no tip figure")
    }

    test("the four captures of 2026-08-11 would all now yield an axis") {
        // Real vectors off calibration/2026-08-11_*.json. Under the old level-hold
        // gate two of these were refused; the axis was never the problem.
        let verticals = [[0.022, 0.992, 0.166], [0.038, 0.976, 0.251],
                         [0.029, 0.999, 0.092], [-0.035, 0.991, 0.179]]
        for v in verticals {
            let o = MountCalibration.rodAxis(vertical: [v], level: [])
            Check.isTrue(o.axis != nil, "capture \(v) should give an axis")
        }
        // And taken as repeats of one pose, the worst pair is inside tolerance.
        let o = MountCalibration.rodAxis(vertical: [verticals[1], verticals[2]], level: [])
        guard let a = Check.notNil(o.axis, "worst real pair") else { return }
        Check.close(a.errorDeg ?? -1, 4.59, 0.05, "half of the 9.18° they actually differed by")
    }

    test("level holds that disagree are reported as a rolled grip") {
        let rolled = rotated(levelUp, about: trueAxis, deg: 15)
        let o = MountCalibration.rodAxis(vertical: [trueAxis, trueAxis],
                                         level: [levelUp, rolled])
        guard let a = Check.notNil(o.axis, "axis") else { return }
        Check.close(a.levelSpreadDeg ?? -1, 15, 0.01, "the roll is measured")
        Check.close(a.errorDeg ?? -1, 0, 0.01, "and does not corrupt the axis")
    }

    test("no vertical hold means no axis") {
        let o = MountCalibration.rodAxis(vertical: [], level: [levelUp])
        Check.isTrue(o.axis == nil, "should refuse")
        guard case .refused(let why) = o else {
            Check.isTrue(false, "expected a refusal")
            return
        }
        Check.equal(why, .noVerticalHold, "reason")
    }

    test("a degenerate hold yields no axis") {
        Check.isTrue(MountCalibration.rodAxis(vertical: [[0, 0, 0]], level: [levelUp]).axis == nil,
                     "zero vertical")
        Check.isTrue(MountCalibration.rodAxis(vertical: [trueAxis], level: [[0, 0, 0]]).axis == nil,
                     "zero level")
        Check.isTrue(MountCalibration.rodAxis(vertical: [[1, 0]], level: [levelUp]).axis == nil,
                     "wrong length")
    }

    test("scale is ignored — only direction is read") {
        let o = MountCalibration.rodAxis(vertical: [trueAxis.map { $0 * 1.03 },
                                                    trueAxis.map { $0 * 0.97 }],
                                         level: [levelUp.map { $0 * 0.98 }])
        guard let a = Check.notNil(o.axis, "axis") else { return }
        Check.close(angleBetweenDeg(a.axis, trueAxis), 0, 0.01, "axis error")
        let mag = (a.axis[0]*a.axis[0] + a.axis[1]*a.axis[1] + a.axis[2]*a.axis[2]).squareRoot()
        Check.close(mag, 1.0, 1e-12, "the result is a unit vector")
    }

    test("uncertainty converts to a distance at the tip") {
        let a1 = rotated(trueAxis, about: tiltAxis, deg: 5)
        let a2 = rotated(trueAxis, about: tiltAxis, deg: -5)
        guard let a = Check.notNil(MountCalibration.rodAxis(vertical: [a1, a2],
                                                            level: [levelUp]).axis,
                                   "axis") else { return }
        // 5° on a 9 ft rod with the sensor 8 in up the handle.
        Check.close(a.tipUncertaintyCm(tipDistanceM: 2.54) ?? -1, 22.2, 0.1, "tip uncertainty")
        Check.close(a.tipUncertaintyCm(tipDistanceM: 0.22) ?? -1, 1.9, 0.1, "at the sensor")
    }
}
