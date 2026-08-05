import Foundation

/// Binds taps to detected strokes.
///
/// A tap is not a measurement of when something happened. The tagger watches the
/// stroke, recognises it, then presses — a few hundred milliseconds of human
/// latency — so the raw timestamp usually lands *after* the stroke it refers to,
/// and in a fast false-casting rhythm it can land inside the next one. Treating
/// that time as exact would mislabel strokes systematically.
///
/// So matching snaps each tap to a stroke rather than slicing the session at it,
/// and the window is asymmetric: a tap well after a stroke is the ordinary case,
/// while a tap *before* a stroke means the tagger predicted it, which is rare.
/// The raw time is still kept — `Match.offset` is how far the tap trailed the
/// stroke, which is worth watching, because a drifting offset means the tagger
/// is falling behind and the labels are about to slip by one.
public enum TagMatcher {

    public struct Settings {
        /// Assumed delay between the stroke and the tap, subtracted from every
        /// tap before matching.
        ///
        /// This is not a nicety. At false-casting tempo a stroke runs ~0.6 s
        /// with ~0.3 s between strokes, which is *shorter* than the tagger's
        /// reaction time — so an uncorrected tap frequently lands inside the
        /// following stroke, where a nearest-in-time match scores it as a
        /// perfect hit and mislabels the pair. Shifting the tap back by the
        /// expected lag first is what makes tagging survive a real rhythm.
        public var reactionLag: TimeInterval = 0.25
        /// How long after a stroke ends a corrected tap can still refer to it.
        public var lookBack: TimeInterval = 1.0
        /// How far before a stroke *starts* a corrected tap can still refer to
        /// it. Small: a tap that early is ahead of the movement entirely.
        public var lookAhead: TimeInterval = 0.4
        /// How much more expensive it is to tag a stroke that hadn't finished
        /// than one that had, per second. Taps aimed at a stroke still in
        /// progress happen — a tagger who sees the stop coming — but they're
        /// the exception, so they lose a tie against a stroke that has ended.
        public var anticipationPenalty: Double = 1.5

        public init() {}
    }

    /// A tap bound to a stroke.
    public struct Match: Equatable {
        /// Matches `StrokeMetrics.index` — 1-based, as the report prints it.
        public let strokeIndex: Int
        public let label: StrokeLabel
        /// Seconds from the start of the session, as tapped — uncorrected.
        public let tapTime: TimeInterval
        /// Raw tap − stroke end, before any lag correction. Positive is the
        /// normal case: the tagger reacted. This is the number to look at when
        /// deciding whether `Settings.reactionLag` suits a particular tagger.
        public let offset: TimeInterval
    }

    /// A tap no stroke could claim. Surfaced rather than dropped: a run of these
    /// is the signal that tagging and casting came apart.
    public struct Unmatched: Equatable {
        public let label: StrokeLabel
        public let tapTime: TimeInterval
        public let reason: String
    }

    public struct Result {
        public let matches: [Match]
        public let unmatched: [Unmatched]

        public static let none = Result(matches: [], unmatched: [])

        public var isEmpty: Bool { matches.isEmpty && unmatched.isEmpty }

        public func match(forStroke index: Int) -> Match? {
            matches.first { $0.strokeIndex == index }
        }

        public func label(forStroke index: Int) -> StrokeLabel? {
            match(forStroke: index)?.label
        }

        public func count(of label: StrokeLabel) -> Int {
            matches.reduce(0) { $0 + ($1.label == label ? 1 : 0) }
        }

        /// Per-label counts in cast order, e.g. `pickup 3, false back 12`.
        public var summary: String {
            StrokeLabel.allCases
                .compactMap { l in count(of: l) > 0 ? "\(l.name) \(count(of: l))" : nil }
                .joined(separator: ", ")
        }

        /// Typical raw lag between a stroke ending and its tap arriving.
        ///
        /// Median rather than mean: one tap the tagger fumbled shouldn't move
        /// the figure. Worth reading — if this is far from the `reactionLag`
        /// used to match, the labels were assigned against the wrong assumption
        /// and re-running with `--lag` set near it will do better.
        public var medianOffset: TimeInterval? {
            guard !matches.isEmpty else { return nil }
            let sorted = matches.map(\.offset).sorted()
            let mid = sorted.count / 2
            return sorted.count % 2 == 1
                ? sorted[mid]
                : (sorted[mid - 1] + sorted[mid]) / 2
        }
    }

    /// Cost of claiming a lag-corrected `tap` for a stroke spanning
    /// `start...end`, or nil if it's out of range entirely.
    ///
    /// Distance is measured to the stroke's **end**, not to the nearest point of
    /// its span. What a tagger reacts to is the stroke *finishing*, so that's
    /// the instant the tap is aimed at — and scoring the whole span as an equal
    /// hit gets this wrong whenever strokes run back to back, which they do at
    /// tempo. In `cast2.csv` stroke 3 ends 5 ms before stroke 4 begins; a tap
    /// half a second into that long stroke 4 belongs to stroke 3, and only an
    /// end-referenced distance says so.
    ///
    /// Reversal splitting made this stricter, not looser: a back cast and the
    /// forward cast after it are cut at one shared sample, so the pair is 5 ms
    /// apart by construction. Adjacency is now the normal case, not the corner.
    static func cost(tap: TimeInterval, start: TimeInterval, end: TimeInterval,
                     _ s: Settings) -> TimeInterval? {
        let d = tap - end
        if d >= 0 { return d <= s.lookBack ? d : nil }
        // Corrected to before the stroke finished: the tagger anticipated the
        // stop. Plausible while the stroke is under way, not before it starts.
        guard tap >= start - s.lookAhead else { return nil }
        return -d * s.anticipationPenalty
    }

    public static func match(tags: [CastTag],
                             to strokes: [StrokeMetrics],
                             sessionStart: Date,
                             settings: Settings = Settings()) -> Result {
        guard !tags.isEmpty else { return .none }

        let taps = tags
            .map { (label: $0.label, t: $0.timestamp.timeIntervalSince(sessionStart)) }
            .sorted { $0.t < $1.t }

        guard !strokes.isEmpty else {
            return Result(matches: [], unmatched: taps.map {
                Unmatched(label: $0.label, tapTime: $0.t,
                          reason: "no strokes were detected at all")
            })
        }

        // Every tap/stroke pairing the windows allow, cheapest first. Matching
        // runs on the lag-corrected time; the raw time is kept for reporting.
        struct Candidate { let tap: Int; let stroke: Int; let cost: TimeInterval }
        var candidates: [Candidate] = []
        for (ti, tap) in taps.enumerated() {
            let corrected = tap.t - settings.reactionLag
            for (si, m) in strokes.enumerated() {
                if let c = cost(tap: corrected, start: m.startTime,
                                end: m.startTime + m.duration, settings) {
                    candidates.append(Candidate(tap: ti, stroke: si, cost: c))
                }
            }
        }
        // Assign greedily from the cheapest pairing outwards. A stroke takes one
        // label and a tap goes to one stroke, so a double-tap can't quietly
        // overwrite the neighbouring stroke's label — the surplus tap is
        // reported instead.
        candidates.sort { $0.cost == $1.cost ? $0.tap < $1.tap : $0.cost < $1.cost }

        var tapToStroke = [Int: Int]()
        var strokeToTap = [Int: Int]()
        for c in candidates where tapToStroke[c.tap] == nil && strokeToTap[c.stroke] == nil {
            tapToStroke[c.tap] = c.stroke
            strokeToTap[c.stroke] = c.tap
        }

        var matches: [Match] = []
        var unmatched: [Unmatched] = []
        let hadCandidate = Set(candidates.map(\.tap))

        for (ti, tap) in taps.enumerated() {
            guard let si = tapToStroke[ti] else {
                let reason = hadCandidate.contains(ti)
                    ? "every stroke near it was already tagged"
                    : String(format: "no stroke ended in the %.1fs before it",
                             settings.lookBack + settings.reactionLag)
                unmatched.append(Unmatched(label: tap.label, tapTime: tap.t, reason: reason))
                continue
            }
            let m = strokes[si]
            matches.append(Match(strokeIndex: m.index,
                                 label: tap.label,
                                 tapTime: tap.t,
                                 offset: tap.t - (m.startTime + m.duration)))
        }

        return Result(matches: matches.sorted { $0.strokeIndex < $1.strokeIndex },
                      unmatched: unmatched)
    }
}

// MARK: - Grouping by label

/// The strokes of one kind, and how alike they are.
public struct LabelGroup {
    public let label: StrokeLabel
    public let strokes: [StrokeMetrics]

    public var count: Int { strokes.count }
    public var spreads: [Spread] { SessionStats.spreads(strokes) }
    public var repeatabilityCV: Double? { SessionStats.repeatabilityCV(strokes) }

    public func spread(_ name: String) -> Spread? {
        spreads.first { $0.name == name }
    }
}

public extension SessionStats {
    /// Strokes bucketed by label, in the order a cast sequence runs.
    ///
    /// This is the point of tagging. A session-wide repeatability figure mixes
    /// pickups, false casts and the delivery — genuinely different movements —
    /// so it reads as inconsistency the caster doesn't have. Compared against
    /// their own kind, each group's spread means something.
    static func byLabel(_ strokes: [StrokeMetrics],
                        _ tags: TagMatcher.Result) -> [LabelGroup] {
        StrokeLabel.allCases.compactMap { label in
            let members = strokes.filter { tags.label(forStroke: $0.index) == label }
            return members.isEmpty ? nil : LabelGroup(label: label, strokes: members)
        }
    }

    /// Strokes no tap claimed. Empty when nothing was tagged at all, so callers
    /// can treat "untagged session" and "session with gaps" differently.
    static func untagged(_ strokes: [StrokeMetrics],
                         _ tags: TagMatcher.Result) -> [StrokeMetrics] {
        guard !tags.matches.isEmpty else { return [] }
        return strokes.filter { tags.label(forStroke: $0.index) == nil }
    }
}
