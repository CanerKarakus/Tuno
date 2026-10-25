import AppKit
import CoreAudio
import IOKit.ps
import Observation
import ScreenCaptureKit
import SwiftUI

/// Çentikli Mac'lerde çentiğin çevresinde iPhone'daki gibi bir Dynamic Island.
///
/// - Boştayken görünmez; üzerine gelince yana açılıp sabitlenen uygulamaları gösterir.
/// - Sürekli etkinlikler (müzik, görüşme, zamanlayıcı, indirme/AirDrop) çentiğin iki yanında durur; tıklanınca büyür.
///   İki etkinlik varsa ikincisi yanda yuvarlak bir baloncukta durur, tıklanınca yer değiştirirler.
/// - Kısa bildirimler (AirPods, şarj, kopyalandı, uyanık tutma, alındı, alarm) bir süre görünüp kapanır.
@Observable
@MainActor
final class NotchIsland {
    enum Live: Hashable {
        case media(String)   // müzik uygulamasının paket kimliği
        case call, timer, transfer
        /// Dosya rafı: içinde dosya varken çentikte durur; tıklanınca raf açılır.
        case shelf
    }

    enum Mode: Equatable {
        case idle, apps
        case compact(Live), expanded(Live)
        case banner(Banner)
        /// Bir dosya çentiğe doğru sürükleniyor: ada bırakma alanı olur.
        case drop
        /// Siri dinliyor: büyük oval, kenarında dönen gökkuşağı ışıltısı.
        case siri
    }

    struct Banner: Equatable, Identifiable {
        enum Kind: Equatable {
            /// Küçük: solda kulaklık, sağda ortalama pil. Üzerine gelince ayrıntı (her parçanın pili).
            case airpods(name: String, symbol: String, levels: [HeadphoneBattery.Device.Level])
            case charging(percent: Int)
            case copied(String)
            case keepAwake(active: Bool, detail: String)
            case received(name: String, url: URL, airdrop: Bool)
            /// `ringing`: sesi Tuno çalıyor (Saat uygulamasınınkini Saat çalar).
            case alarm(String, ringing: Bool)
            /// İnce bildirim (pil azaldı, Odak, Bluetooth cihazı, Wi-Fi/VPN…): yana ince büyür.
            case notice(symbol: String, tone: IslandSignals.Notice.Tone, title: String, detail: String)
        }
        let id = UUID()
        var kind: Kind
    }

    struct Call: Equatable {
        let bundleID: String
        let name: String
        let start: Date
    }

    struct Countdown: Equatable {
        let end: Date
        let total: TimeInterval
        let isAlarm: Bool
        /// Saat uygulamasında kurulmuş; iptal ve +1 dk Saat'te yapılır.
        var fromClock = false
    }

    struct Transfer: Equatable {
        let name: String
        let url: URL?
        let airdrop: Bool
        /// 0…1; toplam boyut bilinmiyorsa nil (halka döner).
        var fraction: Double?
    }

    // MARK: - Ayarlar

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey); refresh() }
    }
    /// İndirme ve AirDrop (İndirilenler klasörü izni). Açılınca izin istenir.
    private(set) var transfersEnabled: Bool {
        didSet { UserDefaults.standard.set(transfersEnabled, forKey: Self.transfersKey) }
    }
    /// Spotify'da ileri/geri sarma (Otomasyon izni). Açılınca izin istenir.
    private(set) var seekEnabled: Bool {
        didSet { UserDefaults.standard.set(seekEnabled, forKey: Self.seekKey) }
    }
    var showsMusic: Bool {
        didSet { UserDefaults.standard.set(showsMusic, forKey: Self.musicKey) }
    }
    /// Siri açılınca çentikten akan sıvı cam damla. Varsayılan açık.
    var showsSiri: Bool {
        didSet { UserDefaults.standard.set(showsSiri, forKey: Self.siriKey); watchSiri() }
    }
    /// Dosya rafı (dosyayı çentiğe sürükle). Varsayılan açık.
    var shelfEnabled: Bool {
        didSet { UserDefaults.standard.set(shelfEnabled, forKey: Self.shelfKey); if !shelfEnabled { shelf.clear(); shelf.dragging = false } }
    }
    /// İnce bildirimler: pil azaldı, Düşük Güç Modu, Bluetooth cihazı, Wi-Fi/VPN. Varsayılan açık.
    var alertsEnabled: Bool {
        didSet { UserDefaults.standard.set(alertsEnabled, forKey: Self.alertsKey); watchAlerts() }
    }
    /// Odak modu bildirimi (Odak durumu izni). Açılınca izin istenir.
    private(set) var focusEnabled: Bool {
        didSet { UserDefaults.standard.set(focusEnabled, forKey: Self.focusKey) }
    }
    let shelf = IslandShelf()
    @ObservationIgnored let signals = IslandSignals()
    private(set) var pinned: [URL]

    static let maxPinned = 8
    /// Ayarlardaki "Dene" bölümü (yayından önce kapatılır).
    static let showsTestButtons = false
    private static let enabledKey = "islandEnabled"
    private static let musicKey = "islandShowsMusic"
    private static let siriKey = "islandShowsSiri"
    private static let pinnedKey = "islandPinnedApps"
    private static let transfersKey = "islandTransfers"
    private static let seekKey = "islandSeek"
    private static let shelfKey = "islandShelf"
    private static let alertsKey = "islandAlerts"
    private static let focusKey = "islandFocus"

    // MARK: - Durum

    private(set) var hovering = false
    private(set) var siriActive = false {
        didSet { if siriActive != oldValue { siriVoice(siriActive) } }
    }
    /// Tanıtım önizlemesi: Yenilikler ekranında Siri anahtarı açıkken damla çentikte görünür (sentetik ışıkla).
    var siriPreview = false {
        didSet { if siriPreview != oldValue { previewVoice(siriPreview) } }
    }
    @ObservationIgnored private var previewTimer: Timer?
    /// Damla görünür mü (gerçek Siri ya da önizleme).
    var siriShown: Bool { siriActive || siriPreview }
    /// Siri damlasının ışığını süren ses: mikrofon (sen konuşurken) ve Siri'nin ses çıkışı (o cevap verirken).
    let siriFeed = SiriGlassAudio.Feed()
    @ObservationIgnored private var siriMic: MicListener?
    @ObservationIgnored private var siriTap: LevelTap?
    @ObservationIgnored private var siriTimer: Timer?
    /// Siri'nin son cevabı (damlanın altındaki kartta).
    private(set) var siriAnswer: String?
    /// Cevabın parçaları (hava durumu kartı için: konum, sıcaklık, durum, en yüksek/en düşük).
    private(set) var siriAnswerParts: [String] = []
    @ObservationIgnored private var lastSiriTexts: [String] = []
    @ObservationIgnored private var siriQuestions: Set<String> = []
    @ObservationIgnored private var pendingParts: [String]?
    @ObservationIgnored private var siri: SiriWatcher?
    private(set) var expanded: Live?
    /// Kullanıcının baloncuğa tıklayarak öne aldığı etkinlik.
    private(set) var primary: Live?
    private(set) var banner: Banner?
    private(set) var call: Call? {
        didSet { if (call == nil) != (oldValue == nil) { callMeter(call != nil) } }
    }
    /// Tuno'nun kendi zamanlayıcısı/alarmı ve Saat uygulamasındaki en yakın zamanlayıcı.
    private(set) var ownCountdown: Countdown?
    private(set) var clockCountdown: Countdown?
    var countdown: Countdown? { ownCountdown ?? clockCountdown }
    private(set) var transfer: Transfer?
    private(set) var notch: CGSize = .zero
    private(set) var inFront: Set<String> = []
    private(set) var levelTap: LevelTap?
    @ObservationIgnored private var levelTapPlayer: String?

    let players = [MediaPlayer(.spotify), MediaPlayer(.music)] + MediaPlayer.Source.browsers.map(MediaPlayer.init)
    @ObservationIgnored private var watchers: [AppWindowWatcher] = []

    /// AppDelegate'in bağladığı modeller (görüşmede mikrofon, uyanık tutma, kulaklık pili).
    @ObservationIgnored private(set) var devices: DeviceStore?
    @ObservationIgnored private(set) var inputMeter: InputMeter?
    @ObservationIgnored private var keepAwake: KeepAwake?
    @ObservationIgnored private var battery: HeadphoneBattery?

    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var screenFrame: CGRect = .zero
    @ObservationIgnored private var mouseTap: CFMachPort?
    @ObservationIgnored private var hoverTimer: Timer?
    @ObservationIgnored private var dragTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var countdownTimer: Timer?
    @ObservationIgnored private var alarmSound: Timer?
    @ObservationIgnored private var callTimer: Timer?
    @ObservationIgnored private var deviceListener: PropertyListener?
    @ObservationIgnored private var bluetoothOutputs: Set<String> = []
    @ObservationIgnored private var powerSource: CFRunLoopSource?
    @ObservationIgnored private var pluggedIn: Bool?
    @ObservationIgnored private var downloads: DownloadsWatcher?
    @ObservationIgnored private var clock: ClockWatcher?
    @ObservationIgnored private var pollTick = 0

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey, default: true)
        showsMusic = UserDefaults.standard.bool(forKey: Self.musicKey, default: true)
        showsSiri = UserDefaults.standard.bool(forKey: Self.siriKey, default: true)
        shelfEnabled = UserDefaults.standard.bool(forKey: Self.shelfKey, default: true)
        alertsEnabled = UserDefaults.standard.bool(forKey: Self.alertsKey, default: true)
        focusEnabled = UserDefaults.standard.bool(forKey: Self.focusKey) && IslandSignals.focusAuthorized
        // İzin sonradan geri alındıysa anahtar kapalı görünür.
        transfersEnabled = UserDefaults.standard.bool(forKey: Self.transfersKey) && IslandPermissions.downloadsGranted
        seekEnabled = UserDefaults.standard.bool(forKey: Self.seekKey)
            && IslandPermissions.automationGranted(MediaPlayer.Source.spotify.bundleID)
        pinned = (UserDefaults.standard.stringArray(forKey: Self.pinnedKey) ?? []).map { URL(fileURLWithPath: $0) }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        for player in players {
            let watcher = AppWindowWatcher(bundleID: player.id)
            if watcher.inFront { inFront.insert(player.id) }
            watcher.onChange = { [weak self] front in
                if front { self?.inFront.insert(player.id) } else { self?.inFront.remove(player.id) }
            }
            watchers.append(watcher)
        }
        observeMode()
        refresh()
    }

    /// AppDelegate açılışta bağlar.
    func attach(devices: DeviceStore, inputMeter: InputMeter, keepAwake: KeepAwake, battery: HeadphoneBattery) {
        self.devices = devices
        self.inputMeter = inputMeter
        self.keepAwake = keepAwake
        self.battery = battery
        observeKeepAwake()
        watchBluetooth()
        watchPower()
        if transfersEnabled { watchTransfers() }
        watchClock()
        callTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollAudioApps() }
        }
        callTimer?.tolerance = 0.3
        watchSiri()
        signals.onNotice = { [weak self] notice in
            self?.show(.notice(symbol: notice.symbol, tone: notice.tone, title: notice.title, detail: notice.detail), for: 2.6)
        }
        watchAlerts()
        if focusEnabled { signals.startFocus() }
        shelf.onLink = { [weak self] _ in self?.show(.copied(L("Link kopyalandı")), for: 2.2) }
        shelf.onChange = { [weak self] in
            guard let self else { return }
            if self.shelf.items.isEmpty, self.expanded == .shelf { self.expanded = nil }
        }
        DemoHook.install(self)
    }

    /// Çentikli bir ekran var mı (dahili ekran).
    static var notchedScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil }
    }

    /// Ada ekranda mı (kısayol göstergeleri yerine adayı kullanmak için).
    var isPresented: Bool { panel != nil }

    // MARK: - Etkinlikler

    func player(_ id: String) -> MediaPlayer? { players.first { $0.id == id } }

    /// Müzik uygulaması çalıyor ya da duraklatılmış (açık kaldığı sürece) ve önde değil.
    private func mediaVisible(_ player: MediaPlayer) -> Bool {
        showsMusic && player.track != nil
    }

    /// Önem sırasıyla sürekli etkinlikler; kullanıcının öne aldığı en başta.
    var activities: [Live] {
        var list: [Live] = []
        if call != nil { list.append(.call) }
        if countdown != nil { list.append(.timer) }
        if transfer != nil { list.append(.transfer) }
        if shelfEnabled, !shelf.items.isEmpty { list.append(.shelf) }
        // Öndeki uygulamanınki en sona: başka etkinlik varsa baloncukta durur.
        let media = players.filter(mediaVisible).sorted { lhs, rhs in
            let lhsFront = inFront.contains(lhs.id), rhsFront = inFront.contains(rhs.id)
            if lhsFront != rhsFront { return rhsFront }
            if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
            return lhs.lastChange > rhs.lastChange
        }
        list += media.map { .media($0.id) }
        if let primary, let index = list.firstIndex(of: primary), index > 0 {
            list.insert(list.remove(at: index), at: 0)
        }
        // iPhone'daki gibi: öndeki uygulamanın etkinliği tek başınaysa gizlenir (büyütülmüşse kalır).
        if list.count == 1, case .media(let id) = list[0], inFront.contains(id), expanded != list[0] { return [] }
        return list
    }

    var mode: Mode {
        if siriShown { return .siri }
        if shelfEnabled, shelf.dragging { return .drop }
        if let banner { return .banner(banner) }
        let list = activities
        if let expanded, list.contains(expanded) { return .expanded(expanded) }
        if let first = list.first { return .compact(first) }
        return hovering ? .apps : .idle
    }

    /// Yandaki yuvarlak baloncuktaki ikinci etkinlik.
    var secondary: Live? {
        switch mode {
        case .compact(let live), .expanded(let live): activities.first { $0 != live }
        default: nil
        }
    }

    /// Adanın gövde boyutu (çentiğin yanındaki kanatlar dahil, üst kıvrımlar hariç). Her durumun azami genişliği
    /// sabittir: kanatlar çentikten fazla uzamaz. Küçük işler (zamanlayıcı, görüşme, aktarım, alarm) büyüyünce
    /// yalnızca biraz uzayan oval bir kapsül olur; büyük kart yalnızca oynatıcı ve AirPods ayrıntısındadır.
    var size: CGSize {
        let w = notch.width, h = notch.height
        let grow: CGFloat = hovering ? 4 : 0
        func wings(_ wing: CGFloat, extra: CGFloat = 0) -> CGSize { CGSize(width: w + 2 * wing, height: h + extra) }
        switch mode {
        case .idle: return CGSize(width: w - 8, height: h)   // çentiğin arkasında kalır; yalnızca yanlardan kapanır
        case .siri: return CGSize(width: w - 8, height: h)   // damla çentikten akar (SiriGlass)
        case .drop: return CGSize(width: w + 2 * 96, height: h + 46)
        case .apps:
            let perSide = max(1, Int(ceil(Double(pinned.count) / 2)))
            return wings(CGFloat(perSide) * 34 + 12)
        case .compact(let live):
            switch live {
            case .media, .transfer, .shelf: return wings(36 + grow)
            case .call, .timer: return wings(58 + grow)
            }
        case .expanded(let live):
            switch live {
            case .media: return CGSize(width: min(max(w + 220, 420), 440), height: h + 150)
            case .call, .timer: return wings(108, extra: 38)
            case .transfer: return wings(104, extra: 30)
            case .shelf: return CGSize(width: min(max(w + 220, 400), 440), height: h + 118)
            }
        case .banner(let banner):
            switch banner.kind {
            case .airpods: return hovering ? wings(110, extra: 40) : wings(66)
            case .alarm: return wings(96, extra: 38)
            case .received: return wings(110)
            case .copied: return wings(86)
            case .charging, .keepAwake: return wings(100)
            case .notice(_, _, let title, let detail):
                // Kanat, metnin uzunluğuna göre açılır (ince kalır, yazı sığar).
                let left = 24 + 7.4 * CGFloat(title.count), right = 7.4 * CGFloat(detail.count)
                return wings(max(88, max(left, right) + 26))
            }
        }
    }

    static let bubbleGap: CGFloat = 4

    /// Adanın boş bir yerine tıklanınca: etkinlik büyür/küçülür, bildirim kendi işini yapar.
    func tapIsland() {
        switch mode {
        case .compact(let live), .expanded(let live): toggleExpanded(live)
        case .banner: tapBanner()
        default: break
        }
    }

    /// Biri ekrana bakıyor (Yüz Tanıma): açık kart kapanır.
    func collapseForPrivacy() {
        expanded = nil
    }

    func toggleExpanded(_ live: Live) {
        expanded = expanded == live ? nil : live
        // Oynatıcı açılınca süre ve konum tazelenir (Spotify atlamada bildirim göndermez).
        if case .media(let id) = expanded { player(id)?.refreshProgress() }
    }

    /// Baloncuğa tıklanınca o etkinlik büyük alana, büyükteki baloncuğa geçer.
    func promote(_ live: Live) {
        primary = live
        if expanded != nil { expanded = live }
    }

    // MARK: - Uygulamalar

    var leftApps: [URL] { Array(pinned.prefix(Int(ceil(Double(pinned.count) / 2)))) }
    var rightApps: [URL] { Array(pinned.dropFirst(Int(ceil(Double(pinned.count) / 2)))) }

    func add(_ urls: [URL]) {
        for url in urls where !pinned.contains(url) && pinned.count < Self.maxPinned { pinned.append(url) }
        savePinned()
    }

    func remove(_ url: URL) {
        pinned.removeAll { $0 == url }
        savePinned()
    }

    func move(from source: IndexSet, to destination: Int) {
        pinned.move(fromOffsets: source, toOffset: destination)
        savePinned()
    }

    func open(_ url: URL) {
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
        setHovering(false)
    }

    func openSettings() {
        setHovering(false)
        WindowOpener.openMain()
        NotificationCenter.default.post(name: .tunoOpenPage, object: Page.island)
    }

    private func savePinned() {
        UserDefaults.standard.set(pinned.map(\.path), forKey: Self.pinnedKey)
    }

    // MARK: - Kısa bildirimler

    func show(_ kind: Banner.Kind, for seconds: TimeInterval?) {
        guard panel != nil else { return }
        let banner = Banner(kind: kind)
        self.banner = banner
        bannerTask?.cancel()
        guard let seconds else { return }
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            // Üzerine gelinmişse fare çekilene kadar kalır, sonra kısa bir süre daha.
            var waited = false
            while !Task.isCancelled, self?.hovering == true {
                waited = true
                try? await Task.sleep(for: .milliseconds(300))
            }
            if waited { try? await Task.sleep(for: .seconds(1.2)) }
            guard !Task.isCancelled, self?.banner?.id == banner.id, self?.hovering == false else { return }
            self?.dismissBanner()
        }
    }

    func dismissBanner() {
        bannerTask?.cancel()
        if case .alarm = banner?.kind { stopAlarmSound() }
        banner = nil
    }

    /// Bildirime tıklanınca: alınan dosya açılır, diğerleri kapanır.
    func tapBanner() {
        guard let banner else { return }
        switch banner.kind {
        case .received(_, let url, _): NSWorkspace.shared.open(url)
        case .alarm: return
        default: break
        }
        dismissBanner()
    }

    func showCopied(_ text: String) {
        show(.copied(text), for: 1.8)
    }

    private func observeKeepAwake() {
        guard let keepAwake else { return }
        withObservationTracking {
            _ = keepAwake.isActive
            _ = keepAwake.minutes
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let keepAwake = self.keepAwake else { return }
                    var detail = L("Kapalı")
                    if keepAwake.isActive {
                        let minutes = keepAwake.minutes
                        detail = KeepAwake.durations.first { $0.minutes == minutes }?.title ?? L("Süresiz")
                    }
                    self.show(.keepAwake(active: keepAwake.isActive, detail: detail), for: 2.2)
                    self.observeKeepAwake()
                }
            }
        }
    }

    // MARK: AirPods ve Bluetooth kulaklık

    private func watchBluetooth() {
        bluetoothOutputs = Self.bluetoothOutputs().reduce(into: []) { $0.insert($1.uid) }
        deviceListener = PropertyListener(.system, .init(kAudioHardwarePropertyDevices)) { [weak self] in
            MainActor.assumeIsolated { self?.bluetoothChanged() }
        }
    }

    private func bluetoothChanged() {
        let current = Self.bluetoothOutputs()
        let added = current.filter { !bluetoothOutputs.contains($0.uid) }
        bluetoothOutputs = Set(current.map(\.uid))
        guard let device = added.first else { return }
        announceHeadphones(name: device.name)
    }

    /// AirPods bağlanınca iPhone'daki gibi büyük bildirim; pil düzeyleri gelince halkalar dolar.
    func announceHeadphones(name: String, levels: [HeadphoneBattery.Device.Level] = []) {
        show(.airpods(name: name, symbol: Self.symbol(forHeadphones: name), levels: levels), for: 5)
        guard levels.isEmpty, let battery else { return }
        battery.refresh(force: true)
        withObservationTracking { _ = battery.devices } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let banner = self.banner, case .airpods(let current, let symbol, _) = banner.kind,
                          current == name, let found = battery.devices.first(where: { $0.name == name })
                    else { return }
                    self.banner?.kind = .airpods(name: name, symbol: symbol, levels: found.levels)
                }
            }
        }
    }

    /// Ayarlardaki deneme düğmesi ve deneme kancası için örnek AirPods.
    func demoAirPods() {
        announceHeadphones(name: "AirPods Pro", levels: [
            .init(label: L("Sol"), percent: 82), .init(label: L("Sağ"), percent: 78), .init(label: L("Kutu"), percent: 45),
        ])
    }

    static func symbol(forHeadphones name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("max") { return "airpodsmax" }
        if lower.contains("pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods.gen3" }
        if lower.contains("beats") { return "beats.headphones" }
        return "headphones"
    }

    private static func bluetoothOutputs() -> [(uid: String, name: String)] {
        AudioObjectID.system.readArray(.init(kAudioHardwarePropertyDevices), of: AudioObjectID.self).compactMap { device in
            let transport = device.read(.init(kAudioDevicePropertyTransportType), initial: UInt32(0)) ?? 0
            guard transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
                  device.hasProperty(.init(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)),
                  !device.readArray(.init(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput), of: AudioObjectID.self).isEmpty,
                  let uid = device.readString(.init(kAudioDevicePropertyDeviceUID))
            else { return nil }
            return (uid, device.readString(.init(kAudioObjectPropertyName)) ?? "AirPods")
        }
    }

    // MARK: Şarj

    private func watchPower() {
        pluggedIn = Self.isPluggedIn()
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let island = Unmanaged<NotchIsland>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { island.powerChanged() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSource = source
    }

    private func powerChanged() {
        let now = Self.isPluggedIn()
        defer { pluggedIn = now }
        signals.batteryChanged()
        guard now == true, pluggedIn == false, let info = MacBattery().info else { return }
        show(.charging(percent: info.percent), for: 3.5)
    }

    private static func isPluggedIn() -> Bool? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        else { return nil }
        return type == kIOPMACPowerKey
    }

    // MARK: Zamanlayıcı ve alarm

    func startTimer(seconds: TimeInterval) {
        start(Countdown(end: Date().addingTimeInterval(seconds), total: seconds, isAlarm: false))
    }

    func setAlarm(at date: Date) {
        var end = date
        if end <= Date() { end = Calendar.current.date(byAdding: .day, value: 1, to: end) ?? end }
        start(Countdown(end: end, total: end.timeIntervalSinceNow, isAlarm: true))
    }

    func addMinute() {
        guard let countdown = ownCountdown else { return }
        start(Countdown(end: countdown.end.addingTimeInterval(60), total: countdown.total + 60, isAlarm: countdown.isAlarm))
    }

    /// Saat uygulamasının zamanlayıcısı Tuno'dan durdurulamaz; Saat açılır.
    func cancelCountdown() {
        guard ownCountdown != nil else {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.clock") {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            }
            return
        }
        countdownTimer?.invalidate()
        ownCountdown = nil
        if expanded == .timer, clockCountdown == nil { expanded = nil }
    }

    private func start(_ value: Countdown) {
        countdownTimer?.invalidate()
        ownCountdown = value
        countdownTimer = Timer.scheduledTimer(withTimeInterval: max(value.end.timeIntervalSinceNow, 0), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.countdownFinished() }
        }
    }

    private func countdownFinished() {
        guard let countdown = ownCountdown else { return }
        cancelCountdown()
        let title = countdown.isAlarm
            ? String(format: L("Alarm · %@"), countdown.end.formatted(date: .omitted, time: .shortened))
            : L("Zamanlayıcı bitti")
        show(.alarm(title, ringing: true), for: nil)
        startAlarmSound()
    }

    /// Saat uygulamasının zamanlayıcıları adada; bitince ya da alarm saati gelince ada kısa bir bildirim gösterir
    /// (sesi Saat çalar).
    private func watchClock() {
        let clock = ClockWatcher()
        clock.onTimers = { [weak self] timers in
            self?.clockCountdown = timers.first.map { Countdown(end: $0.end, total: $0.total, isAlarm: false, fromClock: true) }
        }
        clock.onRing = { [weak self] title, _ in
            self?.show(.alarm(title, ringing: false), for: 8)
        }
        self.clock = clock
    }

    /// Alarm sesi kapatılana kadar (en çok bir dakika) yinelenir.
    private func startAlarmSound() {
        stopAlarmSound()
        var count = 0
        NSSound(named: "Glass")?.play()
        alarmSound = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: true) { [weak self] timer in
            count += 1
            if count > 42 { timer.invalidate(); return }
            MainActor.assumeIsolated { _ = self; NSSound(named: "Glass")?.play() }
        }
    }

    private func stopAlarmSound() {
        alarmSound?.invalidate()
        alarmSound = nil
    }

    // MARK: Görüşme

    private static let callApps: [String: String] = [
        "us.zoom.xos": "Zoom", "com.microsoft.teams2": "Teams", "com.microsoft.teams": "Teams",
        "com.apple.FaceTime": "FaceTime", "com.hnc.Discord": "Discord", "com.tinyspeck.slackmacgap": "Slack",
        "net.whatsapp.WhatsApp": "WhatsApp", "desktop.WhatsApp": "WhatsApp", "ru.keepcoder.Telegram": "Telegram",
        "com.skype.skype": "Skype", "Cisco-Systems.Spark": "Webex",
    ]

    /// Listedeki bir uygulama mikrofonu kullanıyorsa görüşmede sayılır (FaceTime sesi avconferenced'den gelir).
    /// Görüşme (2 sn'de bir) ve tarayıcı sesi (saniyede bir) tek süreç taramasıyla; yalnızca ilgili bir uygulama
    /// açıkken taranır (her tarama coreaudiod'a mesaj gönderir).
    private func pollAudioApps() {
        pollTick += 1
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let checkCall = pollTick % 2 == 0 && (call != nil || !running.isDisjoint(with: Self.callApps.keys))
        let browsers = players.filter { $0.source.isBrowser && (running.contains($0.id) || $0.track != nil) }
        guard checkCall || !browsers.isEmpty else { return }
        let processes = AudioProcess.all()
        if checkCall { pollCall(processes) }
        guard !browsers.isEmpty else { return }
        let apps = AudioApp.group(processes)
        for browser in browsers {
            browser.updateFromBrowser(playing: apps.first { $0.id == browser.id }?.isPlaying ?? false)
        }
    }

    private func pollCall(_ processes: [AudioProcess]) {
        guard call == nil || !(call?.bundleID.hasPrefix("demo") ?? false) else { return }
        var found = AudioApp.group(processes).first { $0.isRecording && Self.callApps[$0.id] != nil }?.id
        if found == nil, processes.contains(where: { $0.isRunningInput && $0.bundleID == "com.apple.avconferenced" }),
           !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.FaceTime").isEmpty {
            found = "com.apple.FaceTime"
        }
        guard let found else {
            if call != nil { call = nil; if expanded == .call { expanded = nil } }
            return
        }
        if call?.bundleID != found { call = Call(bundleID: found, name: Self.callApps[found] ?? found, start: Date()) }
    }

    @ObservationIgnored private var startedMeter = false

    /// Görüşme sürerken mikrofon dalgası için ölçer açık (Tuno başlattıysa görüşme bitince kapanır).
    private func callMeter(_ on: Bool) {
        guard let inputMeter else { return }
        if on, !inputMeter.isRunning {
            inputMeter.start()
            startedMeter = true
        } else if !on, startedMeter {
            inputMeter.stop()
            startedMeter = false
        }
    }

    func toggleMicrophone() {
        guard let devices else { return }
        devices.setMicrophoneMuted(!devices.microphoneMuted)
    }

    // MARK: İndirme ve AirDrop

    /// İndirilenler klasörü: süren indirme ya da AirDrop adada, bitince "İndirildi/Alındı" bildirimi.
    /// Anahtar: açılınca izin istenir; verilmezse kapalı kalır.
    func setTransfers(_ on: Bool) {
        guard on else {
            transfersEnabled = false
            downloads?.stop()
            downloads = nil
            transfer = nil
            return
        }
        Task.detached {
            let granted = IslandPermissions.requestDownloads()
            await MainActor.run {
                self.transfersEnabled = granted
                if granted, self.downloads == nil { self.watchTransfers() }
            }
        }
    }

    func setSeek(_ on: Bool) {
        guard on else { seekEnabled = false; return }
        let spotify = MediaPlayer.Source.spotify
        Task.detached {
            let granted = IslandPermissions.requestAutomation(of: spotify.bundleID, scriptName: spotify.scriptName)
            await MainActor.run { self.seekEnabled = granted }
        }
    }

    private func watchTransfers() {
        let downloads = DownloadsWatcher()
        downloads.onActive = { [weak self] item in
            guard let self else { return }
            guard let item else {
                if self.transfer != nil { self.transfer = nil; if self.expanded == .transfer { self.expanded = nil } }
                return
            }
            self.transfer = Transfer(name: item.name, url: item.url, airdrop: item.airdrop, fraction: item.fraction)
        }
        downloads.onFinished = { [weak self] url, airdrop in
            guard let self else { return }
            self.finishTransfer(Transfer(name: url.lastPathComponent, url: url, airdrop: airdrop, fraction: 1), completed: true)
        }
        self.downloads = downloads
    }

    func finishTransfer(_ value: Transfer, completed: Bool) {
        transfer = nil
        if expanded == .transfer { expanded = nil }
        guard completed, let url = value.url else { return }
        show(.received(name: value.name, url: url, airdrop: value.airdrop), for: 5)
    }

    /// Deneme kancası için sahte aktarım.
    func simulateTransfer(airdrop: Bool) {
        let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        transfer = Transfer(name: airdrop ? "IMG_2048.HEIC" : "Tuno.dmg", url: url, airdrop: airdrop, fraction: 0)
        Task { [weak self] in
            for step in 1...20 {
                try? await Task.sleep(for: .milliseconds(200))
                self?.transfer?.fraction = Double(step) / 20
            }
            if let value = self?.transfer { self?.finishTransfer(value, completed: true) }
        }
    }

    /// Siri açıkken saniyede 30 kez: mikrofonun ve Siri'nin sesinin yükseği damlaya gider.
    private func siriVoice(_ on: Bool) {
        siriTimer?.invalidate()
        siriTimer = nil
        guard on else {
            siriMic?.stop()
            siriTap?.invalidate()
            siriTap = nil
            ScreenLens.shared.stop()
            siriAnswer = nil
            siriAnswerParts = []
            siriQuestions = []
            pendingParts = nil
            lastSiriTexts = []
            return
        }
        // Damlanın arkası: mercek için panelin üst ortasındaki bölge yakalanır.
        if let panel {
            let width = panel.frame.width
            ScreenLens.shared.start(panel: panel, viewRect: CGRect(x: width / 2 - 160, y: 0, width: 320, height: 260))
        }
        let own = AudioProcess.ownObjectID()
        siriTap = own.isValid ? try? LevelTap(processes: [own], excluding: true) : nil
        let mic = siriMic ?? MicListener()
        siriMic = mic
        Task { _ = await mic.start() }
        var tick = 0
        siriTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Siri'nin süreçlerine ölçüm bağlanmaz: konuşma tanımadaki ses yolunu bozup Siri'nin cevap
                // vermesini engelliyordu. Cevabın sesi, hoparlöre giden toplam sesten ölçülür (Tuno hariç).
                if tick % 8 == 0 { self.readSiriAnswer() }   // saniyede ~4: cevap erken görünsün
                tick += 1
                let voice = mic.levels(), answer = Self.levels(self.siriTap?.levels)
                self.siriFeed.send(SiriGlassLevels(loudness: max(voice.loudness, answer.loudness), low: max(voice.low, answer.low),
                                                   mid: max(voice.mid, answer.mid), high: max(voice.high, answer.high)))
            }
        }
    }

    /// Siri'nin cevabı: katmandaki metinler, soru hariç. Hava durumu gibi kartlar kısa parçalardan oluşur
    /// ("Pendik", "16°"…): tek satırda birleşir.
    private func readSiriAnswer() {
        let texts = SiriWatcher.texts()
        guard texts != lastSiriTexts else { return }
        lastSiriTexts = texts
        SupportLog.log("siri", "Metinler: " + texts.joined(separator: " ¦ "), verbose: true)
        // Soru: Siri dinlerken ekranda tek başına duran metin ve onun büyüyen hâlleri ("Hava" → "Hava nasıl").
        // Hiç gösterilmez; kartta yalnızca Siri'nin cevabı olur.
        if texts.count == 1, let only = texts.first { siriQuestions.insert(only) }
        func isQuestion(_ text: String) -> Bool {
            siriQuestions.contains { text == $0 || text.hasPrefix($0) || $0.hasPrefix(text) }
        }
        for text in texts where isQuestion(text) { siriQuestions.insert(text) }
        let parts = texts.filter { !isQuestion($0) }
        guard !parts.isEmpty, parts != siriAnswerParts else { pendingParts = nil; return }
        // Kart kıpırdamasın: ilk cevap hemen; sonraki değişiklik iki okumada üst üste aynıysa. Yalnızca eksilen
        // metinler (Siri'nin kartı kapanırken) kartı değiştirmez.
        if !siriAnswerParts.isEmpty {
            if Set(parts).isSubset(of: Set(siriAnswerParts)) { return }
            guard pendingParts == parts else { pendingParts = parts; return }
        }
        pendingParts = nil
        siriAnswerParts = parts
        siriAnswer = parts.contains { $0.count > 40 } ? parts.joined(separator: "\n") : parts.joined(separator: " · ")
    }

    /// LevelTap'in bant RMS'leri (90 Hz…9 kHz) → damlanın 0…1 düzeyleri.
    private static func levels(_ bands: [Float]?) -> SiriGlassLevels {
        guard let bands, bands.count >= 4 else { return SiriGlassLevels() }
        func unit(_ rms: Float) -> Float { min(max((20 * log10(max(rms, 1e-6)) + 50) / 40, 0), 1) }
        let low = unit(max(bands[0], bands[1])), mid = unit(bands[2]), high = unit(bands[3])
        return SiriGlassLevels(loudness: max(low, mid, high), low: low, mid: mid, high: high)
    }

    /// Siri izleme yalnızca anahtar açıkken çalışır; kapatılınca damla hemen çekilir.
    private func watchSiri() {
        guard showsSiri else {
            siri = nil
            siriActive = false
            return
        }
        guard siri == nil, devices != nil else { return }
        let siri = SiriWatcher()
        siri.onChange = { [weak self] active in self?.siriActive = active }
        self.siri = siri
    }

    /// Önizlemede damlanın ışığı konuşur gibi yavaşça dalgalanır; mikrofon açılmaz.
    private func previewVoice(_ on: Bool) {
        previewTimer?.invalidate()
        previewTimer = nil
        guard !siriActive else { return }
        guard on else { ScreenLens.shared.stop(); return }
        if let panel {
            let width = panel.frame.width
            ScreenLens.shared.start(panel: panel, viewRect: CGRect(x: width / 2 - 160, y: 0, width: 320, height: 260))
        }
        let start = Date()
        previewTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.siriActive else { return }
                let t = Float(Date().timeIntervalSince(start))
                // Hece hece konuşma: yavaş bir zarf ve üstünde hızlı kıpırtılar.
                let envelope = 0.5 + 0.5 * sin(t * 1.3) * sin(t * 0.47 + 1)
                func wave(_ speed: Float, _ phase: Float) -> Float { 0.5 + 0.5 * sin(t * speed + phase) }
                let low = 0.25 + 0.5 * envelope * wave(5.1, 0)
                let mid = 0.2 + 0.5 * envelope * wave(7.3, 1.7)
                let high = 0.15 + 0.45 * envelope * wave(9.7, 3.1)
                self.siriFeed.send(SiriGlassLevels(loudness: max(low, mid, high), low: low, mid: mid, high: high))
            }
        }
    }

    func simulateSiri() {
        siriActive = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.siriActive = self?.siri?.active ?? false
        }
    }

    func simulateCall() {
        call = Call(bundleID: "demo.zoom", name: "Zoom", start: Date())
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            self?.call = nil
        }
    }

    // MARK: - Sistem bildirimleri ve Odak

    private var alertsStarted = false

    private func watchAlerts() {
        signals.alertsOn = alertsEnabled
        guard alertsEnabled, !alertsStarted else { return }
        alertsStarted = true
        signals.startLowPower()
        signals.startBluetooth()
        signals.startNetwork()
    }

    /// Odak anahtarı: açılınca Odak durumu izni istenir; verilmezse kapalı kalır.
    func setFocus(_ on: Bool) {
        guard on else {
            focusEnabled = false
            signals.stopFocus()
            return
        }
        signals.enableFocus { [weak self] granted in self?.focusEnabled = granted }
    }

    // MARK: - Dosya rafı

    /// Rafa dosya bırakıldı: raf açılır.
    func dropFiles(_ urls: [URL]) {
        shelf.dragging = false
        guard shelfEnabled, shelf.add(urls) > 0 else { return }
        expanded = .shelf
        setHovering(true)
    }

    /// Dosya sürüklenirken (Finder, Masaüstü…) fare çentiğe yaklaşınca ada bırakma alanına dönüşür.
    private func checkFileDrag() {
        guard shelfEnabled, NSEvent.pressedMouseButtons & 1 != 0 else { return }
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return }
        let near = hitRect(margin: 70).contains(NSEvent.mouseLocation)
        if near, !shelf.dragging {
            shelf.dragging = true
            updatePanelMouse()
            var away = 0, released = 0
            dragTimer?.invalidate()
            dragTimer = Timer.scheduledTimer(withTimeInterval: 1 / 20, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self, self.shelf.dragging else { timer.invalidate(); self?.dragTimer = nil; return }
                    away = self.hitRect(margin: 110).contains(NSEvent.mouseLocation) ? 0 : away + 1
                    released = NSEvent.pressedMouseButtons & 1 == 0 ? released + 1 : 0
                    // Uzaklaşıldıysa ya da bırakıldı ama bırakma gelmediyse (drop önce gelir) alan kapanır.
                    if away >= 6 || released >= 4 {
                        timer.invalidate()
                        self.dragTimer = nil
                        self.shelf.dragging = false
                        self.updatePanelMouse()
                    }
                }
            }
        }
    }

    /// Panel yalnızca fare üzerindeyken, dosya sürüklenirken ya da raf açıkken fare olaylarını alır.
    private func updatePanelMouse() {
        panel?.ignoresMouseEvents = !(hovering || shelf.dragging)
    }

    /// Dosya rafını deneme için: iki örnek dosya rafa girer.
    func demoShelf() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tuno-raf-deneme", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (name, text) in [("Rapor.txt", "Tuno dosya rafı denemesi."), ("Notlar.txt", "İkinci deneme dosyası.")] {
            let url = folder.appending(path: name)
            try? text.write(to: url, atomically: true, encoding: .utf8)
            urls.append(url)
        }
        guard panel != nil else { return }
        dropFiles(urls)
    }

    // MARK: - Panel

    private func refresh() {
        guard isEnabled, let screen = Self.notchedScreen,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea
        else { return teardown() }

        let frame = screen.frame
        notch = CGSize(width: frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        screenFrame = frame
        let width: CGFloat = 760, height: CGFloat = 340   // Siri'nin cevap kartı için yer
        let midX = left.maxX + notch.width / 2
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(NSRect(x: midX - width / 2, y: frame.maxY - height, width: width, height: height), display: true)
        panel.orderFrontRegardless()

        if mouseTap == nil { startMouseTap() }
    }

    private func teardown() {
        if let mouseTap { CGEvent.tapEnable(tap: mouseTap, enable: false); CFMachPortInvalidate(mouseTap) }
        mouseTap = nil
        hoverTimer?.invalidate()
        hoverTimer = nil
        panel?.orderOut(nil)
        panel = nil
        hovering = false
        expanded = nil
    }

    private func makePanel() -> NSPanel {
        let panel = IslandPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let hosting = FirstMouseHostingView(rootView: IslandView(island: self))
        // Panel sabit boyutlu: her güncellemede pencere boyut sınırlarını yeniden hesaplamasın (dalga saniyede 20 kez çizilir).
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }

    /// Fare hareketleri yalnızca dinlenir (değiştirilmez). Genel izleyici Tuno öndeyken olay almadığından
    /// oturum düzeyinde bir dinleme kancası kullanılır (Erişilebilirlik izniyle); yoksa genel izleyiciye düşülür.
    private func startMouseTap() {
        let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue) | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, info in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput, let info {
                let island = Unmanaged<NotchIsland>.fromOpaque(info).takeUnretainedValue()
                MainActor.assumeIsolated { island.mouseTap.map { CGEvent.tapEnable(tap: $0, enable: true) } }
            } else if let info {
                let island = Unmanaged<NotchIsland>.fromOpaque(info).takeUnretainedValue()
                MainActor.assumeIsolated { island.checkMouse() }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            _ = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkMouse() }
            }
            _ = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
                MainActor.assumeIsolated { self?.checkMouse() }
                return event
            }
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        mouseTap = tap
    }

    /// Adanın ekrandaki dikdörtgeni (üst kıvrımlar, baloncuk ve küçük bir pay dahil).
    private func hitRect(margin: CGFloat) -> CGRect {
        let size = mode == .idle ? notch : self.size
        let bubble = secondary == nil ? 0 : Self.bubbleGap + notch.height
        let midX = (panel?.frame.midX ?? 0)
        let half = size.width / 2 + IslandView.flare + bubble + margin
        // Üstte ekranın en üst satırı da dahil (birkaç nokta taşar).
        return CGRect(x: midX - half, y: screenFrame.maxY - size.height - margin, width: 2 * half, height: size.height + margin + 4)
    }

    private func checkMouse() {
        checkFileDrag()
        guard !hovering, hitRect(margin: 0).contains(NSEvent.mouseLocation) else { return }
        setHovering(true)
    }

    /// Fare adanın üzerindeyken, çıktığını anlamak için hafif bir yoklama (yalnızca bu sırada çalışır).
    private func setHovering(_ value: Bool) {
        guard hovering != value else { return }
        hovering = value
        if !value { expanded = nil }
        updatePanelMouse()
        hoverTimer?.invalidate()
        hoverTimer = nil
        guard value else { return }
        var outside = 0
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                outside = self.hitRect(margin: 8).contains(NSEvent.mouseLocation) ? 0 : outside + 1
                if outside >= 5 { self.setHovering(false) }   // ~150 ms dışarıda kalınca kapanır
            }
        }
    }

    // MARK: - Ses dalgası

    /// Görünüm değişince dalga ölçümü güncellenir.
    private func observeMode() {
        withObservationTracking {
            _ = mode
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.updateLevels()
                    self.observeMode()
                }
            }
        }
    }

    /// Dalga yalnızca ada çalan bir müziği gösterirken ölçülür; başka zaman tap kapalıdır.
    /// Ölçüm duraklatınca ya da ada başka bir şey gösterirken kapanmaz: tap'i kapatmak ses aygıtı listesini
    /// değiştiriyor, tarayıcılar bunu kesintinin bitmesi sayıp duraklatılan videoyu sürdürebiliyor. Yalnızca
    /// etkinlik tamamen kaybolunca ya da başka bir uygulamaya geçince kapanır.
    private func updateLevels() {
        var shownID: String?
        switch mode {
        case .compact(.media(let id)), .expanded(.media(let id)): shownID = id
        default: break
        }
        if shownID == nil, let current = levelTapPlayer, activities.contains(.media(current)) { return }
        guard panel != nil, let shownID, let shown = player(shownID) else {
            levelTap?.invalidate()
            levelTap = nil
            levelTapPlayer = nil
            return
        }
        // Yeni ölçüm yalnızca ses çalarken başlar.
        guard shown.isPlaying || levelTapPlayer == shownID else { return }
        let objects = AudioApp.group(AudioProcess.all()).first { $0.id == shown.id }?.processObjects ?? []
        guard !objects.isEmpty else { return }
        if levelTap?.processObjects == objects { return }
        levelTap?.invalidate()
        do {
            levelTap = try LevelTap(processes: objects)
            levelTapPlayer = shownID
        } catch {
            levelTap = nil
            SupportLog.log("ada", "Dalga ölçülemedi (\(shown.id)): \(error)")
        }
    }
}

/// Site için (deneme kancası): çentiğin çevresindeki ekran bölgesi, Tuno'nun penceresi hariç PNG olarak kaydedilir
/// (~/Library/Logs/Tuno/island-desktop.png).
@MainActor
enum IslandCapture {
    static func desktop() {
        guard let screen = NotchIsland.notchedScreen ?? NSScreen.main else { return }
        let width: CGFloat = 1100, height: CGFloat = 420
        let source = CGRect(x: (screen.frame.width - width) / 2, y: 0, width: width, height: height)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let scale = screen.backingScaleFactor
        // Boş masaüstü: diğer uygulamalar bir anlığına gizlenir, yakalamadan sonra geri açılır.
        NSApp.hideOtherApplications(nil)
        Task {
            defer { NSApp.unhideAllApplications(nil) }
            try? await Task.sleep(for: .seconds(1.5))
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let display = content.displays.first
            else { return }
            let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { $0.owningApplication?.processID == ownPID })
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = source
            configuration.width = Int(width * scale)
            configuration.height = Int(height * scale)
            configuration.showsCursor = false
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            else { SupportLog.log("ada", "Yakalama olmadı"); return }
            let url = SupportLog.folder.appending(path: "island-desktop.png")
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            SupportLog.log("ada", "Yakalandı: \(url.path)")
        }
    }
}

extension Notification.Name {
    /// Ayarlar penceresinde bir sayfayı açar (nesne: `Page`).
    static let tunoOpenPage = Notification.Name("app.tuno.openPage")
}

/// Odak almayan panel: tıklamalar uygulamayı öne getirmez.
private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Etkin olmayan uygulamanın panelinde ilk tıklama da düğmelere ulaşsın.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Animasyonları denemek için: `defaults write app.tuno.mac islandDemo -bool true` ile açılır, sonra
/// "app.tuno.island.demo" dağıtık bildirimi (nesne: airpods, charging, copied, keepawake, airdrop, download,
/// timer, alarm, call, slider) ilgili bildirimi gösterir.
@MainActor
private enum DemoHook {
    private static var observer: NSObjectProtocol?

    static func install(_ island: NotchIsland) {
        guard UserDefaults.standard.bool(forKey: "islandDemo"), observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: .init("app.tuno.island.demo"), object: nil, queue: .main
        ) { [weak island] note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { island.map { run(command, on: $0) } }
        }
    }

    private static func run(_ command: String, on island: NotchIsland) {
        switch command {
        case "airpods": island.demoAirPods()
        case "charging": island.show(.charging(percent: MacBattery().info?.percent ?? 64), for: 3.5)
        case "copied": island.showCopied("Merhaba, bu bir deneme metni.")
        case "keepawake": island.show(.keepAwake(active: true, detail: L("1 saat")), for: 2.2)
        case "airdrop": island.simulateTransfer(airdrop: true)
        case "download": island.simulateTransfer(airdrop: false)
        case "timer": island.startTimer(seconds: 15)
        case "alarm": island.setAlarm(at: Date().addingTimeInterval(8))
        case "call": island.simulateCall()
        case "siri": island.simulateSiri()
        case "watchnc": SiriWatcher.logWindows(for: 90)
        case "capture": IslandCapture.desktop()
        case "slider":
            for player in island.players {
                if let pid = player.runningApp?.processIdentifier {
                    DispatchQueue.global().async { MediaSlider.dump(pid: pid) }
                }
            }
        default: break
        }
    }
}
