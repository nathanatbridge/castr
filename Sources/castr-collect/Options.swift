import Foundation
import CastrBLE

struct Options {
    var outputPath: String?
    var rawMode = false
    var listAll = false
    var replayPath: String?
    var rate: OutputRate?
    var deviceName: String?
    var duration: TimeInterval?
    var checkMode = false
    var showHelp = false

    static let usage = """
    castr-collect — record WT901BLE motion data to CSV

    USAGE:
      castr-collect [options]

    OPTIONS:
      -o, --out <path>     Write CSV here (default: ./CastR_<timestamp>.csv)
          --check          Health check: leave the sensor still for 15s and this
                           reports whether it reads the 1.000 g it must at rest.
                           Run this before trusting any session.
          --raw            Hex-dump packets instead of parsing. Bring-up step 2:
                           confirms the sensor really sends 20-byte 55 61 frames.
          --any            List every BLE peripheral, not just WitMotion ones.
                           Bring-up step 1: find the real advertised name.
          --replay <file>  Feed a hex fixture through the parser instead of
                           connecting. Tests the full pipeline with no hardware.
          --rate <hz>      Set sensor output rate (10|20|50|100|200) and save it.
          --device <name>  Only connect to a device whose name contains this.
          --seconds <n>    Stop automatically after n seconds.
      -h, --help           Show this message.

    EXAMPLES:
      castr-collect --any                    # what is my sensor called?
      castr-collect --raw                    # what do its packets look like?
      castr-collect --check                  # is it reading correctly?
      castr-collect -o backyard.csv          # record until Ctrl-C
      castr-collect --replay fixture.hex -o synthetic.csv

    Recording streams to disk continuously — the CSV is valid even if this
    process is killed mid-session.
    """

    static func parse(_ args: [String]) throws -> Options {
        var options = Options()
        var index = 0

        func next(_ flag: String) throws -> String {
            index += 1
            guard index < args.count else { throw CLIError.missingValue(flag) }
            return args[index]
        }

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-o", "--out":     options.outputPath = try next(arg)
            case "--raw":           options.rawMode = true
            case "--any":           options.listAll = true
            case "--check":         options.checkMode = true
            case "--replay":        options.replayPath = try next(arg)
            case "--device":        options.deviceName = try next(arg)
            case "--seconds":
                let value = try next(arg)
                guard let seconds = TimeInterval(value), seconds > 0 else {
                    throw CLIError.badValue(arg, value)
                }
                options.duration = seconds
            case "--rate":
                let value = try next(arg)
                guard let hz = Int(value), let rate = OutputRate(rawValue: hz) else {
                    throw CLIError.badValue(arg, value)
                }
                options.rate = rate
            case "-h", "--help":    options.showHelp = true
            default:
                throw CLIError.unknownFlag(arg)
            }
            index += 1
        }
        return options
    }

    /// Default output path, used when `--out` is omitted.
    static func defaultOutputURL() -> URL {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("CastR_\(stamp.string(from: Date())).csv")
    }
}

enum CLIError: Error, CustomStringConvertible {
    case unknownFlag(String)
    case missingValue(String)
    case badValue(String, String)
    case fileNotFound(String)

    var description: String {
        switch self {
        case .unknownFlag(let f):     return "unknown option '\(f)' (try --help)"
        case .missingValue(let f):    return "option '\(f)' needs a value"
        case .badValue(let f, let v): return "invalid value '\(v)' for '\(f)'"
        case .fileNotFound(let p):    return "no such file: \(p)"
        }
    }
}
