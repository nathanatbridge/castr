import Foundation
import CastrCore

let usage = """
castr-analyze — turn a recording into per-stroke casting metrics

USAGE:
  castr-analyze <session.csv> [options]

OPTIONS:
      --compare <other.csv>  Analyse a second session and report the difference
      --json                 Emit machine-readable JSON instead of a report
      --events <path>        Stroke tags to use (default: <session>.events.csv)
      --no-events            Ignore stroke tags even if a sidecar is there
      --lag <seconds>        Tagger's reaction delay, corrected out (default 0.25)
      --enter <°/s>          Rotation rate that opens a stroke (default 60)
      --exit <°/s>           Rotation rate that closes a stroke (default 25)
      --min <seconds>        Discard strokes shorter than this (default 0.08)
  -h, --help                 Show this message

WHAT IT MEASURES

  Arc swept     how far the rod turned, start to finish
  Peak rate     fastest rotation reached, and where in the stroke it fell
  Stop decel    how hard the rod was stopped — what unloads it
  Stop share    portion of the stroke spent stopping; crisp stops are small
  Planarity     how much of the rotation stayed in one plane
  Repeatability spread of the above across strokes, as one figure

Rotation is measured at the handle, so these describe what the caster does,
not where the rod tip goes.

STROKE TAGS

If someone tagged the session live (castr-collect writes <session>.events.csv,
as does the iOS app), each kind of stroke is also reported against its own
kind. That matters: pickups, false casts and the delivery are different
movements, so one session-wide repeatability figure understates a caster who
is perfectly consistent within each.
"""

struct Args {
    var path: String?
    var compare: String?
    var json = false
    var detector = StrokeDetector()
    var eventsPath: String?
    var useEvents = true
    var tagging = TagMatcher.Settings()
    var help = false
}

func parseArgs(_ argv: [String]) -> Args? {
    var a = Args()
    var i = 0
    func next(_ flag: String) -> String? {
        i += 1
        return i < argv.count ? argv[i] : nil
    }
    while i < argv.count {
        let arg = argv[i]
        if arg.hasPrefix("#") { break }
        switch arg {
        case "-h", "--help": a.help = true
        case "--json":       a.json = true
        case "--no-events":  a.useEvents = false
        case "--compare":
            guard let v = next(arg) else { return nil }
            a.compare = v
        case "--events":
            guard let v = next(arg) else { return nil }
            a.eventsPath = v
        case "--lag":
            guard let v = next(arg), let d = Double(v), d >= 0 else { return nil }
            a.tagging.reactionLag = d
        case "--enter":
            guard let v = next(arg), let d = Double(v) else { return nil }
            a.detector.enterDPS = d
        case "--exit":
            guard let v = next(arg), let d = Double(v) else { return nil }
            a.detector.exitDPS = d
        case "--min":
            guard let v = next(arg), let d = Double(v) else { return nil }
            a.detector.minDuration = d
        default:
            if arg.hasPrefix("-") { return nil }
            a.path = arg
        }
        i += 1
    }
    return a
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("castr-analyze: " + message + "\n").utf8))
    exit(1)
}

guard let args = parseArgs(Array(CommandLine.arguments.dropFirst())) else {
    fail("bad arguments (try --help)")
}
if args.help { print(usage); exit(0) }
guard let path = args.path else { print(usage); exit(2) }

func load(_ p: String) -> CSVReader.Session {
    do { return try CSVReader.read(contentsOf: URL(fileURLWithPath: p)) }
    catch { fail("\(error)") }
}

/// Finds and binds the tag sidecar for a session.
///
/// An explicitly named `--events` file that doesn't exist is an error — you
/// asked for it. A missing sidecar next to the CSV is not: most sessions have
/// no tagger, and that's the normal case, not a problem to report.
func loadTags(for csvPath: String, strokes: [StrokeMetrics],
              sessionStart: Date, explicit: String?) -> TagMatcher.Result {
    guard args.useEvents else { return .none }

    let url: URL
    if let explicit {
        url = URL(fileURLWithPath: explicit)
        guard FileManager.default.fileExists(atPath: url.path) else {
            fail("no such events file: \(explicit)")
        }
    } else {
        url = EventLog.sidecarURL(for: URL(fileURLWithPath: csvPath))
        guard FileManager.default.fileExists(atPath: url.path) else { return .none }
    }

    do {
        let tags = try EventLogReader.read(contentsOf: url)
        return TagMatcher.match(tags: tags, to: strokes, sessionStart: sessionStart,
                                settings: args.tagging)
    } catch {
        // Never let a bad annotation cost you the analysis of good sensor data.
        FileHandle.standardError.write(
            Data("castr-analyze: ignoring events file — \(error)\n".utf8))
        return .none
    }
}

let session = load(path)
let strokes = StrokeAnalyzer.analyze(session.readings, detector: args.detector)
let tags = loadTags(for: path, strokes: strokes,
                    sessionStart: session.readings.first?.timestamp ?? Date(),
                    explicit: args.eventsPath)

var other: CSVReader.Session? = nil
var otherStrokes: [StrokeMetrics] = []
var otherTags = TagMatcher.Result.none
if let c = args.compare {
    let s = load(c)
    other = s
    otherStrokes = StrokeAnalyzer.analyze(s.readings, detector: args.detector)
    // The comparison session gets its own sidecar; --events applies to the
    // primary one only, so there's no ambiguity about which file it names.
    otherTags = loadTags(for: c, strokes: otherStrokes,
                         sessionStart: s.readings.first?.timestamp ?? Date(),
                         explicit: nil)
}

if args.json {
    print(Report.json(session: session, strokes: strokes, tags: tags,
                      other: other, otherStrokes: otherStrokes, otherTags: otherTags))
} else {
    Report.text(session: session, strokes: strokes, tags: tags,
                other: other, otherStrokes: otherStrokes, otherTags: otherTags)
}
exit(strokes.isEmpty ? 1 : 0)
