import Foundation

/// The rod's own axes in the sensor's frame, recovered from the poses
/// `cast calibrate` records.
///
/// Two jobs belong here and only the first is implemented.
///
/// **The rod axis** — which way the blank points in the sensor's own frame.
/// One pose gives it outright: stand the blank vertical and gravity runs along
/// it, so the accelerometer reads the axis directly.
///
/// **Clocking** — how far the housing is rotated about the blank. Not here
/// yet. It needs a level hold, the only pose with gravity across the rod rather
/// than along it, and a TRIAD solve on the pair. CALIBRATION.md §5.1 is why it
/// is observable at all.
///
/// The rod tip projection needs only the axis: rotation about the blank does
/// not move the tip. So it ships without waiting for clocking — ROD-TIP.md §2.3.
///
/// ## Two vertical holds, and why the error bar is not a different pose
///
/// This has been wrong twice, and both corrections came from real captures.
///
/// **First it asked for a tip-down hold** to sit opposite the tip-up one. A 9 ft
/// rod cannot be pointed at the ground — with the grip at hip height the tip
/// would be a metre and a half underground — so a caster asked for it holds the
/// rod near horizontal instead. Three captures on 2026-08-11 show it plainly:
/// the "down" hold came back 10-14° from the *forward* hold rather than 180°
/// from the up hold, every time.
///
/// **Then it checked the axis against a level hold**, on the reasoning that a
/// level rod must read square to its own axis. True, but that check cannot tell
/// a tilted axis from a tilted level hold — it measures the two together. The
/// 22-07-29 capture failed on a side hold 12.9° out of level while its forward
/// hold said the very same axis was good to 2.5°. A check that rejects a good
/// measurement because a *different* pose was sloppy is not an error bar.
///
/// So the axis is measured **twice with the same pose**, at the two ends of the
/// sequence, and the disagreement between them is the error bar. That number
/// measures what it claims to. Pointing a rod at the sky is also the easiest
/// pose to repeat accurately — you can see the blank against the sky — and
/// across four separate captures that night it repeated to 3-9°, which is
/// already 10-20 cm at the tip and good enough to draw.
///
/// The level hold stays for the clocking, and its squareness is reported as a
/// sanity figure. It does not gate anything, because it cannot separate its own
/// tilt from the axis it is checking.
public struct MountCalibration {

    /// Accelerometer sign convention, because getting it backwards silently
    /// points the rod at the ground: a resting sensor reads +1 g along whichever
    /// of its axes points *up*, opposite gravity. So the tip-at-sky hold — blank
    /// vertical, tip above the hand — measures a vector along tip-ward.
    /// `reconstruct.js` makes the same assumption when it aligns the measured
    /// vector to world +Z.
    public struct RodAxis: Equatable {
        /// Unit vector in the sensor's body frame, pointing butt → tip.
        public let axis: [Double]
        /// Half the disagreement between the vertical holds: the axis is their
        /// mean, so each sits this far from it. **This is the error bar.** It is
        /// nil when only one vertical hold was captured, which is honest — one
        /// measurement of anything has no error bar.
        public let errorDeg: Double?
        /// Worst departure from 90° across the level holds. Reported, never
        /// gated on: a level rod is square to its own axis, but this figure
        /// cannot separate a tilted axis from a tilted level hold, so it is a
        /// smell rather than a measurement. nil when no level hold was given.
        public let levelCheckDeg: Double?
        /// How far apart the level holds pointed. Near zero is expected:
        /// rotating a level rod about the vertical does not change what the
        /// sensor reads. A large value means the rod rolled in the hand, which
        /// is the one thing that would also move the clocking.
        public let levelSpreadDeg: Double?

        /// What the error bar is worth at the tip of a rod whose tip sits
        /// `tipDistanceM` from the sensor. This is the number that matters: an
        /// angle nobody would notice at the handle is centimetres out there.
        public func tipUncertaintyCm(tipDistanceM: Double) -> Double? {
            guard let e = errorDeg else { return nil }
            return e * .pi / 180 * tipDistanceM * 100
        }
    }

    public enum Refusal: Equatable {
        /// A hold vector had no length — an empty or all-zero pose window.
        case degenerate
        /// No vertical hold was supplied, so there is nothing to measure the
        /// axis from.
        case noVerticalHold
        /// The vertical holds disagree by more than a pose repeated twice
        /// should. Carries the measured figure, because that is the evidence.
        case verticalsDisagree(spreadDeg: Double)

        public var reason: String {
            switch self {
            case .degenerate:
                return "a hold vector has no length"
            case .noVerticalHold:
                return "no tip-at-sky hold to measure the axis from"
            case .verticalsDisagree(let d):
                return String(format: "the two tip-at-sky holds are %.1f° apart", d)
            }
        }
    }

    public enum Outcome: Equatable {
        case measured(RodAxis)
        case refused(Refusal)

        public var axis: RodAxis? {
            if case .measured(let a) = self { return a }
            return nil
        }
    }

    /// How far the two vertical holds may disagree before the capture is
    /// treated as not having been performed.
    ///
    /// This is deliberately loose. Across four separate captures on 2026-08-11
    /// the tip-at-sky hold repeated to between 3.4° and 9.2°, and those were
    /// separated by whole sessions — set the rod down, pick it up, re-grip.
    /// Two holds inside one 30-second sequence should do better. Past 20° one
    /// of them was not vertical, which is a different thing from being a few
    /// degrees off, and worth saying so rather than drawing it.
    public static let maxSpreadDeg = 20.0

    /// Above this, the level hold is called out. It is a warning and never a
    /// refusal: the figure conflates the level hold's own tilt with the axis,
    /// so it cannot be held against the axis on its own.
    public static let levelWarnDeg = 20.0

    /// Rod axis from the vertical holds, with the level holds as sanity only.
    ///
    /// `vertical` are the mean accelerometer readings over the tip-at-sky holds
    /// — two of them in the standard sequence, but one is accepted with the
    /// error bar reported as unknown. `level` are the readings over holds where
    /// the rod was horizontal. Scale is irrelevant; only direction is read.
    public static func rodAxis(vertical: [[Double]],
                               level: [[Double]],
                               maxSpreadDeg: Double = maxSpreadDeg) -> Outcome {
        var ups: [[Double]] = []
        for v in vertical {
            guard let u = normalised(v) else { return .refused(.degenerate) }
            ups.append(u)
        }
        guard !ups.isEmpty else { return .refused(.noVerticalHold) }

        // The disagreement between repeats of the same pose is the error bar,
        // and it is the only number here that measures the axis alone.
        var spread = 0.0
        for i in 0..<ups.count {
            for j in (i + 1)..<ups.count {
                spread = Swift.max(spread, angleDeg(ups[i], ups[j]))
            }
        }
        guard ups.count < 2 || spread <= maxSpreadDeg else {
            return .refused(.verticalsDisagree(spreadDeg: spread))
        }

        // Averaging unit vectors is the least-squares answer for a direction.
        var sum = [0.0, 0.0, 0.0]
        for u in ups { for k in 0..<3 { sum[k] += u[k] } }
        guard let axis = normalised(sum) else { return .refused(.degenerate) }

        var levels: [[Double]] = []
        for v in level {
            guard let u = normalised(v) else { return .refused(.degenerate) }
            levels.append(u)
        }

        var levelCheck = 0.0
        for u in levels { levelCheck = Swift.max(levelCheck, abs(90 - angleDeg(axis, u))) }

        var levelSpread = 0.0
        for i in 0..<levels.count {
            for j in (i + 1)..<levels.count {
                levelSpread = Swift.max(levelSpread, angleDeg(levels[i], levels[j]))
            }
        }

        return .measured(RodAxis(axis: axis,
                                 errorDeg: ups.count >= 2 ? spread / 2 : nil,
                                 levelCheckDeg: levels.isEmpty ? nil : levelCheck,
                                 levelSpreadDeg: levels.count >= 2 ? levelSpread : nil))
    }

    // MARK: - vector helpers

    private static func normalised(_ v: [Double]) -> [Double]? {
        guard v.count == 3 else { return nil }
        let n = (v[0]*v[0] + v[1]*v[1] + v[2]*v[2]).squareRoot()
        guard n > 1e-12, n.isFinite else { return nil }
        return v.map { $0 / n }
    }

    /// Angle between two unit vectors. Clamped because a dot product of two
    /// normalised vectors can land a hair outside [-1, 1] in floating point,
    /// and `acos` returns NaN there rather than 0.
    private static func angleDeg(_ a: [Double], _ b: [Double]) -> Double {
        let dot = a[0]*b[0] + a[1]*b[1] + a[2]*b[2]
        return acos(Swift.min(1, Swift.max(-1, dot))) * 180 / .pi
    }
}
