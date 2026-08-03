import SwiftUI
import CoreBluetooth
import CastrCore
import CastrBLE

struct ContentView: View {
    @StateObject private var ble = ObservableBLE()
    @State private var shareURL: ShareableCSV?

    var body: some View {
        NavigationStack {
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
            .navigationTitle("CastR")
        }
    }

    private var statusSection: some View {
        HStack {
            Circle()
                .fill(ble.isConnected ? Color.green : Color.gray)
                .frame(width: 10, height: 10)
            Text(ble.statusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
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

            List(ble.devices, id: \.peripheral.identifier) { device in
                Button {
                    ble.connect(to: device)
                } label: {
                    HStack {
                        Text(device.name)
                        Spacer()
                        Text("\(device.rssi) dBm")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                    Text(String(format: "Rate: %.0f Hz", ble.measuredRateHz))
                }
                .font(.system(.body, design: .monospaced))
            } else {
                Text("Waiting for data…").foregroundStyle(.secondary)
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

            HStack(spacing: 12) {
                Text("\(ble.sampleCount) samples")
                // A non-zero reject count means framing has slipped and the file
                // can't be trusted — surface it rather than hiding it.
                if ble.rejectedFrames > 0 {
                    Label("\(ble.rejectedFrames) rejected", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            HStack {
                Button(ble.isRecording ? "Stop" : "Start Recording") {
                    ble.isRecording ? ble.stopRecording() : ble.startRecording()
                }
                .buttonStyle(.borderedProminent)
                .tint(ble.isRecording ? .red : .green)

                Button("Export CSV") {
                    // Recording streams straight to this file, so there's nothing
                    // to serialize here — just hand over the URL.
                    if let url = ble.recordingURL {
                        shareURL = ShareableCSV(url: url)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(ble.isRecording || ble.recordingURL == nil)
            }

            if let error = ble.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .sheet(item: $shareURL) { item in
            ShareSheet(activityItems: [item.url])
        }
    }
}

/// Identifiable wrapper so a URL can drive `.sheet(item:)`.
///
/// The previous version computed its URL in a getter that *wrote the file as a
/// side effect* — SwiftUI may evaluate a computed property on every render, so
/// that re-serialized the whole session repeatedly. The file now already exists
/// on disk; this just points at it.
struct ShareableCSV: Identifiable {
    let url: URL
    var id: String { url.path }
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
