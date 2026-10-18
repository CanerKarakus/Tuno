import AppKit
import AudioToolbox
import CoreAudio
import Observation

struct AppAudioSettings: Codable, Equatable {
    var volume: Float = 1
    var muted = false
    /// `nil` → sistemin varsayılan çıkışını izler.
    var outputUID: String?

    var isDefault: Bool { abs(volume - 1) < 0.005 && !muted && outputUID == nil }
    var effectiveGain: Float { muted ? 0 : volume }
}

/// Donanım ses denetimi olmayan aygıtlar (HDMI/DisplayPort) için yazılımsal ses.
struct SoftwareVolume: Codable, Equatable {
    var volume: Float = 1
    var muted = false

    var gain: Float { muted ? 0 : volume }
    var isUnity: Bool { !muted && volume > 0.999 }
}

/// Tuno'nun ses motoru: uygulama başına ses, yazılımsal aygıt sesi ve sistem geneli EQ.
///
/// Her ses akışı kendi tap'inde aynı zincirden geçer:
///   uygulama kazancı × aygıt yazılım sesi × EQ ön kazancı → EQ → limiter → aygıt
/// Uygulama ayarı olmayan tüm ses, varsayılan aygıt için tek bir "geri kalan" tap'te işlenir.
@Observable
@MainActor
final class Mixer {
    private(set) var apps: [AudioApp] = []
    private(set) var settings: [String: AppAudioSettings] = [:]
    private(set) var softwareVolumes: [String: SoftwareVolume] = [:]
    private(set) var lastError: String?
    let equalizer: Equalizer

    @ObservationIgnored private let devices: DeviceStore
    @ObservationIgnored private var allApps: [AudioApp] = []
    @ObservationIgnored private var taps: [String: AudioTap] = [:]
    @ObservationIgnored private var remainder: AudioTap?
    @ObservationIgnored private var seenPlaying: Set<String> = []
    @ObservationIgnored private var processListener: PropertyListener?
    @ObservationIgnored private var timer: Timer?

    private static let settingsKey = "appAudioSettings"
    private static let softwareKey = "softwareVolumes"

    init(devices: DeviceStore, equalizer: Equalizer) {
        self.devices = devices
        self.equalizer = equalizer
        settings = Self.load(Self.settingsKey) ?? [:]
        softwareVolumes = Self.load(Self.softwareKey) ?? [:]

        devices.onRoutingChange = { [weak self] in self?.reconcile() }
        equalizer.onChange = { [weak self] in self?.reconcile() }
        processListener = PropertyListener(.system, .init(kAudioHardwarePropertyProcessObjectList)) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // IsRunningOutput için süreç başına dinleyici yerine hafif bir yoklama.
        observePanel()
        schedulePolling()
        refresh()
        reconcile()
    }

    /// Menü paneli ya da Uygulama Sesleri sayfası açıkken ses çalan uygulamalar saniyede bir, kapalıyken
    /// iki saniyede bir yoklanır: arka planda daha az uyanır. Yeni süreçleri zaten PropertyListener anında bildirir.
    @ObservationIgnored private var panelOpen = false
    @ObservationIgnored private var pageVisible = false
    @ObservationIgnored private var panelObservers: [NSObjectProtocol] = []
    private var isWatched: Bool { panelOpen || pageVisible }

    /// Uygulama Sesleri sayfası göründüğünde ve kaybolduğunda (MixerView).
    func setPageVisible(_ visible: Bool) {
        let was = isWatched
        pageVisible = visible
        watchedChanged(from: was)
    }

    private func observePanel() {
        let center = NotificationCenter.default
        for (name, open) in [(Notification.Name.tunoPanelWillOpen, true), (.tunoPanelDidClose, false)] {
            panelObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let was = self.isWatched
                    self.panelOpen = open
                    self.watchedChanged(from: was)
                }
            })
        }
    }

    private func watchedChanged(from was: Bool) {
        guard isWatched != was else { return }
        if isWatched { refresh() }
        schedulePolling()
    }

    private func schedulePolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: isWatched ? 1 : 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = isWatched ? 0.1 : 0.5
    }

    func settings(for app: AudioApp) -> AppAudioSettings { settings[app.id] ?? AppAudioSettings() }

    // MARK: - Süreç listesi

    func refresh() {
        let all = AudioApp.group(AudioProcess.all())
        allApps = all
        for app in all where app.isPlaying { seenPlaying.insert(app.id) }

        let visible = all
            .filter { seenPlaying.contains($0.id) || settings[$0.id].map { !$0.isDefault } == true }
            .sorted { lhs, rhs in
                if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        if visible != apps {
            apps = visible
            reconcile()
        }
    }

    // MARK: - Uygulama eylemleri

    func setVolume(_ volume: Float, for app: AudioApp) {
        update(app) { $0.volume = volume; if volume > 0 { $0.muted = false } }
    }

    func toggleMute(_ app: AudioApp) {
        update(app) { $0.muted.toggle() }
    }

    func setOutput(_ uid: String?, for app: AudioApp) {
        update(app) { $0.outputUID = uid }
    }

    func reset(_ app: AudioApp) {
        update(app) { $0 = AppAudioSettings() }
    }

    func resetAll() {
        settings = [:]
        Self.save(settings, Self.settingsKey)
        reconcile()
    }

    private func update(_ app: AudioApp, _ change: (inout AppAudioSettings) -> Void) {
        var value = settings(for: app)
        change(&value)
        settings[app.id] = value.isDefault ? nil : value
        Self.save(settings, Self.settingsKey)

        // Kaydırıcı sürüklenirken tap'i yeniden kurmadan yalnızca kazancı güncelle.
        if let tap = taps[app.id], tap.outputUID == outputUID(for: value) {
            tap.dsp.target = gain(app: value, device: tap.outputUID)
        } else {
            reconcile()
        }
    }

    // MARK: - Öndeki uygulama (kısayollar için)

    func frontmostApp() -> AudioApp? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        return allApps.first { $0.ownerPID == front.processIdentifier || $0.id == front.bundleIdentifier }
    }

    func adjustFrontmost(by delta: Float) -> (AudioApp, AppAudioSettings)? {
        guard let app = frontmostApp() else { return nil }
        let current = settings(for: app)
        let maxBoost = Float(UserDefaults.standard.double(forKey: PreferenceKey.maxBoost, default: 1.5))
        let next = min(max((current.muted ? 0 : current.volume) + delta, 0), max(maxBoost, 1))
        setVolume(((next * 100).rounded() / 100).snappedToUnity, for: app)
        return (app, settings(for: app))
    }

    func toggleMuteFrontmost() -> (AudioApp, AppAudioSettings)? {
        guard let app = frontmostApp() else { return nil }
        toggleMute(app)
        return (app, settings(for: app))
    }

    // MARK: - Yazılımsal aygıt sesi

    /// Aygıtın donanım ses denetimi yoksa ses Tuno tarafından yazılımsal olarak ayarlanır.
    func usesSoftwareVolume(_ uid: String) -> Bool {
        guard let device = devices.device(uid: uid) else { return false }
        return !device.id.isSettable(.init(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                          kAudioObjectPropertyScopeOutput))
    }

    func softwareVolume(for uid: String) -> SoftwareVolume { softwareVolumes[uid] ?? SoftwareVolume() }

    var defaultUsesSoftwareVolume: Bool {
        devices.defaultOutput.map { usesSoftwareVolume($0.uid) } ?? false
    }

    func setSoftwareVolume(_ value: SoftwareVolume, for uid: String) {
        var value = value
        if let limit = devices.volumeLimit(for: uid) { value.volume = min(value.volume, limit) }
        let needsRebuild = remainder?.outputUID != uid && !value.isUnity
        softwareVolumes[uid] = value
        Self.save(softwareVolumes, Self.softwareKey)
        if needsRebuild { reconcile() } else { applyDSP() }
    }

    /// Klavye ses tuşları için; varsayılan aygıt yazılımsal sesteyse ayarlar.
    func adjustDefaultSoftwareVolume(by delta: Float) -> SoftwareVolume? {
        guard let uid = devices.defaultOutput?.uid, usesSoftwareVolume(uid) else { return nil }
        var value = softwareVolume(for: uid)
        value.volume = min(max(value.volume + delta, 0), 1)
        value.muted = false
        setSoftwareVolume(value, for: uid)
        return value
    }

    func toggleDefaultSoftwareMute() -> SoftwareVolume? {
        guard let uid = devices.defaultOutput?.uid, usesSoftwareVolume(uid) else { return nil }
        var value = softwareVolume(for: uid)
        value.muted.toggle()
        setSoftwareVolume(value, for: uid)
        return value
    }

    // MARK: - Tap yönetimi

    private func outputUID(for value: AppAudioSettings) -> String? {
        if let uid = value.outputUID, devices.device(uid: uid) != nil { return uid }
        return devices.defaultOutput?.uid
    }

    private func deviceGain(_ uid: String) -> Float {
        let software = usesSoftwareVolume(uid) ? softwareVolume(for: uid).gain : 1
        let preamp = Float(pow(10, equalizer.preampDB(for: uid) / 20))
        return software * preamp
    }

    private func gain(app value: AppAudioSettings, device uid: String) -> Float {
        value.effectiveGain * deviceGain(uid)
    }

    /// Kazançları ve EQ filtrelerini tap'leri yeniden kurmadan günceller.
    private func applyDSP() {
        for (id, tap) in taps {
            tap.dsp.target = gain(app: settings[id] ?? AppAudioSettings(), device: tap.outputUID)
            tap.dsp.setFilters(equalizer.filters(for: tap.outputUID, sampleRate: tap.sampleRate))
        }
        if let remainder {
            remainder.dsp.target = deviceGain(remainder.outputUID)
            remainder.dsp.setFilters(equalizer.filters(for: remainder.outputUID, sampleRate: remainder.sampleRate))
        }
    }

    func reconcile() {
        var errors: [String] = []
        reconcileAppTaps(&errors)
        reconcileRemainder(&errors)
        applyDSP()
        if errors.first != lastError, let error = errors.first { SupportLog.log("ses", "Hata: \(error)") }
        SupportLog.log("ses", "Uygulama sesleri: \(apps.count) uygulama, \(errors.count) hata", verbose: true)
        lastError = errors.first
    }

    private func reconcileAppTaps(_ errors: inout [String]) {
        var wanted: Set<String> = []
        for app in apps {
            let value = settings(for: app)
            // Kurulmuş bir tap, ayar %100'e dönse bile uygulama kapanana kadar korunur:
            // tap'i kapatıp yeniden kurmak sesin kesilip çıtırdamasına yol açar.
            guard !value.isDefault || taps[app.id] != nil, let uid = outputUID(for: value) else { continue }
            wanted.insert(app.id)

            if let tap = taps[app.id], tap.outputUID == uid, tap.update(source: .processes(app.processObjects)) {
                continue
            }
            taps[app.id]?.invalidate()
            taps[app.id] = nil
            do {
                taps[app.id] = try AudioTap(
                    name: app.name, source: .processes(app.processObjects), outputUID: uid,
                    gain: gain(app: value, device: uid))
            } catch {
                errors.append(Self.message(for: error, subject: app.name))
            }
        }
        for id in taps.keys where !wanted.contains(id) {
            taps[id]?.invalidate()
            taps[id] = nil
        }
    }

    private func reconcileRemainder(_ errors: inout [String]) {
        guard let uid = devices.defaultOutput?.uid else {
            remainder?.invalidate(); remainder = nil
            return
        }
        let software = usesSoftwareVolume(uid)
        let needed = equalizer.isActive(for: uid)
            || (software && !softwareVolume(for: uid).isUnity)
            || (software && remainder?.outputUID == uid)   // yazılımsal seste tap'i açık tut

        guard needed else {
            remainder?.invalidate(); remainder = nil
            return
        }

        let own = AudioProcess.ownObjectID()
        guard own.isValid else {
            // Kendi çıkışımızı hariç tutamazsak geri besleme riski var; başlatma.
            remainder?.invalidate(); remainder = nil
            errors.append("Sistem geneli ses işleme başlatılamadı (Tuno süreci bulunamadı).")
            return
        }
        let excluded = [own] + taps.values.flatMap { tap -> [AudioObjectID] in
            if case .processes(let objects) = tap.source { return objects }
            return []
        }.sorted()

        if let remainder, remainder.outputUID == uid, remainder.update(source: .device(excluding: excluded)) {
            return
        }
        remainder?.invalidate()
        remainder = nil
        do {
            remainder = try AudioTap(
                name: "Sistem", source: .device(excluding: excluded), outputUID: uid, gain: deviceGain(uid))
        } catch {
            errors.append(Self.message(for: error, subject: "Sistem sesi"))
        }
    }

    private static func message(for error: Error, subject: String) -> String {
        if let error = error as? CoreAudioError {
            return error.isPermissionDenied
                ? "Tuno'nun uygulama seslerine erişim izni yok. Sistem Ayarları › Gizlilik ve Güvenlik › Ses Kaydı bölümünden izin verin."
                : "\(subject): \(error.description)"
        }
        return error.localizedDescription
    }

    func shutdown() {
        timer?.invalidate()
        taps.values.forEach { $0.invalidate() }
        taps = [:]
        remainder?.invalidate()
        remainder = nil
    }

    // MARK: - Kalıcılık

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}

extension UserDefaults {
    func double(forKey key: String, default value: Double) -> Double {
        object(forKey: key) == nil ? value : double(forKey: key)
    }
}
