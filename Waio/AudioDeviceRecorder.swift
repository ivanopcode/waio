//
//  AudioDeviceRecorder.swift
//  Waio
//
//  Updated 26 Jul 2025 – fixes distortion caused by unsafe buffer reuse
//

import Foundation
import CoreAudio
import AVFoundation
import OSLog
import Observation

/// Records from a physical / virtual audio‑input device (microphone, interface, etc.)
/// into a WAV file. Samples are always converted to `targetSampleRate` Hz / `targetChannels` ch
/// using a high‑quality `AVAudioConverter` identical to the one employed in `ProcessTapRecorder`.
@Observable
@MainActor
final class AudioDeviceRecorder {
    
    // ── Public configuration ───────────────────────────────────────────
    let fileURL: URL
    let device : AudioInputDevice
    private let targetSampleRate: Double
    private let targetChannels  : AVAudioChannelCount
    
    // ── Public state ───────────────────────────────────────────────────
    private(set) var isRecording = false
    
    // ── Internals ───────────────────────────────────────────────────────
    private let engine       = AVAudioEngine()
    private var converter    : AVAudioConverter?
    private var outputFile   : AVAudioFile?
    private let writerQueue  = DispatchQueue(label: "AudioDeviceRecorder.Writer",
                                             qos: .utility)
    private let logger       : Logger
    
    // MARK: ‑ Init -------------------------------------------------------
    init(fileURL: URL,
         device: AudioInputDevice,
         targetSampleRate: Double = 16_000,
         targetChannels:   AVAudioChannelCount = 1)
    {
        self.fileURL          = fileURL
        self.device           = device
        self.targetSampleRate = targetSampleRate
        self.targetChannels   = targetChannels
        self.logger = Logger(subsystem: kAppSubsystem,
                             category: "\(String(describing: Self.self))(\(fileURL.lastPathComponent))")
    }
    
    // MARK: ‑ Recording control -----------------------------------------
    func start() throws {
        guard !isRecording else { return }
        
        try prepareEngine()
        try engine.start()
        
        isRecording = true
        let deviceName = device.name
        let fileURL = fileURL
        logger.info("▶️ Started recording “\(deviceName)” → \(fileURL.lastPathComponent)")
    }
    
    func stop() {
        guard isRecording else { return }
        
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        outputFile = nil
        isRecording = false
        logger.info("⏹️ Stopped recording")
    }
    
    // MARK: ‑ Engine / Tap setup ----------------------------------------
    private func prepareEngine() throws {
#if os(iOS) || os(tvOS)
        // iOS 17 / tvOS 17+ – AVAudioSession is available on Apple Silicon Macs as well,
        // but we preserve the HAL path for older macOS.
        if let session = AVAudioSession.sharedInstanceIfAvailable,
           let port = session.setPreferredInputDevice(id: device.id) {
            logger.info("Selected device via AVAudioSession: \(port.portName)")
        } else {
            try AVAudioDeviceTransportManager.setDevice(engine: engine, deviceID: device.id)
        }
#else
        try AVAudioDeviceTransportManager.setDevice(engine: engine, deviceID: device.id)
#endif
        try installTap()
    }
    
    /// Creates input‑node tap, deep‑copies each buffer and hands it to `writerQueue`.
    private func installTap() throws {
        let inFormat = engine.inputNode.inputFormat(forBus: 0)
        logger.info("Input format – \(Int(inFormat.sampleRate)) Hz, \(inFormat.channelCount) ch")
        
        // Target file format (always float32, non‑interleaved)
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: targetSampleRate,
                                               channels: targetChannels,
                                               interleaved: false) else {
            throw "Failed to create target format"
        }
        self.converter = AVAudioConverter(from: inFormat, to: targetFormat)
        self.outputFile = try AVAudioFile(forWriting: fileURL,
                                          settings: targetFormat.settings,
                                          commonFormat: .pcmFormatFloat32,
                                          interleaved: false)
        
        engine.inputNode.installTap(onBus: 0,
                                    bufferSize: 1_024,
                                    format: inFormat)
        { [weak self] buffer, _ /* time */ in
            guard let self else { return }
            
            // --- Deep‑copy the buffer so it survives outside the real‑time callback ----
            guard let owned = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                               frameCapacity: buffer.frameLength) else { return }
            owned.frameLength = buffer.frameLength
            
            if buffer.format.isInterleaved {
                if let src = buffer.floatChannelData?[0],
                   let dst = owned.floatChannelData?[0] {
                    let bytes = Int(buffer.frameLength) *
                    Int(buffer.format.channelCount) *
                    MemoryLayout<Float>.size
                    memcpy(dst, src, bytes)
                }
            } else {
                let channels = Int(buffer.format.channelCount)
                for ch in 0..<channels {
                    if let src = buffer.floatChannelData?[ch],
                       let dst = owned.floatChannelData?[ch] {
                        memcpy(dst, src,
                               Int(buffer.frameLength) * MemoryLayout<Float>.size)
                    }
                }
            }
            // ---------------------------------------------------------------------------
            
            self.writerQueue.async { [weak self, owned] in
                self?.handle(buffer: owned, targetFormat: targetFormat)
            }
        }
    }
    
    // MARK: ‑ Buffer handling (writerQueue) -----------------------------
    private func handle(buffer owned: AVAudioPCMBuffer,
                        targetFormat: AVAudioFormat)
    {
        guard let outputFile else { return }
        
        // -- Rebuild converter if input format ever changes -------------
        if converter?.inputFormat != owned.format {
            logger.info("🔄 Input format changed – rebuilding converter")
            converter = AVAudioConverter(from: owned.format, to: targetFormat)
        }
        guard let converter else { return }
        // ----------------------------------------------------------------
        
        // Allocate output buffer large enough for SRC ratio
        let ratio = targetFormat.sampleRate / owned.format.sampleRate
        let estFrames = AVAudioFrameCount(Double(owned.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                         frameCapacity: max(owned.frameLength, estFrames)) else { return }
        
        do {
            if converter.inputFormat.sampleRate == converter.outputFormat.sampleRate &&
                converter.inputFormat.channelCount == converter.outputFormat.channelCount {
                // Only format layout differs (e.g. interleaved vs planar) – cheap path
                try converter.convert(to: out, from: owned)
            } else {
                var error: NSError?
                var handedOff = false
                let status = converter.convert(to: out, error: &error) { _, outStatus -> AVAudioBuffer? in
                    if !handedOff {
                        handedOff = true
                        outStatus.pointee = .haveData
                        return owned
                    } else {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                }
                if status == .error, let err = error { throw err }
            }
            
            if out.frameLength > 0 {
                try outputFile.write(from: out)
            }
        } catch {
            logger.error("Conversion / write error: \(error, privacy: .public)")
        }
    }
}

// MARK: ‑ AVAudioSession helpers (iOS / tvOS / macOS14+)
#if os(iOS) || os(tvOS)
import AVFAudio
private extension AVAudioSession {
    static var sharedInstanceIfAvailable: AVAudioSession? {
        AVAudioSession.sharedInstance()
    }
    @discardableResult
    func setPreferredInputDevice(id deviceID: AudioDeviceID) -> AVAudioSessionPortDescription? {
        guard let port = availableInputs?.first(where: { $0.uid == deviceID.caUID }) else { return nil }
        try? setPreferredInput(port)
        return port
    }
}
private extension AudioDeviceID {
    var caUID: String? { try? readString(kAudioDevicePropertyDeviceUID) }
}
#endif

// MARK: ‑ Core Audio HAL fallback (macOS <14)
private enum AVAudioDeviceTransportManager {
    static func setDevice(engine: AVAudioEngine, deviceID: AudioDeviceID) throws {
        var devID = deviceID
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        let err = AudioObjectSetPropertyData(.system,
                                             &addr,
                                             0,
                                             nil,
                                             UInt32(MemoryLayout<AudioDeviceID>.size),
                                             &devID)
        guard err == noErr else { throw "Failed to set default input device: \(err)" }
    }
}
