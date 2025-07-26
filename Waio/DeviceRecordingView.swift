import SwiftUI
import AVFoundation

/// UI identical in spirit to RecordingView, but for AudioDeviceRecorder.
@MainActor
struct DeviceRecordingView: View {
    let recorder: AudioDeviceRecorder
    @State private var lastRecordingURL: URL?
    
    var body: some View {
        Section {
            HStack {
                if recorder.isRecording {
                    Button("Stop") { recorder.stop() }
                        .id("device-button")
                } else {
                    Button("Start") {
                        handlingErrors { try recorder.start() }
                    }
                    .id("device-button")
                    
                    if let lastRecordingURL {
                        FileProxyView(url: lastRecordingURL)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .animation(.smooth, value: recorder.isRecording)
            .animation(.smooth, value: lastRecordingURL)
            .onChange(of: recorder.isRecording) { _, newValue in
                if !newValue { lastRecordingURL = recorder.fileURL }
            }
        } header: {
            HStack {
                Image(systemName: "mic")
                Text(recorder.isRecording
                     ? "Recording from “\(recorder.device.name)”"
                     : "Ready to Record from “\(recorder.device.name)”")
                .font(.headline)
                .contentTransition(.identity)
            }
        }
    }
    
    private func handlingErrors(perform block: () throws -> Void) {
        do   { try block() }
        catch { NSAlert(error: error).runModal() }
    }
    
}

