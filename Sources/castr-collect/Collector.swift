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
    private var events: EventLogWriter?
    private var tagger: KeyTagger?
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
    private var saturation = SaturationCounter()
    private lazy var glitches = GlitchFilter(dropsGlitches: options.despike)
    private var tagTotal = 0
    private var lastTag: (label: StrokeLabel, at: Date)?
    private var didStartConnecting = false
    private var didArmCheckTimer = false

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
            startTagging(alongside: url)
        }

        if let rate = options.rate {
            Term.log("Will set output rate to \(rate.rawValue) Hz once connected.")
        }

        // --check measures a window of *data*, so its clock starts on the first
        // sample rather than at launch — scanning and connecting can eat several
        // seconds, which would otherwise silently shorten the measurement.
        if !options.checkMode, let seconds = options.duration {
            armStopTimer(after: seconds)
        }

        startStatusTimer()
        session.startScan()
    }

    /// Opens the tag sidecar and starts listening for keys.
    ///
    /// Best-effort throughout: a terminal that can't be reconfigured, or a
    /// sidecar that can't be opened, costs you tagging and nothing else. The
    /// sensor data is the thing worth protecting.
    private func startTagging(alongside csv: URL) {
        guard options.tagging else { return }
        guard KeyTagger.isAvailable else {
            // Nothing to say when output is piped — that's a script, not a person.
            return
        }

        let url = options.eventsPath.map { URL(fileURLWithPath: $0) }
            ?? EventLog.sidecarURL(for: csv)
        do {
            events = try EventLogWriter(url: url)
        } catch {
            Term.log("note: no stroke tagging (\(error))")
            return
        }

        let keys = KeyTagger { [weak self] key in self?.handleKey(key) }
        guard keys.start() else {
            events?.close()
            events = nil
            Term.log("note: no stroke tagging (this terminal can't report keypresses)")
            return
        }
        tagger = keys

        Term.log("Tagging to \(url.lastPathComponent) — press as each stroke finishes:")
        Term.log("  " + StrokeLabel.keyLegend)
    }

    /// A tag is a human action at a human instant, so it's stamped here, the
    /// moment the byte arrives — not after any queue hop.
    private func handleKey(_ key: Character) {
        guard let label = StrokeLabel.forKey(key) else { return }
        let now = Date()
        lock.lock()
        events?.record(label, at: now)
        tagTotal += 1
        lastTag = (label, now)
        lock.unlock()
    }

    private func armStopTimer(after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.finish(reason: "reached \(Int(seconds))s limit")
        }
    }

    /// Starts the --check countdown once data is actually flowing.
    private func startCheckWindowIfNeeded() {
        guard options.checkMode, !didArmCheckTimer else { return }
        didArmCheckTimer = true
        let seconds = options.duration ?? 15
        DispatchQueue.main.async { [weak self] in
            self?.armStopTimer(after: seconds)
        }
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
        let tags = tagTotal
        let recent = lastTag
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
        if events != nil {
            parts.append("tags \(tags)")
            // Echo the last tag briefly. The tagger is watching the caster, not
            // the screen, so this is for the glance afterwards that confirms the
            // key actually landed.
            if let r = recent, Date().timeIntervalSince(r.at) < 1.5 {
                parts.append("← \(r.label.name)")
            }
        }
        Term.status(parts.joined(separator: "   "))
    }

    /// Peaks and clipping. Clipped samples are pinned at full scale and look
    /// like ordinary data, so this has to be said out loud or it goes unnoticed.
    private func reportSaturation() {
        lock.lock()
        let s = saturation
        let g = glitches
        lock.unlock()
        guard s.total > 0 else { return }

        Term.log(String(format: "Peak |acc| %.2f g of %.0f    peak |gyro| %.0f °/s of %.0f",
                        s.peakAccMagnitude, FrameParser.accelFullScaleG,
                        s.peakGyroMagnitude, FrameParser.gyroFullScaleDPS))

        if g.glitchCount > 0 {
            Term.log(String(format: "  %d corrupt sample%@ detected (%.3f%%)%@",
                            g.glitchCount, g.glitchCount == 1 ? "" : "s",
                            g.glitchPercent,
                            options.despike ? " — removed" : " — KEPT"))
            if !options.despike {
                Term.log("    These are single-sample spikes the frame format can't")
                Term.log("    checksum away. They will distort any peak or derivative.")
                Term.log("    Re-record with --despike to drop them.")
            }
        }

        if s.didClip {
            Term.log("")
            Term.log("  WARNING — the sensor hit its measurement limit.")
            if s.accClipped > 0 {
                Term.log(String(format: "    %d samples (%.1f%%) clipped at ±%.0f g",
                                s.accClipped, s.accClippedPercent,
                                FrameParser.accelFullScaleG))
            }
            if s.gyroClipped > 0 {
                Term.log(String(format: "    %d samples (%.1f%%) clipped at ±%.0f °/s",
                                s.gyroClipped, s.gyroClippedPercent,
                                FrameParser.gyroFullScaleDPS))
            }
            Term.log("    Clipped values are pinned at full scale, so your peaks")
            Term.log("    read LOW and the file doesn't say so.")
            if s.accClipped > 0 {
                Term.log("    Acceleration scales with distance from the pivot, so")
                Term.log("    mounting closer to the hand reduces it.")
            }
            if s.gyroClipped > 0 {
                // Angular velocity is a property of the rigid body, identical at
                // every point on it — so relocating the sensor cannot reduce it.
                Term.log("    Rotation rate is the same everywhere on a rigid rod,")
                Term.log("    so moving the sensor will NOT help. ±2000 °/s is the")
                Term.log("    hardware limit; the stroke has outrun the sensor.")
            }
        } else if s.isNearLimit {
            Term.log("  note: peaks are within 20% of full scale — a harder cast "
                     + "would likely clip.")
        }
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
        // Hand the terminal back before anything else prints, so the shell isn't
        // left without echo if a later step exits early.
        tagger?.stop()
        tagger = nil
        Term.endStatus()

        lock.lock()
        // Release the sample still held by the glitch filter's lookahead.
        let tail = glitches.flush()
        writer?.write(tail)
        saturation.observe(tail)
        totalSamples += tail.count
        let w = writer
        writer = nil
        let e = events
        events = nil
        let total = totalSamples
        lock.unlock()

        w?.close()
        e?.close()

        let stats = session.parserStats

        if options.checkMode {
            reportHealthCheck(rejected: stats.rejected)
            return
        }

        Term.log("Stopped (\(reason)).")

        if let url = w?.url {
            Term.log("Wrote \(total) samples to \(url.path)")
        }
        if let e {
            if e.tags.isEmpty {
                // The empty sidecar would be a trap for castr-analyze to find
                // later, and an untagged session should look untagged.
                try? FileManager.default.removeItem(at: e.url)
            } else {
                Term.log("Tagged \(e.tags.count) strokes — \(e.summary)")
                Term.log("  \(e.url.path)")
            }
        }
        if !options.listAll {
            Term.log("Frames accepted \(stats.accepted), rejected \(stats.rejected), "
                     + "stray bytes \(stats.skippedBytes)")
            if stats.rejected > 0 {
                Term.log("note: rejected frames are non-zero — run --raw to check framing.")
            }
            reportSaturation()
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
        // Passes through the glitch filter first so a corrupt single-sample
        // spike can't masquerade as the session's peak. Output lags by one
        // sample; flush() releases the tail at shutdown.
        let settled = glitches.push(readings)
        writer?.write(settled)
        saturation.observe(settled)
        if options.checkMode {
            checkSamples.append(contentsOf: settled)
            startCheckWindowIfNeeded()
        }
        totalSamples += settled.count
        windowSamples += settled.count
        latest = settled.last ?? latest
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
