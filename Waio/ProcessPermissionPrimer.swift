//
//  ProcessPermissionPrimer.swift
//  Waio
//
//  Created by Ivan Oparin on 27.07.2025.
//


import Foundation
import CoreAudio
import OSLog
import Darwin                          // for proc_name / proc_pidpath

/// Triggers the macOS “Audio Capture” permission dialog at a moment chosen
/// by the user.  It does so by briefly recording from a permanently running
/// system daemon (e.g. universalaccessd), then discarding the file.
enum ProcessPermissionPrimer {
    
    private static let logger = Logger(subsystem: kAppSubsystem,
                                       category: "ProcessPermissionPrimer")
    
    /// Invoke to show the permission prompt.  Returns after the dummy
    /// recording has started and stopped (≈ 0.5 s).
    @MainActor
    static func prime() async throws {
        logger.debug("Priming system‑audio permission …")
        
        // 1️⃣ Find a suitable always‑running process.
        guard let process = try findFallbackProcess() else {
            throw "No suitable host process found – cannot prime permission."
        }
        
        // 2️⃣ Fire up a tap/recorder for ~½ s – enough for the prompt to appear.
        let tap = ProcessTap(process: process, muteWhenRunning: true)
        tap.activate()
        
        let tmpURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("prime-\(UUID().uuidString).wav")
        
        let recorder = ProcessTapRecorder(
            fileURL: tmpURL,
            tap: tap,
            targetSampleRate: 8_000,
            targetChannels: 1
        )
        
        try recorder.start()
        try await Task.sleep(nanoseconds: 500_000_000)   // 0.5 s
        recorder.stop()
        
        // 3️⃣ Clean up the temporary artefacts.
        try? FileManager.default.removeItem(at: tmpURL)
        logger.info("System‑audio permission primed successfully.")
    }
    
    // MARK: – Helpers ---------------------------------------------------
    /// List of daemons that should exist on every macOS installation.
    private static let fallbackNames = ["universalaccessd", "audioaccessoryd"]
    
    private static func findFallbackProcess() throws -> AudioProcess? {
        for objectID in try AudioObjectID.readProcessList() {
            let pid: pid_t =
            (try? objectID.read(kAudioProcessPropertyPID, defaultValue: -1)) ?? -1
            guard pid > 0 else { continue }
            if let info = processInfo(for: pid),
               fallbackNames.contains(info.name) {
                return try AudioProcess(objectID: objectID, pid: pid)
            }
        }
        return nil
    }
    
    /// Local copy of `processInfo(for:)` (kept internal to avoid dependency
    /// on the one inside *AudioProcessController.swift*).
    private static func processInfo(for pid: pid_t) -> (name: String, path: String)? {
        let nameBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(MAXPATHLEN))
        let pathBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(MAXPATHLEN))
        defer {
            nameBuf.deallocate()
            pathBuf.deallocate()
        }
        let nLen = proc_name(pid, nameBuf, UInt32(MAXPATHLEN))
        let pLen = proc_pidpath(pid, pathBuf, UInt32(MAXPATHLEN))
        guard nLen > 0, pLen > 0 else { return nil }
        let name = String(cString: nameBuf)
        let path = String(cString: pathBuf)
        return (name, path)
    }
    
}
