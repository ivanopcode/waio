import SwiftUI
import AVFoundation
import Foundation
import AppKit          // ← NSAlert / NSWorkspace

@MainActor
struct RootView: View {
    // ── Permissions ────────────────────────────────────────────────────
    @State private var audioCapturePermission = AudioRecordingPermission()   // "Audio Capture" (system audio)
    @State private var micPermissionStatus    = AVCaptureDevice.authorizationStatus(for: .audio)
    
    /// `true` once we have successfully shown Apple’s "App‑Audio Recording" prompt
    @State private var didPrimeSystemAudioPermission =
    UserDefaults.standard.bool(forKey: "didPrimeSystemAudioPermission")
    
    /// All permissions required for the recording UI
    private var allPermissionsGranted: Bool {
        audioCapturePermission.status == .authorized &&
        micPermissionStatus            == .authorized &&
        didPrimeSystemAudioPermission
    }
    
    // ── Recording‑sync state (unchanged) ───────────────────────────────
    @State private var startSignal = UUID()
    @State private var stopSignal  = UUID()
    @State private var isProcessRecording = false
    @State private var isDeviceRecording  = false
    
    // Shared base name for files
    @State private var baseName: String = ""
    @FocusState private var isBaseNameFocused: Bool
    
    /// Async task that waits for recorders to finish and then merges the artefacts.
    @State private var mergeTask: Task<Void, Never>? = nil
    
    // ── Body ────────────────────────────────────────────────────────────
    var body: some View {
        Form {
            if allPermissionsGranted {
                recordingRootView                           // ← main capture UI
            } else {
                permissionsView                             // ← single combined screen
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if baseName.isEmpty { baseName = makeRecordingBaseName() }
        }
        // Refresh mic permission whenever app becomes active
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            micPermissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        .task {
            // Explicitly clear initial text‑field focus on first launch
            try? await Task.sleep(nanoseconds: 100_000_000)
            isBaseNameFocused = false
        }
    }
    
    // ── Unified permission screen ──────────────────────────────────────
    @ViewBuilder
    private var permissionsView: some View {
        // Microphone permission ‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑
        Section(header: Text("Microphone").font(.headline)) {
            switch micPermissionStatus {
                case .authorized:
                    Label("Microphone access granted ✔︎", systemImage: "checkmark.circle")
                case .notDetermined:
                    Button("Allow Microphone Access") {
                        AVCaptureDevice.requestAccess(for: .audio) { granted in
                            DispatchQueue.main.async {
                                micPermissionStatus = granted ? .authorized : .denied
                            }
                        }
                    }
                case .denied, .restricted:
                    Button("Open System Settings") { NSWorkspace.shared.openSystemSettings() }
                @unknown default:
                    EmptyView()
            }
        }
        
        // System‑audio capture permission (TCC SPI) ───────────────
        if audioCapturePermission.status != .authorized {
            Section(header: Text("System Audio").font(.headline)) {
                switch audioCapturePermission.status {
                    case .unknown:
                        Button("Allow System‑Audio Capture") { audioCapturePermission.request() }
                    case .denied:
                        Button("Open System Settings") { NSWorkspace.shared.openSystemSettings() }
                    default:
                        EmptyView()
                }
            }
        }
        
        // One‑time priming of per‑process tap privilege ────────────────
        if audioCapturePermission.status == .authorized &&
            !didPrimeSystemAudioPermission {
            Section(header: Text("App Audio Permission").font(.headline)) {
                Button("Grant App‑Audio Permission") {
                    Task {
                        do {
                            try await ProcessPermissionPrimer.prime()
                            didPrimeSystemAudioPermission = true
                            UserDefaults.standard.set(true,
                                                      forKey: "didPrimeSystemAudioPermission")
                        } catch {
                            NSAlert(error: error).runModal()
                        }
                    }
                }
            }
        }
    }
    
    // ── Main recording UI (unchanged) ──────────────────────────────────
    @ViewBuilder
    private var recordingRootView: some View {
        // Recording name
        LabeledContent("Recording Name") {
            TextField("", text: $baseName)
                .textFieldStyle(.roundedBorder)
                .focused($isBaseNameFocused)
        }
        
        // Process picker
        Section(header: Text("Source").font(.headline)) {
            ProcessSelectionView(displayedGroups: [.app, .process],
                                 onlyKnownKinds: true,
                                 startSignal:   $startSignal,
                                 stopSignal:    $stopSignal,
                                 isRecording:   $isProcessRecording,
                                 baseName:      $baseName)
        }
        
        // Microphone picker
        Section(header: Text("Microphone").font(.headline)) {
            DeviceSelectionView(startSignal: $startSignal,
                                stopSignal:  $stopSignal,
                                isRecording: $isDeviceRecording,
                                baseName:    $baseName)
        }
        
        // Start / Stop buttons
        Section {
            Button("Start Both") { startSignal = UUID() }
                .disabled(isProcessRecording || isDeviceRecording)
            
            Button("Stop Both") {
                stopSignal = UUID()
                
                // Wait a moment for both recorders to flush, then merge artefacts.
                mergeTask?.cancel()
                mergeTask = Task.detached(priority: .utility) { [baseName] in
                    // Give recorders time to flush to disk
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    // Hop back to the main actor for UI/state
                    await MainActor.run {
                        if let (procURL, micURL) = latestRecordingURLs() {
                            combineLatestArtifacts(processURL: procURL,
                                                        micURL:      micURL,
                                                        baseName:    baseName
                            )
                        }
                    }
                }
            }
            .disabled(!(isProcessRecording || isDeviceRecording))
        }
    }
    
    /// Combines the latest process + mic recordings into split + mono files.
    func combineLatestArtifacts(processURL: URL,
                                micURL: URL,
                                baseName: String)
    {
        Task {
            do {
                try? await Task.sleep(nanoseconds: 100_000_000) // just in case
                let (stereoURL, monoURL) = try await StereoMergeService.merge(
                    processURL: processURL,
                    micURL:     micURL,
                    baseName:   baseName)
                
                // 👉🏻 handle UI update, share sheet, etc.
                print("New artefacts:", stereoURL.lastPathComponent, monoURL.lastPathComponent)
            }
            catch {
                assertionFailure("Merge failed: \(error)")
            }
        }
    }
    
}

/// Returns a filesystem‑safe default recording name like
/// "2025‑07‑27_0446‑waio".
private func makeRecordingBaseName(date: Date = Date(),
                                   suffix: String = "waio") -> String
{
    let isoDateFormatter = ISO8601DateFormatter()
    isoDateFormatter.formatOptions = [.withFullDate]
    let datePart = isoDateFormatter.string(from: date)
    
    let timeFormatter = DateFormatter()
    timeFormatter.locale = .current
    timeFormatter.timeZone = .current
    timeFormatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "jmm",
                                                        options: 0,
                                                        locale: .current) ?? "HHmm"
    
    let timePart = timeFormatter.string(from: date)
        .replacingOccurrences(of: "[/ :.]", with: "-", options: .regularExpression)
    
    return "\(datePart)_\(timePart)-\(suffix)"
    
}

// MARK: – Post‑processing helpers
private extension RootView {
    private func latestRecordingURLs() -> (processURL: URL, micURL: URL)? {
        let dir = URL.applicationSupport
        let fm  = FileManager.default
        guard let listing = try? fm.contentsOfDirectory(at: dir,
                                                        includingPropertiesForKeys: [.contentModificationDateKey],
                                                        options: .skipsHiddenFiles)
        else { return nil }
        
        let prefix = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let outputs = listing.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.lastPathComponent.contains("-output-") && $0.pathExtension.lowercased() == "wav" }
        let inputs  = listing.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.lastPathComponent.contains("-input-")  && $0.pathExtension.lowercased() == "wav" }
        
        guard
            let procURL = outputs.sorted(by: { ($0.modDate ?? .distantPast) > ($1.modDate ?? .distantPast) }).first,
            let micURL  = inputs .sorted(by: { ($0.modDate ?? .distantPast) > ($1.modDate ?? .distantPast) }).first
        else { return nil }
        return (procURL, micURL)
    }
}

private extension URL {
    var modDate: Date? {
        (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

// Helper to open System Settings exactly once
extension NSWorkspace {
    func openSystemSettings() {
        guard let url = urlForApplication(withBundleIdentifier: "com.apple.systempreferences") else {
            assertionFailure("Failed to get System Settings app URL")
            return
        }
        openApplication(at: url, configuration: .init())
    }
}
