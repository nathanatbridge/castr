import Foundation
import CastrCore

enum Report {

    static func pad(_ s: String, _ w: Int, right: Bool = true) -> String {
        s.count >= w ? s : (right ? String(repeating: " ", count: w - s.count) + s
                                  : s + String(repeating: " ", count: w - s.count))
    }
    static func f(_ v: Double, _ d: Int) -> String { String(format: "%.\(d)f", v) }
    static func rule(_ n: Int) -> String { String(repeating: "─", count: n) }

    // MARK: - Text report

    static func text(session: CSVReader.Session, strokes: [StrokeMetrics],
                     other: CSVReader.Session?, otherStrokes: [StrokeMetrics]) {
        header(session, strokes)

        guard !strokes.isEmpty else {
            print("""

            No strokes detected.

            The session may be all rest, or the threshold may be wrong for this
            motion — the fastest rotation seen was \
            \(f(session.readings.map { ($0.gyroX*$0.gyroX + $0.gyroY*$0.gyroY + $0.gyroZ*$0.gyroZ).squareRoot() }.max() ?? 0, 0)) °/s.
            Lower it with --enter if that looks like a real stroke.
            """)
            return
        }

        strokeTable(strokes)
        consistency(strokes)

        if let o = other, !otherStrokes.isEmpty {
            comparison(a: session, aStrokes: strokes, b: o, bStrokes: otherStrokes)
        } else if other != nil {
            print("\nNo strokes detected in the comparison session — nothing to compare.")
        }
    }

    static func header(_ s: CSVReader.Session, _ strokes: [StrokeMetrics]) {
        print("")
        print(s.name)
        print(rule(76))
        print("  \(s.readings.count) samples over \(f(s.duration, 1)) s "
              + "at \(f(s.sampleRateHz, 0)) Hz    device \(s.deviceName)")
        print("  \(strokes.count) stroke\(strokes.count == 1 ? "" : "s") detected")
    }

    static func strokeTable(_ strokes: [StrokeMetrics]) {
        print("")
        print("STROKES")
        print("  " + pad("#", 3) + pad("t/s", 8) + pad("dur/s", 8) + pad("arc°", 8)
              + pad("peak°/s", 9) + pad("peak@", 7) + pad("decel°/s²", 11)
              + pad("stop%", 7) + pad("planar%", 9) + pad("|a|g", 7))
        print("  " + rule(77))
        for m in strokes {
            print("  " + pad(String(m.index), 3)
                  + pad(f(m.startTime, 2), 8)
                  + pad(f(m.duration, 3), 8)
                  + pad(f(m.arcDeg, 1), 8)
                  + pad(f(m.peakRateDPS, 0), 9)
                  + pad(f(m.peakRateAtPct, 0) + "%", 7)
                  + pad(f(m.peakDecelDPS2, 0), 11)
                  + pad(f(m.stopSharePct, 0) + "%", 7)
                  + pad(f(m.planarityPct, 1), 9)
                  + pad(f(m.peakAccG, 2), 7))
        }
    }

    static func consistency(_ strokes: [StrokeMetrics]) {
        guard strokes.count > 1 else {
            print("\nOne stroke only — repeat the movement a few times for consistency figures.")
            return
        }
        print("")
        print("CONSISTENCY")
        print("  " + pad("metric", 14, right: false) + pad("mean", 11) + pad("sd", 10)
              + pad("cv", 8) + pad("min", 10) + pad("max", 10) + "  outliers")
        print("  " + rule(75))

        for sp in SessionStats.spreads(strokes) {
            let dec = sp.unit == "s" ? 3 : (sp.mean < 10 ? 2 : 0)
            let out = sp.outliers.map { "#\(strokes[$0].index)" }.joined(separator: " ")
            print("  " + pad(sp.name, 14, right: false)
                  + pad(f(sp.mean, dec), 11)
                  + pad(f(sp.sd, dec), 10)
                  + pad(f(sp.cvPct, 1) + "%", 8)
                  + pad(f(sp.min, dec), 10)
                  + pad(f(sp.max, dec), 10)
                  + "  " + out)
        }

        if let cv = SessionStats.repeatabilityCV(strokes) {
            print("")
            print("  Repeatability  " + f(cv, 1) + "%   " + verdict(cv))
            print("  (mean spread across arc, duration, peak rate and stop deceleration —")
            print("   lower is more alike. Planarity and peak acceleration are excluded:")
            print("   they track the mount and geometry more than technique.)")
        }
    }

    static func verdict(_ cv: Double) -> String {
        if cv < 10 { return "very consistent" }
        if cv < 20 { return "consistent" }
        if cv < 35 { return "variable" }
        return "highly variable"
    }

    static func comparison(a: CSVReader.Session, aStrokes: [StrokeMetrics],
                           b: CSVReader.Session, bStrokes: [StrokeMetrics]) {
        print("")
        print("COMPARISON")
        print("  " + pad("metric", 14, right: false)
              + pad(String(a.name.prefix(12)), 12)
              + pad(String(b.name.prefix(12)), 12)
              + pad("change", 12) + "   significance")
        print("  " + rule(75))

        let sa = SessionStats.spreads(aStrokes), sb = SessionStats.spreads(bStrokes)
        for (x, y) in zip(sa, sb) {
            let dec = x.unit == "s" ? 3 : (x.mean < 10 ? 2 : 0)
            let delta = y.mean - x.mean
            let pct = x.mean == 0 ? 0 : delta / abs(x.mean) * 100
            // Compare the shift against the spread within each session: a change
            // smaller than the stroke-to-stroke noise isn't a real difference.
            let pooled = ((x.sd * x.sd + y.sd * y.sd) / 2).squareRoot()
            let note: String
            if pooled == 0 {
                note = "—"
            } else if abs(delta) > 2 * pooled {
                note = "clear"
            } else if abs(delta) > pooled {
                note = "possible"
            } else {
                note = "within noise"
            }
            print("  " + pad(x.name, 14, right: false)
                  + pad(f(x.mean, dec), 12)
                  + pad(f(y.mean, dec), 12)
                  + pad((delta >= 0 ? "+" : "") + f(pct, 1) + "%", 12)
                  + "   " + note)
        }
        print("")
        print("  \"within noise\" means the difference is smaller than the stroke-to-stroke")
        print("  variation inside each session, so it isn't evidence of a real change.")
    }

    // MARK: - JSON

    static func json(session: CSVReader.Session, strokes: [StrokeMetrics],
                     other: CSVReader.Session?, otherStrokes: [StrokeMetrics]) -> String {
        func esc(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        func n(_ v: Double, _ d: Int = 4) -> String {
            let r = (v * pow(10, Double(d))).rounded() / pow(10, Double(d))
            return r.isFinite ? String(r) : "null"
        }
        func strokeObj(_ m: StrokeMetrics) -> String {
            """
            {"index":\(m.index),"startTime":\(n(m.startTime)),"duration":\(n(m.duration)),\
            "samples":\(m.sampleCount),"arcDeg":\(n(m.arcDeg)),"pathDeg":\(n(m.pathDeg)),\
            "planarityPct":\(n(m.planarityPct)),"dominantAxis":\(esc(m.dominantAxis)),\
            "peakRateDPS":\(n(m.peakRateDPS)),"peakRateAtPct":\(n(m.peakRateAtPct)),\
            "accelPhase":\(n(m.accelPhase)),"stopPhase":\(n(m.stopPhase)),\
            "peakDecelDPS2":\(n(m.peakDecelDPS2)),"stopSharePct":\(n(m.stopSharePct)),\
            "peakAccG":\(n(m.peakAccG)),"tempo":\(n(m.tempo))}
            """
        }
        func spreadObj(_ s: Spread) -> String {
            """
            {"name":\(esc(s.name)),"unit":\(esc(s.unit)),"mean":\(n(s.mean)),\
            "sd":\(n(s.sd)),"cvPct":\(n(s.cvPct)),"min":\(n(s.min)),"max":\(n(s.max))}
            """
        }
        func sessionObj(_ s: CSVReader.Session, _ m: [StrokeMetrics]) -> String {
            let rep = SessionStats.repeatabilityCV(m).map { n($0) } ?? "null"
            return """
            {"name":\(esc(s.name)),"device":\(esc(s.deviceName)),\
            "samples":\(s.readings.count),"duration":\(n(s.duration)),\
            "sampleRateHz":\(n(s.sampleRateHz)),"repeatabilityCV":\(rep),\
            "strokes":[\(m.map(strokeObj).joined(separator: ","))],\
            "spreads":[\(SessionStats.spreads(m).map(spreadObj).joined(separator: ","))]}
            """
        }
        var out = "{\"session\":" + sessionObj(session, strokes)
        if let o = other { out += ",\"compare\":" + sessionObj(o, otherStrokes) }
        return out + "}"
    }
}
