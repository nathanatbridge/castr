import Foundation
import CoreBluetooth
import CastrCore
import CastrBLE

/// Terminal output helpers. Status goes to stderr so `--raw` output and any
/// future stdout piping stay clean.
enum Term {
    /// Only emit cursor control when stderr is a real terminal — piped or
    /// redirected output would otherwise be littered with escape sequences.
    static let isTTY = isatty(FileHandle.standardError.fileDescriptor) == 1

    private static var lastStatusWasLive = false

    static func log(_ message: String) {
        if lastStatusWasLive { endStatus() }
        FileHandle.standardError.write(Data(("\(message)\n").utf8))
    }

    static func status(_ message: String) {
        guard isTTY else { return }
        // \u{1B}[2K clears the line so shorter updates don't leave debris.
        FileHandle.standardError.write(Data("\r\u{1B}[2K\(message)".utf8))
        lastStatusWasLive = true
    }

    static func endStatus() {
        guard lastStatusWasLive else { return }
        lastStatusWasLive = false
        FileHandle.standardError.write(Data("\n".utf8))
    }
}

/// Connects to the sensor, streams readings to a CSV, and prints live status.
final class Collector: NSObject {

    private let options: Options
    private let session = BLESession()
    private var writer: CSVWriter?
    private var statusTimer: Timer?

    private let lock = NSLock()
    private var totalSamples = 0
    private var windowSamples = 0
    private var windowStart = Date()
    private var currentRate: Double = 0
    private var latest: SensorReading?
    private var statusLine = "starting up…"
    private var rawPackets = 0
    private var ticks = 0
    /// Retained only in --check mode; a 15s window at 200 Hz is ~3000 samples.
    private var checkSamples: [SensorReading] = []
    private var didStartConnecting = false

    private var didFinish = false

    init(options: Options) {
        self.options = options
        super.init()
        session.delegate = self
        session.reportAllDevices = options.listAll
    }

    func start() {
        if options.listAll {
            Term.log("Listing every BLE peripheral in range. Ctrl-C to stop.")
            Term.log("Look for your sensor's name, and whether it advertises FFE5.\n")
        }

        if options.checkMode {
            Term.log("""
                Health check — leave the sensor completely still on a flat surface.
                Measuring for \(Int(options.duration ?? 15)) seconds…
                """)
        }

        if !options.rawMode && !options.listAll && !options.checkMode {
            let url = options.outputPath.map { URL(fileURLWithPath: $0) }
                ?? Options.defaultOutputURL()
            do {
                writer = try CSVWriter(url: url, deviceName: "WT901BLE")
                Term.log("Recording to \(url.path)")
            } catch {
                Term.log("error: \(error)")
                exit(1)
            }
        }

        if let rate = options.rate {
            Term.log("Will set output rate to \(rate.rawValue) Hz once connected.")
        }

        // --check is time-boxed by definition; --seconds overrides the default.
        let limit = options.duration ?? (options.checkMode ? 15 : nil)
        if let seconds = limit {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.finish(reason: "reached \(Int(seconds))s limit")
            }
        }

        startStatusTimer()
        session.startScan()
    }

    private func startStatusTimer() {
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    private func tick() {
        lock.lock()
        let elapsed = Date().timeIntervalSince(windowStart)
        if elapsed >= 1.0 {
            currentRate = Double(windowSamples) / elapsed
            windowSamples = 0
            windowStart = Date()
        }
        let total = totalSamples
        let rate = currentRate
        let reading = latest
        let line = statusLine
        let raw = rawPackets
        lock.unlock()

        let rejected = session.parserStats.rejected

        // With no terminal there's no live status line, so emit a periodic
        // heartbeat instead — otherwise a redirected run looks hung.
        ticks += 1
        if !Term.isTTY {
            guard ticks % 25 == 0 else { return }
            Term.log(options.rawMode
                     ? "\(line)  packets \(raw)  frames \(total)  rejected \(rejected)"
                     : String(format: "%@  %d samples  %.0f Hz  rejected %d",
                              line, total, rate, rejected))
            return
        }

        if options.listAll {
            Term.status(line)
            return
        }

        if options.rawMode {
            Term.status("\(line)   packets \(raw)   frames \(total)   rejected \(rejected)")
            return
        }

        var parts = [line]
        if total > 0 {
            parts.append(String(format: "%d samples", total))
            parts.append(String(format: "%.0f Hz", rate))
            if let r = reading {
                parts.append(String(format: "acc % .2f % .2f % .2f (|%.2f|g)",
                                    r.accX, r.accY, r.accZ, r.accMagnitude))
            }
            // Surfaced always, not just when nonzero — a rising count is the
            // signal that framing has gone wrong and the CSV is untrustworthy.
            parts.append("rejected \(rejected)")
        }
        Term.status(parts.joined(separator: "   "))
    }

    private func reportHealthCheck(rejected: Int) {
        lock.lock()
        let samples = checkSamples
        lock.unlock()

        guard let r = StaticCheck.evaluate(samples, rejectedFrames: rejected) else {
            Term.log("\nNo data received — the sensor never streamed. "
                     + "Run --any to confirm it's advertising.")
            exit(1)
        }

        let mark: (StaticCheck.Verdict) -> String = { v in
            switch v {
            case .pass: return "ok  "
            case .warn: return "warn"
            case .fail: return "FAIL"
            }
        }

        Term.log("")
        Term.log("  samples          \(r.sampleCount) over \(String(format: "%.1f", r.duration))s"
                 + "  (\(String(format: "%.0f", r.effectiveRateHz)) Hz)")
        Term.log("  [\(mark(r.stillness))] stillness    gyro mean "
                 + String(format: "%.2f", r.gyroMeanMagnitude) + " °/s, peak "
                 + String(format: "%.2f", r.gyroMaxMagnitude) + " °/s")
        Term.log("  [\(mark(r.calibration))] gravity      |acc| median "
                 + String(format: "%.3f", r.medianAccMagnitude) + " g  ("
                 + String(format: "%+.1f", r.calibrationErrorPercent) + "% vs 1.000 g)")
        Term.log("       axes         X " + String(format: "%+.3f", r.meanAccX)
                 + "  Y " + String(format: "%+.3f", r.meanAccY)
                 + "  Z " + String(format: "%+.3f", r.meanAccZ))
        Term.log("  [\(mark(rejected == 0 ? .pass : .warn))] framing      "
                 + "\(rejected) rejected frames")
        Term.log("")

        switch r.overall {
        case .pass:
            Term.log("  PASS — sensor is reading correctly. Good to record.")
        case .warn:
            Term.log("  WARN — usable, but check the flagged lines above.")
        case .fail:
            if r.stillness == .fail {
                Term.log("  FAIL — the sensor was moving, so gravity couldn't be measured.")
                Term.log("         Put it flat on a table, don't touch it, and rerun.")
            } else {
                Term.log("  FAIL — at rest this must read 1.000 g and it doesn't.")
                Term.log("         Absolute acceleration from this sensor is not")
                Term.log("         trustworthy until it's recalibrated. Run the")
                Term.log("         acceleration calibration in the WitMotion app,")
                Term.log("         leave the sensor still while it runs, then recheck.")
                Term.log("         (The Feb 2025 oven session read 1.756 g like this.)")
            }
        }
        exit(r.overall == .fail ? 1 : 0)
    }

    /// Idempotent shutdown: flush and close the CSV, then exit.
    func finish(reason: String) {
        guard !didFinish else { return }
        didFinish = true

        statusTimer?.invalidate()
        session.disconnect()
        Term.endStatus()

        lock.lock()
        let w = writer
        writer = nil
        let total = totalSamples
        lock.unlock()

        w?.close()

        let stats = session.parserStats

        if options.checkMode {
            reportHealthCheck(rejected: stats.rejected)
            return
        }

        Term.log("Stopped (\(reason)).")

        if let url = w?.url {
            Term.log("Wrote \(total) samples to \(url.path)")
        }
        if !options.listAll {
            Term.log("Frames accepted \(stats.accepted), rejected \(stats.rejected), "
                     + "stray bytes \(stats.skippedBytes)")
            if stats.rejected > 0 {
                Term.log("note: rejected frames are non-zero — run --raw to check framing.")
            }
        }
        exit(0)
    }
}

// MARK: - BLESessionDelegate

extension Collector: BLESessionDelegate {
    func session(_ session: BLESession, didChange state: BLEState) {
        lock.lock()
        statusLine = state.description
        lock.unlock()

        switch state {
        case .unauthorized:
            Term.log("""

                Bluetooth permission was denied.
                Grant it in System Settings → Privacy & Security → Bluetooth,
                enabling the terminal app you're running this from, then retry.
                """)
            exit(1)
        case .unsupported:
            Term.log("\nThis machine reports no Bluetooth LE support.")
            exit(1)
        case .poweredOff:
            Term.log("Bluetooth is off — turn it on and this will start scanning.")
        default:
            break
        }
    }

    func session(_ session: BLESession, didDiscover device: DiscoveredDevice) {
        let service = device.advertisedService ? "advertises FFE5" : "no FFE5 in advert"
        Term.endStatus()
        Term.log(String(format: "  found: %@  (rssi %d, %@)",
                        device.name, device.rssi, service))

        guard !options.listAll else { return }

        if let filter = options.deviceName,
           !device.name.lowercased().contains(filter.lowercased()) {
            return
        }

        // Discoveries already queued before stopScan() takes effect would
        // otherwise each fire a connect, and the last one would win — silently
        // attaching to whichever device happened to be reported last.
        lock.lock()
        let alreadyConnecting = didStartConnecting
        didStartConnecting = true
        lock.unlock()
        guard !alreadyConnecting else { return }

        Term.log("  connecting to \(device.name)…")
        session.connect(to: device.peripheral)
        if let rate = options.rate {
            session.setOutputRate(rate)
        }
    }

    func session(_ session: BLESession, didReceive readings: [SensorReading]) {
        lock.lock()
        writer?.write(readings)
        if options.checkMode { checkSamples.append(contentsOf: readings) }
        totalSamples += readings.count
        windowSamples += readings.count
        latest = readings.last
        lock.unlock()
    }

    func session(_ session: BLESession, didReceiveRawPacket bytes: [UInt8]) {
        guard options.rawMode else { return }
        lock.lock()
        rawPackets += 1
        let count = rawPackets
        lock.unlock()

        Term.endStatus()
        Term.log(String(format: "[%4d] %2d bytes  %@",
                        count, bytes.count, SyntheticSource.hexString(bytes)))
    }
}
