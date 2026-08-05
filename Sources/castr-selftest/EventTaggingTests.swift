import Foundation
import CastrCore

private let tagBase = Date(timeIntervalSince1970: 1_700_000_000)

/// A stroke of `duration` starting `at` seconds into the session, wrapped in
/// enough rest that the detector closes it. Mirrors the shape used in
/// StrokeAnalysisTests so the two agree about what a stroke looks like.
private func tagStroke(at start: Double, duration: Double = 0.4,
                       peakDPS: Double = 500, rateHz: Double = 200) -> [SensorReading] {
    var out = [SensorReading]()
    let n = Int(duration * rateHz)
    for i in 0..<n {
        let u = Double(i) / Double(n)
        let rate = peakDPS * exp(-pow((u - 0.5) / 0.22, 2))
        out.append(SensorReading(
            timestamp: tagBase.addingTimeInterval(start + Double(i) / rateHz),
            accX: 0, accY: 0, accZ: 1,
            gyroX: rate, gyroY: 0, gyroZ: 0,
            angleX: 0, angleY: 0, angleZ: 0))
    }
    return out
}

private func quiet(from start: Double, to end: Double, rateHz: Double = 200) -> [SensorReading] {
    var out = [SensorReading]()
    var t = start
    while t < end {
        out.append(SensorReading(
            timestamp: tagBase.addingTimeInterval(t),
            accX: 0, accY: 0, accZ: 1,
            gyroX: 0.3, gyroY: -0.2, gyroZ: 0.1,
            angleX: 0, angleY: 0, angleZ: 0))
        t += 1 / rateHz
    }
    return out
}

/// Four strokes at 1.0, 2.5, 4.0 and 5.5 s, each 0.4 s long.
private func fourStrokeSession() -> [SensorReading] {
    var out = quiet(from: 0, to: 1.0)
    for k in 0..<4 {
        let start = 1.0 + Double(k) * 1.5
        out += tagStroke(at: start)
        out += quiet(from: start + 0.4, to: start + 1.5)
    }
    return out
}

private func tag(_ label: StrokeLabel, _ at: Double) -> CastTag {
    CastTag(timestamp: tagBase.addingTimeInterval(at), label: label)
}

func runEventTaggingTests() {
    print("EventLog")

    test("label round-trips through its written name") {
        for l in StrokeLabel.allCases {
            Check.equal(StrokeLabel.named(l.name), l, "name \(l.name)")
            Check.equal(StrokeLabel.named(l.rawValue), l, "raw \(l.rawValue)")
        }
    }

    test("each key selects exactly one label") {
        var seen = Set<Character>()
        for l in StrokeLabel.allCases {
            for k in l.keys {
                Check.isFalse(seen.contains(k), "key '\(k)' is used twice")
                seen.insert(k)
                Check.equal(StrokeLabel.forKey(k), l, "key '\(k)'")
            }
        }
        // Uppercase works too — caps lock shouldn't silently drop a tag.
        Check.equal(StrokeLabel.forKey("P"), .pickup, "uppercase P")
        Check.isTrue(StrokeLabel.forKey("z") == nil, "unmapped key must not tag")
    }

    test("sidecar sits beside the recording") {
        let csv = URL(fileURLWithPath: "/tmp/backyard.csv")
        Check.equal(EventLog.sidecarURL(for: csv).lastPathComponent, "backyard.events.csv")
    }

    test("writes and reads back a session's tags") {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("castr-tags-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }

        guard let w = Check.notNil(try? EventLogWriter(url: url), "writer") else { return }
        w.record(.pickup, at: tagBase.addingTimeInterval(1.4))
        w.record(.falseBack, at: tagBase.addingTimeInterval(2.9))
        w.record(.falseForward, at: tagBase.addingTimeInterval(4.4))
        w.record(.delivery, at: tagBase.addingTimeInterval(5.9))
        Check.equal(w.count(of: .pickup), 1, "pickup count")
        w.close()

        let read = (try? EventLogReader.read(contentsOf: url)) ?? []
        Check.equal(read.count, 4, "tags read back")
        Check.equal(read.map(\.label),
                    [.pickup, .falseBack, .falseForward, .delivery], "order")
        if read.count == 4 {
            // Millisecond resolution is all the format carries, so that's the
            // tolerance the timestamps have to hold to.
            Check.close(read[1].timestamp.timeIntervalSince(tagBase), 2.9, 0.002, "time")
        }
    }

    test("every tag is on disk before the writer closes") {
        // A tap can't be reconstructed after a crash the way a sample nearly can,
        // so nothing about tagging is allowed to buffer.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("castr-tags-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }

        guard let w = Check.notNil(try? EventLogWriter(url: url), "writer") else { return }
        w.record(.delivery, at: tagBase)
        let onDisk = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        Check.isTrue(onDisk.contains("delivery"), "tag reached disk before close()")
        w.close()
    }

    test("damaged lines are skipped, not fatal") {
        let text = """
        time,label
        2023-11-14 22:13:20.000,pickup
        not a timestamp,false back
        2023-11-14 22:13:22.000,not a label
        2023-11-14 22:13:23.000,delivery
        """
        let tags = EventLogReader.parse(text)
        Check.equal(tags.count, 2, "surviving tags")
        Check.equal(tags.map(\.label), [.pickup, .delivery], "which survived")
    }

    print("")
    print("TagMatching")

    let readings = fourStrokeSession()
    let strokes = StrokeAnalyzer.analyze(readings)

    test("the fixture has the four strokes the matching tests assume") {
        Check.equal(strokes.count, 4, "strokes")
    }

    test("a tap during a stroke tags that stroke") {
        let r = TagMatcher.match(tags: [tag(.pickup, 1.2)], to: strokes,
                                 sessionStart: tagBase)
        Check.equal(r.matches.count, 1, "matches")
        Check.equal(r.label(forStroke: 1), .pickup, "stroke 1")
    }

    test("a tap in the caster's wake still tags the stroke it followed") {
        // Stroke 2's bell runs 2.5–2.9 s, but the detector closes it at ~2.85
        // where the rate drops through 25 °/s, so a tap at 3.2 trails the
        // *detected* stroke by ~0.35 s — ordinary human reaction lag.
        let r = TagMatcher.match(tags: [tag(.falseBack, 3.2)], to: strokes,
                                 sessionStart: tagBase)
        Check.equal(r.label(forStroke: 2), .falseBack, "stroke 2")
        Check.equal(r.unmatched.count, 0, "unmatched")
        if let m = r.match(forStroke: 2) {
            Check.close(m.offset, 0.35, 0.05, "offset behind the stroke")
        }
    }

    test("a whole sequence tags in order") {
        // Each tap lands ~0.4 s after its stroke finishes.
        let taps = [tag(.pickup, 1.8), tag(.falseBack, 3.3),
                    tag(.falseForward, 4.8), tag(.delivery, 6.3)]
        let r = TagMatcher.match(tags: taps, to: strokes, sessionStart: tagBase)
        Check.equal(r.matches.count, 4, "matches")
        Check.equal(r.unmatched.count, 0, "unmatched")
        Check.equal((1...4).compactMap { r.label(forStroke: $0) },
                    [.pickup, .falseBack, .falseForward, .delivery], "sequence")
    }

    test("a tap between strokes goes to the earlier one even when the later is nearer") {
        // Stroke 2 is detected out to ~2.85, stroke 3 from ~4.07. A tap at 3.6
        // is 0.47 s before stroke 3 but 0.75 s after stroke 2 — nearer the
        // later stroke in raw time, yet it belongs to the earlier one, because
        // tagging a stroke before it happens would mean predicting it.
        let r = TagMatcher.match(tags: [tag(.falseBack, 3.6)], to: strokes,
                                 sessionStart: tagBase)
        Check.equal(r.label(forStroke: 2), .falseBack, "claimed by the earlier stroke")
        Check.isTrue(r.label(forStroke: 3) == nil, "stroke 3 stays untagged")
    }

    test("but a tap right on top of the next stroke does go forward") {
        // The bias is a lean, not a rule. 4.1 s corrects back to 3.85, which is
        // 0.22 s ahead of stroke 3 and a full second behind stroke 2 — the
        // tagger was early, not late.
        let r = TagMatcher.match(tags: [tag(.falseForward, 4.1)], to: strokes,
                                 sessionStart: tagBase)
        Check.equal(r.label(forStroke: 3), .falseForward, "claimed by the later stroke")
        Check.isTrue(r.label(forStroke: 2) == nil, "stroke 2 stays untagged")
    }

    test("at false-casting tempo, a lagged tap doesn't steal the next stroke") {
        // The case that motivates lag correction, taken from cast2.csv: strokes
        // ~0.65 s long with ~0.33 s between them — a shorter gap than a human
        // reaction. Tapping 0.35 s after each stroke ends puts every tap
        // physically *inside* the following stroke, which a nearest-in-time
        // match would score as a perfect hit and shift every label by one.
        var fast = quiet(from: 0, to: 0.5)
        var ends: [Double] = []
        for k in 0..<4 {
            let start = 0.5 + Double(k) * 0.98
            fast += tagStroke(at: start, duration: 0.65, peakDPS: 480)
            fast += quiet(from: start + 0.65, to: start + 0.98)
            ends.append(start + 0.65)
        }
        let fastStrokes = StrokeAnalyzer.analyze(fast)
        Check.equal(fastStrokes.count, 4, "strokes in the fast fixture")

        let labels: [StrokeLabel] = [.pickup, .falseBack, .falseForward, .delivery]
        let taps = zip(labels, ends).map { tag($0.0, $0.1 + 0.35) }
        let r = TagMatcher.match(tags: taps, to: fastStrokes, sessionStart: tagBase)

        Check.equal(r.matches.count, 4, "matches")
        Check.equal(r.unmatched.count, 0, "unmatched")
        Check.equal((1...4).compactMap { r.label(forStroke: $0) }, labels,
                    "labels stayed on their own strokes")
    }

    test("the median offset reports how far the tagger actually trailed") {
        let taps = [tag(.pickup, 1.8), tag(.falseBack, 3.3), tag(.falseForward, 4.8)]
        let r = TagMatcher.match(tags: taps, to: strokes, sessionStart: tagBase)
        guard let m = Check.notNil(r.medianOffset, "median offset") else { return }
        // Each tap is 0.448 s past its detected stroke end.
        Check.close(m, 0.45, 0.03, "median offset")
    }

    test("a tap nowhere near a stroke is reported, not forced onto one") {
        let r = TagMatcher.match(tags: [tag(.delivery, 0.2)], to: strokes,
                                 sessionStart: tagBase)
        Check.equal(r.matches.count, 0, "matches")
        Check.equal(r.unmatched.count, 1, "unmatched")
        Check.isTrue(r.unmatched.first?.reason.contains("no stroke") ?? false,
                     "reason names the cause")
    }

    test("a double tap can't overwrite the neighbouring stroke") {
        // Two taps in stroke 1's window. One wins; the other is surfaced rather
        // than sliding onto stroke 2 and shifting every label after it.
        let r = TagMatcher.match(tags: [tag(.pickup, 1.5), tag(.falseBack, 1.55)],
                                 to: strokes, sessionStart: tagBase)
        Check.equal(r.matches.count, 1, "matches")
        Check.equal(r.unmatched.count, 1, "unmatched")
        Check.isTrue(r.label(forStroke: 2) == nil, "stroke 2 untouched")
    }

    test("no tags means no matches and no complaints") {
        let r = TagMatcher.match(tags: [], to: strokes, sessionStart: tagBase)
        Check.isTrue(r.isEmpty, "result is empty")
    }

    test("tags with no strokes are all reported") {
        let r = TagMatcher.match(tags: [tag(.pickup, 1.0)], to: [], sessionStart: tagBase)
        Check.equal(r.unmatched.count, 1, "unmatched")
    }

    print("")
    print("Label grouping")

    test("strokes bucket by label in cast order") {
        let taps = [tag(.pickup, 1.8), tag(.falseBack, 3.3),
                    tag(.falseBack, 4.8), tag(.delivery, 6.3)]
        let r = TagMatcher.match(tags: taps, to: strokes, sessionStart: tagBase)
        let groups = SessionStats.byLabel(strokes, r)

        Check.equal(groups.count, 3, "groups")
        Check.equal(groups.map(\.label), [.pickup, .falseBack, .delivery], "cast order")
        Check.equal(groups[1].count, 2, "two false backs")
        // False forward was never tapped, so it isn't a group at all.
        Check.isFalse(groups.contains { $0.label == .falseForward }, "no empty groups")
    }

    test("untagged strokes are listed only when something was tagged") {
        let r = TagMatcher.match(tags: [tag(.pickup, 1.8)], to: strokes,
                                 sessionStart: tagBase)
        Check.equal(SessionStats.untagged(strokes, r).count, 3, "untagged strokes")

        // An entirely untagged session isn't "3 strokes you forgot" — it's a
        // session nobody was tagging, and shouldn't nag.
        Check.equal(SessionStats.untagged(strokes, .none).count, 0, "no tagger at all")
    }

    test("a group's repeatability is computed over its own strokes only") {
        let taps = [tag(.falseBack, 1.8), tag(.falseBack, 3.3), tag(.falseBack, 4.8)]
        let r = TagMatcher.match(tags: taps, to: strokes, sessionStart: tagBase)
        guard let g = Check.notNil(SessionStats.byLabel(strokes, r).first, "group") else { return }
        Check.equal(g.count, 3, "members")
        guard let cv = Check.notNil(g.repeatabilityCV, "repeatability") else { return }
        // The fixture's strokes are identical by construction, so a group of
        // them must come out near-perfectly repeatable.
        Check.isTrue(cv < 5, "identical strokes should read as consistent, got \(cv)")
    }
}
