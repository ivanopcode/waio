import SwiftUI
import OSLog

/// UI that lets the user choose an audio‑input device (microphone etc.)
/// and records from it using AudioDeviceRecorder.
@MainActor
struct DeviceSelectionView: View {
    // ── Model/controller objects ────────────────────────────────────────
    @StateObject private var deviceController = AudioInputDeviceController()
    @State private var recorder: AudioDeviceRecorder?
    @State private var selectedDevice: AudioInputDevice?
    
    private let logger = Logger(subsystem: kAppSubsystem, category: "DeviceSelectionView")
    
    // ── Body ────────────────────────────────────────────────────────────
    var body: some View {
        Section {
            Picker("Input Device", selection: $selectedDevice) {
                Text("Select…")
                    .tag(Optional<AudioInputDevice>.none)
                
                ForEach(deviceController.devices) { device in
                    HStack {
                        // Microphone icon
                        Image(systemName: "mic")
                        Text(device.name)
                    }
                    .tag(Optional<AudioInputDevice>.some(device))
                }
            }
            .disabled(recorder?.isRecording == true)
            .onAppear { deviceController.activate() }
            .onChange(of: selectedDevice) { old, new in
                guard new != old else { return }
                if let device = new {
                    logger.info("Selected input device #\(device.id, privacy: .public) “\(device.name, privacy: .public)”")
                    setupRecorder(for: device)
                }
            }
        } header: {
            Text("Source")
                .font(.headline)
        }
        
        if let recorder {
            DeviceRecordingView(recorder: recorder)
                .onChange(of: recorder.isRecording) { wasRecording, isRecording in
                    if wasRecording, !isRecording {
                        // Start a fresh file when a recording stops
                        if let device = selectedDevice { setupRecorder(for: device) }
                    }
                }
        }
    }
    
    // ── Helpers ─────────────────────────────────────────────────────────
    private func setupRecorder(for device: AudioInputDevice) {
        let filename = "\(device.name)-\(Int(Date.now.timeIntervalSinceReferenceDate))"
        let fileURL  = URL.applicationSupport
            .appendingPathComponent(filename, conformingTo: .wav)
        
        recorder = AudioDeviceRecorder(fileURL: fileURL, device: device)
    }
}
    
