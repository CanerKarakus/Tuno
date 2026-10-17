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
            KeyboardHUD.shared.show(symbol: on ? "capslock.fill" : "capslock", title: on ? "Caps Lock Açık" : "Caps Lock Kapalı")
        }
        return false
    }

    private func inputSourceChanged() {
        guard let name = Self.currentSourceName(), name != lastSource else { return }
        lastSource = name
        if isEnabled { KeyboardHUD.shared.show(symbol: "globe", title: name) }
    }

    private static func currentSourceName() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}
