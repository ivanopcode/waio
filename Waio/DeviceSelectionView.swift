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
    /// Signal used by RootView to start recording simultaneously with the process recorder
    @Binding var startSignal: UUID
    @Binding var stopSignal:  UUID
    /// Binds to RootView's device-recording state.
    @Binding var isRecording: Bool
    /// Shared base name from RootView (ISO8601-waio or user override)
    @Binding var baseName: String
    
    private let logger = Logger(subsystem: kAppSubsystem, category: "DeviceSelectionView")
    
    init(startSignal: Binding<UUID>,
         stopSignal:  Binding<UUID>,
         isRecording: Binding<Bool>,
         baseName:    Binding<String>) {
        self._startSignal = startSignal
        self._stopSignal  = stopSignal
        self._isRecording = isRecording
        self._baseName    = baseName
    }
    
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
            .disabled(isRecording)
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
                .onChange(of: startSignal) { _, _ in
                    do {
                        if !recorder.isRecording {
                            try recorder.start()
                            self.isRecording = true
                        }
                    } catch {
                        logger.error("Device recorder failed to start: \(error, privacy: .public)")
                    }
                }
                .onChange(of: stopSignal) { _, _ in
                    if recorder.isRecording {
                        recorder.stop()
                        self.isRecording = false
                    }
                }
        }
    }
    
    // ── Helpers ─────────────────────────────────────────────────────────
    private func setupRecorder(for device: AudioInputDevice) {
        let safeBase  = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix    = safeBase.isEmpty ? device.name : safeBase
        let deviceName = device.name.lowercased().replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
        let filename  = "\(prefix)-input-\(deviceName)"
        let fileURL   = URL.applicationSupport
            .appendingPathComponent(filename, conformingTo: .wav)
        
        recorder = AudioDeviceRecorder(fileURL: fileURL, device: device)
    }
}



#if DEBUG
struct DeviceSelectionView_Previews: PreviewProvider {
    static var previews: some View {
        DeviceSelectionView(startSignal: .constant(UUID()),
                            stopSignal:  .constant(UUID()),
                            isRecording: .constant(false),
                            baseName:    .constant(""))
        .padding()
    }
}
#endif
