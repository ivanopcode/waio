import SwiftUI
import OSLog

@MainActor
struct ProcessSelectionView: View {
    @StateObject private var processController: AudioProcessController
    @State private var tap: ProcessTap?
    @State private var recorder: ProcessTapRecorder?
    
    @State private var selectedProcess: AudioProcess?
    /// Signal used by RootView to start recording simultaneously with the device recorder
    @Binding private var startSignal: UUID
    @Binding private var stopSignal: UUID
    /// Binds to RootView's process-recording state.
    @Binding private var isRecording: Bool
    /// Shared base name coming from RootView (ISO8601‑waio or user override)
    @Binding private var baseName: String
    
    private let logger = Logger(subsystem: kAppSubsystem, category: "ProcessSelectionView")
    
    
    init(displayedGroups: Set<AudioProcess.Kind>,
         onlyKnownKinds: Bool,
         startSignal: Binding<UUID>,
         stopSignal:  Binding<UUID>,
         isRecording: Binding<Bool>,
         baseName:    Binding<String>) {
        self._processController = StateObject(
            wrappedValue: AudioProcessController(
                displayedGroups: displayedGroups,
                onlyKnownKinds: onlyKnownKinds
            )
        )
        self._startSignal = startSignal
        self._stopSignal = stopSignal
        self._isRecording = isRecording
        self._baseName = baseName
    }
    
    
    var body: some View {
        Section {
            Picker("Process", selection: $selectedProcess) {
                Text("Select…")
                    .tag(Optional<AudioProcess>.none)
                
                ForEach(processController.processGroups.values) { group in
                    Section {
                        ForEach(group.processes) { process in
                            HStack {
                                Image(nsImage: process.icon)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 16, height: 16)
                                
                                Text(process.name)
                            }
                            .tag(Optional<AudioProcess>.some(process))
                        }
                    } header: {
                        Text(group.title)
                    }
                }
            }
            .disabled(recorder?.isRecording == true)
            .task { processController.activate() }
            .onChange(of: selectedProcess) { oldValue, newValue in
                guard newValue != oldValue else { return }
                
                if let newValue {
                    logger.info("""
                        Selected process – name: \(newValue.name, privacy: .public), \
                        pid: \(newValue.id, format: .decimal, privacy: .public), \
                        bundleID: \(newValue.bundleID ?? "nil", privacy: .public)
                        """)
                    
                    setupRecording(for: newValue)
                } else if oldValue == tap?.process {
                    teardownTap()
                }
            }
            .onChange(of: startSignal) { _, _ in
                if let recorder, !recorder.isRecording {
                    do {
                        try recorder.start()
                        self.isRecording = true
                    } catch {
                        logger.error("Process recorder failed to start: \(error, privacy: .public)")
                    }
                }
            }
            .onChange(of: stopSignal) { _, _ in
                if let recorder, recorder.isRecording {
                    recorder.stop()
                    self.isRecording = false
                }
            }
        } header: {
            Text("Source")
                .font(.headline)
        }
        
        if let tap {
            if let errorMessage = tap.errorMessage {
                Text(errorMessage)
                    .font(.headline)
                    .foregroundStyle(.red)
            } else if let recorder {
                RecordingView(recorder: recorder)
                    .onChange(of: recorder.isRecording) { wasRecording, isRecording in
                        /// Each recorder instance can only record a single file, so we create a new file/recorder when recording stops.
                        self.isRecording = isRecording
                        if wasRecording, !isRecording {
                            createRecorder()
                        }
                    }
            }
        }
    }
    
    private func setupRecording(for process: AudioProcess) {
        let newTap = ProcessTap(process: process)
        self.tap = newTap
        newTap.activate()
        
        createRecorder()
        self.isRecording = false
    }
    
    private func createRecorder() {
        guard let tap else { return }
        
        // Construct filename: <baseName>-<processName>-<timestamp>.wav
        let timestamp = Int(Date.now.timeIntervalSinceReferenceDate)
        let safeBase  = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix    = safeBase.isEmpty ? tap.process.name : safeBase
        let filename  = "\(prefix)-output-\(tap.process.name.lowercased())"
        let audioFileURL = URL.applicationSupport.appendingPathComponent(filename, conformingTo: .wav)
        
        let newRecorder = ProcessTapRecorder(fileURL: audioFileURL, tap: tap)
        self.recorder = newRecorder
    }
    
    private func teardownTap() {
        self.isRecording = false
        tap = nil
    }
}

extension URL {
    static var applicationSupport: URL {
        do {
            let appSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            let subdir = appSupport.appending(path: "Waio", directoryHint: .isDirectory)
            if !FileManager.default.fileExists(atPath: subdir.path) {
                try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
            }
            return subdir
        } catch {
            assertionFailure("Failed to get application support directory: \(error)")
            
            return FileManager.default.temporaryDirectory
        }
    }
}

#if DEBUG
struct ProcessSelectionView_Previews: PreviewProvider {
    static var previews: some View {
        ProcessSelectionView(displayedGroups: [.app, .process],
                             onlyKnownKinds: true,
                             startSignal: .constant(UUID()),
                             stopSignal:  .constant(UUID()),
                             isRecording: .constant(false),
                             baseName:    .constant(""))
    }
}
#endif
