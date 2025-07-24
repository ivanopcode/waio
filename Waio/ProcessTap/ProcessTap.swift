import SwiftUI
import AudioToolbox
import OSLog
import AVFoundation

@Observable
final class ProcessTap {
    
    typealias InvalidationHandler = (ProcessTap) -> Void
    
    let process: AudioProcess
    let muteWhenRunning: Bool
    private let logger: Logger
    
    private(set) var errorMessage: String? = nil
    
    init(process: AudioProcess, muteWhenRunning: Bool = false) {
        self.process = process
        self.muteWhenRunning = muteWhenRunning
        self.logger = Logger(subsystem: kAppSubsystem,
                             category: "\(String(describing: ProcessTap.self))(\(process.name))")
    }
    
    // MARK: Core Audio IDs we must keep around while active
    
    @ObservationIgnored private var processTapID: AudioObjectID      = .unknown
    @ObservationIgnored private var aggregateDeviceID: AudioObjectID = .unknown
    @ObservationIgnored private var deviceProcID: AudioDeviceIOProcID?
    @ObservationIgnored private(set) var tapStreamDescription: AudioStreamBasicDescription?
    @ObservationIgnored private var invalidationHandler: InvalidationHandler?
    
    @ObservationIgnored private(set) var activated = false
    
    // MARK: Lifecycle
    
    @MainActor
    func activate() {
        guard !activated else { return }
        activated = true
        
        logger.debug(#function)
        
        self.errorMessage = nil
        
        do {
            try prepare(for: process.objectID)
        } catch {
            logger.error("\(error, privacy: .public)")
            self.errorMessage = error.localizedDescription
        }
    }
    
    func invalidate() {
        guard activated else { return }
        defer { activated = false }
        
        logger.debug(#function)
        
        invalidationHandler?(self)
        self.invalidationHandler = nil
        
        if aggregateDeviceID.isValid {
            var err = AudioDeviceStop(aggregateDeviceID, deviceProcID)
            if err != noErr { logger.warning("Failed to stop aggregate device: \(err, privacy: .public)") }
            
            if let deviceProcID {
                err = AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
                if err != noErr { logger.warning("Failed to destroy device I/O proc: \(err, privacy: .public)") }
                self.deviceProcID = nil
            }
            
            err = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if err != noErr {
                logger.warning("Failed to destroy aggregate device: \(err, privacy: .public)")
            }
            aggregateDeviceID = .unknown
        }
        
        if processTapID.isValid {
            let err = AudioHardwareDestroyProcessTap(processTapID)
            if err != noErr {
                logger.warning("Failed to destroy audio tap: \(err, privacy: .public)")
            }
            self.processTapID = .unknown
        }
    }
    
    // MARK: Setup helpers
    
    private func prepare(for objectID: AudioObjectID) throws {
        errorMessage = nil
        
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [objectID])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = muteWhenRunning ? .mutedWhenTapped : .unmuted
        var tapID: AUAudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        
        guard err == noErr else {
            errorMessage = "Process tap creation failed with error \(err)"
            return
        }
        
        logger.debug("Created process tap #\(tapID, privacy: .public)")
        
        self.processTapID = tapID
        
        let systemOutputID = try AudioDeviceID.readDefaultSystemOutputDevice()
        let outputUID      = try systemOutputID.readDeviceUID()
        let aggregateUID   = UUID().uuidString
        
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey:           "Tap-\(process.id)",
            kAudioAggregateDeviceUIDKey:            aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey:  outputUID,
            kAudioAggregateDeviceIsPrivateKey:      true,
            kAudioAggregateDeviceIsStackedKey:      false,
            kAudioAggregateDeviceTapAutoStartKey:   true,
            kAudioAggregateDeviceSubDeviceListKey:  [
                [ kAudioSubDeviceUIDKey: outputUID ]
            ],
            kAudioAggregateDeviceTapListKey : [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey:              tapDescription.uuid.uuidString
                ]
            ]
        ]
        
        self.tapStreamDescription = try tapID.readAudioTapStreamBasicDescription()
        
        aggregateDeviceID = .unknown
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateDeviceID)
        guard err == noErr else {
            throw "Failed to create aggregate device: \(err)"
        }
        
        logger.debug("Created aggregate device #\(self.aggregateDeviceID, privacy: .public)")
    }
    
    func run(on queue: DispatchQueue,
             ioBlock: @escaping AudioDeviceIOBlock,
             invalidationHandler: @escaping InvalidationHandler) throws
    {
        assert(activated,               "\(#function) called with inactive tap!")
        assert(self.invalidationHandler == nil, "\(#function) called with tap already active!")
        
        errorMessage = nil
        
        logger.debug("Run tap!")
        
        self.invalidationHandler = invalidationHandler
        
        var err = AudioDeviceCreateIOProcIDWithBlock(&deviceProcID,
                                                     aggregateDeviceID,
                                                     queue,
                                                     ioBlock)
        guard err == noErr else { throw "Failed to create device I/O proc: \(err)" }
        
        err = AudioDeviceStart(aggregateDeviceID, deviceProcID)
        guard err == noErr else { throw "Failed to start audio device: \(err)" }
    }
    
    deinit { invalidate() }
}

// MARK: - ProcessTapRecorder

@Observable
final class ProcessTapRecorder {
    
    // MARK: Public API
    
    let fileURL: URL
    let process: AudioProcess
    
    // MARK: Private
    
    private let queue  = DispatchQueue(label: "ProcessTapRecorder", qos: .userInitiated)
    private let logger: Logger
    
    @ObservationIgnored private weak var _tap: ProcessTap?
    @ObservationIgnored private var currentFile: AVAudioFile?
    
    // Track last-seen format to avoid spamming the console
    @ObservationIgnored private var lastSampleRate: Double?
    @ObservationIgnored private var lastChannelCount: AVAudioChannelCount?
    
    private(set) var isRecording = false
    
    // MARK: Init
    
    init(fileURL: URL, tap: ProcessTap) {
        self.process  = tap.process
        self.fileURL  = fileURL
        self._tap     = tap
        self.logger   = Logger(subsystem: kAppSubsystem,
                               category: "\(String(describing: ProcessTapRecorder.self))(\(fileURL.lastPathComponent))")
    }
    
    private var tap: ProcessTap {
        get throws {
            guard let _tap else { throw "Process tap unavailable" }
            return _tap
        }
    }
    
    // MARK: Recording control
    
    @MainActor
    func start() throws {
        logger.debug(#function)
        
        guard !isRecording else {
            logger.warning("\(#function, privacy: .public) while already recording")
            return
        }
        
        let tap = try tap
        
        if !tap.activated { tap.activate() }
        
        guard var streamDescription = tap.tapStreamDescription else {
            throw "Tap stream description not available."
        }
        
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw "Failed to create AVAudioFormat."
        }
        
        logger.info("""
            🟣 Stream format detected – sampleRate: \(Int(format.sampleRate), privacy: .public) Hz, \
            channels: \(format.channelCount, privacy: .public), \
            interleaved: \(format.isInterleaved, privacy: .public)
            """)
        
        // Prepare file for writing
        let settings: [String: Any] = [
            AVFormatIDKey:        streamDescription.mFormatID,
            AVSampleRateKey:      format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount
        ]
        let file = try AVAudioFile(forWriting: fileURL,
                                   settings: settings,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: format.isInterleaved)
        
        self.currentFile = file
        
        // MARK: Core Audio I/O Block
        try tap.run(on: queue) { [weak self] inNow, inInputData, inInputTime, outOutputData, inOutputTime in
            guard
                let self,
                let currentFile = self.currentFile,
                let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                              bufferListNoCopy: inInputData,
                                              deallocator: nil)
            else { return }
            
            // -----------   Log New buffer format  -----------
            let sr  = buffer.format.sampleRate
            let ch  = buffer.format.channelCount
            if sr != self.lastSampleRate || ch != self.lastChannelCount {
                self.logger.info("""
                    🟣 Stream format detected – sampleRate: \(Int(sr), privacy: .public) Hz, \
                    channels: \(ch, privacy: .public), \
                    frames: \(buffer.frameLength, privacy: .public)
                    """)
                self.lastSampleRate   = sr
                self.lastChannelCount = ch
            }
            // --------------------------------------
            
            do {
                try currentFile.write(from: buffer)
            } catch {
                self.logger.error("File write error: \(error, privacy: .public)")
            }
        } invalidationHandler: { [weak self] _ in
            self?.handleInvalidation()
        }
        
        isRecording = true
    }
    
    func stop() {
        do {
            logger.debug(#function)
            
            guard isRecording else { return }
            
            currentFile = nil
            isRecording = false
            
            try tap.invalidate()
        } catch {
            logger.error("Stop failed: \(error, privacy: .public)")
        }
    }
    
    private func handleInvalidation() {
        guard isRecording else { return }
        logger.debug(#function)
    }
}
