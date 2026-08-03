import Foundation
import CastrCore
import CastrBLE

// MARK: - Argument parsing

let options: Options
do {
    options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    Term.log("castr-collect: \(error)")
    exit(2)
}

if options.showHelp {
    print(Options.usage)
    exit(0)
}

// MARK: - Replay mode (no Bluetooth, no hardware)

if let replayPath = options.replayPath {
    guard let text = try? String(contentsOfFile: replayPath, encoding: .utf8) else {
        Term.log("castr-collect: \(CLIError.fileNotFound(replayPath))")
        exit(2)
    }

    let bytes = SyntheticSource.bytes(fromHex: text)
    Term.log("Replaying \(bytes.count) bytes from \(replayPath)")

    let url = options.outputPath.map { URL(fileURLWithPath: $0) } ?? Options.defaultOutputURL()
    let writer: CSVWriter
    do {
        writer = try CSVWriter(url: url, deviceName: "replay")
    } catch {
        Term.log("castr-collect: \(error)")
        exit(1)
    }

    var parser = FrameParser()
    // Feed in 20-byte chunks so the replay exercises the same incremental,
    // split-across-packets path that real BLE notifications take.
    var offset = 0
    let chunkSize = 20
    let start = Date()
    while offset < bytes.count {
        let end = min(offset + chunkSize, bytes.count)
        let chunk = Array(bytes[offset..<end])
        // Space timestamps at a nominal 200 Hz so the CSV looks like a real session.
        let time = start.addingTimeInterval(Double(offset / chunkSize) / 200.0)
        writer.write(parser.feed(chunk, at: time))
        offset = end
    }
    writer.close()

    let stats = parser.stats
    Term.log("Parsed \(stats.accepted) frames "
             + "(rejected \(stats.rejected), stray bytes \(stats.skippedBytes))")
    Term.log("Wrote \(writer.rowsWritten) rows to \(url.path)")
    exit(stats.accepted > 0 ? 0 : 1)
}

// MARK: - Live capture

let collector = Collector(options: options)

// Handle Ctrl-C so the CSV gets flushed and closed rather than truncated.
// signal() is ignored and the work happens on a dispatch source, since almost
// nothing is safe to call from a real signal handler.
signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler { collector.finish(reason: "interrupted") }
interrupt.resume()

signal(SIGTERM, SIG_IGN)
let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminate.setEventHandler { collector.finish(reason: "terminated") }
terminate.resume()

collector.start()
RunLoop.main.run()
