import Foundation
import SwiftUI
import Observation

/// Uygulamanın arayüz dili. Seçim `UserDefaults`'ta saklanır; hiç seçilmediyse Mac'in dil tercihinden
/// (desteklenen ilk dil) önerilir, yoksa İngilizce. Metinler `L(_:)` ile çevrilir (Support/Localization.swift).
enum AppLanguage: String, CaseIterable, Identifiable {
    case tr, en, es

    var id: String { rawValue }

    /// Dilin kendi dilindeki adı.
    var name: String {
        switch self {
        case .tr: "Türkçe"
        case .en: "English"
        case .es: "Español"
        }
    }

    static let key = "appLanguage"

    /// Kullanıcının seçtiği dil; hiç seçmediyse nil.
    static var chosen: AppLanguage? {
        UserDefaults.standard.string(forKey: key).flatMap(AppLanguage.init(rawValue:))
    }

    static var isChosen: Bool { chosen != nil }

    /// Mac'in dil tercihleri sırasında ilk desteklenen dil; yoksa İngilizce.
    static var detected: AppLanguage {
        for tag in Locale.preferredLanguages {
            if let language = AppLanguage(rawValue: String(tag.prefix(2)).lowercased()) { return language }
        }
        return .en
    }

    /// Şu an kullanılan dil (seçim, yoksa algılanan).
    static var current: AppLanguage { chosen ?? detected }
}

/// Dil değişince arayüzü yeniden çizdiren gözlemlenebilir kayıt.
@Observable
@MainActor
final class LanguageStore {
    static let shared = LanguageStore()
    private var revision = 0

    var current: AppLanguage {
        _ = revision
        return AppLanguage.current
    }

    /// Seçim yapılmış mı; yapılmadıysa ana pencere dil seçimi katmanıyla kapatılır.
    var isChosen: Bool {
        _ = revision
        return AppLanguage.isChosen
    }

    func set(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: AppLanguage.key)
        revision += 1
        NotificationCenter.default.post(name: .tunoAppearanceChoiceChanged, object: nil)
    }
}

/// Dil değişince içeriği yeniden çizer (menü çubuğu paneli gibi ana pencere dışındaki yüzeyler için).
struct LanguageRefresh<Content: View>: View {
    @Environment(LanguageStore.self) private var language
    @ViewBuilder let content: () -> Content

    var body: some View {
        content().id(language.current)
    }
}
