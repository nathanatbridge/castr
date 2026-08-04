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
        let split = merged.flatMap { splitIfTooLong($0, r, rate, depth: 0) }
        return split.filter { span in
            r[span.upperBound - 1].timestamp.timeIntervalSince(r[span.lowerBound].timestamp) >= minDuration
        }
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
    /// Total angular distance travelled, including any back-and-forth.
    public let pathDeg: Double
    /// Share of net rotation about the dominant axis. 100% is a perfect plane.
    public let planarityPct: Double
    public let dominantAxis: String

    public let peakRateDPS: Double
    /// Where the peak falls within the stroke, 0–100%. Late peaks mean the rod
    /// is still accelerating deep into the stroke.
    public let peakRateAtPct: Double

    /// Start of stroke to peak rotation rate.
    public let accelPhase: TimeInterval
    /// Peak rotation rate to the stop.
    public let stopPhase: TimeInterval
    /// Sharpest deceleration after the peak — the abruptness of the stop, which
    /// is what unloads a rod.
    public let peakDecelDPS2: Double

    public let peakAccG: Double

    public var tempo: Double { duration > 0 ? arcDeg / duration : 0 }

    /// Fraction of the stroke spent stopping. A crisp stop is a small number.
    public var stopSharePct: Double { duration > 0 ? stopPhase / duration * 100 : 0 }
}

public enum StrokeAnalyzer {

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

        return StrokeMetrics(
            index: index,
            startTime: r[0].timestamp.timeIntervalSince(sessionStart),
            duration: duration,
            sampleCount: n,
            arcDeg: arc,
            pathDeg: path,
            planarityPct: planarity,
            dominantAxis: ["X", "Y", "Z"][dom],
            peakRateDPS: peakRate,
            peakRateAtPct: t[peakIdx] / duration * 100,
            accelPhase: t[peakIdx],
            stopPhase: max(t[stopEnd] - t[peakIdx], 0),
            peakDecelDPS2: abs(peakDecel),
            peakAccG: peakAcc)
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

public enum SessionStats {
    /// The metrics worth tracking for consistency, in reporting order.
    public static func spreads(_ s: [StrokeMetrics]) -> [Spread] {
        [
            Spread(name: "Arc swept", unit: "°", values: s.map(\.arcDeg)),
            Spread(name: "Duration", unit: "s", values: s.map(\.duration)),
            Spread(name: "Peak rate", unit: "°/s", values: s.map(\.peakRateDPS)),
            Spread(name: "Peak at", unit: "% of stroke", values: s.map(\.peakRateAtPct)),
            Spread(name: "Stop decel", unit: "°/s²", values: s.map(\.peakDecelDPS2)),
            Spread(name: "Stop share", unit: "% of stroke", values: s.map(\.stopSharePct)),
            Spread(name: "Planarity", unit: "%", values: s.map(\.planarityPct)),
            Spread(name: "Peak accel", unit: "g", values: s.map(\.peakAccG)),
        ]
    }

    /// Single-figure repeatability: the mean CV across the metrics a caster
    /// controls. Deliberately excludes planarity and peak acceleration, which
    /// track mounting and geometry more than technique.
    public static func repeatabilityCV(_ s: [StrokeMetrics]) -> Double? {
        guard s.count > 2 else { return nil }
        let core = spreads(s).filter {
            ["Arc swept", "Duration", "Peak rate", "Stop decel"].contains($0.name)
        }
        return core.reduce(0) { $0 + $1.cvPct } / Double(core.count)
    }
}
