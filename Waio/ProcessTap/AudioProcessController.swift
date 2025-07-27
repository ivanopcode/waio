import SwiftUI
import AudioToolbox
import OSLog
import Combine
import OrderedCollections
import Darwin

struct AudioProcess: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case process
        case app
        
        var sortPriority: Int {
            switch self {
                case .process:
                    0
                case .app:
                    1
            }
        }
    }
    enum SupportedProcess: String, Sendable, Hashable {
        case telegram = "ru.keepcoder.Telegram"
        case braveBrowserBeta = "com.brave.Browser.beta.helper"
        case chrome = "com.google.Chrome.helper"
        case chromium = "org.chromium.Chromium.helper"
        case whatsApp = "net.whatsapp.WhatsApp"
        case webkit = "com.apple.WebKit.GPU"
        case discord = "com.hnc.Discord.helper"
    }
    
    var id: pid_t
    var kind: Kind
    var name: String
    let knownType: SupportedProcess?
    var audioActive: Bool
    var bundleID: String?
    var bundleURL: URL?
    var parentAppBundleURL: URL?
    var objectID: AudioObjectID
}

struct AudioProcessGroup: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var processes: [AudioProcess]
}

extension AudioProcess.Kind {
    var defaultIcon: NSImage {
        switch self {
            case .process: NSWorkspace.shared.icon(for: .unixExecutable)
            case .app: NSWorkspace.shared.icon(for: .applicationBundle)
        }
    }
}


extension AudioProcess.SupportedProcess {
    var defaultIcon: NSImage {
        switch self {
           // case .braveBrowserBeta, .telegram, .whatsApp, .webkit, .chromium:
            default:
                NSWorkspace.shared.icon(for: .applicationBundle)
        }
    }
}

extension AudioProcess {
    var icon: NSImage {
        if let parentAppBundleURL {
            let image = NSWorkspace.shared.icon(forFile: parentAppBundleURL.path)
            image.size = NSSize(width: 32, height: 32)
            return image
        }
        guard let bundleURL else { return kind.defaultIcon }
        let image = NSWorkspace.shared.icon(forFile: bundleURL.path)
        image.size = NSSize(width: 32, height: 32)
        return image
    }
}

extension String: @retroactive LocalizedError {
    public var errorDescription: String? { self }
}

@MainActor
final class AudioProcessController: ObservableObject {
    
    private let displayedGroups: Set<AudioProcess.Kind>
    private let onlyKnownKinds: Bool
    
    private let logger = Logger(subsystem: kAppSubsystem, category: String(describing: AudioProcessController.self))
    
    private(set) var processes = [AudioProcess]() {
        didSet {
            guard processes != oldValue else { return }
            
            processGroups = AudioProcessGroup.groups(
                with: processes,
                onlyKnownKinds: onlyKnownKinds,
                displayedGroups: displayedGroups
            )
        }
    }
    
    @Published private(set) var processGroups = OrderedDictionary<AudioProcess.Kind, AudioProcessGroup>()
    
    private var cancellables = Set<AnyCancellable>()
    
    init(displayedGroups: Set<AudioProcess.Kind>, onlyKnownKinds: Bool) {
        self.displayedGroups = displayedGroups
        self.onlyKnownKinds = onlyKnownKinds
    }
    
    func activate() {
        logger.debug(#function)
        
        NSWorkspace.shared
            .publisher(for: \.runningApplications, options: [.initial, .new])
            .map { $0.filter({ $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) }
            .sink { [weak self] apps in
                guard let self else { return }
                self.reload(apps: apps)
            }
            .store(in: &cancellables)
    }
    
    fileprivate func reload(apps: [NSRunningApplication]) {
        logger.debug(#function)
        
        do {
            let objectIdentifiers = try AudioObjectID.readProcessList()
            
            let updatedProcesses: [AudioProcess] = objectIdentifiers.compactMap { objectID in
                // Always try to obtain pid and uid first
                guard
                    let pid: pid_t = try? objectID.read(kAudioProcessPropertyPID, defaultValue: -1)
                else { return nil }
                
                let maybeUID = uid(for: pid)
                
                // If UID could not be determined → log & skip
                if maybeUID == nil {
                    let fallBackName = processInfo(for: pid)?.name ?? "Unknown"
                    AudioProcess.logInit(kind: "ignored",
                                         pid: pid,
                                         name: fallBackName,
                                         bundleID: objectID.readProcessBundleID(),
                                         parent: nil,
                                         procUID: nil,
                                         ignored: true)
                    return nil
                }
                
                let otherUID = maybeUID!
                
                // Skip and log if UID does not match current user
                if otherUID != kCurrentUID {
                    let ignoredName = processInfo(for: pid)?.name ?? "Unknown"
                    AudioProcess.logInit(kind: "ignored",
                                         pid: pid,
                                         name: ignoredName,
                                         bundleID: objectID.readProcessBundleID(),
                                         parent: nil,
                                         procUID: otherUID,
                                         ignored: true)
                    return nil
                }
                do {
                    let proc = try AudioProcess(objectID: objectID, runningApplications: apps)
                    
                    // Determine if this process will be excluded later
                    let willBeIgnored = (!displayedGroups.contains(proc.kind)) ||
                    (onlyKnownKinds && proc.knownType == nil)
                    
                    AudioProcess.logInit(kind: willBeIgnored ? "ignored" : "detected",
                                         pid: proc.id,
                                         name: proc.name,
                                         bundleID: proc.bundleID,
                                         parent: proc.parentAppBundleURL,
                                         procUID: kCurrentUID,
                                         ignored: willBeIgnored)
                    
                    if willBeIgnored { return nil }
                    return proc
                } catch {
                    logger.warning("Failed to initialize process with object ID #\(objectID, privacy: .public): \(error, privacy: .public)")
                    return nil
                }
            }
            
            self.processes = updatedProcesses
                .sorted { // Keep processes with audio active always on top
                    if $0.name.localizedStandardCompare($1.name) == .orderedAscending {
                        $1.audioActive && !$0.audioActive ? false : true
                    } else {
                        $0.audioActive && !$1.audioActive ? true : false
                    }
                }
        } catch {
            logger.error("Error reading process list: \(error, privacy: .public)")
        }
    }
    
}

// MARK: - UID Helpers (same‑user filtering)

fileprivate let kCurrentUID: uid_t = geteuid()

/// Returns the effective UID of the process identified by `pid`, or `nil` if it
/// can’t be read.
fileprivate func uid(for pid: pid_t) -> uid_t? {
    var info = proc_bsdinfo()
    let size = MemoryLayout.size(ofValue: info)
    let k = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
    guard k == size else { return nil }
    return info.pbi_uid
}

extension AudioProcess {
    
    // ───────────────────────────── Helpers ─────────────────────────────
    
    /// Fixed list of suffixes that indicate a helper / plugin process.
    static let defaultParentSuffixes: [String] =
    [".helper.plugin", ".plugin", ".helper.Plugin", ".helper"]
    
    /// Pad or truncate to exactly `width` characters so columns line up.
    static func fixed(_ str: String?, width: Int) -> String {
        // Sanitise: drop any zero‑width bidi marks or other control characters
        let cleaned = (str ?? "nil")
            .unicodeScalars
            .filter { !($0.properties.isBidiControl || CharacterSet.controlCharacters.contains($0)) }
            .map(String.init)
            .joined()
        
        return cleaned.count < width
        ? cleaned.padding(toLength: width, withPad: " ", startingAt: 0)
        : String(cleaned.prefix(width))
    }
    
    /// Best‑effort human‑readable name for a running application.
    static func humanName(for app: NSRunningApplication) -> String {
        app.localizedName
        ?? app.bundleURL?.deletingPathExtension().lastPathComponent
        ?? app.bundleIdentifier?.components(separatedBy: ".").last
        ?? "Unknown \(app.processIdentifier)"
    }
    
    /// Guess the parent application’s bundle URL.
    ///
    /// 1. If `bundleID` ends with any `suffix`, look for a running application
    ///    whose bundle identifier is the trimmed parent‑id.
    /// 2. If that fails *or* `bundleID` is absent, climb the `bundleURL`
    ///    hierarchy until we hit an `.app` bundle.
    static func inferParentBundleURL(
        bundleID : String?,
        bundleURL: URL?,
        suffixes : [String] = defaultParentSuffixes
    ) -> URL? {
        
        // ── Strategy 1: running‑apps lookup via stripped bundle‑id ──
        if
            let bundleID,
            let suffix = suffixes.first(where: { bundleID.hasSuffix($0) })
        {
            let parentID = String(bundleID.dropLast(suffix.count))
            if let parent = NSRunningApplication
                .runningApplications(withBundleIdentifier: parentID)
                .first
            {
                return parent.bundleURL
            }
        }
        
        // ── Strategy 2: walk the helper's path up until we find ".app" ──
        if let url = bundleURL?.topmostAppBundleURL() {
            return url
        }
        
        return nil
    }
    
    // ───────────────────── Structured logging helpers ───────────────────
    
    private static let initLogger = Logger(subsystem: kAppSubsystem,
                                           category: "AudioProcess.Init")
    
    static func logInit(kind: String,
                        pid: pid_t,
                        name: String,
                        bundleID: String?,
                        parent: URL?,
                        procUID: uid_t? = nil,
                        ignored: Bool = false)
    {
        let uidStr      = procUID.map(String.init) ?? "–"
        let ignoredFlag = ignored ? "yes" : "no"
        
        initLogger.debug(
      """
      \(fixed(kind,width:12)) | pid \(pid,format:.decimal,align:.right(columns:6),privacy:.public) \
      | user \(fixed(uidStr,width:6)) \
      | ignnored \(fixed(ignoredFlag,width:3)) \
      | name \(fixed(name,width:28)) \
      | bundleID \(fixed(bundleID,width:38)) \
      | parent \(fixed(parent?.lastPathComponent,width:18))
      """
        )
    }
    
    // ────────────────── Designated core initializer ────────────────────
    
    /// All convenience inits forward to this to remove duplication.
    init(corePID          pid: pid_t,
         name             : String,
         bundleID         : String?,
         bundleURL        : URL?,
         parentBundleURL  : URL?,
         objectID         : AudioObjectID,
         kind             : Kind) {
        
        self.init(
            id: pid,
            kind: kind,
            name: name,
            knownType: bundleID.flatMap { SupportedProcess(rawValue: $0) },
            audioActive: objectID.readProcessIsRunning(),
            bundleID: bundleID,
            bundleURL: bundleURL,
            parentAppBundleURL: parentBundleURL,
            objectID: objectID
        )
    }
    
    // ────────────────────── Convenience initializers ───────────────────
    
    /// Init from a running **helper / plugin** application.
    init(app                : NSRunningApplication,
         objectID           : AudioObjectID,
         parentBundleSuffixes: [String] = Self.defaultParentSuffixes) {
        
        let name       = Self.humanName(for: app)
        let parentURL  = Self.inferParentBundleURL(bundleID: app.bundleIdentifier,
                                                   bundleURL: app.bundleURL,
                                                   suffixes: parentBundleSuffixes)
        
        Self.logInit(kind: "helper-app",
                     pid: app.processIdentifier,
                     name: name,
                     bundleID: app.bundleIdentifier,
                     parent: parentURL,
                     procUID: uid(for: app.processIdentifier) ?? kCurrentUID)
        
        self.init(corePID         : app.processIdentifier,
                  name            : name,
                  bundleID        : app.bundleIdentifier,
                  bundleURL       : app.bundleURL,
                  parentBundleURL : parentURL,
                  objectID        : objectID,
                  kind            : .app)
    }
    
    /// Init from a Core Audio **process objectID** looking up in running apps list.
    init(objectID: AudioObjectID, runningApplications apps: [NSRunningApplication]) throws {
        let pid: pid_t = try objectID.read(kAudioProcessPropertyPID, defaultValue: -1)
        Self.logInit(kind: "objectID→apps",
                     pid: pid,
                     name: "",
                     bundleID: nil,
                     parent: nil,
                     procUID: kCurrentUID)
        
        if let app = apps.first(where: { $0.processIdentifier == pid }) {
            self.init(app: app, objectID: objectID)
        } else {
            try self.init(objectID: objectID, pid: pid)
        }
    }
    
    /// Init when all we have is an objectID and a PID (often background daemons).
    init(objectID: AudioObjectID, pid: pid_t) throws {
        
        let bundleID  = objectID.readProcessBundleID()
        let bundleURL = processInfo(for: pid)
            .flatMap { info in
                URL(fileURLWithPath: info.path).topmostAppBundleURL()
            }
        let name      = processInfo(for: pid)?.name
        ?? bundleID?.lastReverseDNSComponent
        ?? "Unknown (\(pid))"
        
        let parentURL = Self.inferParentBundleURL(bundleID: bundleID,
                                                  bundleURL: bundleURL)
        
        Self.logInit(kind: "bare-pid",
                     pid: pid,
                     name: name,
                     bundleID: bundleID,
                     parent: parentURL,
                     procUID: kCurrentUID)
        
        self.init(corePID         : pid,
                  name            : name,
                  bundleID        : bundleID?.isEmpty == true ? nil : bundleID,
                  bundleURL       : bundleURL,
                  parentBundleURL : parentURL,
                  objectID        : objectID,
                  kind            : bundleURL?.isApp == true ? .app : .process)
    }
}

// MARK: - Grouping

//extension AudioProcessGroup {
//    static func groups(with processes: [AudioProcess]) -> [AudioProcessGroup] {
//        var byKind = [AudioProcess.Kind: AudioProcessGroup]()
//
//        for process in processes {
//            byKind[process.kind, default: .init(for: process.kind)].processes.append(process)
//        }
//
//        return byKind.values.sorted(by: { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
//    }
//}

extension AudioProcessGroup {
    static func groups(
        with processes: [AudioProcess],
        onlyKnownKinds: Bool,
        displayedGroups: Set<AudioProcess.Kind>
    ) -> OrderedDictionary<AudioProcess.Kind, AudioProcessGroup> {
        
        // Group processes by kind, optionally filtering for known types only
        var byKind = OrderedDictionary<AudioProcess.Kind, AudioProcessGroup>()
        for process in processes {
            if !displayedGroups.contains(process.kind) { continue }
            if onlyKnownKinds && process.knownType == nil { continue }
            byKind[process.kind, default: .init(for: process.kind)].processes.append(process)
        }
        
        // Sort processes inside each group alphabetically (ascending)
        for key in byKind.keys {
            byKind[key]?.processes.sort {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
        
        // Preserve predictable ordering of kinds via sortPriority
        let sortedPairs = byKind.sorted { lhs, rhs in
            lhs.key.sortPriority < rhs.key.sortPriority
        }
        
        // Reconstruct ordered dictionary with the desired ordering
        return OrderedDictionary(uniqueKeysWithValues: sortedPairs)
    }
}


extension AudioProcessGroup {
    init(for kind: AudioProcess.Kind) {
        self.init(id: kind.rawValue, title: kind.groupTitle, processes: [])
    }
}

extension AudioProcess.Kind {
    var groupTitle: String {
        switch self {
            case .process: "Processes"
            case .app: "Apps"
        }
    }
}

// MARK: - Helpers

private func processInfo(for pid: pid_t) -> (name: String, path: String)? {
    let nameBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(MAXPATHLEN))
    let pathBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(MAXPATHLEN))
    
    defer {
        nameBuffer.deallocate()
        pathBuffer.deallocate()
    }
    
    let nameLength = proc_name(pid, nameBuffer, UInt32(MAXPATHLEN))
    let pathLength = proc_pidpath(pid, pathBuffer, UInt32(MAXPATHLEN))
    
    guard nameLength > 0, pathLength > 0 else {
        return nil
    }
    
    let name = String(cString: nameBuffer)
    let path = String(cString: pathBuffer)
    
    return (name, path)
}

private extension String {
    var lastReverseDNSComponent: String? {
        components(separatedBy: ".").last.flatMap { $0.isEmpty ? nil : $0 }
    }
}

private extension URL {
    /// Walks up the directory tree (up to `maxDepth` levels) and returns the
    /// highest‑level `.app` bundle encountered. This avoids choosing nested
    /// Helper/Plugin bundles that live inside `Frameworks/Helpers`.
    func topmostAppBundleURL(maxDepth: Int = 10) -> URL? {
        var depth       = 0
        var node        = self            // start at the original URL
        var candidate: URL? = nil         // last seen .app bundle
        
        while depth < maxDepth {
            if node.isApp { candidate = node }
            let parent = node.deletingLastPathComponent()
            if parent == node { break }   // reached filesystem root
            node  = parent
            depth += 1
        }
        return candidate
    }
    
    var isBundle: Bool {
        (try? resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .bundle) == true
    }
    
    var isApp: Bool {
        (try? resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .application) == true
    }
}
