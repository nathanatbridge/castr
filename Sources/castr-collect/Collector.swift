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

        if !options.rawMode && !options.listAll {
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

        if let seconds = options.duration {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.finish(reason: "reached --seconds \(Int(seconds))")
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

        Term.log("  connecting to \(device.name)…")
        session.connect(to: device.peripheral)
        if let rate = options.rate {
            session.setOutputRate(rate)
        }
    }

    func session(_ session: BLESession, didReceive readings: [SensorReading]) {
        lock.lock()
        writer?.write(readings)
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
