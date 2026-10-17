import AppKit
import ApplicationServices
import Observation

enum PointingDevice: String, CaseIterable, Identifiable {
    case trackpad, mouse
    var id: Self { self }
}

/// Bir aygıt sınıfı için kaydırma tercihleri; `nil` → sistem ayarını izle.
struct ScrollPreferences: Codable, Equatable {
    var verticalNatural: Bool?
    var horizontalNatural: Bool?
}

/// Fare tuşlarına atanabilen işlevler.
enum ButtonAction: String, CaseIterable, Codable, Identifiable {
    case system, back, forward, missionControl, appWindows, showDesktop, previousSpace, nextSpace, middleClick

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "Varsayılan"
        case .back: "Geri"
        case .forward: "İleri"
        case .missionControl: "Mission Control"
        case .appWindows: "Uygulama pencereleri"
        case .showDesktop: "Masaüstünü göster"
        case .previousSpace: "Önceki masaüstü"
        case .nextSpace: "Sonraki masaüstü"
        case .middleClick: "Orta tık"
        }
    }

    /// Ana iş parçacığında çalıştırır.
    @MainActor
    func perform() {
        switch self {
        case .system: break
        case .back: NavigationPerformer.shared.perform(.back)
        case .forward: NavigationPerformer.shared.perform(.forward)
        case .missionControl: Self.openMissionControl([])
        case .appWindows: Self.openMissionControl(["2"])
        case .showDesktop: Self.openMissionControl(["1"])
        case .previousSpace: SyntheticEvent.postKey(0x7B, flags: .maskControl)   // ⌃←
        case .nextSpace: SyntheticEvent.postKey(0x7C, flags: .maskControl)       // ⌃→
        case .middleClick: SyntheticEvent.postMouseButton(2)
        }
    }

    private static func openMissionControl(_ arguments: [String]) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.activates = false
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Applications/Mission Control.app"), configuration: configuration)
    }
}

enum MouseButton: Int64, CaseIterable, Identifiable {
    case middle = 2, back = 3, forward = 4
    var id: Self { self }

    var title: String {
        switch self {
        case .middle: "Orta tuş (tekerlek)"
        case .back: "Yan tuş 4 (geri)"
        case .forward: "Yan tuş 5 (ileri)"
        }
    }
}

/// Fare ve trackpad için kaydırma yönü dışındaki tercihler.
struct PointerPreferences: Codable, Equatable {
    var smoothScrolling = false
    /// 0.5 … 3: bir tekerlek adımında kaydırılan mesafe çarpanı.
    var scrollSpeed: Double = 1
    /// 0 … 1: kaydırmanın ne kadar uzun süre "süzüleceği".
    var scrollSmoothness: Double = 0.5
    var disableAcceleration = false
    /// 0.3 … 3: hızlandırma kapalıyken sabit işaretçi hızı.
    var pointerSpeed: Double = 1
    var buttons: [String: ButtonAction] = [:]
    var trackpadMiddleClick = false

    func action(for button: MouseButton) -> ButtonAction {
        buttons[String(button.rawValue)] ?? .system
    }
}

/// macOS'un tek "Doğal kaydırma" ayarı trackpad ve fareyi birlikte değiştirir.
/// Tuno kaydırma olaylarını yakalayıp kaynağına göre dikey ve/veya yatay ekseni ters
/// çevirerek her aygıt için ayrı yön sağlar. Yatay eksen "sayfalar arasında kaydır"
/// (geri/ileri) hareketinin yönünü de belirler.
@Observable
@MainActor
final class PointerController {
    private(set) var systemNatural = PointerController.readSystemNatural()
    private(set) var preferences: [String: ScrollPreferences]
    private(set) var pointer: PointerPreferences
    private(set) var isTrusted = AXIsProcessTrusted()
    private(set) var isActive = false
    /// Olay yakalama başlatılamadıysa (ör. izin geri alındıysa).
    private(set) var tapFailed = false
    /// Son kaydırmanın algılandığı aygıt (arayüzde canlı gösterilir).
    private(set) var lastDetected: PointingDevice?

    @ObservationIgnored private let state = ScrollTapState()
    @ObservationIgnored private var thread: ScrollTapThread?
    @ObservationIgnored private var trustTimer: Timer?
    @ObservationIgnored private var statusTimer: Timer?
    @ObservationIgnored private let acceleration = PointerAcceleration()

    private static let key = "scrollPreferences"
    private static let pointerKey = "pointerPreferences"
    /// Tuno'nun geçici olarak kapattığı sistem "sayfalar arasında kaydır" ayarlarının özgün değerleri.
    private static let savedSwipeKey = "savedSwipeNavigation"
    private static let swipeKeys: [PointingDevice: String] = [
        .trackpad: "AppleEnableSwipeNavigateWithScrolls",
        .mouse: "AppleEnableMouseSwipeNavigateWithScrolls",
    ]

    init() {
        preferences = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: ScrollPreferences].self, from: $0) } ?? [:]
        pointer = UserDefaults.standard.data(forKey: Self.pointerKey)
            .flatMap { try? JSONDecoder().decode(PointerPreferences.self, from: $0) } ?? PointerPreferences()
        state.onButton = { action in
            DispatchQueue.main.async { MainActor.assumeIsolated { action.perform() } }
        }
        MultitouchMonitor.shared.onMiddleClick = {
            SyntheticEvent.postMouseButton(2)
        }
        state.onNavigate = { direction in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    VolumeHUD.shared.show(
                        symbol: direction == .back ? "chevron.backward.circle.fill" : "chevron.forward.circle.fill",
                        title: direction == .back ? "Geri" : "İleri")
                }
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("SwipeScrollDirectionDidChangeNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSystem() }
        }
        apply()
    }

    // MARK: - Tercihler

    func verticalNatural(_ device: PointingDevice) -> Bool {
        preferences[device.rawValue]?.verticalNatural ?? systemNatural
    }

    func horizontalNatural(_ device: PointingDevice) -> Bool {
        preferences[device.rawValue]?.horizontalNatural ?? systemNatural
    }

    func setVerticalNatural(_ value: Bool, for device: PointingDevice) {
        update(device) { $0.verticalNatural = value }
    }

    func setHorizontalNatural(_ value: Bool, for device: PointingDevice) {
        update(device) { $0.horizontalNatural = value }
    }

    func resetToSystem(_ device: PointingDevice) {
        update(device) { $0 = ScrollPreferences() }
    }

    /// Fare/trackpad tercihlerini değiştirir ve hemen uygular.
    func updatePointer(_ change: (inout PointerPreferences) -> Void) {
        var value = pointer
        change(&value)
        guard value != pointer else { return }
        pointer = value
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: Self.pointerKey) }
        apply()
    }

    func setAction(_ action: ButtonAction, for button: MouseButton) {
        updatePointer { $0.buttons[String(button.rawValue)] = action == .system ? nil : action }
    }

    func isCustomized(_ device: PointingDevice) -> Bool {
        verticalNatural(device) != systemNatural || horizontalNatural(device) != systemNatural
    }

    private func update(_ device: PointingDevice, _ change: (inout ScrollPreferences) -> Void) {
        var value = preferences[device.rawValue] ?? ScrollPreferences()
        change(&value)
        preferences[device.rawValue] = value == ScrollPreferences() ? nil : value
        if let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data, forKey: Self.key) }
        apply()
    }

    func refreshSystem() {
        systemNatural = Self.readSystemNatural()
        isTrusted = AXIsProcessTrusted()
        apply()
    }

    private static func readSystemNatural() -> Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let value = CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication)
        return (value as? Bool) ?? true
    }

    // MARK: - Olay yakalama

    /// Ters çevirme bayraklarını günceller; gerekiyorsa yakalamayı başlatır/durdurur.
    ///
    /// Sayfa geçişi (geri/ileri) yönü olay değerlerini ters çevirerek değiştirilemiyor: macOS
    /// geçişi başlatıp parmak kalkınca ham parmak hızına bakarak iptal ediyor. Bu yüzden ters
    /// seçilen aygıtta sistemin kendi geçişi geçici olarak kapatılır, yatay hareketi Tuno
    /// algılar ve doğru yönde geri/ileri komutu verir. Yatay içerik kaydırmasına dokunulmaz.
    private func apply() {
        state.invertTrackpadVertical = verticalNatural(.trackpad) != systemNatural
        state.invertMouseVertical = verticalNatural(.mouse) != systemNatural
        state.invertTrackpadHorizontal = false
        state.invertMouseHorizontal = false

        var saved = UserDefaults.standard.dictionary(forKey: Self.savedSwipeKey) as? [String: Bool] ?? [:]
        for device in PointingDevice.allCases {
            let key = Self.swipeKeys[device]!
            let reversed = isTrusted && horizontalNatural(device) != systemNatural
            var navigate = false
            if reversed {
                if saved[key] == nil { saved[key] = Self.readGlobalBool(key) ?? true }
                if Self.readGlobalBool(key) != false { Self.writeGlobalBool(key, false) }
                // Kullanıcı sistemde sayfa geçişini zaten kapatmışsa Tuno da yapmaz.
                navigate = saved[key] ?? true
            } else if let original = saved.removeValue(forKey: key) {
                Self.writeGlobalBool(key, original)
            }
            if device == .trackpad { state.navigateTrackpad = navigate } else { state.navigateMouse = navigate }
        }
        UserDefaults.standard.set(saved, forKey: Self.savedSwipeKey)
        state.systemNatural = systemNatural

        // Yumuşak kaydırma ve fare tuşları
        state.smoothScrolling = pointer.smoothScrolling
        state.scrollStep = 48 * pointer.scrollSpeed
        state.scrollTau = 0.05 + 0.2 * pointer.scrollSmoothness
        state.middleAction = pointer.action(for: .middle)
        state.backAction = pointer.action(for: .back)
        state.forwardAction = pointer.action(for: .forward)
        let buttonsMapped = MouseButton.allCases.contains { pointer.action(for: $0) != .system }

        // Trackpad'de üç parmakla dokunma → orta tık
        MultitouchMonitor.shared.middleClickEnabled = isTrusted && pointer.trackpadMiddleClick
        if pointer.trackpadMiddleClick { MultitouchMonitor.shared.scan() }

        // İşaretçi hızlandırması (yalnızca fareler)
        acceleration.apply(disable: pointer.disableAcceleration, speed: pointer.pointerSpeed)

        let needed = state.invertTrackpadVertical || state.invertMouseVertical
            || state.navigateTrackpad || state.navigateMouse || state.smoothScrolling || buttonsMapped
        if needed && isTrusted {
            if thread == nil {
                MultitouchMonitor.shared.scan()
                state.tapStatus = 0
                let thread = ScrollTapThread(state: state)
                thread.start()
                self.thread = thread
                startStatusTimer()
            }
        } else {
            thread?.stop()
            thread = nil
            statusTimer?.invalidate()
            statusTimer = nil
            tapFailed = false
        }
        isActive = thread != nil
    }

    /// Yakalama durumunu ve son algılanan aygıtı arayüze taşır; yeni bağlanan
    /// dokunmatik aygıtları (ör. Magic Mouse) da ara ara tarar. Saniyede bir: arka planda boşuna uyanmasın.
    private func startStatusTimer() {
        statusTimer?.invalidate()
        var ticks = 0
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                ticks += 1
                if self.state.tapStatus == 2 { self.tapFailed = true }
                if self.state.tapStatus == 1 { self.tapFailed = false }
                let detected: PointingDevice? = switch self.state.lastSource {
                case 1: .trackpad
                case 2: .mouse
                default: nil
                }
                if detected != self.lastDetected { self.lastDetected = detected }
                if ticks % 5 == 0 {
                    MultitouchMonitor.shared.scan()
                    self.acceleration.refresh()   // yeni bağlanan farelere de uygula
                }
            }
        }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                if AXIsProcessTrusted() {
                    timer.invalidate()
                    self.refreshSystem()
                }
            }
        }
    }

    func shutdown() {
        thread?.stop()
        thread = nil
        acceleration.restore()
        // Geçici olarak kapatılan sistem sayfa geçişi ayarlarını geri yükle.
        let saved = UserDefaults.standard.dictionary(forKey: Self.savedSwipeKey) as? [String: Bool] ?? [:]
        for (key, value) in saved { Self.writeGlobalBool(key, value) }
        UserDefaults.standard.removeObject(forKey: Self.savedSwipeKey)
    }

    private static func readGlobalBool(_ key: String) -> Bool? {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        return CFPreferencesCopyAppValue(key as CFString, kCFPreferencesAnyApplication) as? Bool
    }

    private static func writeGlobalBool(_ key: String, _ value: Bool) {
        CFPreferencesSetValue(key as CFString, value as CFBoolean, kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}

// MARK: - Gerçek zamanlı kısım (ayrı iş parçacığı)

/// Ana iş parçacığı bayrakları yazar, olay iş parçacığı okur.
final class ScrollTapState: @unchecked Sendable {
    var invertTrackpadVertical = false
    var invertTrackpadHorizontal = false
    var invertMouseVertical = false
    var invertMouseHorizontal = false

    // Yalnızca olay iş parçacığında kullanılır.
    /// Bu aygıtlarda geri/ileri geçişini Tuno yapar.
    var navigateTrackpad = false
    var navigateMouse = false
    var systemNatural = true
    /// Tuno'nun gerçekleştirdiği son geçiş (arayüz geri bildirimi için).
    var onNavigate: (@Sendable (NavigationDirection) -> Void)?
    var onButton: (@Sendable (ButtonAction) -> Void)?

    var smoothScrolling = false
    var scrollStep: Double = 48
    var scrollTau: Double = 0.15
    var middleAction = ButtonAction.system
    var backAction = ButtonAction.system
    var forwardAction = ButtonAction.system
    /// 0: başlıyor, 1: çalışıyor, 2: başlatılamadı.
    var tapStatus = 0
    /// 1: trackpad, 2: fare.
    var lastSource = 0

    fileprivate var tap: CFMachPort?
    fileprivate var gestureIsTrackpad = false
    fileprivate var swipeX: Double = 0
    fileprivate var swipeY: Double = 0
    fileprivate var swipeFired = false

    // Yumuşak kaydırma (olay iş parçacığında)
    fileprivate var pendingX: Double = 0
    fileprivate var pendingY: Double = 0
    fileprivate var carryX: Double = 0
    fileprivate var carryY: Double = 0
    fileprivate var lastTick: CFAbsoluteTime = 0
    fileprivate var smoothTimer: CFRunLoopTimer?

    func action(forButton number: Int64) -> ButtonAction {
        switch number {
        case 2: middleAction
        case 3: backAction
        case 4: forwardAction
        default: .system
        }
    }
}

/// Kaydırma olaylarını ana iş parçacığını meşgul etmeden kendi run loop'unda işler.
private final class ScrollTapThread: Thread, @unchecked Sendable {
    private let state: ScrollTapState
    private var runLoop: CFRunLoop?

    init(state: ScrollTapState) {
        self.state = state
        super.init()
        name = "app.tuno.scroll-tap"
        qualityOfService = .userInteractive
    }

    override func main() {
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: scrollTapCallback,
            userInfo: Unmanaged.passUnretained(state).toOpaque())
        else {
            state.tapStatus = 2
            return
        }
        state.tap = tap
        state.tapStatus = 1
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRun()
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        state.tap = nil
    }

    func stop() {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(runLoop) }
        CFRunLoopWakeUp(runLoop)
    }
}

private func scrollTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let state = Unmanaged<ScrollTapState>.fromOpaque(userInfo).takeUnretainedValue()

    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let tap = state.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)

    case _ where SyntheticEvent.isMarked(event):
        return Unmanaged.passUnretained(event)   // Tuno'nun kendi ürettiği olay

    case .otherMouseDown, .otherMouseUp:
        let action = state.action(forButton: event.getIntegerValueField(.mouseEventButtonNumber))
        guard action != .system else { return Unmanaged.passUnretained(event) }
        if type == .otherMouseDown { state.onButton?(action) }
        return nil

    case .scrollWheel:
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)

        let isTrackpad: Bool
        if !continuous {
            isTrackpad = false                      // tekerlekli fare
        } else if momentum != 0 || ![0, 1, 128].contains(phase) {   // 1: began, 128: mayBegin
            isTrackpad = state.gestureIsTrackpad    // süren hareket / atalet: başlangıçtaki kaynak
        } else {
            // Hareketin başında trackpad yüzeyinde parmak varsa kaynak trackpad'dir;
            // yoksa sürekli kaydırma Magic Mouse'tan gelir.
            isTrackpad = MultitouchMonitor.shared.trackpadIsTouched(at: ProcessInfo.processInfo.systemUptime)
            state.gestureIsTrackpad = isTrackpad
        }
        state.lastSource = isTrackpad ? 1 : 2

        if continuous, momentum == 0, isTrackpad ? state.navigateTrackpad : state.navigateMouse {
            trackNavigationSwipe(state, event: event, phase: phase)
        }

        let vertical = isTrackpad ? state.invertTrackpadVertical : state.invertMouseVertical
        let horizontal = isTrackpad ? state.invertTrackpadHorizontal : state.invertMouseHorizontal
        if vertical { invert(event, .vertical) }
        if horizontal { invert(event, .horizontal) }

        // Tekerlekli farelerde yumuşak kaydırma: adımı yut, süzülerek piksel kaydırmasına çevir.
        if !continuous, state.smoothScrolling {
            state.pendingY += event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) * state.scrollStep
            state.pendingX += event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) * state.scrollStep
            startSmoothScrolling(state)
            return nil
        }
        return Unmanaged.passUnretained(event)

    default:
        return Unmanaged.passUnretained(event)
    }
}

// MARK: - Yumuşak kaydırma

private func startSmoothScrolling(_ state: ScrollTapState) {
    guard state.smoothTimer == nil else { return }
    state.lastTick = CFAbsoluteTimeGetCurrent()
    var context = CFRunLoopTimerContext(
        version: 0, info: Unmanaged.passUnretained(state).toOpaque(), retain: nil, release: nil, copyDescription: nil)
    let timer = CFRunLoopTimerCreate(nil, CFAbsoluteTimeGetCurrent(), 1.0 / 120, 0, 0, smoothScrollTick, &context)
    state.smoothTimer = timer
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
}

/// Kalan mesafenin bir kısmını her karede kaydırır (üstel yavaşlama → doğal süzülme).
private func smoothScrollTick(_ timer: CFRunLoopTimer?, _ info: UnsafeMutableRawPointer?) {
    guard let info else { return }
    let state = Unmanaged<ScrollTapState>.fromOpaque(info).takeUnretainedValue()
    let now = CFAbsoluteTimeGetCurrent()
    let dt = min(now - state.lastTick, 0.05)
    state.lastTick = now
    let factor = 1 - exp(-dt / state.scrollTau)

    let dy = state.pendingY * factor, dx = state.pendingX * factor
    state.pendingY -= dy
    state.pendingX -= dx
    state.carryY += dy
    state.carryX += dx
    let stepY = state.carryY.rounded(.towardZero), stepX = state.carryX.rounded(.towardZero)
    state.carryY -= stepY
    state.carryX -= stepX

    if stepY != 0 || stepX != 0,
       let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                           wheel1: Int32(stepY), wheel2: Int32(stepX), wheel3: 0) {
        SyntheticEvent.mark(event)
        event.post(tap: .cgSessionEventTap)
    }
    if abs(state.pendingY) < 0.5 && abs(state.pendingX) < 0.5 {
        state.pendingX = 0; state.pendingY = 0; state.carryX = 0; state.carryY = 0
        if let timer { CFRunLoopTimerInvalidate(timer) }
        state.smoothTimer = nil
    }
}

/// Yatay bir sayfa geçişi hareketini izler; yeterince uzun ve belirgin yatay olduğunda
/// (parmak kalkmadan) bir kez geri/ileri tetikler.
private func trackNavigationSwipe(_ state: ScrollTapState, event: CGEvent, phase: Int64) {
    switch phase {
    case 1, 128:   // başladı / başlayabilir
        state.swipeX = 0
        state.swipeY = 0
        state.swipeFired = false
    case 2:        // sürüyor
        state.swipeX += Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        state.swipeY += Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        let dx = state.swipeX, dy = state.swipeY
        guard !state.swipeFired, abs(dx) > 80, abs(dx) > 2.5 * abs(dy) else { return }
        state.swipeFired = true
        // Olay değerleri sistemin "doğal" ayarını zaten içerir; parmak yönünü ondan çıkar.
        let fingersRight = state.systemNatural ? dx > 0 : dx < 0
        // Seçilen yön sistemin tersidir: doğal → parmak sağa = geri; klasik → parmak sola = geri.
        let wantsNatural = !state.systemNatural
        let direction: NavigationDirection = (wantsNatural == fingersRight) ? .back : .forward
        NavigationPerformer.shared.perform(direction)
        state.onNavigate?(direction)
    default:       // bitti / iptal
        state.swipeX = 0
        state.swipeY = 0
    }
}

/// Bir eksenin tüm miktar alanlarını ters çevirir: satır, nokta, kesirli ve macOS'un
/// sayfa geçişi (geri/ileri) gibi hareketlerde kullandığı hızlandırılmış/ham değerler.
/// Hepsi tutarlı çevrilmezse sistem hareketi çelişkili bulup iptal eder.
/// Satır alanı yazılınca macOS nokta ve kesir alanlarını ondan yeniden hesapladığı için
/// önce hepsi okunur, sonra özgün değerlerin tersi yazılır.
private struct ScrollAxis {
    let delta: CGEventField
    let point: CGEventField
    let fixed: CGEventField
    let accelerated: CGEventField?
    let raw: CGEventField?

    static let vertical = ScrollAxis(
        delta: .scrollWheelEventDeltaAxis1, point: .scrollWheelEventPointDeltaAxis1,
        fixed: .scrollWheelEventFixedPtDeltaAxis1,
        accelerated: CGEventField(rawValue: 176), raw: CGEventField(rawValue: 178))
    static let horizontal = ScrollAxis(
        delta: .scrollWheelEventDeltaAxis2, point: .scrollWheelEventPointDeltaAxis2,
        fixed: .scrollWheelEventFixedPtDeltaAxis2,
        accelerated: CGEventField(rawValue: 175), raw: CGEventField(rawValue: 177))
}

private func invert(_ event: CGEvent, _ axis: ScrollAxis) {
    let lines = event.getIntegerValueField(axis.delta)
    let points = event.getIntegerValueField(axis.point)
    let precise = event.getDoubleValueField(axis.fixed)
    let accelerated = axis.accelerated.map { event.getDoubleValueField($0) }
    let raw = axis.raw.map { event.getDoubleValueField($0) }

    event.setIntegerValueField(axis.delta, value: -lines)
    event.setIntegerValueField(axis.point, value: -points)
    event.setDoubleValueField(axis.fixed, value: -precise)
    if let field = axis.accelerated, let accelerated { event.setDoubleValueField(field, value: -accelerated) }
    if let field = axis.raw, let raw { event.setDoubleValueField(field, value: -raw) }
}
