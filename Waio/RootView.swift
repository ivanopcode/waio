import SwiftUI
import AVFoundation

@MainActor
struct RootView: View {
    // ── Permissions ─────────────────────────────────────────────────────
    @State private var permission = AudioRecordingPermission()
    @State private var micPermissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    
    // ── Body ────────────────────────────────────────────────────────────
    var body: some View {
        Form {
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
                                 onlyKnownKinds: true)
        }
        
        Section(header: Text("Microphone").font(.headline)) {
            DeviceSelectionView()
        }
    }
    
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
