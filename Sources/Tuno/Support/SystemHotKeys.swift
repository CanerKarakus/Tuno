import Foundation

/// macOS'un kendi ⌘⇥ uygulama değiştiricisi. Pencere sunucusu bu kısayolu olay yakalayıcılardan
/// önce işlediği için Tuno'nun değiştiricisi açıkken sistemdeki kapatılır, Tuno kapanınca açılır.
/// Ayar oturum boyunca kalıcı: Tuno çökerse bir sonraki açılışta `restore()` geri alır.
@MainActor
enum SystemHotKeys {
    private typealias SetEnabled = @convention(c) (Int32, Bool) -> Int32
    private static let setEnabled = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSSetSymbolicHotKeyEnabled")
        .map { unsafeBitCast($0, to: SetEnabled.self) }
    /// ⌘⇥ ve ⌘⇧⇥.
    private static let commandTab: [Int32] = [1, 2]
    private static let disabledKey = "systemCommandTabDisabled"

    static func setCommandTabTakenOver(_ takenOver: Bool) {
        guard let setEnabled else { return }
        commandTab.forEach { _ = setEnabled($0, !takenOver) }
        UserDefaults.standard.set(takenOver, forKey: disabledKey)
    }

    static func restore() {
        guard UserDefaults.standard.bool(forKey: disabledKey) else { return }
        setCommandTabTakenOver(false)
    }
}
