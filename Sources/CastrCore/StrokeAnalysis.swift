import Foundation

// MARK: - Detection

/// Splits a session into individual strokes.
///
/// Segmentation runs on rotation rate rather than acceleration. A cast is
/// fundamentally a rotation of the rod, and the handle's linear acceleration is
/// dominated by gravity's changing direction as the rod tilts — so an
/// acceleration threshold fires on slow re-positioning that isn't a stroke at all.
///
/// Uses hysteresis: a stroke opens at `enterDPS` and doesn't close until rate has
/// stayed below `exitDPS` for `settleTime`. A single threshold chatters through
/// the noisy tail of a stroke and splits one cast into several.
///
/// Rate alone is not enough to end a stroke. At real casting tempo the rod never
/// stops between a back cast and the forward cast that follows: measured across
/// the corpus, the trough between the two stays below 25 °/s for at most 0.13 s
/// and usually 0.00–0.08 s, so `settleTime` is never satisfied and the pair is
/// reported as one stroke whose opposing rotations cancel. `fish1` #22 is the
/// clearest case — +307 °/s one way, then −383 °/s back, netting an arc of 18.9°
/// off a path of 242°. Direction, not rate, is what separates them, so
/// `splitAtReversals` runs before the duration guard.
public struct StrokeDetector {

    public var enterDPS: Double = 60
    public var exitDPS: Double = 25
    /// Rate must stay below `exitDPS` this long before a stroke is considered over.
    public var settleTime: TimeInterval = 0.12
    /// Strokes shorter than this are twitches, not casts.
    public var minDuration: TimeInterval = 0.08
    /// Strokes separated by less than this are merged.
    public var mergeGap: TimeInterval = 0.10
    /// No casting stroke lasts this long. Spans exceeding it are continuous
    /// movement that never fully settled — several motions run together — and
    /// get split at their quietest interior moment rather than reported as one.
    public var maxDuration: TimeInterval = 3.0
    /// Two bursts of rotation whose net directions are at least this far apart
    /// are opposing strokes, not one stroke. Across the corpus this measure is
    /// sharply bimodal: 62 of 68 burst pairs inside a merged span sat at
    /// 150–180°, the rest at 86° or below, so anything in the middle is absent.
    public var reversalAngleDeg: Double = 120
    /// A burst carrying less of the span's rotation than this share of its
    /// largest burst is a wobble inside one stroke, not a stroke of its own.
    /// Relative, not absolute, because §4c of PLAN.md showed no constant arc
    /// threshold survives: `benchtest2` casts ranged 67–152° with no line at
    /// all. The ripples measured 17–21° against 76–129° mains — 0.17–0.27 of
    /// the largest — while genuine pairs sit at 0.8–1.0.
    public var minBurstShare: Double = 0.4

    public init() {}

    public func detect(_ r: [SensorReading]) -> [Range<Int>] {
        guard r.count > 2 else { return [] }
        let rate = r.map(Self.rateMagnitude)

        var spans: [Range<Int>] = []
        var start: Int? = nil
        var quietSince: Int? = nil

        for i in 0..<r.count {
            if rate[i] >= enterDPS {
                if start == nil { start = i }
                quietSince = nil
            } else if let s = start, rate[i] < exitDPS {
                if quietSince == nil { quietSince = i }
                let elapsed = r[i].timestamp.timeIntervalSince(r[quietSince!].timestamp)
                if elapsed >= settleTime {
                    spans.append(s..<quietSince!)
                    start = nil
                    quietSince = nil
                }
            } else {
                quietSince = nil
            }
        }
        if let s = start { spans.append(s..<r.count) }

        // merge, then drop the short ones
        var merged: [Range<Int>] = []
        for span in spans {
            if let last = merged.last,
               r[span.lowerBound].timestamp.timeIntervalSince(r[last.upperBound - 1].timestamp) < mergeGap {
                merged[merged.count - 1] = last.lowerBound..<span.upperBound
            } else {
                merged.append(span)
            }
        }
        let split = merged
            .flatMap { splitAtReversals($0, r, rate) }
            .flatMap { splitIfTooLong($0, r, rate, depth: 0) }
        return split.filter { span in
            r[span.upperBound - 1].timestamp.timeIntervalSince(r[span.lowerBound].timestamp) >= minDuration
        }
    }

    /// Splits a span wherever the rod turned around.
    ///
    /// A back cast and the forward cast after it are the same movement in
    /// opposite directions, so their net rotation vectors point ~180° apart.
    /// Bursts of rotation within the span are compared pairwise and the span is
    /// cut between any two that oppose, at the quietest sample between them.
    private func splitAtReversals(_ span: Range<Int>,
                                  _ r: [SensorReading],
                                  _ rate: [Double]) -> [Range<Int>] {
        // Bursts: contiguous runs at or above the rate that opens a stroke.
        var bursts: [Range<Int>] = []
        var open: Int? = nil
        for i in span {
            if rate[i] >= enterDPS {
                if open == nil { open = i }
            } else if let s = open {
                bursts.append(s..<i)
                open = nil
            }
        }
        if let s = open { bursts.append(s..<span.upperBound) }
        guard bursts.count > 1 else { return [span] }

        let nets = bursts.map { Self.netRotation(r, $0) }
        guard let largest = nets.map(Self.magnitude).max(), largest > 0 else { return [span] }
        let kept = zip(bursts, nets).filter { Self.magnitude($0.1) >= minBurstShare * largest }
        guard kept.count > 1 else { return [span] }

        var cuts: [Int] = []
        for k in 1..<kept.count {
            guard Self.angleBetween(kept[k - 1].1, kept[k].1) >= reversalAngleDeg else { continue }
            let between = kept[k - 1].0.upperBound..<kept[k].0.lowerBound
            guard let quietest = between.min(by: { rate[$0] < rate[$1] }) else { continue }
            cuts.append(quietest)
        }
        guard !cuts.isEmpty else { return [span] }

        var out: [Range<Int>] = []
        var lower = span.lowerBound
        for cut in cuts {
            out.append(lower..<cut)
            lower = cut
        }
        out.append(lower..<span.upperBound)
        return out
    }

    /// Rotation integrated over a span, as a vector — the signed form of the
    /// arc that `StrokeAnalyzer` later collapses to a magnitude.
    static func netRotation(_ r: [SensorReading], _ span: Range<Int>) -> [Double] {
        var net = [0.0, 0.0, 0.0]
        for i in span where i + 1 < r.count {
            let dt = r[i + 1].timestamp.timeIntervalSince(r[i].timestamp)
            net[0] += r[i].gyroX * dt
            net[1] += r[i].gyroY * dt
            net[2] += r[i].gyroZ * dt
        }
        return net
    }

    static func magnitude(_ v: [Double]) -> Double {
        (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).squareRoot()
    }

    /// Angle between two rotation vectors, in degrees. Zero-length vectors have
    /// no direction, so they are reported as 0° — never a reversal.
    static func angleBetween(_ a: [Double], _ b: [Double]) -> Double {
        let ma = magnitude(a), mb = magnitude(b)
        guard ma > 0, mb > 0 else { return 0 }
        let cos = (a[0] * b[0] + a[1] * b[1] + a[2] * b[2]) / (ma * mb)
        return Foundation.acos(Swift.max(-1, Swift.min(1, cos))) * 180 / .pi
    }

    /// Recursively halves an over-long span at its quietest interior sample.
    private func splitIfTooLong(_ span: Range<Int>,
                                _ r: [SensorReading],
                                _ rate: [Double],
                                depth: Int) -> [Range<Int>] {
        let dur = r[span.upperBound - 1].timestamp.timeIntervalSince(r[span.lowerBound].timestamp)
        guard dur > maxDuration, depth < 6, span.count > 8 else { return [span] }

        // Keep the cut away from the ends so a slow start can't be shaved off
        // and counted as its own stroke.
        let margin = max(2, span.count / 8)
        let interior = (span.lowerBound + margin)..<(span.upperBound - margin)
        guard !interior.isEmpty,
              let cut = interior.min(by: { rate[$0] < rate[$1] })
        else { return [span] }

        return splitIfTooLong(span.lowerBound..<cut, r, rate, depth: depth + 1)
             + splitIfTooLong(cut..<span.upperBound, r, rate, depth: depth + 1)
    }

    static func rateMagnitude(_ r: SensorReading) -> Double {
        (r.gyroX * r.gyroX + r.gyroY * r.gyroY + r.gyroZ * r.gyroZ).squareRoot()
    }
}

// MARK: - Per-stroke metrics

public struct StrokeMetrics {
    public let index: Int
    /// Seconds from the start of the session.
    public let startTime: TimeInterval
    public let duration: TimeInterval
    public let sampleCount: Int

    /// Net rotation — how far the rod actually turned, end to end.
    public let arcDeg: Double
    /// The same rotation before it was collapsed to a magnitude, as X/Y/Z
    /// degrees. A back cast and a forward cast are one movement in opposite
    /// directions, so the sign is what tells them apart — `arcDeg` alone
    /// cannot. Kept because throwing it away is what hid the merged pairs.
    public let netRotationDeg: [Double]
    /// Total angular distance travelled, including any back-and-forth.
    public let pathDeg: Double
    /// Share of net rotation about the dominant axis. 100% is a perfect plane.
    public let planarityPct: Double
    public let dominantAxis: String

    /// Rotation about axes other than the stroke's own, in degrees — the part
    /// of the turning that did not happen in the stroke's plane.
    ///
    /// Unlike `planarityPct` this is measured against the stroke's own rotation
    /// axis rather than whichever sensor axis happens to be largest, so it does
    /// not change when the sensor is remounted. §8.1 of PLAN.md is the test
    /// that would prove that, and it has not been run yet.
    public let offPlaneDeg: Double
    /// Share of the turning that stayed in the stroke's plane. 100% is a stroke
    /// that never left it.
    public let inPlanePct: Double

    public let peakRateDPS: Double
    /// Where the peak falls within the stroke, 0–100%. Late peaks mean the rod
    /// is still accelerating deep into the stroke.
    public let peakRateAtPct: Double

    /// Start of stroke to peak rotation rate.
    public let accelPhase: TimeInterval
    /// Peak rotation rate to the stop.
    public let stopPhase: TimeInterval
    /// Sharpest acceleration before the peak — how hard the rod was driven, and
    /// the mirror of `peakDecelDPS2`. Loading the rod and unloading it are two
    /// separate things a caster does, so they are measured separately.
    public let peakAccelDPS2: Double
    /// Sharpest deceleration after the peak — the abruptness of the stop, which
    /// is what unloads a rod.
    public let peakDecelDPS2: Double
    /// Share of the drive — start of stroke to peak rate — spent still speeding
    /// up. 100% is one continuous build; a stall or a second shove pulls it down.
    public let driveSmoothPct: Double

    /// Rotation rate over the stroke, resampled to a fixed grid of normalised
    /// times and divided by this stroke's own peak. Size is already carried by
    /// `arcDeg`, `duration` and `peakRateDPS`, so what is left here is shape —
    /// which is what makes two strokes comparable curve against curve.
    public let rateProfile: [Double]

    public let peakAccG: Double

    /// Which way is up, in the sensor's frame, over the still moment at the end
    /// of the stroke — so, where the rod was pointing when it stopped.
    ///
    /// Read straight off the accelerometer: at the stop the rod is momentarily
    /// still and the accelerometer reads gravity, so attitude falls out with
    /// nothing integrated and nothing to drift. Nil when there was no genuine
    /// still moment to read it from — see `StrokeAnalyzer.stopUp`.
    public let stopUp: [Double]?
    /// How many samples the stopping point was averaged over. Zero when there
    /// is no stopping point.
    public let stopStillSamples: Int

    public var tempo: Double { duration > 0 ? arcDeg / duration : 0 }

    /// Fraction of the stroke spent stopping. A crisp stop is a small number.
    public var stopSharePct: Double { duration > 0 ? stopPhase / duration * 100 : 0 }
}

public enum StrokeAnalyzer {

    /// Points in the resampled rate profile. Sixteen is enough to separate a
    /// single smooth build from a stall or a double shove, which is all the
    /// shape comparison asks of it, and small enough that every stroke can
    /// carry its own curve into the JSON.
    public static let profilePoints = 16

    // MARK: Stopping point

    /// A stopping point is only read from a genuinely still moment.
    ///
    /// At casting tempo there often isn't one: a back cast is followed straight
    /// away by the forward cast, and PLAN.md Stage 1 records the elevation
    /// estimate coming back *inverted* on `cast2` #3→#5, whose gaps between
    /// strokes are 0.00 s. So stillness is required rather than assumed, and
    /// when it isn't there the stopping point is reported absent — the same
    /// discipline as the ten deliberately blank CSV columns.
    public static let stopStillMaxRateDPS = 25.0
    /// How far the acceleration may sit off 1 g and still be taken for gravity.
    public static let stopStillMaxAccDevG = 0.10
    /// How far past the stroke to look for that still moment.
    public static let stopStillSearchSeconds = 0.60
    /// How much of it to average over once it has arrived.
    public static let stopStillWindowSeconds = 0.40
    public static let stopStillMinSamples = 8
    /// Rate at which the search gives up because the rod is moving again.
    ///
    /// Without it the search can run past the next stroke and read that one's
    /// quiet as this one's stopping point — which is not a subtle error: on a
    /// back-to-back reversal it reports the far end of the *following* cast.
    /// Matches `StrokeDetector.enterDPS`, since a stroke starting is exactly
    /// the event that ends the quiet after the last one.
    public static let stopSearchAbortDPS = 60.0
    /// How far the rod may turn between the stop and the still moment before
    /// carrying the reading back is doing more work than it can be trusted with.
    ///
    /// The carry-back is short-baseline — a fraction of a second, integrated
    /// from a direct reading rather than from the start of the session — so its
    /// error is a small fraction of whatever rotation happened in the gap, not
    /// something that accumulates. This bounds that rotation, and so bounds the
    /// error, instead of leaving it open.
    public static let stopTransportMaxDeg = 90.0

    /// Rotate `v` by `angle` radians about unit axis `n` (Rodrigues).
    static func rotated(_ v: [Double], about n: [Double], by angle: Double) -> [Double] {
        let c = Foundation.cos(angle), s = Foundation.sin(angle)
        let cross = [n[1]*v[2] - n[2]*v[1], n[2]*v[0] - n[0]*v[2], n[0]*v[1] - n[1]*v[0]]
        let dot = n[0]*v[0] + n[1]*v[1] + n[2]*v[2]
        return (0..<3).map { v[$0]*c + cross[$0]*s + n[$0]*dot*(1 - c) }
    }

    /// Up, in the sensor's frame, at the moment the stroke stopped — or nil
    /// when there is nothing to read it from.
    ///
    /// Gravity is the reference, because it is the one direction a handle IMU
    /// knows without integrating anything. It can only be read while the rod is
    /// still, and the rod is not still at the stop — that is the instant it is
    /// being hauled to a halt. So the reading is taken from the still moment
    /// that follows and carried back to the stop across the gyro.
    ///
    /// Reading the still moment *as* the stopping point, without carrying it
    /// back, was measurably wrong: against the burst reconstruction's own
    /// attitude at the stop it sat a median 8° out across the corpus, with no
    /// trend in elapsed time — a real difference in *when*, not drift. The hand
    /// keeps moving after the rod has stopped, and 8° is larger than the
    /// stroke-to-stroke spread this figure exists to measure.
    public static func stopUp(_ r: [SensorReading],
                              span: Range<Int>,
                              stopIndex: Int) -> (up: [Double], samples: Int)? {
        guard span.upperBound <= r.count, span.upperBound > 0 else { return nil }
        let end = r[span.upperBound - 1].timestamp

        func still(_ i: Int) -> Bool {
            StrokeDetector.rateMagnitude(r[i]) < stopStillMaxRateDPS
                && abs(r[i].accMagnitude - 1) < stopStillMaxAccDevG
        }

        // The first still-looking sample is often a lone one — the rod is still
        // ringing down and the acceleration crosses the bound and comes back.
        // Giving up there threw away good windows a few samples later: on the
        // parity fixture it cost four of seven strokes their stopping point.
        // So a short run is skipped rather than treated as a refusal.
        var windowStart = -1
        var sum = [0.0, 0.0, 0.0], n = 0
        var i = span.upperBound
        while i < r.count, r[i].timestamp.timeIntervalSince(end) <= stopStillSearchSeconds {
            if StrokeDetector.rateMagnitude(r[i]) >= stopSearchAbortDPS { break }
            guard still(i) else { i += 1; continue }
            let from = i
            var acc = [0.0, 0.0, 0.0], count = 0
            var j = i
            while j < r.count,
                  r[j].timestamp.timeIntervalSince(r[from].timestamp) <= stopStillWindowSeconds,
                  still(j) {
                acc[0] += r[j].accX; acc[1] += r[j].accY; acc[2] += r[j].accZ
                count += 1
                j += 1
            }
            if count >= stopStillMinSamples {
                windowStart = from; sum = acc; n = count
                break
            }
            i = j + 1
        }
        guard n >= stopStillMinSamples else { return nil }

        let m = (sum[0]*sum[0] + sum[1]*sum[1] + sum[2]*sum[2]).squareRoot()
        guard m > 0 else { return nil }
        var up = [sum[0]/m, sum[1]/m, sum[2]/m]

        // Carry it back from the still window to the stop. A world-fixed vector
        // seen from a rotating body obeys dv/dt = −w × v, so stepping backwards
        // means turning it by +w dt at each sample.
        let deg = Double.pi / 180
        var turned = 0.0
        var j = windowStart - 1
        while j >= stopIndex {
            let dt = r[j + 1].timestamp.timeIntervalSince(r[j].timestamp)
            let w = [r[j].gyroX * deg, r[j].gyroY * deg, r[j].gyroZ * deg]
            let mag = (w[0]*w[0] + w[1]*w[1] + w[2]*w[2]).squareRoot()
            let ang = mag * dt
            if ang > 1e-12 {
                up = rotated(up, about: [w[0]/mag, w[1]/mag, w[2]/mag], by: ang)
                turned += ang / deg
            }
            j -= 1
        }
        guard turned <= stopTransportMaxDeg else { return nil }
        return (up, n)
    }

    public static func metrics(for readings: [SensorReading],
                               span: Range<Int>,
                               index: Int,
                               sessionStart: Date) -> StrokeMetrics? {
        guard span.count >= 3 else { return nil }
        let r = Array(readings[span])
        let n = r.count
        let t = r.map { $0.timestamp.timeIntervalSince(r[0].timestamp) }
        let duration = t[n - 1]
        guard duration > 0 else { return nil }

        let rate = r.map(StrokeDetector.rateMagnitude)

        // integrate rotation: net vector (arc) and scalar path length
        var net = [0.0, 0.0, 0.0]
        var path = 0.0
        for i in 0..<(n - 1) {
            let dt = t[i + 1] - t[i]
            net[0] += r[i].gyroX * dt
            net[1] += r[i].gyroY * dt
            net[2] += r[i].gyroZ * dt
            path += rate[i] * dt
        }
        let arc = (net[0] * net[0] + net[1] * net[1] + net[2] * net[2]).squareRoot()
        let dom = (0..<3).max(by: { abs(net[$0]) < abs(net[$1]) })!
        let planarity = arc > 0 ? abs(net[dom]) / arc * 100 : 0

        // Turning in the stroke's own plane, and turning out of it. The axis is
        // the stroke's net rotation, so this asks "how much of the movement was
        // about the axis the movement was about" — a question the sensor's
        // mounting angle has no say in.
        var alongPath = 0.0, perpPath = 0.0
        if arc > 0 {
            let n0 = [net[0] / arc, net[1] / arc, net[2] / arc]
            for i in 0..<(n - 1) {
                let dt = t[i + 1] - t[i]
                let w = [r[i].gyroX, r[i].gyroY, r[i].gyroZ]
                let along = w[0]*n0[0] + w[1]*n0[1] + w[2]*n0[2]
                let perp = [w[0] - along*n0[0], w[1] - along*n0[1], w[2] - along*n0[2]]
                alongPath += abs(along) * dt
                perpPath += (perp[0]*perp[0] + perp[1]*perp[1] + perp[2]*perp[2]).squareRoot() * dt
            }
        }
        let inPlane = alongPath + perpPath > 0 ? alongPath / (alongPath + perpPath) * 100 : 0

        // peak rate and where it falls
        var peakIdx = 0
        for i in 1..<n where rate[i] > rate[peakIdx] { peakIdx = i }
        let peakRate = rate[peakIdx]

        // Angular acceleration, centrally differenced over a short window —
        // a raw sample-to-sample difference at 200 Hz is mostly quantisation.
        func alpha(_ i: Int) -> Double {
            let a = max(0, i - 2), b = min(n - 1, i + 2)
            let dt = t[b] - t[a]
            return dt > 0 ? (rate[b] - rate[a]) / dt : 0
        }

        // Sharpest acceleration before the peak: the drive.
        var peakAccel = 0.0
        for i in 0..<peakIdx {
            let a = alpha(i)
            if a > peakAccel { peakAccel = a }
        }

        // How much of the drive was still speeding up. Weighted by time rather
        // than counted by sample so a varying sample interval can't tilt it.
        var rising = 0.0, driveTime = 0.0
        for i in 0..<peakIdx {
            let dt = t[i + 1] - t[i]
            driveTime += dt
            if alpha(i) > 0 { rising += dt }
        }
        let driveSmooth = driveTime > 0 ? rising / driveTime * 100 : 0

        // Sharpest deceleration after the peak: the stop.
        var peakDecel = 0.0
        if peakIdx < n - 1 {
            for i in peakIdx..<n {
                let a = alpha(i)
                if a < peakDecel { peakDecel = a }
            }
        }

        // The stop ends when rate has fallen to a fifth of its peak.
        var stopEnd = n - 1
        let floorRate = peakRate * 0.2
        for i in peakIdx..<n where rate[i] <= floorRate { stopEnd = i; break }

        var peakAcc = 0.0
        for reading in r where reading.accMagnitude > peakAcc { peakAcc = reading.accMagnitude }

        // The rate curve on a common grid, scaled by its own peak, so two
        // strokes of different size and length can still be laid over each
        // other. Linear between samples: at 200 Hz the grid is coarser than
        // the data everywhere a casting stroke is long enough to be one.
        var profile = [Double](repeating: 0, count: profilePoints)
        if peakRate > 0 {
            var j = 0
            for k in 0..<profilePoints {
                let want = duration * Double(k) / Double(profilePoints - 1)
                while j + 1 < n - 1 && t[j + 1] < want { j += 1 }
                let dt = t[j + 1] - t[j]
                let f = dt > 0 ? Swift.max(0, Swift.min(1, (want - t[j]) / dt)) : 0
                profile[k] = (rate[j] + (rate[j + 1] - rate[j]) * f) / peakRate
            }
        }

        // The stop itself: the slowest moment after the peak. Distinct from
        // `stopEnd`, which is where the rate first falls to a fifth of peak and
        // is what `stopPhase` times — this is where the rotation actually died.
        var stopIdx = peakIdx
        for i in peakIdx..<n where rate[i] < rate[stopIdx] { stopIdx = i }
        let stop = stopUp(readings, span: span, stopIndex: span.lowerBound + stopIdx)

        return StrokeMetrics(
            index: index,
            startTime: r[0].timestamp.timeIntervalSince(sessionStart),
            duration: duration,
            sampleCount: n,
            arcDeg: arc,
            netRotationDeg: net,
            pathDeg: path,
            planarityPct: planarity,
            dominantAxis: ["X", "Y", "Z"][dom],
            offPlaneDeg: perpPath,
            inPlanePct: inPlane,
            peakRateDPS: peakRate,
            peakRateAtPct: t[peakIdx] / duration * 100,
            accelPhase: t[peakIdx],
            stopPhase: max(t[stopEnd] - t[peakIdx], 0),
            peakAccelDPS2: peakAccel,
            peakDecelDPS2: abs(peakDecel),
            driveSmoothPct: driveSmooth,
            rateProfile: profile,
            peakAccG: peakAcc,
            stopUp: stop?.up,
            stopStillSamples: stop?.samples ?? 0)
    }

    public static func analyze(_ readings: [SensorReading],
                              detector: StrokeDetector = StrokeDetector()) -> [StrokeMetrics] {
        guard let first = readings.first else { return [] }
        return detector.detect(readings).enumerated().compactMap { i, span in
            metrics(for: readings, span: span, index: i + 1, sessionStart: first.timestamp)
        }
    }
}

// MARK: - Consistency across strokes

/// Spread of one metric over a session.
public struct Spread {
    public let name: String
    public let unit: String
    public let values: [Double]

    public init(name: String, unit: String, values: [Double]) {
        self.name = name
        self.unit = unit
        self.values = values
    }

    public var mean: Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
    public var sd: Double {
        guard values.count > 1 else { return 0 }
        let m = mean
        return (values.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(values.count - 1)).squareRoot()
    }
    /// Coefficient of variation — spread relative to size, so metrics measured in
    /// different units can be compared for consistency on one scale.
    public var cvPct: Double { mean == 0 ? 0 : abs(sd / mean) * 100 }
    public var min: Double { values.min() ?? 0 }
    public var max: Double { values.max() ?? 0 }

    /// Strokes more than 2 SD from the mean, by position in `values`.
    public var outliers: [Int] {
        guard values.count > 2, sd > 0 else { return [] }
        let m = mean, s = sd
        return values.indices.filter { abs(values[$0] - m) > 2 * s }
    }
}

/// How far a set of directions sit from their own mean, in degrees.
///
/// A separate type from `Spread` because a coefficient of variation is
/// meaningless here: these are angles measured *about* a mean direction, so the
/// mean deviation is near zero by construction and dividing by it would produce
/// a number that swings between nonsense and infinity. The spread is the
/// reading, in degrees, and it is already on a scale a caster understands.
public struct AngularSpread {
    public let name: String
    /// Strokes the direction could be measured on.
    public let count: Int
    /// Strokes in the group where it could not — reported, never filled in.
    public let missing: Int
    /// Mean deviation from the group's mean direction.
    public let meanDeg: Double
    /// Deviation from the mean direction, as a spread rather than an average —
    /// this is the "how repeatable" figure.
    public let sdDeg: Double
    public let maxDeg: Double
    /// `StrokeMetrics.index` of the stroke furthest from the mean.
    public let worstStroke: Int?
    /// Per stroke, in the order given; nil where the direction was unmeasurable.
    public let deviationsDeg: [Double?]

    public init(name: String, count: Int, missing: Int, meanDeg: Double, sdDeg: Double,
                maxDeg: Double, worstStroke: Int?, deviationsDeg: [Double?]) {
        self.name = name
        self.count = count
        self.missing = missing
        self.meanDeg = meanDeg
        self.sdDeg = sdDeg
        self.maxDeg = maxDeg
        self.worstStroke = worstStroke
        self.deviationsDeg = deviationsDeg
    }
}

/// How alike a set of rate curves are, once size and length are divided out.
public struct ProfileAgreement {
    public let name: String
    public let count: Int
    /// Mean RMS departure from the group's average curve, as a percentage of
    /// peak rate.
    public let meanDeviationPct: Double
    public let maxDeviationPct: Double
    public let worstStroke: Int?
    public let deviationsPct: [Double]
    /// The average curve itself, for drawing.
    public let meanProfile: [Double]

    /// The complement, which is the way the question is asked: how alike, not
    /// how different. Floored at zero for the same reason the page floors
    /// 100 − CV: a negative percentage of alikeness would be noise in a suit.
    public var agreementPct: Double { Swift.max(0, 100 - meanDeviationPct) }
}

/// The session's casting axis, and which way each stroke turned about it.
///
/// Stage 2 of PLAN.md, in the small: back casts and forward casts are the same
/// movement in opposite directions, so their rotation vectors are antiparallel
/// and averaging them raw cancels the session to nothing. Folding the sign
/// first makes them reinforce. `reconstruct.js` builds the same axis per burst.
public struct CastingFrame {
    public let axis: [Double]
    /// +1 or −1 per stroke, in the order given. The largest-arc stroke is the
    /// sign anchor and is always +1, so the labelling is stable across runs —
    /// but which physical direction is which is not in the data. PLAN.md
    /// Stage 2 is still open on that.
    public let signs: [Int]
}

public enum SessionStats {
    /// The metrics worth tracking for consistency, in reporting order.
    public static func spreads(_ s: [StrokeMetrics]) -> [Spread] {
        [
            Spread(name: "Arc swept", unit: "°", values: s.map(\.arcDeg)),
            Spread(name: "Duration", unit: "s", values: s.map(\.duration)),
            Spread(name: "Peak rate", unit: "°/s", values: s.map(\.peakRateDPS)),
            Spread(name: "Peak at", unit: "% of stroke", values: s.map(\.peakRateAtPct)),
            Spread(name: "Drive accel", unit: "°/s²", values: s.map(\.peakAccelDPS2)),
            Spread(name: "Drive smooth", unit: "% of drive", values: s.map(\.driveSmoothPct)),
            Spread(name: "Stop decel", unit: "°/s²", values: s.map(\.peakDecelDPS2)),
            Spread(name: "Stop share", unit: "% of stroke", values: s.map(\.stopSharePct)),
            Spread(name: "Off-plane", unit: "°", values: s.map(\.offPlaneDeg)),
            Spread(name: "Planarity", unit: "%", values: s.map(\.planarityPct)),
            Spread(name: "Peak accel", unit: "g", values: s.map(\.peakAccG)),
        ]
    }

    /// Single-figure repeatability: the mean CV across the metrics a caster
    /// controls. Deliberately excludes planarity and peak acceleration, which
    /// track mounting and geometry more than technique.
    ///
    /// Drive acceleration is in because it is the half of the stroke stop
    /// deceleration was already speaking for — loading the rod and unloading it
    /// are two separate things to be consistent at.
    public static func repeatabilityCV(_ s: [StrokeMetrics]) -> Double? {
        guard s.count > 2 else { return nil }
        let core = spreads(s).filter {
            ["Arc swept", "Duration", "Peak rate", "Drive accel", "Stop decel"].contains($0.name)
        }
        return core.reduce(0) { $0 + $1.cvPct } / Double(core.count)
    }

    // MARK: - Direction

    static func unit(_ v: [Double]) -> [Double]? {
        let m = (v[0]*v[0] + v[1]*v[1] + v[2]*v[2]).squareRoot()
        guard m > 1e-12, m.isFinite else { return nil }
        return [v[0]/m, v[1]/m, v[2]/m]
    }

    static func dot(_ a: [Double], _ b: [Double]) -> Double {
        a[0]*b[0] + a[1]*b[1] + a[2]*b[2]
    }

    static func angleDeg(_ a: [Double], _ b: [Double]) -> Double {
        Foundation.acos(Swift.max(-1, Swift.min(1, dot(a, b)))) * 180 / .pi
    }

    public static func castingFrame(_ s: [StrokeMetrics]) -> CastingFrame? {
        guard !s.isEmpty else { return nil }
        // Anchor on the biggest stroke rather than the first: the first can be a
        // lift or a slack twitch, and its axis is then noise setting the sign
        // for the whole session.
        guard let anchorIdx = s.indices.max(by: { s[$0].arcDeg < s[$1].arcDeg }),
              let anchor = unit(s[anchorIdx].netRotationDeg) else { return nil }

        var sum = [0.0, 0.0, 0.0]
        for m in s {
            let v = m.netRotationDeg
            let sign: Double = dot(v, anchor) >= 0 ? 1 : -1
            sum[0] += sign*v[0]; sum[1] += sign*v[1]; sum[2] += sign*v[2]
        }
        guard let axis = unit(sum) else { return nil }
        // Keep the anchor positive so the two groups don't swap names between
        // runs on the same recording.
        let flip: Double = dot(anchor, axis) >= 0 ? 1 : -1
        let a = [axis[0]*flip, axis[1]*flip, axis[2]*flip]
        return CastingFrame(axis: a, signs: s.map { dot($0.netRotationDeg, a) >= 0 ? 1 : -1 })
    }

    // MARK: - Which strokes were casts

    /// The strokes big enough to be casts, by the relative rule §6 of PLAN.md
    /// settled on: half the median arc of the largest third of the session.
    ///
    /// Relative, not a constant. §4c of PLAN.md ruled a constant out — casts in
    /// `benchtest2` ranged 67–152° with no line on the rod at all, so any fixed
    /// degree threshold either swallows real casts or admits the lifts and
    /// re-positions between them. Those are what a repeatability figure must
    /// not be measured over: a lift travels in a different plane from the cast
    /// that follows it, and counting it reads as a caster whose plane wanders.
    public static func casts(_ s: [StrokeMetrics]) -> [StrokeMetrics] {
        guard s.count >= 3 else { return s }
        let sorted = s.map(\.arcDeg).sorted(by: >)
        let top = Array(sorted.prefix(Swift.max(1, sorted.count / 3)))
        let median = top[top.count / 2]
        guard median > 0 else { return s }
        return s.filter { $0.arcDeg >= median / 2 }
    }

    // MARK: - Repeatability of shape and position

    /// Deviations of a set of directions from their own weighted mean.
    ///
    /// `foldSign` treats a direction and its opposite as the same, which is what
    /// a *plane* needs: a back cast and the forward cast that follows turn about
    /// the same line in opposite senses, and they are in the same plane exactly
    /// when that line is the same.
    static func angularSpread(name: String,
                              vectors: [[Double]?],
                              strokeIndices: [Int],
                              weights: [Double],
                              foldSign: Bool) -> AngularSpread? {
        var units: [[Double]?] = []
        for v in vectors { units.append(v.flatMap(unit)) }
        let present = units.indices.filter { units[$0] != nil }
        guard present.count >= 2 else { return nil }

        guard let anchor = present.max(by: { weights[$0] < weights[$1] }).map({ units[$0]! })
        else { return nil }

        var sum = [0.0, 0.0, 0.0]
        for i in present {
            let u = units[i]!
            let sign: Double = foldSign ? (dot(u, anchor) >= 0 ? 1 : -1) : 1
            let w = weights[i]
            sum[0] += sign*w*u[0]; sum[1] += sign*w*u[1]; sum[2] += sign*w*u[2]
        }
        guard let mean = unit(sum) else { return nil }

        var devs = [Double?](repeating: nil, count: units.count)
        var values: [Double] = []
        for i in present {
            var a = angleDeg(units[i]!, mean)
            // A plane has no front and back, so 175° off is 5° off.
            if foldSign { a = Swift.min(a, 180 - a) }
            devs[i] = a
            values.append(a)
        }

        let n = Double(values.count)
        let meanDev = values.reduce(0, +) / n
        // Spread about zero, not about the mean deviation: the target is
        // agreement with the mean direction, and every degree away from it is
        // error whether or not the other strokes are away by the same amount.
        let sd = (values.reduce(0) { $0 + $1*$1 } / n).squareRoot()
        let worst = present.max(by: { devs[$0]! < devs[$1]! })

        return AngularSpread(name: name, count: values.count,
                             missing: units.count - values.count,
                             meanDeg: meanDev, sdDeg: sd,
                             maxDeg: values.max() ?? 0,
                             worstStroke: worst.map { strokeIndices[$0] },
                             deviationsDeg: devs)
    }

    /// How much the casting plane moved between strokes.
    public static func planeSpread(_ s: [StrokeMetrics]) -> AngularSpread? {
        angularSpread(name: "Casting plane",
                      vectors: s.map { $0.arcDeg > 0 ? $0.netRotationDeg : nil },
                      strokeIndices: s.map(\.index),
                      // A stroke that barely turned has a barely-defined axis.
                      // Weighting by arc keeps it from steering the mean.
                      weights: s.map(\.arcDeg),
                      foldSign: true)
    }

    /// How much the rod's attitude at the stop moved between strokes.
    public static func stopSpread(_ s: [StrokeMetrics], name: String) -> AngularSpread? {
        angularSpread(name: name,
                      vectors: s.map(\.stopUp),
                      strokeIndices: s.map(\.index),
                      weights: s.map { _ in 1 },
                      foldSign: false)
    }

    /// How alike the strokes' rate curves are.
    public static func profileAgreement(_ s: [StrokeMetrics], name: String) -> ProfileAgreement? {
        let usable = s.filter { $0.rateProfile.count == StrokeAnalyzer.profilePoints
                                && $0.peakRateDPS > 0 }
        guard usable.count >= 2 else { return nil }
        let points = StrokeAnalyzer.profilePoints

        var mean = [Double](repeating: 0, count: points)
        for m in usable {
            for k in 0..<points { mean[k] += m.rateProfile[k] }
        }
        for k in 0..<points { mean[k] /= Double(usable.count) }

        var devs: [Double] = []
        for m in usable {
            var acc = 0.0
            for k in 0..<points {
                let d = m.rateProfile[k] - mean[k]
                acc += d*d
            }
            devs.append((acc / Double(points)).squareRoot() * 100)
        }
        let worst = usable.indices.max(by: { devs[$0] < devs[$1] })
        return ProfileAgreement(name: name, count: usable.count,
                                meanDeviationPct: devs.reduce(0, +) / Double(devs.count),
                                maxDeviationPct: devs.max() ?? 0,
                                worstStroke: worst.map { usable[$0].index },
                                deviationsPct: devs, meanProfile: mean)
    }

    /// The three things a caster is trying to repeat that a coefficient of
    /// variation can't speak for: where the rod stops, how it is driven there,
    /// and the plane it travels in.
    ///
    /// Stops and drive shape are split by direction. A back cast and a forward
    /// cast stop in two different places and are driven two different ways, so
    /// measured together their spread is the gap between the two groups and
    /// says nothing about how repeatable either one is.
    public struct Repeatability {
        public let plane: AngularSpread?
        public let stops: [AngularSpread]
        public let drive: [ProfileAgreement]
        /// Casts measured, and strokes set aside as too small to be casts.
        public let castCount: Int
        public let setAside: Int
        /// Casts with no still moment to read a stopping point from.
        public let stopsUnmeasured: Int
    }

    /// Named for the reader, since the data cannot say which way is which.
    static let directionNames = ["one way", "the other way"]

    public static func repeatability(_ all: [StrokeMetrics]) -> Repeatability {
        let s = casts(all)
        let unmeasured = s.filter { $0.stopUp == nil }.count
        let counts = (cast: s.count, aside: all.count - s.count)
        guard s.count >= 2, let frame = castingFrame(s) else {
            return Repeatability(plane: planeSpread(s), stops: [], drive: [],
                                 castCount: counts.cast, setAside: counts.aside,
                                 stopsUnmeasured: unmeasured)
        }

        var stops: [AngularSpread] = []
        var drive: [ProfileAgreement] = []
        for (k, sign) in [1, -1].enumerated() {
            let group = zip(s, frame.signs).filter { $0.1 == sign }.map(\.0)
            guard group.count >= 2 else { continue }
            let suffix = directionNames[k]
            if let sp = stopSpread(group, name: "Stops, " + suffix) { stops.append(sp) }
            if let pa = profileAgreement(group, name: "Drive shape, " + suffix) {
                drive.append(pa)
            }
        }
        return Repeatability(plane: planeSpread(s), stops: stops, drive: drive,
                             castCount: counts.cast, setAside: counts.aside,
                             stopsUnmeasured: unmeasured)
    }

    /// Reading for an angular spread, in the register of the CV verdicts.
    ///
    /// The bands are where the corpus actually falls, not a preference. Across
    /// the fourteen usable sessions the casting plane spread runs 4.8–20.2°
    /// and stopping points 3.6–15.4°, so 5° is about as tight as anyone in it
    /// has managed and 15° is the loose end. They are one scale for both
    /// because both are the same quantity — degrees away from a mean direction
    /// — and their ranges sit on top of each other. PLAN.md §10.
    public static func angularVerdict(_ sdDeg: Double) -> String {
        if sdDeg < 5 { return "very consistent" }
        if sdDeg < 10 { return "consistent" }
        if sdDeg < 15 { return "variable" }
        return "highly variable"
    }
}
