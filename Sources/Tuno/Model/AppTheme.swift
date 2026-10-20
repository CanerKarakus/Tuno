import AppKit
import Observation

/// Uygulamanın görünümü: açık, koyu ya da macOS'a uyan. Seçim `UserDefaults`'ta saklanır ve tüm pencerelere
/// (ayarlar, menü çubuğu paneli, göstergeler) `NSApp.appearance` ile uygulanır. Güncelleme denetimiyle
/// yönetim paneline de gider (dil ile birlikte).
enum AppTheme: String, CaseIterable, Identifiable {
    case light, dark, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: Lc("Açık", "tema")
        case .dark: L("Koyu")
        case .system: L("Otomatik")
        }
    }

    static let key = "appTheme"

    static var chosen: AppTheme? {
        UserDefaults.standard.string(forKey: key).flatMap(AppTheme.init(rawValue:))
    }

    static var current: AppTheme { chosen ?? .system }

    @MainActor
    func apply() {
        switch self {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp.appearance = nil
        }
    }
}

@Observable
@MainActor
final class ThemeStore {
    static let shared = ThemeStore()
    private var revision = 0

    var current: AppTheme {
        _ = revision
        return AppTheme.current
    }

    var isChosen: Bool {
        _ = revision
        return AppTheme.chosen != nil
    }

    func set(_ theme: AppTheme) {
        UserDefaults.standard.set(theme.rawValue, forKey: AppTheme.key)
        theme.apply()
        revision += 1
        NotificationCenter.default.post(name: .tunoAppearanceChoiceChanged, object: nil)
    }
}

extension Notification.Name {
    /// Dil ya da tema seçildi: yönetim paneli bir sonraki güncelleme denetiminde görsün diye kısa süre sonra denetlenir.
    static let tunoAppearanceChoiceChanged = Notification.Name("tunoAppearanceChoiceChanged")
}
