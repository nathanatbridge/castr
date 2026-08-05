import SwiftUI
import CoreBluetooth
import CastrCore
import CastrBLE

struct ContentView: View {
    @StateObject private var ble = ObservableBLE()
    @State private var shareItem: ShareableFiles?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusSection

                    if ble.isConnected {
                        // While recording, the tag buttons are the whole point of
                        // the screen — whoever is holding the phone is watching
                        // the caster, not reading numbers. Everything else moves
                        // below them.
                        if ble.isRecording { taggingSection }
                        recordingSection
                        liveReadingSection
                    } else {
                        connectionSection
                    }
                }
                .padding()
            }
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

    /// Four big buttons, one per stroke type.
    ///
    /// Sized and coloured for a thumb belonging to someone who is looking at the
    /// caster rather than the screen: a 2×2 grid of full-width targets, each a
    /// different colour, each showing its own running count so a glance
    /// afterwards confirms the taps landed. A haptic on every press is the real
    /// feedback — it's the only channel available to someone not watching.
    private var taggingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Mark strokes").font(.headline)
                Spacer()
                if ble.tagTotal > 0 {
                    Text("\(ble.tagTotal) tagged")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Tap as each stroke finishes. Reaction lag is expected — analysis "
                 + "corrects for it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(StrokeLabel.allCases, id: \.self) { label in
                    Button {
                        ble.tag(label)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    } label: {
                        VStack(spacing: 4) {
                            Text(label.name.capitalized)
                                .font(.headline)
                                .minimumScaleFactor(0.7)
                                .lineLimit(1)
                            Text("\(ble.tagCounts[label] ?? 0)")
                                .font(.system(.title3, design: .rounded).weight(.semibold))
                                .monospacedDigit()
                        }
                        .frame(maxWidth: .infinity, minHeight: 72)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(tint(for: label))
                }
            }

            if let last = ble.lastTag {
                Text("last: \(last.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if ble.eventsURL == nil {
                // Say so rather than silently dropping taps.
                Text("Tags can't be saved for this recording.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Distinct colours so the grid can be hit by position and colour alone.
    private func tint(for label: StrokeLabel) -> Color {
        switch label {
        case .pickup:       return .blue
        case .falseBack:    return .orange
        case .falseForward: return .teal
        case .delivery:     return .green
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

                Button("Export") {
                    // Recording streams straight to these files, so there's
                    // nothing to serialize here — just hand over the URLs. The
                    // tag sidecar goes with the CSV or the labels are lost.
                    let urls = ble.exportURLs
                    if !urls.isEmpty { shareItem = ShareableFiles(urls: urls) }
                }
                .buttonStyle(.bordered)
                .disabled(ble.isRecording || ble.recordingURL == nil)
            }

            if let error = ble.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(activityItems: item.urls)
        }
    }
}

/// Identifiable wrapper so the export set can drive `.sheet(item:)`.
///
/// An earlier version computed its URL in a getter that *wrote the file as a
/// side effect* — SwiftUI may evaluate a computed property on every render, so
/// that re-serialized the whole session repeatedly. The files now already exist
/// on disk; this just points at them.
struct ShareableFiles: Identifiable {
    let urls: [URL]
    var id: String { urls.map(\.path).joined(separator: "|") }
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
