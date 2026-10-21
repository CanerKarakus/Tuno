import AppKit
import Observation

/// Bir müzik uygulamasında (Spotify, Apple Music) çalan şarkı. Durum uygulamanın yayınladığı dağıtık
/// bildirimden gelir (izin gerekmez); kontroller (çal/duraklat, ileri, geri) medya tuşu olarak gönderilir.
/// Kapak Spotify'da oEmbed adresinden, diğerlerinde ad ve sanatçıyla iTunes Search'ten alınır.
@Observable
@MainActor
final class MediaPlayer: Identifiable {
    struct Source {
        let bundleID: String
        let notification: String
        let idKey: String
        /// Süre milisaniye olarak.
        let durationKey: String
        /// Konum saniye olarak; bildirim vermiyorsa nil.
        let positionKey: String?
        /// Tuno açıldığında zaten çalıyorsa şarkı adı pencere başlığından okunur ("Sanatçı - Şarkı"); okunamıyorsa
        /// ilk bildirime kadar uygulama adı görünür.
        let titleFromWindow: Bool
        /// AppleScript'teki uygulama adı (konuma atlamak için).
        let scriptName: String
        /// Kaydırıcısı Erişilebilirlik'e açık mı (Spotify açmıyor).
        let accessibleSlider: Bool
        /// Tarayıcı: bildirim yok; ses Core Audio'dan, başlık pencere başlığından okunur (YouTube vb.).
        var isBrowser = false

        static let spotify = Source(
            bundleID: "com.spotify.client", notification: "com.spotify.client.PlaybackStateChanged",
            idKey: "Track ID", durationKey: "Duration", positionKey: "Playback Position",
            titleFromWindow: true, scriptName: "Spotify", accessibleSlider: false)
        static let music = Source(
            bundleID: "com.apple.Music", notification: "com.apple.Music.playerInfo",
            idKey: "PersistentID", durationKey: "Total Time", positionKey: nil,
            titleFromWindow: false, scriptName: "Music", accessibleSlider: true)

        static let browsers: [Source] = [
            "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "com.microsoft.edgemac",
            "com.brave.Browser", "org.mozilla.firefox", "com.operasoftware.Opera",
        ].map {
            Source(bundleID: $0, notification: "", idKey: "", durationKey: "", positionKey: nil, titleFromWindow: false,
                   scriptName: "", accessibleSlider: false, isBrowser: true)
        }
    }

    struct Track: Equatable {
        let id: String
        let title: String
        let artist: String
        let duration: TimeInterval
    }

    let source: Source
    nonisolated var id: String { source.bundleID }

    private(set) var track: Track?
    private(set) var isPlaying = false
    private(set) var artwork: NSImage?
    /// Son bilinen konum ve o anın zamanı; aradaki süre çalarken eklenir.
    private(set) var position: TimeInterval = 0
    private(set) var positionDate = Date()
    /// Son durum değişikliği: iki uygulama birden açıksa en son dokunulan öne gelir.
    private(set) var lastChange = Date.distantPast

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var artworkCache: [String: NSImage] = [:]
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private let scriptQueue = DispatchQueue(label: "app.tuno.media")
    /// İlk bildirim geldi mi; geldiyse yoklama durur.
    @ObservationIgnored private var notified = false
    @ObservationIgnored private var loggedKeys = false

    init(_ source: Source) {
        self.source = source
        if !source.isBrowser { observeNotifications() }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == source.bundleID else { return }
            MainActor.assumeIsolated { self?.clear() }
        })
        // Uygulama bilgiyi yalnızca bir şey değişince yayınlar. Tuno açıldığında zaten çalıyorsa, bildirim gelene
        // kadar sesin çalıp çalmadığı Core Audio'dan, şarkı adı pencere başlığından okunur.
        if !source.isBrowser {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollUntilNotified() }
            }
            pollTimer?.tolerance = 0.5
            pollUntilNotified()
            // İzin önceden verildiyse süre ve konum hemen okunur (izin penceresi açılmaz).
            if runningApp != nil { refreshProgress() }
        }
    }

    private func observeNotifications() {
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: .init(self.source.notification), object: nil, queue: .main
        ) { [weak self] note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated { self?.apply(info) }
        })
    }

    var runningApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleID).first
    }

    var icon: NSImage? { runningApp?.icon }

    func elapsed(at date: Date) -> TimeInterval {
        let value = position + (isPlaying ? date.timeIntervalSince(positionDate) : 0)
        return min(max(value, 0), track?.duration ?? value)
    }

    // MARK: - Kontroller

    /// Kontroller klavyedeki medya tuşları gibi gönderilir: ayrı bir izin gerekmez (Erişilebilirlik yeterli).
    func playPause() {
        position = elapsed(at: Date())
        positionDate = Date()
        isPlaying.toggle()
        Self.press(16)   // NX_KEYTYPE_PLAY
    }

    func next() { Self.press(17) }       // NX_KEYTYPE_NEXT
    func previous() { Self.press(18) }   // NX_KEYTYPE_PREVIOUS

    /// Şarkıda konuma atlar. Kaydırıcısı erişilebilirse (Müzik) izinsiz ayarlanır; değilse (Spotify) uygulamaya
    /// AppleScript komutu gider: macOS ilk seferde bir kez Otomasyon izni sorar, reddedilirse sessizce bir şey olmaz.
    /// Kaydırıcı sürüklenebilir mi: Müzik izinsiz, Spotify yalnızca "ileri/geri sarma" açıksa.
    func canSeek(scriptAllowed: Bool) -> Bool { !source.isBrowser && (source.accessibleSlider || scriptAllowed) }

    /// Süre ve konumu yeniden okur (oynatıcı açılınca). Spotify/Müzik: Otomasyon izni önceden verildiyse uygulamaya
    /// sorulur (izin penceresi açılmaz). Tarayıcı: sayfadaki video çubuğu Erişilebilirlik ile okunur.
    func refreshProgress() {
        guard let pid = runningApp?.processIdentifier else { return }
        let source = source
        // Ayrı kuyruk: izin sorgusu takılırsa sarma komutlarını bekletmesin.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            if source.isBrowser {
                guard let (value, maximum) = MediaSlider.browserVideo(pid: pid) else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let track = self.track else { return }
                        self.track = Track(id: track.id, title: track.title, artist: track.artist, duration: maximum)
                        self.position = value
                        self.positionDate = Date()
                    }
                }
                return
            }
            guard IslandPermissions.automationGranted(source.bundleID) else { return }
            let id = source.bundleID == Source.spotify.bundleID ? "(id of t)" : "(persistent ID of t)"
            let duration = source.bundleID == Source.spotify.bundleID ? "(duration of t)" : "(round ((duration of t) * 1000))"
            var error: NSDictionary?
            let output = NSAppleScript(source: """
                tell application "\(source.scriptName)"
                    if player state is stopped then return "stopped"
                    set t to current track
                    return (player state as string) & tab & (name of t) & tab & (artist of t) & tab & \(id) & tab & \(duration) & tab & (round (player position * 1000))
                end tell
                """)?.executeAndReturnError(&error).stringValue
            guard let parts = output?.components(separatedBy: "\t"), parts.count == 6 else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Aynı şarkıysa bildirimdeki kimlik korunur (kapak yeniden yüklenmesin).
                    let id = self.track?.title == parts[1] ? self.track!.id
                        : (parts[3].hasPrefix("spotify:") ? parts[3] : "\(source.bundleID):\(parts[3])")
                    self.update(Track(id: id, title: parts[1], artist: parts[2], duration: (Double(parts[4]) ?? 0) / 1000),
                                playing: parts[0] == "playing", position: (Double(parts[5]) ?? 0) / 1000)
                }
            }
        }
    }

    func seek(to fraction: Double) {
        guard let track, track.duration > 0, let pid = runningApp?.processIdentifier else { return }
        let fraction = min(max(fraction, 0), 1)
        position = track.duration * fraction
        positionDate = Date()
        let seconds = position, duration = track.duration, source = source
        scriptQueue.async {
            if source.accessibleSlider, MediaSlider.seek(pid: pid, fraction: fraction, duration: duration) { return }
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"\(source.scriptName)\" to set player position to \(String(format: "%.2f", seconds))")?
                .executeAndReturnError(&error)
            if let error { SupportLog.log("ada", "Konuma atlanamadı: \(error[NSAppleScript.errorNumber] ?? "?")") }
        }
    }

    func activate() { runningApp?.activate() }

    private static func press(_ key: Int) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, subtype: 8, data1: (key << 16) | ((down ? 0xA : 0xB) << 8), data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Durum

    private func apply(_ info: [AnyHashable: Any]) {
        notified = true
        let state = info["Player State"] as? String
        if !loggedKeys, info.count > 1 {
            loggedKeys = true
            SupportLog.log("ada", "\(source.bundleID) bildirimi: \(info.keys.map { "\($0)" }.sorted().joined(separator: ", "))")
        }
        // Radyo yayınlarında parça kimliği olmayabilir: ad ve sanatçı (ya da yayın adı) kimlik olur.
        let name = info["Name"] as? String ?? info["Stream Title"] as? String ?? info["Display Line 0"] as? String
        guard state != "Stopped" else { return clear() }
        guard let label = info[source.idKey].map({ "\($0)" }) ?? name else {
            // Yalnızca durum geldi (radyo yayını): bilinen şarkı korunur, yoksa uygulama adıyla görünür.
            let current = track ?? Track(id: "\(source.bundleID):?", title: runningApp?.localizedName ?? "", artist: "", duration: 0)
            update(current, playing: state == "Playing", position: elapsed(at: Date()))
            return
        }
        let id = label.hasPrefix("spotify:") ? label : "\(source.bundleID):\(label)"
        let duration = (info[source.durationKey] as? NSNumber)?.doubleValue ?? 0
        let new = Track(id: id, title: name ?? "", artist: info["Artist"] as? String ?? info["Display Line 1"] as? String ?? "",
                        duration: duration / 1000)
        // Konum bildirilmiyorsa: yeni şarkı baştan başlar, aynı şarkıda bilinen konum korunur.
        let position = source.positionKey.flatMap { (info[$0] as? NSNumber)?.doubleValue }
            ?? (new.id == track?.id ? elapsed(at: Date()) : 0)
        update(new, playing: state == "Playing", position: position)
    }

    // MARK: - Tarayıcı

    @ObservationIgnored private var playingPolls = 0
    @ObservationIgnored private var pausedSince: Date?

    /// Tarayıcıda çalan medya (YouTube vb.). Kısa uyarı seslerinde görünmesin diye ses en az iki yoklama
    /// sürmeli; duraklatılınca on dakika yerinde kalır.
    func updateFromBrowser(playing: Bool) {
        guard let app = runningApp else { return clear() }
        guard playing else {
            playingPolls = 0
            guard track != nil else { return }
            if isPlaying { isPlaying = false; lastChange = Date(); pausedSince = Date() }
            if let pausedSince, Date().timeIntervalSince(pausedSince) > 600 { clear() }
            return
        }
        playingPolls += 1
        guard playingPolls >= 2 || track != nil else { return }
        let (title, url) = Self.browserTitle(pid: app.processIdentifier)
        let (name, site) = Self.split(title ?? app.localizedName ?? "")
        let new = Track(id: "web:\(title ?? "")", title: name, artist: site ?? app.localizedName ?? "", duration: 0)
        // Süre sonradan okunur (refreshProgress); yalnızca sekme başlığı değişince yeni video sayılır.
        if new.id != track?.id {
            track = new
            artwork = nil
            if let video = url.flatMap(Self.youTubeID),
               let thumbnail = URL(string: "https://i.ytimg.com/vi/\(video)/mqdefault.jpg") {
                fetch(key: "yt:\(video)", trackID: new.id) { thumbnail }
            }
        }
        if !isPlaying { isPlaying = true; lastChange = Date() }
        pausedSince = nil
    }

    /// "Video adı - YouTube" → ("Video adı", "YouTube"); baştaki "(3) " bildirim sayısı atılır.
    private static func split(_ title: String) -> (String, String?) {
        var text = title
        if text.hasPrefix("("), let close = text.firstIndex(of: ")"), text[text.index(after: close)...].hasPrefix(" ") {
            text = String(text[text.index(close, offsetBy: 2)...])
        }
        guard let range = text.range(of: " - ", options: .backwards) else { return (text, nil) }
        return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
    }

    /// Ses çalan sekmenin başlığı: YouTube içeren pencere, yoksa ana pencere. Safari'de sayfa adresi de okunur.
    private static func browserTitle(pid: pid_t) -> (String?, URL?) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var windows: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
        let list = (windows as? [AXUIElement]) ?? []
        let titled = list.compactMap { window -> (AXUIElement, String)? in
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            return (title as? String).flatMap { $0.isEmpty ? nil : (window, $0) }
        }
        guard let chosen = titled.first(where: { $0.1.contains("YouTube") }) ?? titled.first else { return (nil, nil) }
        return (chosen.1, webURL(in: chosen.0))
    }

    /// Penceredeki web alanının adresi (AXWebArea › AXURL); derinlik ve düğüm sayısı sınırlı.
    private static func webURL(in window: AXUIElement) -> URL? {
        var visited = 0
        func walk(_ element: AXUIElement, depth: Int) -> URL? {
            visited += 1
            guard depth < 12, visited < 400 else { return nil }
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if (role as? String) == "AXWebArea" {
                var url: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &url)
                return url as? URL
            }
            var children: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
            for child in (children as? [AXUIElement]) ?? [] {
                if let found = walk(child, depth: depth + 1) { return found }
            }
            return nil
        }
        return walk(window, depth: 0)
    }

    private static func youTubeID(_ url: URL) -> String? {
        guard let host = url.host(), host.contains("youtu") else { return nil }
        if host.contains("youtu.be") { return url.pathComponents.dropFirst().first }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
    }

    /// Yalnızca açılıştan sonraki ilk 20 saniye (sonra uygulamanın bildirimleri yeter).
    @ObservationIgnored private var pollsLeft = 10

    private func pollUntilNotified() {
        pollsLeft -= 1
        guard !notified, pollsLeft >= 0 else { pollTimer?.invalidate(); pollTimer = nil; return }
        guard let app = runningApp else { return }
        let playing = AudioApp.group(AudioProcess.all()).first { $0.id == source.bundleID }?.isPlaying ?? false
        guard playing else {
            if track?.id.isEmpty == true, isPlaying { isPlaying = false; lastChange = Date() }
            return
        }
        let (artist, title) = source.titleFromWindow ? Self.windowTitle(pid: app.processIdentifier) : (nil, nil)
        let current = Track(id: "", title: title ?? app.localizedName ?? "", artist: artist ?? "", duration: 0)
        if track != current {
            track = current
            artwork = nil
            if let artist { searchArtwork(artist: artist, title: current.title) }
        }
        if !isPlaying { isPlaying = true; lastChange = Date() }
    }

    /// Çalarken pencere başlığı "Sanatçı - Şarkı" olur (Erişilebilirlik ile okunur).
    private static func windowTitle(pid: pid_t) -> (String?, String?) {
        let app = AXUIElementCreateApplication(pid)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
              let list = windows as? [AXUIElement]
        else { return (nil, nil) }
        for window in list {
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
                  let text = title as? String, let range = text.range(of: " - ")
            else { continue }
            return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
        }
        return (nil, nil)
    }

    private func update(_ new: Track, playing: Bool, position: TimeInterval) {
        if new != track {
            // Pencere başlığından gelen şarkının iTunes kapağı, uygulamanınki gelene kadar kalır.
            let keep = track?.id.isEmpty == true && track?.title == new.title
            track = new
            loadArtwork(for: new, keepCurrent: keep)
        }
        isPlaying = playing
        self.position = position
        positionDate = Date()
        lastChange = Date()
    }

    private func clear() {
        playingPolls = 0
        pausedSince = nil
        track = nil
        isPlaying = false
        artwork = nil
        position = 0
    }

    // MARK: - Kapak

    private func loadArtwork(for track: Track, keepCurrent: Bool) {
        if let cached = artworkCache[track.id] { artwork = cached; return }
        if !keepCurrent { artwork = nil }
        let parts = track.id.split(separator: ":")
        if track.id.hasPrefix("spotify:"), parts.count == 3,
           let url = URL(string: "https://open.spotify.com/oembed?url=https://open.spotify.com/\(parts[1])/\(parts[2])") {
            // "spotify:track:ID" → open.spotify.com/oembed → thumbnail_url.
            fetch(key: track.id, trackID: track.id) {
                struct Embed: Decodable { let thumbnail_url: String }
                guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
                return (try? JSONDecoder().decode(Embed.self, from: data)).flatMap { URL(string: $0.thumbnail_url) }
            }
        } else if !track.artist.isEmpty {
            searchArtwork(artist: track.artist, title: track.title, trackID: track.id)
        }
    }

    /// Ad ve sanatçıyla iTunes Search'ten kapak.
    private func searchArtwork(artist: String, title: String, trackID: String = "") {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [.init(name: "term", value: "\(artist) \(title)"), .init(name: "entity", value: "song"),
                                 .init(name: "limit", value: "1")]
        guard let url = components.url else { return }
        fetch(key: "search:\(artist)|\(title)", trackID: trackID) {
            struct Result: Decodable { let artworkUrl100: String? }
            struct Response: Decodable { let results: [Result] }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let link = try? JSONDecoder().decode(Response.self, from: data).results.first?.artworkUrl100
            else { return nil }
            return URL(string: link.replacingOccurrences(of: "100x100", with: "300x300"))
        }
    }

    private func fetch(key: String, trackID: String, imageURL: @escaping () async -> URL?) {
        if let cached = artworkCache[key] {
            if track?.id == trackID { artwork = cached }
            return
        }
        Task { [weak self] in
            guard let link = await imageURL(),
                  let (data, _) = try? await URLSession.shared.data(from: link),
                  let image = NSImage(data: data)
            else { return }
            guard let self else { return }
            self.artworkCache[key] = image
            if self.track?.id == trackID { self.artwork = image }
        }
    }
}

/// Müzik uygulamasının penceresindeki ilerleme kaydırıcısı (Erişilebilirlik). Kaydırıcı, en büyük değeri
/// şarkı süresine en yakın olandır (ses kaydırıcısından ayırmak için).
enum MediaSlider {
    private nonisolated(unsafe) static var cached: (pid: pid_t, element: AXUIElement)?
    private static let lock = NSLock()

    static func seek(pid: pid_t, fraction: Double, duration: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let cached, cached.pid == pid, set(cached.element, fraction: fraction) { return true }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        // Ağaç ilk açılışta biraz geç kurulur.
        for attempt in 0..<4 {
            if let slider = find(in: app, duration: duration) {
                cached = (pid, slider)
                return set(slider, fraction: fraction)
            }
            if attempt < 3 { Thread.sleep(forTimeInterval: 0.25) }
        }
        return false
    }

    private static func set(_ slider: AXUIElement, fraction: Double) -> Bool {
        let maximum = number(slider, kAXMaxValueAttribute) ?? 1
        let minimum = number(slider, kAXMinValueAttribute) ?? 0
        let value = minimum + (maximum - minimum) * fraction
        return AXUIElementSetAttributeValue(slider, kAXValueAttribute as CFString, NSNumber(value: value)) == .success
    }

    private static func find(in app: AXUIElement, duration: TimeInterval) -> AXUIElement? {
        var best: (AXUIElement, Double)?
        walkSliders(app) { slider, maximum in
            // Süre saniye ya da milisaniye olabilir; ikisine de uzaklığa bakılır.
            let distance = min(abs(maximum - duration), abs(maximum - duration * 1000) / 1000)
            if best == nil || distance < best!.1 { best = (slider, distance) }
        }
        return best?.0
    }

    private static func walkSliders(_ root: AXUIElement, _ found: (AXUIElement, Double) -> Void) {
        var visited = 0
        func walk(_ element: AXUIElement, depth: Int) {
            visited += 1
            guard depth < 60, visited < 15_000 else { return }
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if (role as? String) == kAXSliderRole, let maximum = number(element, kAXMaxValueAttribute), maximum > 1 {
                found(element, maximum)
            }
            var children: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
            for child in (children as? [AXUIElement]) ?? [] { walk(child, depth: depth + 1) }
        }
        walk(root, depth: 0)
    }

    /// Tarayıcıdaki videonun konumu ve süresi (saniye): YouTube'un ilerleme çubuğu (ARIA kaydırıcı).
    /// Ses düzeyi gibi diğer kaydırıcılardan ayırmak için adı "seek/ara/ilerleme" içeren, yoksa en uzunu seçilir.
    static func browserVideo(pid: pid_t) -> (Double, Double)? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        var best: (value: Double, max: Double, named: Bool)?
        var visited = 0
        func walk(_ element: AXUIElement, depth: Int) {
            visited += 1
            guard depth < 50, visited < 6_000 else { return }
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if (role as? String) == kAXSliderRole, let maximum = number(element, kAXMaxValueAttribute), maximum > 1,
               let value = number(element, kAXValueAttribute), value <= maximum {
                var description: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &description)
                let text = ((description as? String) ?? "").lowercased()
                let named = ["seek", "ara", "ilerleme", "progress"].contains { text.contains($0) }
                if best == nil || (named && !best!.named) || (named == best!.named && maximum > best!.max) {
                    best = (value, maximum, named)
                }
            }
            var children: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
            for child in (children as? [AXUIElement]) ?? [] { walk(child, depth: depth + 1) }
        }
        var windows: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
        for window in (windows as? [AXUIElement]) ?? [] { walk(window, depth: 0) }
        return best.map { ($0.value, $0.max) }
    }

    /// Tanı için: uygulamadaki kaydırıcıları destek günlüğüne yazar (deneme kancasından).
    static func dump(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let enhanced = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 2)
        var roles: [String: Int] = [:]
        func count(_ element: AXUIElement, depth: Int) {
            guard depth < 60, roles.values.reduce(0, +) < 15_000 else { return }
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            roles[(role as? String) ?? "?", default: 0] += 1
            var children: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
            for child in (children as? [AXUIElement]) ?? [] { count(child, depth: depth + 1) }
        }
        count(app, depth: 0)
        SupportLog.log("ada", "AX (\(pid)) manual=\(manual.rawValue) enhanced=\(enhanced.rawValue) roller: "
                       + roles.sorted { $0.value > $1.value }.prefix(15).map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        var lines: [String] = []
        walkSliders(app) { slider, maximum in
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(slider, kAXValueAttribute as CFString, &settable)
            var actions: CFArray?
            AXUIElementCopyActionNames(slider, &actions)
            var value: CFTypeRef?, description: CFTypeRef?
            AXUIElementCopyAttributeValue(slider, kAXValueAttribute as CFString, &value)
            AXUIElementCopyAttributeValue(slider, kAXDescriptionAttribute as CFString, &description)
            lines.append("slider desc=\(description as? String ?? "-") value=\(value.map { "\($0)" } ?? "-") "
                         + "max=\(maximum) settable=\(settable.boolValue) actions=\((actions as? [String]) ?? [])")
        }
        SupportLog.log("ada", "Kaydırıcılar (\(pid)): " + (lines.isEmpty ? "yok" : lines.joined(separator: " | ")))
    }

    private static func number(_ element: AXUIElement, _ attribute: String) -> Double? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (value as? NSNumber)?.doubleValue
    }
}
