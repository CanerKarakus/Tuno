import CoreServices
import Foundation

/// İndirilenler klasörünü izler: süren indirmeler (Safari ".download", Chrome ".crdownload", Firefox ".part")
/// ve AirDrop ile gelen dosyalar (karantina imzası "sharingd"). Safari'de yüzde paketteki Info.plist'ten okunur;
/// diğerlerinde toplam boyut bilinmediği için ilerleme belirsizdir.
@MainActor
final class DownloadsWatcher {
    struct Item: Equatable {
        let name: String
        let url: URL
        let airdrop: Bool
        /// 0…1; bilinmiyorsa nil.
        let fraction: Double?
    }

    var onActive: ((Item?) -> Void)?
    var onFinished: ((_ url: URL, _ airdrop: Bool) -> Void)?

    private let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    private var stream: FSEventStreamRef?
    private var known: Set<String> = []
    /// Boyutu hâlâ değişen yeni dosyalar (AirDrop yazarken): ad → son boyut.
    private var growing: [String: Int] = [:]
    private var active: Item?
    private var timer: Timer?

    private static let partial = ["download", "crdownload", "part"]

    init() {
        known = Set(contents().map(\.lastPathComponent))
        start()
    }

    private func contents() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey],
                                                      options: [.skipsHiddenFiles])) ?? []
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    private func start() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DownloadsWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.scan() }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// Klasör değişince ve bir aktarım sürerken yarım saniyede bir.
    private func scan() {
        let items = contents()
        var current: Item?
        var names: Set<String> = []
        for url in items {
            let name = url.lastPathComponent
            names.insert(name)
            if Self.partial.contains(url.pathExtension) {
                current = Item(name: url.deletingPathExtension().lastPathComponent, url: url.deletingPathExtension(),
                               airdrop: false, fraction: Self.safariFraction(url))
                continue
            }
            guard !known.contains(name) else { continue }
            // Yeni, tamamlanmış görünen dosya: boyutu bir tur boyunca sabit kalınca bitti sayılır.
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            // Yalnızca dışarıdan gelenler (karantinalı): kaydedilen ekran görüntüsü gibi yerel dosyalar sayılmaz.
            guard let agent = Self.quarantineAgent(url) else { known.insert(name); continue }
            let airdrop = agent == "sharingd"
            if growing[name] == size, size > 0 {
                growing[name] = nil
                known.insert(name)
                onFinished?(url, airdrop)
            } else {
                growing[name] = size
                if airdrop { current = Item(name: name, url: url, airdrop: true, fraction: nil) }
            }
        }
        known.formIntersection(names)
        growing = growing.filter { names.contains($0.key) }
        if current != active {
            active = current
            onActive?(current)
        }
        // Süren bir şey varken yoklamaya devam et (FSEvents boyut değişimini her zaman bildirmez).
        let busy = current != nil || !growing.isEmpty
        if busy, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.scan() }
            }
        } else if !busy {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Safari indirmesinin yüzdesi (paketin Info.plist'i).
    private static func safariFraction(_ url: URL) -> Double? {
        guard url.pathExtension == "download",
              let data = try? Data(contentsOf: url.appending(path: "Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let total = (info["DownloadEntryProgressTotalToLoad"] as? NSNumber)?.doubleValue, total > 0,
              let done = (info["DownloadEntryProgressBytesSoFar"] as? NSNumber)?.doubleValue
        else { return nil }
        return min(done / total, 1)
    }

    /// "0083;6ad8466c;Safari;UUID" → "Safari".
    private static func quarantineAgent(_ url: URL) -> String? {
        let name = "com.apple.quarantine"
        let length = getxattr(url.path, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard getxattr(url.path, name, &buffer, length, 0, 0) == length else { return nil }
        let parts = String(decoding: buffer, as: UTF8.self).split(separator: ";")
        return parts.count > 2 ? String(parts[2]) : nil
    }
}
