import SwiftUI
import CoreBluetooth

struct ContentView: View {
    @StateObject private var ble = BLEManager()
    @State private var csvToShare: CSVFile?

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                statusSection

                if ble.isConnected {
                    liveReadingSection
                    recordingSection
                } else {
                    connectionSection
                }

                Spacer()
            }
            .padding()
            .navigationTitle("CastR Data Collector")
        }
    }

    private var statusSection: some View {
        HStack {
            Circle()
                .fill(ble.isConnected ? Color.green : Color.gray)
                .frame(width: 10, height: 10)
            Text(ble.statusMessage)
                .font(.footnote)
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(ble.isScanning ? "Stop Scanning" : "Scan for Sensor") {
                ble.isScanning ? ble.stopScan() : ble.startScan()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!ble.isBluetoothReady)

            List(ble.discoveredPeripherals, id: \.identifier) { peripheral in
                Button {
                    ble.connect(to: peripheral)
                } label: {
                    Text(peripheral.name ?? "Unnamed device")
                }
            }
            .listStyle(.plain)
            .frame(minHeight: 200)
        }
    }

    private var liveReadingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live Reading").font(.headline)
            if let r = ble.latestReading {
                Group {
                    Text(String(format: "Acc  (g):  X %.2f   Y %.2f   Z %.2f", r.accX, r.accY, r.accZ))
                    Text(String(format: "Gyro (°/s): X %.1f   Y %.1f   Z %.1f", r.gyroX, r.gyroY, r.gyroZ))
                    Text(String(format: "Angle (°): X %.1f   Y %.1f   Z %.1f", r.angleX, r.angleY, r.angleZ))
                }
                .font(.system(.body, design: .monospaced))
            } else {
                Text("Waiting for data...").foregroundColor(.secondary)
            }

            Button("Disconnect") { ble.disconnect() }
                .buttonStyle(.bordered)
        }
        .padding(.vertical)
    }

    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Recording").font(.headline)
            Text("\(ble.recordedReadings.count) samples captured")
                .font(.footnote)
                .foregroundColor(.secondary)

            HStack {
                Button(ble.isRecording ? "Stop" : "Start Recording") {
                    ble.isRecording ? ble.stopRecording() : ble.startRecording()
                }
                .buttonStyle(.borderedProminent)
                .tint(ble.isRecording ? .red : .green)

                Button("Export CSV") {
                    let csv = ble.exportCSV()
                    csvToShare = CSVFile(content: csv)
                }
                .buttonStyle(.bordered)
                .disabled(ble.recordedReadings.isEmpty)
            }
        }
        .sheet(item: $csvToShare) { file in
            ShareSheet(activityItems: [file.fileURL])
        }
    }
}

/// Wraps CSV text as a temp file so it can be shared via the system share sheet.
struct CSVFile: Identifiable {
    let id = UUID()
    let content: String

    var fileURL: URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "CastR_\(formatter.string(from: Date())).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// Thin UIKit bridge for the standard iOS share sheet.
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    ContentView()
}
