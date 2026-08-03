import Foundation
import CoreBluetooth
import CastrCore

/// WitMotion BLE 5.0 GATT layout.
public enum WitMotionGATT {
    public static let service = CBUUID(string: "0000FFE5-0000-1000-8000-00805F9A34FB")
    public static let notify = CBUUID(string: "0000FFE4-0000-1000-8000-00805F9A34FB")
    public static let write = CBUUID(string: "0000FFE9-0000-1000-8000-00805F9A34FB")
}

/// Output rates the sensor accepts, with their command byte.
public enum OutputRate: Int, CaseIterable {
    case hz10 = 10, hz20 = 20, hz50 = 50, hz100 = 100, hz200 = 200

    var code: UInt8 {
        switch self {
        case .hz10: return 0x06
        case .hz20: return 0x07
        case .hz50: return 0x08
        case .hz100: return 0x09
        case .hz200: return 0x0B
        }
    }
}

public struct DiscoveredDevice {
    public let peripheral: CBPeripheral
    public let name: String
    public let rssi: Int
    /// Whether the advertisement actually carried the FFE5 service UUID.
    public let advertisedService: Bool
}

public enum BLEState: Equatable {
    /// Before CoreBluetooth has reported anything. Distinct from `poweredOff` so
    /// that the very first state report always registers as a change — otherwise
    /// a machine with Bluetooth off looks identical to one that never answered,
    /// and the UI sits on its initial message with no explanation.
    case unknown
    case poweredOff
    case unsupported
    case unauthorized
    case ready
    case scanning
    case connecting(String)
    case connected(String)
    case streaming(String)
    case disconnected(String?)

    public var description: String {
        switch self {
        case .unknown: return "Waiting for Bluetooth…"
        case .poweredOff: return "Bluetooth is off"
        case .unsupported: return "Bluetooth LE is not available on this machine"
        case .unauthorized: return "Bluetooth permission denied"
        case .ready: return "Ready"
        case .scanning: return "Scanning…"
        case .connecting(let n): return "Connecting to \(n)…"
        case .connected(let n): return "Connected to \(n)"
        case .streaming(let n): return "Streaming from \(n)"
        case .disconnected(let e): return e.map { "Disconnected: \($0)" } ?? "Disconnected"
        }
    }

    /// True once we know Bluetooth will never work without user action.
    public var isTerminalFailure: Bool {
        switch self {
        case .unauthorized, .unsupported: return true
        default: return false
        }
    }
}

public protocol BLESessionDelegate: AnyObject {
    func session(_ session: BLESession, didChange state: BLEState)
    func session(_ session: BLESession, didDiscover device: DiscoveredDevice)
    func session(_ session: BLESession, didReceive readings: [SensorReading])
    /// Raw notification payload, before parsing. Drives `--raw` bring-up mode.
    func session(_ session: BLESession, didReceiveRawPacket bytes: [UInt8])
}

public extension BLESessionDelegate {
    func session(_ session: BLESession, didReceiveRawPacket bytes: [UInt8]) {}
}

/// Drives the CoreBluetooth connection and turns notifications into readings.
///
/// All CoreBluetooth work and all parsing happen on a dedicated serial queue, and
/// results are handed to the delegate on that same queue. Nothing here touches the
/// main thread or publishes per-sample UI state — at 200 Hz that was the dominant
/// cost in the original design. `ObservableBLE` adds throttled UI state on top.
public final class BLESession: NSObject {

    public weak var delegate: BLESessionDelegate?

    /// Report every peripheral seen, not just ones matching a WitMotion filter.
    /// Bring-up escape hatch for a unit that advertises under an unexpected name.
    public var reportAllDevices = false

    /// Set once `startScan()` is called before Bluetooth is ready, so the scan
    /// can begin the moment it powers on rather than silently doing nothing.
    private var wantsScan = false

    public private(set) var state: BLEState = .unknown {
        didSet {
            guard state != oldValue else { return }
            delegate?.session(self, didChange: state)
        }
    }

    public var parserStats: FrameParser.Stats { parser.stats }
    public private(set) var connectedName: String?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var parser = FrameParser()
    private var seen = Set<UUID>()
    private var pendingRate: OutputRate?

    /// Nominal spacing between samples, used to spread a BLE burst's timestamps.
    /// Seeded from `--rate` when given, otherwise measured from the stream.
    private var sampleInterval: TimeInterval?
    private var configuredRate: OutputRate?
    private var rateWindowStart: Date?
    private var rateWindowCount = 0

    /// Serial queue for CoreBluetooth callbacks and parsing.
    public let queue = DispatchQueue(label: "com.castr.ble", qos: .userInitiated)

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    // MARK: - Control

    public func startScan() {
        queue.async { self._startScan() }
    }

    private func _startScan() {
        // CoreBluetooth reports its initial state asynchronously, so a caller
        // that scans immediately after init will almost always arrive before
        // the radio is ready. Remember the intent and start on power-on rather
        // than dropping the request on the floor.
        guard central.state == .poweredOn else {
            wantsScan = true
            return
        }
        wantsScan = false
        seen.removeAll()

        // Scan with no service filter, then filter in `didDiscover`.
        //
        // The previous implementation passed `[service]` here, which meant
        // CoreBluetooth only ever surfaced peripherals whose *advertisement*
        // carried FFE5 — and many WT901BLE units don't include it. That also made
        // the name-prefix check downstream unreachable. Filtering ourselves keeps
        // both the UUID and the name path live.
        central.scanForPeripherals(withServices: nil, options: nil)
        state = .scanning
    }

    public func stopScan() {
        queue.async { self.central.stopScan() }
    }

    public func connect(to peripheral: CBPeripheral) {
        queue.async {
            self.central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            self.connectedName = peripheral.name ?? "sensor"
            self.state = .connecting(self.connectedName ?? "sensor")
            self.central.connect(peripheral, options: nil)
        }
    }

    public func disconnect() {
        queue.async {
            guard let p = self.peripheral else { return }
            self.central.cancelPeripheralConnection(p)
        }
    }

    /// Queues an output-rate change; applied once the write characteristic is found.
    public func setOutputRate(_ rate: OutputRate) {
        queue.async {
            self.pendingRate = rate
            self.configuredRate = rate
            // Seed the timestamp spacing from the rate we asked for, so the very
            // first samples are spread correctly rather than waiting on a measurement.
            self.sampleInterval = 1.0 / Double(rate.rawValue)
            self.applyPendingRateIfPossible()
        }
    }

    private func applyPendingRateIfPossible() {
        guard let rate = pendingRate,
              let characteristic = writeCharacteristic,
              let p = peripheral
        else { return }
        pendingRate = nil

        // WitMotion requires unlocking config before a setting sticks, and an
        // explicit save afterwards to survive a power cycle.
        let unlock: [UInt8] = [0xFF, 0xAA, 0x69, 0x88, 0xB5]
        let set: [UInt8] = [0xFF, 0xAA, 0x03, rate.code, 0x00]
        let save: [UInt8] = [0xFF, 0xAA, 0x00, 0x00, 0x00]

        for (index, command) in [unlock, set, save].enumerated() {
            queue.asyncAfter(deadline: .now() + .milliseconds(120 * index)) {
                p.writeValue(Data(command), for: characteristic, type: .withoutResponse)
            }
        }
    }

    public func resetParser() {
        queue.async {
            self.parser.reset()
            self.parser.resetStats()
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLESession: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            state = .ready
            if wantsScan { _startScan() }
        case .unauthorized:
            state = .unauthorized
        case .unsupported:
            state = .unsupported
        case .poweredOff:
            state = .poweredOff
        case .resetting, .unknown:
            state = .unknown
        @unknown default:
            state = .unknown
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertisedName ?? peripheral.name ?? ""

        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let hasService = services.contains(WitMotionGATT.service)
        let looksLikeWitMotion = name.uppercased().hasPrefix("WT")

        guard reportAllDevices || hasService || looksLikeWitMotion else { return }
        guard seen.insert(peripheral.identifier).inserted else { return }

        delegate?.session(self, didDiscover: DiscoveredDevice(
            peripheral: peripheral,
            name: name.isEmpty ? "(unnamed)" : name,
            rssi: RSSI.intValue,
            advertisedService: hasService
        ))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // Clear any partial frame left over from a previous connection, otherwise
        // its trailing bytes prefix this session and corrupt the first sample.
        parser.reset()
        state = .connected(connectedName ?? "sensor")
        peripheral.discoverServices([WitMotionGATT.service])
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral,
                               error: Error?) {
        state = .disconnected(error?.localizedDescription ?? "failed to connect")
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        parser.reset()
        self.peripheral = nil
        writeCharacteristic = nil
        state = .disconnected(error?.localizedDescription)
    }
}

// MARK: - CBPeripheralDelegate

extension BLESession: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == WitMotionGATT.service {
            peripheral.discoverCharacteristics(
                [WitMotionGATT.notify, WitMotionGATT.write], for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case WitMotionGATT.notify:
                peripheral.setNotifyValue(true, for: characteristic)
            case WitMotionGATT.write:
                writeCharacteristic = characteristic
                applyPendingRateIfPossible()
            default:
                break
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        if characteristic.uuid == WitMotionGATT.notify, characteristic.isNotifying {
            state = .streaming(connectedName ?? "sensor")
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard characteristic.uuid == WitMotionGATT.notify,
              let data = characteristic.value
        else { return }

        let bytes = [UInt8](data)
        delegate?.session(self, didReceiveRawPacket: bytes)

        let now = Date()
        let readings = parser.feed(bytes, at: now, sampleInterval: sampleInterval)
        guard !readings.isEmpty else { return }

        updateMeasuredInterval(sampleCount: readings.count, now: now)
        delegate?.session(self, didReceive: readings)
    }

    /// Learns the sample interval from throughput when `--rate` wasn't given.
    ///
    /// Measured over a whole second rather than per packet: BLE bursts make any
    /// short-window estimate wildly wrong, but the aggregate rate is accurate
    /// (a real 200 Hz export came in at 198.8 Hz over 38 s).
    private func updateMeasuredInterval(sampleCount: Int, now: Date) {
        guard let start = rateWindowStart else {
            rateWindowStart = now
            rateWindowCount = sampleCount
            return
        }
        rateWindowCount += sampleCount
        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= 1.0 else { return }

        let measured = Double(rateWindowCount) / elapsed
        if measured > 1 {
            // Only adopt a measured value if the rate wasn't set explicitly.
            if pendingRate == nil, sampleInterval == nil || configuredRate == nil {
                sampleInterval = 1.0 / measured
            }
        }
        rateWindowStart = now
        rateWindowCount = 0
    }
}
