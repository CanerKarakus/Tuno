import AppKit
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
        let previous = current
        guard previous != language else { return }

        UserDefaults.standard.set(language.rawValue, forKey: AppLanguage.key)
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        UserDefaults.standard.synchronize()

        revision += 1
        NotificationCenter.default.post(name: .tunoAppearanceChoiceChanged, object: nil)

        // SwiftUI content updates live, but the macOS-provided application menu
        // reads the bundle language at launch time.
        let alert = NSAlert()
        alert.messageText = restartTitle(for: language)
        alert.informativeText = restartMessage(for: language)
        alert.addButton(withTitle: restartNowTitle(for: language))
        alert.addButton(withTitle: restartLaterTitle(for: language))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundleURL.path]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            let failure = NSAlert()
            failure.messageText = "Tuno"
            failure.informativeText = error.localizedDescription
            failure.runModal()
        }
    }

    private func restartTitle(for language: AppLanguage) -> String {
        switch language {
        case .en: "Restart Tuno?"
        case .es: "¿Reiniciar Tuno?"
        case .tr: "Tuno yeniden başlatılsın mı?"
        }
    }

    private func restartMessage(for language: AppLanguage) -> String {
        switch language {
        case .en: "The app interface has changed. Restart Tuno to apply the selected language to the macOS menu bar."
        case .es: "La interfaz de la app ha cambiado. Reinicia Tuno para aplicar el idioma seleccionado a la barra de menús de macOS."
        case .tr: "Uygulama arayüzü değişti. Seçilen dili macOS menü çubuğuna uygulamak için Tuno'yu yeniden başlatın."
        }
    }

    private func restartNowTitle(for language: AppLanguage) -> String {
        switch language {
        case .en: "Restart Now"
        case .es: "Reiniciar ahora"
        case .tr: "Şimdi Yeniden Başlat"
        }
    }

    private func restartLaterTitle(for language: AppLanguage) -> String {
        switch language {
        case .en: "Later"
        case .es: "Más tarde"
        case .tr: "Daha Sonra"
        }
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
