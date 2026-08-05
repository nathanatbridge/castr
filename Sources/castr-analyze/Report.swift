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
                     tags: TagMatcher.Result,
                     other: CSVReader.Session?, otherStrokes: [StrokeMetrics],
                     otherTags: TagMatcher.Result) {
        header(session, strokes, tags)

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

        strokeTable(strokes, tags)
        consistency(strokes)
        byLabel(strokes, tags)
        untaggedNote(strokes, tags)

        if let o = other, !otherStrokes.isEmpty {
            comparison(a: session, aStrokes: strokes, b: o, bStrokes: otherStrokes)
        } else if other != nil {
            print("\nNo strokes detected in the comparison session — nothing to compare.")
        }
    }

    static func header(_ s: CSVReader.Session, _ strokes: [StrokeMetrics],
                       _ tags: TagMatcher.Result) {
        print("")
        print(s.name)
        print(rule(76))
        print("  \(s.readings.count) samples over \(f(s.duration, 1)) s "
              + "at \(f(s.sampleRateHz, 0)) Hz    device \(s.deviceName)")
        print("  \(strokes.count) stroke\(strokes.count == 1 ? "" : "s") detected")
        if !tags.matches.isEmpty {
            print("  \(tags.matches.count) tagged — \(tags.summary)")
            if let lag = tags.medianOffset {
                // The tagger's own reaction time, measured rather than assumed.
                // If this is far off the lag that was corrected out, the labels
                // were placed against the wrong assumption — rerun with --lag.
                print("  taps landed " + f(lag, 2) + " s after their stroke, typically")
            }
        }
    }

    static func strokeTable(_ strokes: [StrokeMetrics], _ tags: TagMatcher.Result) {
        let labelled = !tags.matches.isEmpty
        print("")
        print("STROKES")
        print("  " + pad("#", 3) + (labelled ? " " + pad("label", 10, right: false) : "")
              + pad("t/s", 8) + pad("dur/s", 8) + pad("arc°", 8)
              + pad("peak°/s", 9) + pad("peak@", 7) + pad("decel°/s²", 11)
              + pad("stop%", 7) + pad("planar%", 9) + pad("|a|g", 7))
        print("  " + rule(labelled ? 88 : 77))
        for m in strokes {
            // An untagged stroke inside a tagged session gets a dash, not a
            // blank — a gap in the tagging should be visible, not invisible.
            let label = labelled
                ? " " + pad(tags.label(forStroke: m.index)?.short ?? "—", 10, right: false)
                : ""
            print("  " + pad(String(m.index), 3) + label
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

    /// Mean ± sd, for the compact by-label table.
    static func pm(_ s: Spread?, _ dec: Int) -> String {
        guard let s else { return "—" }
        return f(s.mean, dec) + "±" + f(s.sd, dec)
    }

    static func byLabel(_ strokes: [StrokeMetrics], _ tags: TagMatcher.Result) {
        let groups = SessionStats.byLabel(strokes, tags)
        guard !groups.isEmpty else { return }

        print("")
        print("BY LABEL")
        print("  " + pad("label", 15, right: false) + pad("n", 4)
              + pad("arc°", 14) + pad("dur/s", 14) + pad("peak°/s", 14)
              + pad("decel°/s²", 15) + pad("repeat", 9))
        print("  " + rule(85))
        for g in groups {
            let rep = g.repeatabilityCV.map { f($0, 1) + "%" } ?? "—"
            let note = g.repeatabilityCV.map { "  " + verdict($0) } ?? "  (needs 3+)"
            print("  " + pad(g.label.name, 15, right: false)
                  + pad(String(g.count), 4)
                  + pad(pm(g.spread("Arc swept"), 1), 14)
                  + pad(pm(g.spread("Duration"), 3), 14)
                  + pad(pm(g.spread("Peak rate"), 0), 14)
                  + pad(pm(g.spread("Stop decel"), 0), 15)
                  + pad(rep, 9)
                  + note)
        }

        print("")
        print("  Each group is measured against its own kind. A pickup and a delivery are")
        print("  different movements, so the session-wide repeatability above mixes them")
        print("  and reads worse than any single group actually is — compare within a row,")
        print("  not against the overall figure.")
    }

    /// Tagging that came apart, and strokes it missed.
    static func untaggedNote(_ strokes: [StrokeMetrics], _ tags: TagMatcher.Result) {
        guard !tags.matches.isEmpty || !tags.unmatched.isEmpty else { return }

        let missed = SessionStats.untagged(strokes, tags)
        if !missed.isEmpty {
            print("")
            print("  \(missed.count) detected stroke\(missed.count == 1 ? "" : "s") "
                  + "went untagged: "
                  + missed.map { "#\($0.index)" }.joined(separator: " "))
        }
        if !tags.unmatched.isEmpty {
            print("")
            print("  \(tags.unmatched.count) tap\(tags.unmatched.count == 1 ? "" : "s") "
                  + "matched no stroke:")
            for u in tags.unmatched.prefix(8) {
                print("    " + pad(f(u.tapTime, 2) + "s", 9) + "  "
                      + pad(u.label.name, 15, right: false) + u.reason)
            }
            if tags.unmatched.count > 8 {
                print("    … and \(tags.unmatched.count - 8) more")
            }
            print("")
            print("  Taps that land nowhere usually mean the tagger drifted a stroke behind,")
            print("  or a movement the caster made wasn't big enough to detect. Check the")
            print("  labels above before trusting the grouping.")
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
                     tags: TagMatcher.Result,
                     other: CSVReader.Session?, otherStrokes: [StrokeMetrics],
                     otherTags: TagMatcher.Result) -> String {
        func esc(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        func n(_ v: Double, _ d: Int = 4) -> String {
            let r = (v * pow(10, Double(d))).rounded() / pow(10, Double(d))
            return r.isFinite ? String(r) : "null"
        }
        func strokeObj(_ m: StrokeMetrics, _ t: TagMatcher.Result) -> String {
            // The tap's own offset rides along with the label: a consumer that
            // wants to re-snap tags under different detector settings needs to
            // see how far each tap actually trailed its stroke.
            let match = t.match(forStroke: m.index)
            let label = match.map { esc($0.label.name) } ?? "null"
            let tapOffset = match.map { n($0.offset) } ?? "null"
            return """
            {"index":\(m.index),"startTime":\(n(m.startTime)),"duration":\(n(m.duration)),\
            "samples":\(m.sampleCount),"arcDeg":\(n(m.arcDeg)),\
            "netRotationDeg":[\(m.netRotationDeg.map { n($0) }.joined(separator: ","))],\
            "pathDeg":\(n(m.pathDeg)),\
            "planarityPct":\(n(m.planarityPct)),"dominantAxis":\(esc(m.dominantAxis)),\
            "peakRateDPS":\(n(m.peakRateDPS)),"peakRateAtPct":\(n(m.peakRateAtPct)),\
            "accelPhase":\(n(m.accelPhase)),"stopPhase":\(n(m.stopPhase)),\
            "peakDecelDPS2":\(n(m.peakDecelDPS2)),"stopSharePct":\(n(m.stopSharePct)),\
            "peakAccG":\(n(m.peakAccG)),"tempo":\(n(m.tempo)),\
            "label":\(label),"tapOffset":\(tapOffset)}
            """
        }
        func spreadObj(_ s: Spread) -> String {
            """
            {"name":\(esc(s.name)),"unit":\(esc(s.unit)),"mean":\(n(s.mean)),\
            "sd":\(n(s.sd)),"cvPct":\(n(s.cvPct)),"min":\(n(s.min)),"max":\(n(s.max))}
            """
        }
        func groupObj(_ g: LabelGroup) -> String {
            let rep = g.repeatabilityCV.map { n($0) } ?? "null"
            return """
            {"label":\(esc(g.label.name)),"count":\(g.count),"repeatabilityCV":\(rep),\
            "strokes":[\(g.strokes.map { String($0.index) }.joined(separator: ","))],\
            "spreads":[\(g.spreads.map(spreadObj).joined(separator: ","))]}
            """
        }
        func unmatchedObj(_ u: TagMatcher.Unmatched) -> String {
            """
            {"label":\(esc(u.label.name)),"tapTime":\(n(u.tapTime)),"reason":\(esc(u.reason))}
            """
        }
        func sessionObj(_ s: CSVReader.Session, _ m: [StrokeMetrics],
                        _ t: TagMatcher.Result) -> String {
            let rep = SessionStats.repeatabilityCV(m).map { n($0) } ?? "null"
            let groups = SessionStats.byLabel(m, t)
            return """
            {"name":\(esc(s.name)),"device":\(esc(s.deviceName)),\
            "samples":\(s.readings.count),"duration":\(n(s.duration)),\
            "sampleRateHz":\(n(s.sampleRateHz)),"repeatabilityCV":\(rep),\
            "tagged":\(t.matches.count),\
            "strokes":[\(m.map { strokeObj($0, t) }.joined(separator: ","))],\
            "spreads":[\(SessionStats.spreads(m).map(spreadObj).joined(separator: ","))],\
            "byLabel":[\(groups.map(groupObj).joined(separator: ","))],\
            "untaggedStrokes":[\(SessionStats.untagged(m, t).map { String($0.index) }.joined(separator: ","))],\
            "unmatchedTaps":[\(t.unmatched.map(unmatchedObj).joined(separator: ","))]}
            """
        }
        var out = "{\"session\":" + sessionObj(session, strokes, tags)
        if let o = other { out += ",\"compare\":" + sessionObj(o, otherStrokes, otherTags) }
        return out + "}"
    }
}
