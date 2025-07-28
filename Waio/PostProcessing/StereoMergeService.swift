//  Waio/PostProcessing/StereoMergeService.swift
//  Updated 27 Jul 2025 – adds exhaustive logging & mono output
//  ===========================================================

import Foundation
import AVFoundation
import OSLog

// ───────────────────────────── Errors ────────────────────────────────
enum StereoMergeError: LocalizedError {
    case inputFileMissing(URL)
    case notMono(URL)
    case unsupportedFormat(URL)
    case converterCreationFailed(URL)
    case notStereo(URL)
    case writeFailed(URL, underlying: any Error)
    
    var errorDescription: String? {
        switch self {
            case .inputFileMissing(let u):        return "Source file missing: \(u.lastPathComponent)"
            case .notMono(let u):                 return "Expected mono track in \(u.lastPathComponent)"
            case .unsupportedFormat(let u):       return "Unsupported audio format in \(u.lastPathComponent)"
            case .converterCreationFailed(let u): return "Could not create converter for \(u.lastPathComponent)"
            case .notStereo(let u):               return "Expected stereo file at \(u.lastPathComponent)"
            case .writeFailed(let u, let e):      return "Failed writing \(u.lastPathComponent): \(e)"
        }
    }
}

// ─────────────────────── Public entry point ──────────────────────────
@MainActor
enum StereoMergeService {
    
    /// Merges `<base>-output-*.wav` + `<base>-input-*.wav` →
    /// `<base>-split.wav` (stereo) + `<base>-split-mono.wav` (mono).
    static func merge(processURL: URL,
                      micURL: URL,
                      baseName: String,
                      sampleRate: Double = 16_000) async throws
    -> (stereoURL: URL, monoURL: URL) {
        
        let outDir     = processURL.deletingLastPathComponent()
        let stereoURL  = outDir.appendingPathComponent("\(baseName)-merged.wav")
        let monoURL    = outDir.appendingPathComponent("\(baseName)-merged-mono.wav")
        
        let log = Logger(subsystem: kAppSubsystem, category: "StereoMergeService")
        log.debug("▶︎ merge request – proc: \(processURL.lastPathComponent, privacy: .public), mic: \(micURL.lastPathComponent, privacy: .public)")
        
        // Kick heavy work off‑thread
        do {
            try await Task.detached(priority: .utility) {
                try await mergeLoop(processURL: processURL,
                                    micURL:     micURL,
                                    stereoURL:  stereoURL,
                                    monoURL:    monoURL,
                                    sampleRate: sampleRate,
                                    logger:     log)
                
                log.info("✅ merge finished – \(stereoURL.lastPathComponent, privacy: .public) & \(monoURL.lastPathComponent, privacy: .public)")
            }.value
        } catch {
            log.error("❌ merge failed: \(error, privacy: .public)")
            throw error        // propagate so UI layer can react
        }
        
        return (stereoURL, monoURL)
    }
}

// ─────────────────────── Implementation detail ───────────────────────
private extension StereoMergeService {
    
    // 1️⃣ Main work loop – fully isolated
    static func mergeLoop(processURL: URL,
                          micURL: URL,
                          stereoURL: URL,
                          monoURL: URL,
                          sampleRate: Double,
                          logger: Logger) throws
    {
        // ── Preconditions ──────────────────────────────────────────────
        guard FileManager.default.fileExists(atPath: processURL.path)
        else { throw StereoMergeError.inputFileMissing(processURL) }
        guard FileManager.default.fileExists(atPath: micURL.path)
        else { throw StereoMergeError.inputFileMissing(micURL) }
        
        // ── Open sources ───────────────────────────────────────────────
        let procFile: AVAudioFile
        let micFile : AVAudioFile
        do {
            procFile = try AVAudioFile(forReading: processURL)
            
            print("micURL:", micURL.path)
            print("size:", (try? FileManager.default.attributesOfItem(atPath: micURL.path)[.size]) ?? "n/a")
            let f = try AVAudioFile(forReading: micURL)
            micFile  = f
            if #available(macOS 15.0, *) {
                print("file len:", f.length, "proc fmt:", f.processingFormat, "isOpen:", f.isOpen)
            } else {
                // Fallback on earlier versions
            }   // macOS 15+
        } catch {
            logger.error("Failed opening input files: \(error, privacy: .public)")
            throw error
        }
        
        let procFmt = procFile.processingFormat
        let micFmt  = micFile .processingFormat
        
        guard procFmt.channelCount == 1 else { throw StereoMergeError.notMono(processURL) }
        guard micFmt .channelCount == 1 else { throw StereoMergeError.notMono(micURL) }
        
        // ── Destinations ───────────────────────────────────────────────
        let stereoFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate:   sampleRate,
                                      channels:     2,
                                      interleaved:  false)!
        let monoFmt   = stereoFmt.monoLayout
        
        let stereoFile: AVAudioFile
        let monoFile  : AVAudioFile
        do {
            stereoFile = try AVAudioFile(forWriting: stereoURL,
                                         settings: stereoFmt.settings,
                                         commonFormat: .pcmFormatFloat32,
                                         interleaved: false)
            monoFile   = try AVAudioFile(forWriting: monoURL,
                                         settings: monoFmt.settings,
                                         commonFormat: .pcmFormatFloat32,
                                         interleaved: false)
        } catch {
            logger.error("Failed opening output files: \(error, privacy: .public)")
            throw error
        }
        
        // ── Optional converters (SR / format) ─────────────────────────
        let procConv = try makeConverter(input: procFmt,
                                         targetMonoSR: sampleRate,
                                         stereoFmt: stereoFmt,
                                         srcURL: processURL,
                                         logger: logger)
        let micConv  = try makeConverter(input: micFmt,
                                         targetMonoSR: sampleRate,
                                         stereoFmt: stereoFmt,
                                         srcURL: micURL,
                                         logger: logger)
        
        logger.debug("Running merge loop – chunk 4 096 f")
        // ── Processing loop ────────────────────────────────────────────
        let chunk: AVAudioFrameCount = 4_096
        loop: while true {
            // ❶ read next pair ----------------------------------------------------
            let pRaw: AVAudioPCMBuffer
            let mRaw: AVAudioPCMBuffer
            do {
                guard let pair = try nextChunk(procFile: procFile,
                                               micFile:  micFile,
                                               chunk:    chunk,
                                               procFmt:  procFmt,
                                               micFmt:   micFmt,
                                               logger:   logger)
                else {
                    logger.debug("EOF reached – merge complete")
                    break loop
                }
                pRaw = pair.0
                mRaw = pair.1
            } catch {
                logger.error("nextChunk threw: \(error, privacy: .public)")
                throw error
            }
            
            // skip silent pair
            guard pRaw.frameLength > 0 || mRaw.frameLength > 0 else { continue }
            
            // ❷ SRC / format‑convert --------------------------------------------
            let left: AVAudioPCMBuffer
            do {
                left = try pRaw.converted(using: procConv)
            } catch {
                logger.error("procConv failed: \(error, privacy: .public)")
                throw error
            }
            
            let right: AVAudioPCMBuffer
            do {
                right = try mRaw.converted(using: micConv)
            } catch {
                logger.error("micConv failed: \(error, privacy: .public)")
                throw error
            }
            
            // skip if nothing came out
            let frames = max(left.frameLength, right.frameLength)
            guard frames > 0 else { continue }
            
            // ❸ build out‑buffers -----------------------------------------------
            guard
                let stereoBuf = AVAudioPCMBuffer(pcmFormat: stereoFmt,
                                                 frameCapacity: frames),
                let monoBuf   = AVAudioPCMBuffer(pcmFormat: monoFmt,
                                                 frameCapacity: frames)
            else { continue }
            
            stereoBuf.frameLength = frames
            monoBuf  .frameLength = frames
            memset(stereoBuf.floatChannelData![0], 0,
                   Int(frames) * MemoryLayout<Float>.size)
            memset(stereoBuf.floatChannelData![1], 0,
                   Int(frames) * MemoryLayout<Float>.size)
            
            safeCopy(from: left,  toChannel: 0, dst: stereoBuf)
            safeCopy(from: right, toChannel: 1, dst: stereoBuf)
            
            // down‑mix L+R → mono
            if let l = stereoBuf.floatChannelData?[0],
               let r = stereoBuf.floatChannelData?[1],
               let m = monoBuf.floatChannelData?[0] {
                let n = Int(frames)
                for i in 0..<n { m[i] = 0.5 * (l[i] + r[i]) }
            }
            
            // ❹ write ------------------------------------------------------------
            do {
                try stereoFile.write(from: stereoBuf)
            } catch {
                logger.error("stereo write failed: \(error, privacy: .public)")
                throw StereoMergeError.writeFailed(stereoURL, underlying: error)
            }
            
            do {
                try monoFile.write(from: monoBuf)
            } catch {
                logger.error("mono write failed: \(error, privacy: .public)")
                throw StereoMergeError.writeFailed(monoURL, underlying: error)
            }
        }
    }
    
    // 2️⃣ Read helpers --------------------------------------------------
    private static func nextChunk(procFile: AVAudioFile,
                                  micFile : AVAudioFile,
                                  chunk   : AVAudioFrameCount,
                                  procFmt : AVAudioFormat,
                                  micFmt  : AVAudioFormat,
                                  logger  : Logger) throws
    -> (AVAudioPCMBuffer, AVAudioPCMBuffer)?
    {
        // Helper that returns the number of **remaining** frames for a file
        func remainingFrames(of f: AVAudioFile) -> AVAudioFramePosition {
            if #available(macOS 15, *) {
                return f.length - f.framePosition
            } else {
                // On older SDKs `length` is still available but not `isOpen`
                return f.length - f.framePosition
            }
        }
        
        //------------------------------------------------------------------
        // Process track
        //------------------------------------------------------------------
        let pBuf: AVAudioPCMBuffer?
        do {
            let want = AVAudioFrameCount(min(AVAudioFramePosition(chunk),
                                             remainingFrames(of: procFile)))
            if want > 0 {
                pBuf = try procFile.readPCMChunk(maxFrames: want)
            } else {
                pBuf = nil   // already at EOF
            }
        } catch {
            logger.error("procFile.readPCMChunk() failed: \(error, privacy: .public)")
            throw error
        }
        
        //------------------------------------------------------------------
        // Mic track
        //------------------------------------------------------------------
        let mBuf: AVAudioPCMBuffer?
        do {
            let want = AVAudioFrameCount(min(AVAudioFramePosition(chunk),
                                             remainingFrames(of: micFile)))
            if want > 0 {
                mBuf = try micFile.readPCMChunk(maxFrames: want)
            } else {
                mBuf = nil
            }
        } catch {
            logger.error("micFile.readPCMChunk() failed: \(error, privacy: .public)")
            throw error
        }
        
        //------------------------------------------------------------------
        // End‑of‑file reached for BOTH sources
        //------------------------------------------------------------------
        if pBuf == nil && mBuf == nil { return nil }
        
        //------------------------------------------------------------------
        // Substitute silence where a buffer is missing (unequal lengths)
        //------------------------------------------------------------------
        let left  = pBuf ?? procFmt.silence(frames: mBuf?.frameLength ?? 0)
        let right = mBuf ?? micFmt .silence(frames: left.frameLength)
        
        return (left, right)
    }
    
    // 3️⃣ Converter factory --------------------------------------------
    private static func makeConverter(input: AVAudioFormat,
                                      targetMonoSR: Double,
                                      stereoFmt: AVAudioFormat,
                                      srcURL: URL,
                                      logger: Logger) throws -> AVAudioConverter?
    {
        guard input.sampleRate != targetMonoSR ||
                input.commonFormat != .pcmFormatFloat32 else { return nil }
        
        guard let c = AVAudioConverter(from: input, to: stereoFmt.monoLayout)
        else { throw StereoMergeError.converterCreationFailed(srcURL) }
        
        if #available(macOS 14, iOS 17, tvOS 17, *) { c.sampleRateConverterQuality = .max }
        logger.debug("Built converter for \(srcURL.lastPathComponent, privacy: .public) – \(Int(input.sampleRate)) → \(Int(targetMonoSR)) Hz")
        return c
    }
    
    // 4️⃣ Safe channel copy --------------------------------------------
    private static func safeCopy(from src: AVAudioPCMBuffer,
                                 toChannel ch: Int,
                                 dst dstBuf: AVAudioPCMBuffer)
    {
        guard ch < dstBuf.format.channelCount else { return }
        guard src.frameLength > 0 else { return }
        guard let srcPtr = src.floatChannelData?[0],
              let dstPtr = dstBuf.floatChannelData?[ch] else { return }
        
        memcpy(dstPtr,
               srcPtr,
               Int(src.frameLength) * MemoryLayout<Float>.size)
    }
}

// ───────────────────────── Convenience ───────────────────────────────
private extension AVAudioFormat {
    var monoLayout: AVAudioFormat {
        AVAudioFormat(commonFormat: commonFormat,
                      sampleRate:   sampleRate,
                      channels:     1,
                      interleaved:  false)!
    }
    func silence(frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: monoLayout, frameCapacity: frames)!
        b.frameLength = frames
        return b
    }
}

private extension AVAudioFile {
    func readPCMChunk(maxFrames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        guard let buf = AVAudioPCMBuffer(pcmFormat: processingFormat,
                                         frameCapacity: maxFrames) else { return nil }
        try read(into: buf, frameCount: maxFrames)
        return buf.frameLength == 0 ? nil : buf
    }
}

private extension AVAudioPCMBuffer {
    func converted(using conv: AVAudioConverter?) throws -> AVAudioPCMBuffer {
        guard let conv else { return self }
        
        let dstFmt = conv.outputFormat
        let ratio  = dstFmt.sampleRate / format.sampleRate
        let need   = AVAudioFrameCount((Double(frameLength) * ratio).rounded(.up) + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: dstFmt, frameCapacity: need)
        else { throw StereoMergeError.unsupportedFormat(URL(fileURLWithPath: "(memory)")) }
        
        var err: NSError?
        var handed = false
        _ = conv.convert(to: out, error: &err) { _, status -> AVAudioBuffer? in
            if handed { status.pointee = .noDataNow; return nil }
            handed = true
            status.pointee = .haveData
            return self
        }
        if let err { throw err }
        return out
    }
}
