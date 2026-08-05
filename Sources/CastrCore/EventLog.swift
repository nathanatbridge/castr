import Foundation

/// The four moments a tagger marks during a cast sequence.
///
/// A fixed set on purpose. Tagging happens in real time while watching someone
/// else cast, so the choice has to be reflexive — four keys, four buttons, no
/// menu. Anything richer belongs in post-processing.
public enum StrokeLabel: String, CaseIterable, Hashable {
    case pickup
    case falseBack
    case falseForward
    case delivery

    /// What gets written to the sidecar, and what's matched when reading it back.
    public var name: String {
        switch self {
        case .pickup:       return "pickup"
        case .falseBack:    return "false back"
        case .falseForward: return "false forward"
        case .delivery:     return "delivery"
        }
    }

    /// Narrow form for report columns.
    public var short: String {
        switch self {
        case .pickup:       return "pickup"
        case .falseBack:    return "f-back"
        case .falseForward: return "f-fwd"
        case .delivery:     return "deliver"
        }
    }

    /// Keys that select this label at the terminal. The digits run in the order a
    /// cast does, so the sequence is 1-2-3-…-4; the letters are there for anyone
    /// who'd rather not count.
    public var keys: [Character] {
        switch self {
        case .pickup:       return ["1", "p"]
        case .falseBack:    return ["2", "b"]
        case .falseForward: return ["3", "f"]
        case .delivery:     return ["4", "d"]
        }
    }

    /// Accepts the written form (`false back`) or the case name (`falseBack`).
    public static func named(_ s: String) -> StrokeLabel? {
        let k = s.trimmingCharacters(in: .whitespaces).lowercased()
        return allCases.first { $0.name == k || $0.rawValue.lowercased() == k }
    }

    public static func forKey(_ c: Character) -> StrokeLabel? {
        let lower = Character(c.lowercased())
        return allCases.first { $0.keys.contains(lower) }
    }

    /// One-line key legend for the terminal.
    public static var keyLegend: String {
        allCases.map { "\($0.keys[0]) \($0.name)" }.joined(separator: "   ")
    }
}

/// One tap: a label and the wall-clock instant the key or button went down.
public struct CastTag: Equatable {
    public let timestamp: Date
    public let label: StrokeLabel

    public init(timestamp: Date, label: StrokeLabel) {
        self.timestamp = timestamp
        self.label = label
    }
}

/// Where tags live and how they're spelled on disk.
///
/// Tags go in a **sidecar** file rather than an extra CSV column. `CSVFormat` is
/// byte-parity with WitMotion's own export — that's the whole reason recordings
/// drop into existing analysis unchanged — and a 22nd column would break it for
/// every consumer that checks the shape of the header. A sidecar also means a
/// session recorded without a tagger produces no stray file at all.
public enum EventLog {
    public static let columns = ["time", "label"]
    public static let header = columns.joined(separator: ",")

    /// `backyard.csv` → `backyard.events.csv`, sitting beside the recording.
    public static func sidecarURL(for csv: URL) -> URL {
        csv.deletingPathExtension().appendingPathExtension("events.csv")
    }

    public static func row(_ tag: CastTag) -> String {
        SensorReading.timestampFormatter.string(from: tag.timestamp) + "," + tag.label.name
    }
}

/// Appends tags to the sidecar as they're pressed.
///
/// Unlike `CSVWriter` this doesn't buffer. Taps arrive a few per second at most,
/// so there's no throughput to win — and a tap is a human action that can't be
/// reconstructed after the fact, unlike a sample, which the next one nearly
/// replaces. Every tag is on disk before the function returns.
public final class EventLogWriter {

    public enum WriterError: Error, CustomStringConvertible {
        case couldNotCreateFile(URL)

        public var description: String {
            switch self {
            case .couldNotCreateFile(let url): return "could not create file at \(url.path)"
            }
        }
    }

    public let url: URL
    public private(set) var tags: [CastTag] = []

    private let handle: FileHandle
    private var isClosed = false

    public init(url: URL) throws {
        self.url = url

        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        guard fm.createFile(atPath: url.path, contents: nil),
              let h = try? FileHandle(forWritingTo: url) else {
            throw WriterError.couldNotCreateFile(url)
        }
        self.handle = h
        append(EventLog.header)
    }

    @discardableResult
    public func record(_ label: StrokeLabel, at when: Date = Date()) -> CastTag {
        let tag = CastTag(timestamp: when, label: label)
        guard !isClosed else { return tag }
        tags.append(tag)
        append(EventLog.row(tag))
        return tag
    }

    public func count(of label: StrokeLabel) -> Int {
        tags.reduce(0) { $0 + ($1.label == label ? 1 : 0) }
    }

    /// Per-label counts in cast order, e.g. `pickup 3   false back 12`.
    public var summary: String {
        StrokeLabel.allCases
            .compactMap { l in count(of: l) > 0 ? "\(l.name) \(count(of: l))" : nil }
            .joined(separator: "   ")
    }

    private func append(_ line: String) {
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        try? handle.close()
    }

    deinit {
        if !isClosed { try? handle.close() }
    }
}

/// Reads a sidecar back.
///
/// Unparseable lines are skipped rather than fatal: the tags are an annotation on
/// the sensor data, and a damaged one shouldn't cost you the session.
public enum EventLogReader {

    public enum ReadError: Error, CustomStringConvertible {
        case unreadable(URL)

        public var description: String {
            switch self {
            case .unreadable(let u): return "could not read \(u.lastPathComponent)"
            }
        }
    }

    public static func read(contentsOf url: URL) throws -> [CastTag] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            throw ReadError.unreadable(url)
        }
        return parse(raw)
    }

    public static func parse(_ text: String) -> [CastTag] {
        var out = [CastTag]()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            let parts = line.split(separator: ",", maxSplits: 1,
                                   omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2,
                  let when = SensorReading.parseTimestamp(
                      parts[0].trimmingCharacters(in: .whitespaces)),
                  let label = StrokeLabel.named(parts[1])
            else { continue }   // header row lands here too, and is meant to
            out.append(CastTag(timestamp: when, label: label))
        }
        return out.sorted { $0.timestamp < $1.timestamp }
    }
}
