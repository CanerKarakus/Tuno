import AppKit
import Carbon.HIToolbox
import Observation

/// Caps Lock açılıp kapanınca ve klavye dili değişince ekranda kısa bir gösterge.
@Observable
@MainActor
final class KeyboardIndicator {
    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    @ObservationIgnored private var capsLockOn = NSEvent.modifierFlags.contains(.capsLock)
    @ObservationIgnored private var lastSource: String?
    private static let enabledKey = "keyboardIndicator"

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey, default: true)
        lastSource = Self.currentSourceName()
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.inputSourceChanged() }
        }
    }

    /// KeyboardTap'ten gelen değiştirici tuş olayları; olayı hiçbir zaman üstlenmez.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard type == .flagsChanged else { return false }
        let on = event.flags.contains(.maskAlphaShift)
        guard on != capsLockOn else { return false }
        capsLockOn = on
        if isEnabled {
            KeyboardHUD.shared.show(symbol: on ? "capslock.fill" : "capslock", title: on ? L("Caps Lock Açık") : L("Caps Lock Kapalı"))
        }
        return false
    }

    private func inputSourceChanged() {
        guard let name = Self.currentSourceName(), name != lastSource else { return }
        lastSource = name
        if isEnabled { KeyboardHUD.shared.show(symbol: "globe", title: name) }
    }

    private static func currentSourceName() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }

        // Keep Apple's ABC layout understandable regardless of the macOS display language.
        if property(kTISPropertyInputSourceID, from: source) == "com.apple.keylayout.ABC" {
            return "English"
        }

        // Show other layouts using their language's own name, not macOS's localized name.
        if let languages = languageCodes(from: source), let language = languages.first {
            let locale = Locale(identifier: language)
            if let name = locale.localizedString(forLanguageCode: language) {
                return name.prefix(1).uppercased() + name.dropFirst()
            }
        }

        return property(kTISPropertyLocalizedName, from: source)
    }

    private static func property(_ key: CFString, from source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func languageCodes(from source: TISInputSource) -> [String]? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return nil }
        return (Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String])
    }
}
