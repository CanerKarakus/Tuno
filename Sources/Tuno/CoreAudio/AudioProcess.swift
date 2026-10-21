import AppKit
import CoreAudio

/// Core Audio'nun ses istemcisi olarak tanıdığı tek bir süreç.
struct AudioProcess: Hashable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isRunningOutput: Bool
    let isRunningInput: Bool

    static func all() -> [AudioProcess] {
        let ownPID = getpid()
        return AudioObjectID.system
            .readArray(.init(kAudioHardwarePropertyProcessObjectList), of: AudioObjectID.self)
            .compactMap { object in
                guard let pid = object.read(.init(kAudioProcessPropertyPID), initial: pid_t(-1)),
                      pid > 0, pid != ownPID
                else { return nil }
                let running = object.read(.init(kAudioProcessPropertyIsRunningOutput), initial: UInt32(0)) ?? 0
                let input = object.read(.init(kAudioProcessPropertyIsRunningInput), initial: UInt32(0)) ?? 0
                return AudioProcess(
                    objectID: object,
                    pid: pid,
                    bundleID: object.readString(.init(kAudioProcessPropertyBundleID)),
                    isRunningOutput: running != 0,
                    isRunningInput: input != 0
                )
            }
    }
}

/// Bir veya daha fazla sesli süreci tek bir uygulama altında toplar
/// (ör. Safari'nin sesi "com.apple.WebKit.GPU" sürecinden gelir).
struct AudioApp: Identifiable, Hashable {
    let id: String
    let name: String
    let ownerPID: pid_t
    var processObjects: [AudioObjectID]
    var isPlaying: Bool
    /// Mikrofonu kullanıyor (görüşme).
    var isRecording = false

    var icon: NSImage {
        NSRunningApplication(processIdentifier: ownerPID)?.icon
            ?? NSWorkspace.shared.icon(for: .application)
    }

    static func group(_ processes: [AudioProcess]) -> [AudioApp] {
        var apps: [String: AudioApp] = [:]
        for process in processes {
            let owner = Self.owner(of: process.pid)
            // Yalnızca gerçek uygulamaları göster (corespeechd, coreaudiod gibi servisleri gizle).
            guard let owner, owner.bundleURL?.pathExtension == "app" else { continue }
            let key = owner.bundleIdentifier ?? process.bundleID ?? "pid.\(owner.processIdentifier)"
            if var existing = apps[key] {
                existing.processObjects.append(process.objectID)
                existing.isPlaying = existing.isPlaying || process.isRunningOutput
                existing.isRecording = existing.isRecording || process.isRunningInput
                apps[key] = existing
            } else {
                apps[key] = AudioApp(
                    id: key,
                    name: owner.localizedName ?? Self.fallbackName(process),
                    ownerPID: owner.processIdentifier,
                    processObjects: [process.objectID],
                    isPlaying: process.isRunningOutput,
                    isRecording: process.isRunningInput
                )
            }
        }
        return Array(apps.values)
    }

    private static func owner(of pid: pid_t) -> NSRunningApplication? {
        if let responsible = responsiblePID?(pid), responsible > 0, responsible != pid,
           let app = NSRunningApplication(processIdentifier: responsible),
           app.bundleIdentifier != nil {
            return app
        }
        return NSRunningApplication(processIdentifier: pid)
    }

    private static func fallbackName(_ process: AudioProcess) -> String {
        if let bundleID = process.bundleID, let last = bundleID.split(separator: ".").last {
            return String(last)
        }
        return String(format: L("Süreç %d"), Int(process.pid))
    }

    /// Yardımcı süreçleri (WebKit, Chrome Helper…) asıl uygulamaya bağlamak için.
    private static let responsiblePID: (@convention(c) (pid_t) -> pid_t)? = {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(rtldDefault, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()
}
