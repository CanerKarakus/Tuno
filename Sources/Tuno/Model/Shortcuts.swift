import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Observation

/// Tuno'nun genel klavye kısayolları.
enum Shortcut: String, CaseIterable, Identifiable {
    case frontVolumeUp, frontVolumeDown, frontMute, toggleEqualizer, nextOutput
    case clipboardHistory, switchWindows, switchWindowsBackward, microphoneMute, keepAwake
    case snapLeft, snapRight, snapMaximize, snapCenter
    case snapTopHalf, snapBottomHalf, snapLeftThird, snapCenterThird, snapRightThird, snapLeftTwoThirds, snapRightTwoThirds

    static let snapping: [Shortcut] = [.snapLeft, .snapRight, .snapMaximize, .snapCenter, .snapTopHalf, .snapBottomHalf,
                                       .snapLeftThird, .snapCenterThird, .snapRightThird, .snapLeftTwoThirds, .snapRightTwoThirds]

    /// Kısayollar sayfasında ayrı satır olarak gösterilenler (geri yönlü geçiş, ileri yönlüyle birlikte açılıp kapanır).
    static var listed: [Shortcut] { allCases.filter { $0 != .switchWindowsBackward } }

    var id: Self { self }

    var title: String {
        switch self {
        case .frontVolumeUp: L("Öndeki uygulamanın sesini aç")
        case .frontVolumeDown: L("Öndeki uygulamanın sesini kıs")
        case .frontMute: L("Öndeki uygulamayı sessize al")
        case .toggleEqualizer: L("Ekolayzeri aç / kapat")
        case .nextOutput: L("Sonraki çıkış aygıtına geç")
        case .clipboardHistory: L("Pano geçmişini göster")
        case .switchWindows: L("Pencereler arasında geçiş (⇧ ile geri, yazarak ara)")
        case .switchWindowsBackward: L("Pencereler arasında geri geçiş")
        case .microphoneMute: L("Mikrofonu sessize al / aç")
        case .keepAwake: L("Uyanık tut (süresiz) / kapat")
        case .snapLeft: L("Pencereyi sol yarıya yerleştir")
        case .snapRight: L("Pencereyi sağ yarıya yerleştir")
        case .snapMaximize: L("Pencereyi ekranı kaplayacak şekilde büyüt")
        case .snapCenter: L("Pencereyi ortala")
        case .snapTopHalf: L("Pencereyi üst yarıya yerleştir")
        case .snapBottomHalf: L("Pencereyi alt yarıya yerleştir")
        case .snapLeftThird: L("Pencereyi sol üçte bire yerleştir")
        case .snapCenterThird: L("Pencereyi orta üçte bire yerleştir")
        case .snapRightThird: L("Pencereyi sağ üçte bire yerleştir")
        case .snapLeftTwoThirds: L("Pencereyi sol üçte ikiye yerleştir")
        case .snapRightTwoThirds: L("Pencereyi sağ üçte ikiye yerleştir")
        }
    }

    var keys: [String] {
        switch self {
        case .frontVolumeUp: ["⌃", "⌥", "↑"]
        case .frontVolumeDown: ["⌃", "⌥", "↓"]
        case .frontMute: ["⌃", "⌥", "M"]
        case .toggleEqualizer: ["⌃", "⌥", "E"]
        case .nextOutput: ["⌃", "⌥", "O"]
        case .clipboardHistory: ["⌘", "⇧", "V"]
        case .switchWindows: ["⌘", "⇥"]
        case .switchWindowsBackward: ["⌘", "⇧", "⇥"]
        case .microphoneMute: ["⌃", "⌥", "⇧", "M"]
        case .keepAwake: ["⌃", "⌥", "⇧", "U"]
        case .snapLeft: ["⌃", "⌥", "⌘", "←"]
        case .snapRight: ["⌃", "⌥", "⌘", "→"]
        case .snapMaximize: ["⌃", "⌥", "⌘", "↑"]
        case .snapCenter: ["⌃", "⌥", "⌘", "↓"]
        case .snapTopHalf: ["⌃", "⌥", "⌘", "⇧", "↑"]
        case .snapBottomHalf: ["⌃", "⌥", "⌘", "⇧", "↓"]
        case .snapLeftThird: ["⌃", "⌥", "⌘", "D"]
        case .snapCenterThird: ["⌃", "⌥", "⌘", "F"]
        case .snapRightThird: ["⌃", "⌥", "⌘", "G"]
        case .snapLeftTwoThirds: ["⌃", "⌥", "⌘", "E"]
        case .snapRightTwoThirds: ["⌃", "⌥", "⌘", "T"]
        }
    }

    fileprivate var modifiers: Int {
        switch self {
        case .clipboardHistory: cmdKey | shiftKey
        case .switchWindows: cmdKey
        case .switchWindowsBackward: cmdKey | shiftKey
        case .microphoneMute, .keepAwake: controlKey | optionKey | shiftKey
        case .snapTopHalf, .snapBottomHalf: controlKey | optionKey | cmdKey | shiftKey
        case _ where Shortcut.snapping.contains(self): controlKey | optionKey | cmdKey
        default: controlKey | optionKey
        }
    }

    fileprivate var keyCode: Int {
        switch self {
        case .frontVolumeUp: kVK_UpArrow
        case .frontVolumeDown: kVK_DownArrow
        case .frontMute: kVK_ANSI_M
        case .toggleEqualizer: kVK_ANSI_E
        case .nextOutput: kVK_ANSI_O
        case .clipboardHistory: kVK_ANSI_V
        case .switchWindows, .switchWindowsBackward: kVK_Tab
        case .microphoneMute: kVK_ANSI_M
        case .keepAwake: kVK_ANSI_U
        case .snapLeft: kVK_LeftArrow
        case .snapRight: kVK_RightArrow
        case .snapMaximize: kVK_UpArrow
        case .snapCenter: kVK_DownArrow
        case .snapTopHalf: kVK_UpArrow
        case .snapBottomHalf: kVK_DownArrow
        case .snapLeftThird: kVK_ANSI_D
        case .snapCenterThird: kVK_ANSI_F
        case .snapRightThird: kVK_ANSI_G
        case .snapLeftTwoThirds: kVK_ANSI_E
        case .snapRightTwoThirds: kVK_ANSI_T
        }
    }

    fileprivate var hotKeyID: UInt32 { UInt32(Self.allCases.firstIndex(of: self)! + 1) }

    var defaultsKey: String {
        "shortcut.\(self == .switchWindowsBackward ? Shortcut.switchWindows.rawValue : rawValue)"
    }
}

/// Global kısayolları (Carbon, izin gerektirmez) ve klavye ses tuşlarını
/// (CGEvent tap, Erişilebilirlik izni gerektirir) yönetir.
@Observable
@MainActor
final class ShortcutCenter {
    private(set) var isAccessibilityTrusted = AXIsProcessTrusted()
    var mediaKeysEnabled: Bool {
        didSet {
            UserDefaults.standard.set(mediaKeysEnabled, forKey: Self.mediaKeysKey)
            updateMediaKeyTap()
        }
    }

    @ObservationIgnored private let mixer: Mixer
    @ObservationIgnored private let devices: DeviceStore
    @ObservationIgnored private let displays: DisplayController
    @ObservationIgnored var onClipboard: (() -> Void)?
    @ObservationIgnored var onMicrophoneMute: (() -> Void)?
    @ObservationIgnored var onKeepAwake: (() -> Void)?
    @ObservationIgnored var onSnap: ((Shortcut) -> Void)?
    @ObservationIgnored private var transient: [UInt32: (ref: EventHotKeyRef, action: () -> Void)] = [:]
    @ObservationIgnored private var nextTransientID: UInt32 = 1000
    @ObservationIgnored private var hotKeys: [Shortcut: EventHotKeyRef] = [:]
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private var eventTap: CFMachPort?
    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var trustTimer: Timer?

    private static let mediaKeysKey = "mediaKeysForSoftwareVolume"
    fileprivate static weak var current: ShortcutCenter?

    init(mixer: Mixer, devices: DeviceStore, displays: DisplayController) {
        self.mixer = mixer
        self.devices = devices
        self.displays = displays
        mediaKeysEnabled = UserDefaults.standard.bool(forKey: Self.mediaKeysKey)
        Self.current = self
        displays.onKeysPreferenceChange = { [weak self] in self?.updateMediaKeyTap() }
        installHotKeyHandler()
        for shortcut in Shortcut.allCases { setEnabled(isEnabled(shortcut), for: shortcut) }
        updateMediaKeyTap()
    }

    // MARK: - Global kısayollar

    /// Açık/kapalı değişince artar; sayfalar (ve destek panelinden gelen değişiklikler) anında yansısın.
    private(set) var revision = 0

    func isEnabled(_ shortcut: Shortcut) -> Bool {
        _ = revision
        return UserDefaults.standard.bool(forKey: shortcut.defaultsKey, default: true)
    }

    func setEnabled(_ enabled: Bool, for shortcut: Shortcut) {
        UserDefaults.standard.set(enabled, forKey: shortcut.defaultsKey)
        revision += 1
        register(shortcut, enabled: enabled)
        if shortcut == .switchWindows { register(.switchWindowsBackward, enabled: enabled) }
    }

    /// Pencere değiştirici Ekran Kaydı izni olmadan çalışmaz; izin yokken ⌘⇥ macOS'ta kalsın.
    func isAvailable(_ shortcut: Shortcut) -> Bool {
        switch shortcut {
        case .switchWindows, .switchWindowsBackward: CGPreflightScreenCaptureAccess() && AXIsProcessTrusted()
        case _ where Shortcut.snapping.contains(shortcut): AXIsProcessTrusted()
        default: true
        }
    }

    /// İzinler değişince kısayolları yeniden kaydet.
    func refreshAvailability() {
        for shortcut in Shortcut.allCases { register(shortcut, enabled: isEnabled(shortcut)) }
        updateMediaKeyTap()
    }

    private func register(_ shortcut: Shortcut, enabled: Bool) {
        if let ref = hotKeys.removeValue(forKey: shortcut) { UnregisterEventHotKey(ref) }
        // ⌘⇥ Carbon ile kaydedilemez; KeyboardTap yakalar, macOS'unki bu sürede kapatılır.
        if shortcut == .switchWindows {
            SystemHotKeys.setCommandTabTakenOver(enabled && isAvailable(shortcut))
            return
        }
        if shortcut == .switchWindowsBackward { return }
        guard enabled, isAvailable(shortcut) else { return }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x54554E4F) /* 'TUNO' */, id: shortcut.hotKeyID)
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode), UInt32(shortcut.modifiers), id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { hotKeys[shortcut] = ref }
    }

    /// Geçici kısayol (ör. pencere değiştirici açıkken ⌥Esc). Dönen kimlikle kaldırılır.
    func registerTransient(keyCode: Int, modifiers: Int, action: @escaping () -> Void) -> UInt32? {
        nextTransientID += 1
        let identifier = nextTransientID
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x54554E4F), id: identifier)
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref) == noErr,
              let ref else { return nil }
        transient[identifier] = (ref, action)
        return identifier
    }

    func unregisterTransient(_ identifier: UInt32) {
        if let entry = transient.removeValue(forKey: identifier) { UnregisterEventHotKey(entry.ref) }
    }

    private func installHotKeyHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            MainActor.assumeIsolated {
                if let shortcut = Shortcut.allCases.first(where: { $0.hotKeyID == id.id }) {
                    ShortcutCenter.current?.perform(shortcut)
                } else {
                    ShortcutCenter.current?.transient[id.id]?.action()
                }
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    func perform(_ shortcut: Shortcut) {
        switch shortcut {
        case .frontVolumeUp, .frontVolumeDown, .frontMute:
            let result = shortcut == .frontMute
                ? mixer.toggleMuteFrontmost()
                : mixer.adjustFrontmost(by: shortcut == .frontVolumeUp ? 0.1 : -0.1)
            if let (app, settings) = result {
                VolumeHUD.shared.show(
                    image: app.icon, title: app.name, value: settings.volume,
                    maximum: Float(max(UserDefaults.standard.double(forKey: PreferenceKey.maxBoost, default: 1.5), 1)),
                    muted: settings.muted)
            } else {
                let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? L("Uygulama")
                VolumeHUD.shared.show(symbol: "speaker.slash", title: String(format: L("%@ ses çalmıyor"), name))
            }
        case .toggleEqualizer:
            mixer.equalizer.isEnabled.toggle()
            VolumeHUD.shared.show(
                symbol: "slider.vertical.3",
                title: mixer.equalizer.isEnabled ? String(format: L("Ekolayzer: %@"), mixer.equalizer.presetName) : L("Ekolayzer kapalı"))
        case .clipboardHistory:
            onClipboard?()
        case .switchWindows, .switchWindowsBackward:
            break   // KeyboardTap ve WindowSwitcher
        case .microphoneMute:
            onMicrophoneMute?()
        case .keepAwake:
            onKeepAwake?()
        case .nextOutput:
            let outputs = devices.outputDevices
            guard !outputs.isEmpty else { return }
            let index = outputs.firstIndex { $0.id == devices.defaultOutputID } ?? -1
            let next = outputs[(index + 1) % outputs.count]
            devices.setDefault(next, scope: .output)
            VolumeHUD.shared.show(symbol: next.symbolName(for: .output), title: next.name)
        default:
            if Shortcut.snapping.contains(shortcut) { onSnap?(shortcut) }
        }
    }

    // MARK: - Klavye ses tuşları (yazılımsal ses için)

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        isAccessibilityTrusted = AXIsProcessTrustedWithOptions(options)
        // İzin Sistem Ayarları'nda verilince fark etmek için kısa süre yokla.
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.isAccessibilityTrusted = AXIsProcessTrusted()
                if self.isAccessibilityTrusted {
                    timer.invalidate()
                    self.updateMediaKeyTap()
                }
            }
        }
    }

    func updateMediaKeyTap() {
        isAccessibilityTrusted = AXIsProcessTrusted()
        if (mediaKeysEnabled || displays.brightnessKeysEnabled) && isAccessibilityTrusted {
            guard eventTap == nil else { return }
            let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: { _, type, event, _ in
                    MainActor.assumeIsolated { ShortcutCenter.current?.handle(type: type, event: event) }
                }, userInfo: nil)
            else { return }
            eventTap = tap
            runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        } else if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
            eventTap = nil
            runLoopSource = nil
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let nsEvent = NSEvent(cgEvent: event), nsEvent.type == .systemDefined, nsEvent.subtype.rawValue == 8
        else { return Unmanaged.passUnretained(event) }

        let keyCode = Int32((nsEvent.data1 & 0xFFFF_0000) >> 16)
        let isDown = ((nsEvent.data1 & 0xFF00) >> 8) == 0xA
        if [NX_KEYTYPE_BRIGHTNESS_UP, NX_KEYTYPE_BRIGHTNESS_DOWN].contains(keyCode) {
            return handleBrightness(event, up: keyCode == NX_KEYTYPE_BRIGHTNESS_UP, isDown: isDown,
                                    fine: nsEvent.modifierFlags.contains([.option, .shift]))
        }
        guard mediaKeysEnabled, mixer.defaultUsesSoftwareVolume,
              [NX_KEYTYPE_SOUND_UP, NX_KEYTYPE_SOUND_DOWN, NX_KEYTYPE_MUTE].contains(keyCode) else {
            return Unmanaged.passUnretained(event)
        }
        if isDown {
            // ⌥⇧ ile ince ayar (macOS'taki gibi çeyrek adım).
            let fine = nsEvent.modifierFlags.contains([.option, .shift])
            let step: Float = fine ? 1 / 64 : 1 / 16
            let value: SoftwareVolume? = switch keyCode {
            case NX_KEYTYPE_SOUND_UP: mixer.adjustDefaultSoftwareVolume(by: step)
            case NX_KEYTYPE_SOUND_DOWN: mixer.adjustDefaultSoftwareVolume(by: -step)
            default: mixer.toggleDefaultSoftwareMute()
            }
            if let value, let device = devices.defaultOutput {
                VolumeHUD.shared.show(
                    symbol: device.symbolName(for: .output), title: device.name,
                    value: value.volume, maximum: 1, muted: value.muted)
            }
        }
        return nil // olayı tüket; macOS "desteklenmiyor" simgesini göstermesin
    }

    /// İmleç harici bir ekrandaysa parlaklık tuşları o ekranı ayarlar; değilse olay sisteme kalır.
    private func handleBrightness(_ event: CGEvent, up: Bool, isDown: Bool, fine: Bool) -> Unmanaged<CGEvent>? {
        guard displays.brightnessKeysEnabled, displays.isExternalUnderCursor else {
            return Unmanaged.passUnretained(event)
        }
        if isDown {
            let step = fine ? 1.0 / 64 : 1.0 / 16
            if let display = displays.adjustDisplayUnderCursor(by: up ? step : -step) {
                VolumeHUD.shared.show(symbol: "sun.max.fill", title: display.name,
                                      value: Float(display.brightness), maximum: 1)
            }
        }
        return nil
    }
}
