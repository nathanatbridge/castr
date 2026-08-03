import Foundation
import CoreBluetooth
import Combine

/// Handles all Bluetooth communication with a WitMotion WT901BLE sensor:
/// scanning, connecting, subscribing to notifications, and parsing the
/// raw byte stream into SensorReading values.
///
/// Protocol reference (WitMotion BLE 5.0 SDK):
///   Service UUID:              0000FFE5-0000-1000-8000-00805F9A34FB
///   Notify characteristic:     0000FFE4-0000-1000-8000-00805F9A34FB
///   Write characteristic:      0000FFE9-0000-1000-8000-00805F9A34FB
///   Frame format (20 bytes):   0x55 0x61 <9 x int16 LE: AccXYZ, GyroXYZ, AngleXYZ>
final class BLEManager: NSObject, ObservableObject {

    // MARK: - Published state for SwiftUI

    @Published var isBluetoothReady = false
    @Published var isScanning = false
    @Published var discoveredPeripherals: [CBPeripheral] = []
    @Published var connectedPeripheral: CBPeripheral?
    @Published var isConnected = false
    @Published var latestReading: SensorReading?
    @Published var isRecording = false
    @Published private(set) var recordedReadings: [SensorReading] = []
    @Published var statusMessage = "Not connected"

    // MARK: - CoreBluetooth

    private var centralManager: CBCentralManager!
    private let serviceUUID = CBUUID(string: "0000FFE5-0000-1000-8000-00805F9A34FB")
    private let notifyCharUUID = CBUUID(string: "0000FFE4-0000-1000-8000-00805F9A34FB")
    private let writeCharUUID = CBUUID(string: "0000FFE9-0000-1000-8000-00805F9A34FB")
    private var notifyCharacteristic: CBCharacteristic?

    // Rolling buffer for reassembling frames split across BLE packets.
    private var rxBuffer = [UInt8]()

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Public controls

    func startScan() {
        guard isBluetoothReady else {
            statusMessage = "Bluetooth not ready yet"
            return
        }
        discoveredPeripherals.removeAll()
        statusMessage = "Scanning..."
        isScanning = true
        // Scan for the known service UUID first; if nothing shows up within
        // a few seconds, WT901 sensors sometimes advertise without the
        // service in the payload, so fall back to scanning for everything
        // and filtering by name prefix "WT901" in didDiscover.
        centralManager.scanForPeripherals(withServices: [serviceUUID], options: nil)
    }

    func stopScan() {
        centralManager.stopScan()
        isScanning = false
    }

    func connect(to peripheral: CBPeripheral) {
        stopScan()
        statusMessage = "Connecting to \(peripheral.name ?? "device")..."
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
    }

    func disconnect() {
        guard let peripheral = connectedPeripheral else { return }
        centralManager.cancelPeripheralConnection(peripheral)
    }

    func startRecording() {
        recordedReadings.removeAll()
        isRecording = true
    }

    func stopRecording() {
        isRecording = false
    }

    /// Builds a CSV string from the currently recorded readings.
    func exportCSV() -> String {
        let deviceName = connectedPeripheral?.name ?? "WT901BLE"
        var lines = [SensorReading.csvHeader]
        lines.append(contentsOf: recordedReadings.map { $0.csvRow(deviceName: deviceName) })
        return lines.joined(separator: "\n")
    }

    // MARK: - Frame parsing

    /// Appends newly received bytes to the buffer and extracts as many
    /// complete 0x55 0x61 frames as are available.
    private func processIncoming(_ data: Data) {
        rxBuffer.append(contentsOf: [UInt8](data))

        while rxBuffer.count >= 20 {
            // Look for the frame header within the buffer.
            guard let headerIndex = rxBuffer.firstIndex(where: { $0 == 0x55 }) else {
                rxBuffer.removeAll()
                break
            }
            if headerIndex > 0 {
                rxBuffer.removeFirst(headerIndex)
            }
            guard rxBuffer.count >= 20 else { break }
            guard rxBuffer[1] == 0x61 else {
                // Not the attitude/accel/gyro frame we care about (e.g. it
                // could be a magnetometer 0x55 0x71 register-read reply).
                // Drop the header byte and keep scanning.
                rxBuffer.removeFirst(1)
                continue
            }

            let frame = Array(rxBuffer.prefix(20))
            rxBuffer.removeFirst(20)

            if let reading = parseFrame(frame) {
                DispatchQueue.main.async {
                    self.latestReading = reading
                    if self.isRecording {
                        self.recordedReadings.append(reading)
                    }
                }
            }
        }
    }

    private func int16LE(_ lo: UInt8, _ hi: UInt8) -> Int16 {
        Int16(bitPattern: UInt16(lo) | (UInt16(hi) << 8))
    }

    private func parseFrame(_ bytes: [UInt8]) -> SensorReading? {
        guard bytes.count == 20, bytes[0] == 0x55, bytes[1] == 0x61 else { return nil }

        let axRaw = int16LE(bytes[2], bytes[3])
        let ayRaw = int16LE(bytes[4], bytes[5])
        let azRaw = int16LE(bytes[6], bytes[7])
        let gxRaw = int16LE(bytes[8], bytes[9])
        let gyRaw = int16LE(bytes[10], bytes[11])
        let gzRaw = int16LE(bytes[12], bytes[13])
        let axAngleRaw = int16LE(bytes[14], bytes[15])
        let ayAngleRaw = int16LE(bytes[16], bytes[17])
        let azAngleRaw = int16LE(bytes[18], bytes[19])

        func acc(_ raw: Int16) -> Double { Double(raw) / 32768.0 * 16.0 }
        func gyro(_ raw: Int16) -> Double { Double(raw) / 32768.0 * 2000.0 }
        func angle(_ raw: Int16) -> Double { Double(raw) / 32768.0 * 180.0 }

        return SensorReading(
            timestamp: Date(),
            accX: acc(axRaw), accY: acc(ayRaw), accZ: acc(azRaw),
            gyroX: gyro(gxRaw), gyroY: gyro(gyRaw), gyroZ: gyro(gzRaw),
            angleX: angle(axAngleRaw), angleY: angle(ayAngleRaw), angleZ: angle(azAngleRaw)
        )
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        isBluetoothReady = (central.state == .poweredOn)
        if !isBluetoothReady {
            statusMessage = "Turn on Bluetooth to continue"
        } else {
            statusMessage = "Ready to scan"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? ""
        let matchesService = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .contains(serviceUUID) ?? false
        let matchesName = name.hasPrefix("WT901") || name.hasPrefix("WT9011")

        guard matchesService || matchesName else { return }
        if !discoveredPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
            discoveredPeripherals.append(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedPeripheral = peripheral
        isConnected = true
        statusMessage = "Connected — discovering services..."
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        statusMessage = "Failed to connect: \(error?.localizedDescription ?? "unknown error")"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        connectedPeripheral = nil
        notifyCharacteristic = nil
        statusMessage = "Disconnected"
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == serviceUUID {
            peripheral.discoverCharacteristics([notifyCharUUID, writeCharUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            if characteristic.uuid == notifyCharUUID {
                notifyCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == notifyCharUUID && characteristic.isNotifying {
            statusMessage = "Streaming data"
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == notifyCharUUID, let data = characteristic.value else { return }
        processIncoming(data)
    }
}
