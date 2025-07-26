import Foundation
import CoreAudio
import AudioToolbox
import OSLog
import Observation

/// Lightweight value type representing an input‑capable audio device.
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let name: String
    let isDefault: Bool
    let nominalSampleRate: Double
}

/// Publishes the list of currently available microphone/input devices and
/// tracks hot‑plugging via Core Audio property‑listener blocks.
@MainActor
final class AudioInputDeviceController: ObservableObject {
    // ── Published list ──────────────────────────────────────────────────
    @Published private(set) var devices: [AudioInputDevice] = []
    
    private let logger = Logger(subsystem: kAppSubsystem, category: "AudioInputDeviceController")
    
    // System object listener tokens
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var defaultListener:    AudioObjectPropertyListenerBlock?
    
    deinit {
        // `deinit` can run on any thread; hop to the Main Actor before touching
        // Main‑actor‑isolated state.
        func cleanup() {
            MainActor.assumeIsolated {
                deactivate()
            }
        }
        if Thread.isMainThread {
            cleanup()
        } else {
            DispatchQueue.main.async {
                cleanup()
            }
        }
    }
    
    // ── Activation / deactivation ───────────────────────────────────────
    func activate() {
        guard deviceListListener == nil else { return }
        
        reloadDeviceList()
        
        // Listen for device‑list changes (add/remove)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        deviceListListener = { [weak self] _, _ in self?.reloadDeviceList() }
        AudioObjectAddPropertyListenerBlock(.system,
                                            &addr,
                                            DispatchQueue.main,
                                            deviceListListener!)
        
        // Listen for default‑input change
        addr.mSelector = kAudioHardwarePropertyDefaultInputDevice
        defaultListener = { [weak self] _, _ in self?.reloadDeviceList() }
        AudioObjectAddPropertyListenerBlock(.system,
                                            &addr,
                                            DispatchQueue.main,
                                            defaultListener!)
    }
    
    func deactivate() {
        if let block = deviceListListener {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope:    kAudioObjectPropertyScopeGlobal,
                mElement:  kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(.system, &addr, DispatchQueue.main, block)
            deviceListListener = nil
        }
        
        if let block = defaultListener {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope:    kAudioObjectPropertyScopeGlobal,
                mElement:  kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(.system, &addr, DispatchQueue.main, block)
            defaultListener = nil
        }
    }
    
    // ── Device enumeration ──────────────────────────────────────────────
    private func reloadDeviceList() {
        do {
            let allDeviceIDs = try AudioObjectID.readDeviceList()
            
            let defaultInputID = try AudioObjectID.system.read(
                kAudioHardwarePropertyDefaultInputDevice,
                defaultValue: AudioDeviceID.zero
            )
            
            var newList: [AudioInputDevice] = []
            logger.debug("Enumerating allDeviceIDs: \(allDeviceIDs)")
            for devID in allDeviceIDs {
                var addr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyStreamConfiguration,
                    mScope:    kAudioDevicePropertyScopeInput,
                    mElement:  kAudioObjectPropertyElementMain
                )
                var dataSize: UInt32 = 0
                let err1 = AudioObjectGetPropertyDataSize(devID, &addr, 0, nil, &dataSize)
                if err1 != noErr {
                    logger.error("Failed to get property data size for device \(devID): \(err1)")
                    continue
                }
                if dataSize < MemoryLayout<AudioBufferList>.size {
                    logger.error("Property data size too small (\(dataSize)) for device \(devID)")
                    continue
                }
                
                let bufferList = UnsafeMutableRawPointer.allocate(
                    byteCount: Int(dataSize),
                    alignment: MemoryLayout<AudioBufferList>.alignment
                )
                defer { bufferList.deallocate() }
                
                let err2 = AudioObjectGetPropertyData(devID, &addr, 0, nil, &dataSize, bufferList)
                if err2 != noErr {
                    logger.error("Failed to get property data for device \(devID): \(err2)")
                    continue
                }
                
                let list = bufferList.assumingMemoryBound(to: AudioBufferList.self)
                let abl  = UnsafeMutableAudioBufferListPointer(list)
                let channelCount = abl.reduce(0) { $0 + Int($1.mNumberChannels) }
                if channelCount == 0 {
                    logger.error("Device \(devID) has zero input channels")
                    continue
                }
                
                let name: String = (try? devID.readString(kAudioObjectPropertyName)) ?? "Unknown Device"
                let rate: Double = (try? devID.read(kAudioDevicePropertyNominalSampleRate, defaultValue: 44_100.0)) ?? 44_100.0
                
                newList.append(AudioInputDevice(id: devID,
                                                name: name,
                                                isDefault: devID == defaultInputID,
                                                nominalSampleRate: rate))
            }
            
            self.devices = newList.sorted { $0.isDefault && !$1.isDefault
                || ($0.isDefault == $1.isDefault
                    && $0.name.localizedStandardCompare($1.name) == .orderedAscending) }
            
            logger.debug("Refreshed input‑device list (\(self.devices.count) devices)")
        } catch {
            logger.error("Failed to enumerate devices: \(error, privacy: .public)")
        }
    }
    
}
