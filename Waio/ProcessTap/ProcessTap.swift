
import SwiftUI
import AudioToolbox
import OSLog
@preconcurrency import AVFoundation
@preconcurrency import AVFAudio

// ── Compatibility shim (for SDKs prior to macOS 15) ─────────────────────────
/// New in macOS 15: lets the tap deliver digital‑silence buffers while the
/// host process is idle.  On older SDKs the symbol is absent, so we define
/// it manually; Core Audio simply ignores unknown keys at runtime.
private let kAudioSubTapProvidesSilenceWhenHostProcessIsSilentKey: CFString =
"kAudioSubTapProvidesSilenceWhenHostProcessIsSilentKey" as CFString

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
    
    @ObservationIgnored private var formatListenerAddress = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    @ObservationIgnored private var formatListenerBlock: AudioObjectPropertyListenerBlock?
    
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
        
        if let block = formatListenerBlock {
            var addr = formatListenerAddress
            let err = AudioObjectRemovePropertyListenerBlock(processTapID, &addr, DispatchQueue.main, block)
            if err != noErr {
                logger.warning("Failed to remove format listener: \(err)")
            }
            formatListenerBlock = nil
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
        
        var tapDescription = CATapDescription(stereoMixdownOfProcesses: [objectID])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = muteWhenRunning ? .mutedWhenTapped : .unmuted
        
        var tapID: AUAudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        if err != noErr {
            errorMessage = "Process tap creation failed with error \(err)"
            return
        }
        
        logger.debug("Created process tap #\(tapID, privacy: .public)")
        processTapID = tapID
        
        // Aggregate‑device plumbing
        let systemOutputID = try AudioDeviceID.readDefaultSystemOutputDevice()
        let outputUID      = try systemOutputID.readDeviceUID()
        let aggregateUID   = UUID().uuidString
        
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey:          "Tap-\(process.id)",
            kAudioAggregateDeviceUIDKey:           aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey:     true,
            kAudioAggregateDeviceIsStackedKey:     false,
            kAudioAggregateDeviceTapAutoStartKey:  true,
            
            // Keep the original output as the sole sub‑device
            kAudioAggregateDeviceSubDeviceListKey: [
                [ kAudioSubDeviceUIDKey: outputUID ]
            ],
            
            // Attach our tap – make it *emit silence* when host process is silent
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey:             true,
                    kAudioSubTapUIDKey:                           tapDescription.uuid.uuidString,
                    kAudioSubTapProvidesSilenceWhenHostProcessIsSilentKey: true
                ]
            ]
        ]
        
        tapStreamDescription = try tapID.readAudioTapStreamBasicDescription()
        registerFormatChangeListener()
        
        aggregateDeviceID = .unknown
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateDeviceID)
        guard err == noErr else { throw "Failed to create aggregate device: \(err)" }
        let aggregateDeviceID = aggregateDeviceID
        logger.debug("Created aggregate device #\(aggregateDeviceID, privacy: .public)")
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
    
    // MARK: Format‑change monitoring
    private func registerFormatChangeListener() {
        guard processTapID.isValid else { return }
        
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            do {
                let newDesc = try self.processTapID.readAudioTapStreamBasicDescription()
                self.tapStreamDescription = newDesc
                self.logger.info("🔄 Tap format changed – sampleRate: \(Int(newDesc.mSampleRate)) Hz, channels: \(newDesc.mChannelsPerFrame)")
            } catch {
                self.logger.error("Failed to read format on change: \(error)")
            }
        }
        formatListenerBlock = block
        
        var addr = formatListenerAddress
        let err = AudioObjectAddPropertyListenerBlock(processTapID, &addr, DispatchQueue.main, block)
        if err != noErr {
            logger.warning("Failed to add format listener: \(err)")
        }
    }
    
    deinit { invalidate() }
}

// MARK: - ProcessTapRecorder

@Observable
final class ProcessTapRecorder {
    
    // Persistent timing state for effective‑sample‑rate measurement
    @ObservationIgnored private var lastHostTime: UInt64 = 0
    @ObservationIgnored private var startHostTime: UInt64 = 0
    /// We skip padding for micro‑gaps shorter than this at the output rate.
    private let minGapFramesOut: AVAudioFrameCount = 32
    
    // Mach‑time tick conversion factor
    private static let hostTicksPerSecond: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return 1_000_000_000.0 * Double(tb.denom) / Double(tb.numer)
    }()
    
    // MARK: Public API
    
    let fileURL: URL
    let process: AudioProcess
    
    // ── Resampling configuration ────────────────────────────────────────────
    private let targetSampleRate: Double
    private let targetChannels: AVAudioChannelCount
    
    // ── Dynamic‑rate tracking ─────────────────────────────────────────
    private let driftThreshold: Double = 0.001          // 0.1 % tolerance
    private let smoothingAlpha: Double  = 0.1            // EMA weight
    @ObservationIgnored private var smoothedEffectiveSampleRate: Double = 0
    @ObservationIgnored private var converterInputSampleRate: Double = 0
    
    // Hysteresis for large, asynchronous sample‑rate jumps (e.g. 48 k → 24 k when a VoIP call starts)
    private let largeChangeRatio: Double = 0.05      // 5 % or more is considered a *new* rate, not drift
                                                     /// Common telephony / media sample‑rates we will snap to (Hz)
    private static let nominalRates: [Double] = [
        8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000
    ]
    
    /// Pick the nearest nominal rate for a measured value
    private static func nearestNominal(_ measured: Double) -> Double {
        nominalRates.min(by: { abs($0 - measured) < abs($1 - measured) }) ?? measured
    }
    private let consecutiveConfirmationsNeeded = 8   // how many successive buffers must confirm the new rate
    @ObservationIgnored private var pendingRate: Double?
    @ObservationIgnored private var confirmationCount: Int = 0
    
    // Current converter state (writerQueue‑confined)
    @ObservationIgnored private var sourceFormat: AVAudioFormat?
    @ObservationIgnored private var targetFormat: AVAudioFormat?
    @ObservationIgnored private var converter: AVAudioConverter?
    
    // Helper that always builds a high‑quality converter
    private func makeConverter(input: AVAudioFormat, output: AVAudioFormat) -> AVAudioConverter? {
        guard let c = AVAudioConverter(from: input, to: output) else { return nil }
        c.sampleRateConverterQuality   = .max      // 96‑tap sinc SRC
        c.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal   // polyphase windowed‑sinc
        c.primeMethod                  = .normal   // prime filter delay line
        if input.channelCount > output.channelCount { c.downmix = true }
        return c
    }
    
    // MARK: Private
    
    private let queue  = DispatchQueue(label: "ProcessTapRecorder", qos: .userInitiated)
    /// Serial queue dedicated to non‑real‑time file I/O
    private let writerQueue = DispatchQueue(label: "ProcessTapRecorder.Writer", qos: .utility)
    private let logger: Logger
    
    @ObservationIgnored private weak var _tap: ProcessTap?
    @ObservationIgnored private var currentFile: AVAudioFile?
    
    private(set) var isRecording = false
    
    // MARK: Init
    
    init(fileURL: URL,
         tap: ProcessTap,
         targetSampleRate: Double = 16_000,
         targetChannels: AVAudioChannelCount = 1) {
        self.process  = tap.process
        self.fileURL  = fileURL
        self._tap     = tap
        self.targetSampleRate = targetSampleRate
        self.targetChannels   = targetChannels
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
        
        self.sourceFormat = format
        
        guard let tgtFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: targetSampleRate,
                                            channels: targetChannels,
                                            interleaved: false) else {
            throw "Failed to create target AVAudioFormat."
        }
        self.targetFormat = tgtFormat
        
        self.converter = makeConverter(input: format, output: tgtFormat)
        self.converterInputSampleRate = format.sampleRate
        
        let file = try AVAudioFile(forWriting: fileURL,
                                   settings: tgtFormat.settings,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        self.currentFile = file
        // initialise real‑time baseline
        self.startHostTime = mach_absolute_time()
        self.lastHostTime  = self.startHostTime
        
        // MARK: Core Audio I/O Block
        try tap.run(on: queue) { [weak self] inNow, inInputData, inInputTime, outOutputData, inOutputTime in
            // --- Read live format and create buffer ---
            guard var desc = tap.tapStreamDescription else { return }
            guard let inFmt = AVAudioFormat(streamDescription: &desc) else { return }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: inFmt,
                                                bufferListNoCopy: inInputData,
                                                deallocator: nil) else { return }
            // Detect and rebuild converter if input format changed
            if inFmt != self?.converter?.inputFormat {
                self?.writerQueue.async { [weak self] in
                    guard let self, let tgt = self.targetFormat else { return }
                    self.converter = self.makeConverter(input: inFmt, output: tgt)
                    self.converterInputSampleRate = inFmt.sampleRate
                    self.logger.info("🔄 Rebuilt converter for \(Int(inFmt.sampleRate)) Hz / \(inFmt.channelCount)ch")
                }
            }
            guard let self,
                  let currentFile = self.currentFile
            else { return }
            
            // --- Real‑time gap detection ---------------------------------
            let nowHost = inInputTime.pointee.mHostTime
            // Use a signed difference to avoid trapping on wrap‑around or clock jitter
            let deltaTicks: UInt64 = nowHost >= self.lastHostTime
            ? nowHost - self.lastHostTime
            : 0                       // if clock moved backwards, treat as zero gap
            
            let deltaSec = Double(deltaTicks) / Self.hostTicksPerSecond
            let expectedIn = deltaSec * self.converterInputSampleRate
            let gapIn = expectedIn - Double(buffer.frameLength)
            let gapSec = max(0, gapIn / self.converterInputSampleRate)
            self.lastHostTime = nowHost
            // ----------------------------------------------------------------
            
            // --- Effective sample‑rate measurement ---------------------------------
            var effectiveSR = self.converterInputSampleRate
            let thisHostTime = nowHost
            if self.lastHostTime != 0, thisHostTime > self.lastHostTime {
                effectiveSR = Double(buffer.frameLength) /
                (Double(thisHostTime - self.lastHostTime) / Self.hostTicksPerSecond)
                self.logger.info("🟢 Effective sample rate ≈ \(Int(effectiveSR)) Hz")
                
                // Exponential‑moving‑average smoothing
                if self.smoothedEffectiveSampleRate == 0 {
                    self.smoothedEffectiveSampleRate = effectiveSR
                } else {
                    self.smoothedEffectiveSampleRate =
                    self.smoothedEffectiveSampleRate * (1 - self.smoothingAlpha) +
                    effectiveSR * self.smoothingAlpha
                }
                // self.lastHostTime = thisHostTime -- already set above
            } else {
                // self.lastHostTime = thisHostTime -- already set above
            }
            // -----------------------------------------------------------------------
            
            // Pass the raw rate to the writer queue
            let capturedEffSR = effectiveSR
            
            // Deep‑copy the no‑copy buffer so its memory is valid outside the RT callback
            guard
                let ownedBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                                   frameCapacity: buffer.frameCapacity)
            else { return }
            
            ownedBuffer.frameLength = buffer.frameLength
            // Explicit memcpy of sample data for compatibility with all SDKs
            if buffer.format.isInterleaved {
                // Interleaved: all channels stored sequentially in one buffer
                if let src = buffer.floatChannelData?[0],
                   let dst = ownedBuffer.floatChannelData?[0] {
                    let byteCount = Int(buffer.frameLength) *
                    Int(buffer.format.channelCount) *
                    MemoryLayout<Float>.size
                    memcpy(dst, src, byteCount)
                }
            } else {
                // Non‑interleaved (planar): copy channel‑by‑channel
                for ch in 0 ..< Int(buffer.format.channelCount) {
                    if let src = buffer.floatChannelData?[ch],
                       let dst = ownedBuffer.floatChannelData?[ch] {
                        let byteCount = Int(buffer.frameLength) * MemoryLayout<Float>.size
                        memcpy(dst, src, byteCount)
                    }
                }
            }
            
            // Offload disk I/O to the writer queue to keep the audio callback real‑time safe
            self.writerQueue.async(execute: { [weak self, ownedBuffer, capturedEffSR, gapSec] in
                // -------------------------------------------------------------------
                // Ensure `self` is still alive before touching any properties.
                // -------------------------------------------------------------------
                guard let self = self,
                      let tgtFormat = self.targetFormat else { return }
                
                // ❶ Inject digital silence for any detected gap
                if gapSec > 0 {
                    let gapFrames = AVAudioFrameCount(round(gapSec * tgtFormat.sampleRate))
                    if gapFrames >= self.minGapFramesOut,
                       let silent = AVAudioPCMBuffer(pcmFormat: tgtFormat,
                                                     frameCapacity: gapFrames) {
                        silent.frameLength = gapFrames   // buffer already zero‑filled
                        try? self.currentFile?.write(from: silent)
                    }
                }
                
                // --- Snap to nearest nominal rate and rebuild converter for stable SRC ---
                let nominalSR = Self.nearestNominal(capturedEffSR)
                let diffRatio = abs(nominalSR - self.converterInputSampleRate) / self.converterInputSampleRate
                if diffRatio >= self.largeChangeRatio,
                   let newInFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: nominalSR,
                                                channels: ownedBuffer.format.channelCount,
                                                interleaved: ownedBuffer.format.isInterleaved) {
                    self.converter = self.makeConverter(input: newInFmt, output: tgtFormat)
                    self.converterInputSampleRate = nominalSR
                    self.logger.info("🚨 Detected new base rate – rebuilt converter for \(Int(nominalSR)) Hz (quality: max)")
                }
                
                // Ensure buffer format matches converter.inputFormat; otherwise
                // reinterpret samples in a new buffer with the correct ASBD.
                var inBuffer = ownedBuffer
                guard let converter = self.converter else { return }
                if ownedBuffer.format != converter.inputFormat,
                   let compat = AVAudioPCMBuffer(pcmFormat: converter.inputFormat,
                                                 frameCapacity: ownedBuffer.frameLength) {
                    compat.frameLength = ownedBuffer.frameLength
                    // Sample‑for‑sample copy (format is always float32 here)
                    let channels = Int(converter.inputFormat.channelCount)
                    for ch in 0..<channels {
                        if let src = ownedBuffer.floatChannelData?[ch],
                           let dst = compat.floatChannelData?[ch] {
                            memcpy(dst, src, Int(ownedBuffer.frameLength) * MemoryLayout<Float>.size)
                        }
                    }
                    inBuffer = compat
                }
                
                // Output‑capacity estimate: allow for SRC in either direction
                let ratio = tgtFormat.sampleRate / converter.inputFormat.sampleRate
                let estimated = Double(ownedBuffer.frameLength) * ratio          // expected frame count after SRC
                                                                                 // Always allocate at least input length + 32 frames to avoid truncation
                let capacity = max(Double(ownedBuffer.frameLength), estimated).rounded(.up) + 32
                let neededFrames = AVAudioFrameCount(capacity)
                guard let outBuffer = AVAudioPCMBuffer(pcmFormat: tgtFormat,
                                                       frameCapacity: neededFrames) else { return }
                
                do {
                    if converter.inputFormat.sampleRate == converter.outputFormat.sampleRate {
                        // No sample‑rate conversion needed
                        try converter.convert(to: outBuffer, from: inBuffer)
                    } else {
                        // Use the streaming API for SRC
                        var error: NSError?
                        var handedOff = false
                        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus -> AVAudioBuffer? in
                            if !handedOff {
                                handedOff = true
                                outStatus.pointee = .haveData
                                return inBuffer
                            } else {
                                outStatus.pointee = .noDataNow
                                return nil
                            }
                        }
                        if status == .error, let err = error { throw err }
                    }
                    self.logger.debug("converted \(inBuffer.frameLength) → \(outBuffer.frameLength)")
                    try self.currentFile?.write(from: outBuffer)
                } catch {
                    self.logger.error("Conversion/write error: \(error, privacy: .public)")
                }
            })
        } invalidationHandler: { [weak self] _ in
            self?.handleInvalidation()
        }
        
        isRecording = true
    }
    
    func stop() {
        do {
            logger.debug(#function)
            
            guard isRecording else { return }
            
            flushTrailingSilence()
            currentFile = nil
            isRecording = false
            
            try tap.invalidate()
        } catch {
            logger.error("Stop failed: \(error, privacy: .public)")
        }
    }
    
    /// Pads the tail of the file with zeros so duration matches wall‑clock.
    private func flushTrailingSilence() {
        guard let tgt = targetFormat,
              let file = currentFile else { return }
        
        let deltaSec = Double(mach_absolute_time() - lastHostTime) / Self.hostTicksPerSecond
        let frames   = AVAudioFrameCount(round(deltaSec * tgt.sampleRate))
        guard frames >= minGapFramesOut,
              let silent = AVAudioPCMBuffer(pcmFormat: tgt, frameCapacity: frames) else { return }
        
        silent.frameLength = frames
        try? file.write(from: silent)
    }
    
    private func handleInvalidation() {
        guard isRecording else { return }
        logger.debug(#function)
    }
}
