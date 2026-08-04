import Foundation
import CastrCore

let usage = """
castr-analyze — turn a recording into per-stroke casting metrics

USAGE:
  castr-analyze <session.csv> [options]

OPTIONS:
      --compare <other.csv>  Analyse a second session and report the difference
      --json                 Emit machine-readable JSON instead of a report
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
"""

struct Args {
    var path: String?
    var compare: String?
    var json = false
    var detector = StrokeDetector()
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
        case "--compare":
            guard let v = next(arg) else { return nil }
            a.compare = v
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

let session = load(path)
let strokes = StrokeAnalyzer.analyze(session.readings, detector: args.detector)

var other: CSVReader.Session? = nil
var otherStrokes: [StrokeMetrics] = []
if let c = args.compare {
    let s = load(c)
    other = s
    otherStrokes = StrokeAnalyzer.analyze(s.readings, detector: args.detector)
}

if args.json {
    print(Report.json(session: session, strokes: strokes,
                      other: other, otherStrokes: otherStrokes))
} else {
    Report.text(session: session, strokes: strokes,
                other: other, otherStrokes: otherStrokes)
}
exit(strokes.isEmpty ? 1 : 0)
