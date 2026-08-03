import Foundation
import Combine
import CoreBluetooth
import CastrCore

/// SwiftUI-facing wrapper around `BLESession`.
///
/// The important property here is that samples never drive the UI directly.
/// Readings arrive on the BLE queue and go straight to disk; a timer republishes
/// a snapshot at `uiRefreshHz`. The original design published two properties per
/// sample — at 200 Hz that is 200 SwiftUI invalidations per second, and because
/// one of them was a growing array, cost climbed as the recording got longer.
public final class ObservableBLE: NSObject, ObservableObject {

    // MARK: - Published UI state (updated at uiRefreshHz, not per sample)

    @Published public private(set) var statusMessage = "Starting up…"
    @Published public private(set) var isConnected = false
    @Published public private(set) var isScanning = false
    @Published public private(set) var isBluetoothReady = false
    @Published public private(set) var devices: [DiscoveredDevice] = []
    @Published public private(set) var latestReading: SensorReading?
    @Published public private(set) var sampleCount = 0
    @Published public private(set) var rejectedFrames = 0
    @Published public private(set) var measuredRateHz: Double = 0
    @Published public private(set) var isRecording = false
    @Published public private(set) var recordingURL: URL?
    @Published public private(set) var lastError: String?

    public var uiRefreshHz: Double = 10

    // MARK: - Internals

    private let session = BLESession()
    private var writer: CSVWriter?
    private var timer: Timer?

    // Written on the BLE queue, read on the main queue via the timer.
    private let lock = NSLock()
    private var pendingReading: SensorReading?
    private var pendingCount = 0
    private var pendingDevices: [DiscoveredDevice] = []
    private var rateWindowStart = Date()
    private var rateWindowSamples = 0

    public override init() {
        super.init()
        session.delegate = self
        startTimer()
    }

    deinit {
        timer?.invalidate()
        writer?.close()
    }

    private func startTimer() {
        let t = Timer(timeInterval: 1.0 / uiRefreshHz, repeats: true) { [weak self] _ in
            self?.publishSnapshot()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func publishSnapshot() {
        lock.lock()
        let reading = pendingReading
        let count = pendingCount
        let newDevices = pendingDevices
        pendingDevices = []
        let elapsed = Date().timeIntervalSince(rateWindowStart)
        var rate = measuredRateHz
        if elapsed >= 1.0 {
            rate = Double(rateWindowSamples) / elapsed
            rateWindowSamples = 0
            rateWindowStart = Date()
        }
        lock.unlock()

        if let reading { latestReading = reading }
        sampleCount = count
        measuredRateHz = rate
        rejectedFrames = session.parserStats.rejected
        if !newDevices.isEmpty { devices.append(contentsOf: newDevices) }
    }

    // MARK: - Controls

    public func startScan() {
        devices.removeAll()
        isScanning = true
        session.startScan()
    }

    public func stopScan() {
        isScanning = false
        session.stopScan()
    }

    public func connect(to device: DiscoveredDevice) {
        isScanning = false
        session.connect(to: device.peripheral)
    }

    public func disconnect() {
        session.disconnect()
    }

    public func setOutputRate(_ rate: OutputRate) {
        session.setOutputRate(rate)
    }

    /// Opens a CSV file and begins appending. Returns the destination, or nil on failure.
    @discardableResult
    public func startRecording(directory: URL? = nil) -> URL? {
        guard !isRecording else { return recordingURL }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        let dir = directory ?? FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("CastR_\(stamp.string(from: Date())).csv")

        do {
            let w = try CSVWriter(url: url, deviceName: session.connectedName ?? "WT901BLE")
            lock.lock()
            writer = w
            pendingCount = 0
            lock.unlock()
            recordingURL = url
            isRecording = true
            lastError = nil
            return url
        } catch {
            lastError = "\(error)"
            return nil
        }
    }

    public func stopRecording() {
        guard isRecording else { return }
        lock.lock()
        let w = writer
        writer = nil
        lock.unlock()
        w?.close()
        isRecording = false
    }
}

// MARK: - BLESessionDelegate (all callbacks arrive on the BLE queue)

extension ObservableBLE: BLESessionDelegate {
    public func session(_ session: BLESession, didChange state: BLEState) {
        DispatchQueue.main.async {
            self.statusMessage = state.description
            switch state {
            case .ready, .scanning:
                self.isBluetoothReady = true
                self.isConnected = false
            case .connected, .streaming:
                self.isBluetoothReady = true
                self.isConnected = true
            case .disconnected:
                self.isConnected = false
                self.stopRecording()
            case .poweredOff, .unauthorized, .unsupported, .unknown:
                self.isBluetoothReady = false
                self.isConnected = false
                if state.isTerminalFailure { self.lastError = state.description }
            case .connecting:
                break
            }
        }
    }

    public func session(_ session: BLESession, didDiscover device: DiscoveredDevice) {
        lock.lock()
        pendingDevices.append(device)
        lock.unlock()
    }

    public func session(_ session: BLESession, didReceive readings: [SensorReading]) {
        lock.lock()
        writer?.write(readings)
        pendingReading = readings.last
        pendingCount += readings.count
        rateWindowSamples += readings.count
        lock.unlock()
    }
}
