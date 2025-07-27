import SwiftUI
import AVFoundation
import Foundation

@MainActor
struct RootView: View {
    // ── Permissions ─────────────────────────────────────────────────────
    @State private var permission = AudioRecordingPermission()
    @State private var micPermissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    
    // Trigger used to start both recorders simultaneously
    @State private var startSignal = UUID()
    @State private var stopSignal = UUID()
    @State private var isProcessRecording = false
    @State private var isDeviceRecording  = false
    
    
    /// Shared base name for both recordings
    @State private var baseName: String = ""
    @FocusState private var isBaseNameFocused: Bool
    
    // ── Body ────────────────────────────────────────────────────────────
    var body: some View {
        Form {
            LabeledContent("Recording Name") {
                TextField("", text: $baseName)
                    .textFieldStyle(.roundedBorder)
                    .focused($isBaseNameFocused)
            }
            switch permission.status {
                case .unknown:
                    requestPermissionView
                    
                case .denied:
                    permissionDeniedView
                    
                case .authorized:
                    switch micPermissionStatus {
                        case .notDetermined:
                            micPermissionRequestView
                        case .denied, .restricted:
                            micPermissionDeniedView
                        case .authorized:
                            recordingRootView
                        @unknown default:
                            micPermissionRequestView
                    }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if baseName.isEmpty {
                baseName = makeRecordingBaseName()
            }
        }
        .task {
            // Explicitly clear initial focus
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            isBaseNameFocused = false
        }
    }
    
    // ── Permission helper views ─────────────────────────────────────────
    @ViewBuilder
    private var requestPermissionView: some View {
        LabeledContent("Please Allow Audio Recording") {
            Button("Allow") { permission.request() }
        }
    }
    
    @ViewBuilder
    private var permissionDeniedView: some View {
        LabeledContent("Audio Recording Permission Required") {
            Button("Open System Settings") { NSWorkspace.shared.openSystemSettings() }
        }
    }
    
    @ViewBuilder
    private var micPermissionRequestView: some View {
        LabeledContent("Please Allow Microphone Access") {
            Button("Allow") {
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        micPermissionStatus = granted ? .authorized : .denied
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var micPermissionDeniedView: some View {
        LabeledContent("Microphone Permission Required") {
            Button("Open System Settings") {
                NSWorkspace.shared.openSystemSettings()
            }
        }
    }
    
    // ── Root view for both capture paths ────────────────────────────────
    @ViewBuilder
    private var recordingRootView: some View {
        Section(header: Text("Source").font(.headline)) {
            ProcessSelectionView(displayedGroups: [.app, .process],
                                 onlyKnownKinds: true,
                                 startSignal: $startSignal,
                                 stopSignal:  $stopSignal,
                                 isRecording: $isProcessRecording,
                                 baseName:    $baseName)
        }
        
        Section(header: Text("Microphone").font(.headline)) {
            DeviceSelectionView(startSignal: $startSignal,
                                stopSignal:  $stopSignal,
                                isRecording: $isDeviceRecording,
                                baseName:    $baseName)
        }
        
        Section {
            Button("Start Both") {
                startSignal = UUID()
            }
            .disabled(isProcessRecording || isDeviceRecording)
            
            Button("Stop Both") {
                stopSignal = UUID()
            }
            .disabled(!(isProcessRecording || isDeviceRecording))
        }
    }
    
}

/// Returns a filesystem‑safe default recording name like
/// “2025-07-27_0446-waio”, where the time part respects the
/// user’s 12‑/24‑hour locale preference.
private func makeRecordingBaseName(date: Date = Date(),
                                   suffix: String = "waio") -> String {
    // ISO‑8601 date (yyyy‑MM‑dd)
    let isoDateFormatter = ISO8601DateFormatter()
    isoDateFormatter.formatOptions = [.withFullDate]
    let datePart = isoDateFormatter.string(from: date)
    
    // Localized time (12‑/24‑hour)
    let timeFormatter = DateFormatter()
    timeFormatter.locale = .current
    timeFormatter.timeZone = .current
    
    // “j” picks 12‑ vs 24‑hour automatically
    let timeTemplate = "jmm"          // hours + minutes
    let timeFormat = DateFormatter.dateFormat(fromTemplate: timeTemplate,
                                              options: 0,
                                              locale: .current) ?? "HHmm"
    timeFormatter.dateFormat = timeFormat
    
    // Convert any separators to dashes so the string is safe for filenames
    var timePart = timeFormatter.string(from: date)
    timePart = timePart
        .replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ":", with: "-")
        .replacingOccurrences(of: ".", with: "-")
        .replacingOccurrences(of: " ", with: "-")
    
    return "\(datePart)_\(timePart)-\(suffix)"
}

extension NSWorkspace {
    func openSystemSettings() {
        guard let url = urlForApplication(withBundleIdentifier: "com.apple.systempreferences") else {
            assertionFailure("Failed to get System Settings app URL")
            return
        }
        openApplication(at: url, configuration: .init())
    }
}

#if DEBUG
#Preview {
    RootView()
}
#endif
