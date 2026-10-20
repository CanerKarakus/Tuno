import ServiceManagement
import SwiftUI

struct GeneralView: View {
    @Environment(LanguageStore.self) private var language
    @Environment(ThemeStore.self) private var theme
    @Environment(Mixer.self) private var mixer
    @Environment(Updater.self) private var updater
    @AppStorage(PreferenceKey.showMenuBar) private var showMenuBar = true
    @AppStorage(PreferenceKey.maxBoost) private var maxBoost = 1.5
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section { PageHeader(page: .general) }
            Section {
                Picker(L("Uygulama dili"), selection: Binding(get: { language.current }, set: { language.set($0) })) {
                    ForEach(AppLanguage.allCases) { Text($0.name).tag($0) }
                }.searchAnchor("Uygulama dili")
            } header: {
                Text(L("Dil"))
            } footer: {
                Text(L("Değişiklik hemen uygulanır."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ThemePicker(selection: Binding(get: { theme.current }, set: { _ in }), cardWidth: 128)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            } header: {
                Text(L("Görünüm"))
            }

            Section {
                Toggle(L("Girişte başlat"), isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin)).searchAnchor("Girişte başlat")
                if let loginError {
                    NoticeRow(symbol: "exclamationmark.triangle.fill", color: .orange, text: loginError)
                }
                Toggle(L("Menü çubuğunda göster"), isOn: $showMenuBar).searchAnchor("Menü çubuğunda göster")
            } footer: {
                Text(L("Pencereyi kapatsanız da ayarlarınız çalışmaya devam eder."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent(L("Sürüm"), value: updater.version)
                if updater.isConfigured {
                    Toggle(L("Güncellemeleri otomatik denetle"), isOn: Binding(
                        get: { updater.automaticallyChecks },
                        set: { updater.automaticallyChecks = $0 })).searchAnchor("Güncellemeleri otomatik denetle")
                    LabeledContent {
                        Button(L("Şimdi Denetle")) { updater.checkForUpdates() }
                            .disabled(!updater.canCheck)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Güncellemeler"))
                            if let date = updater.lastCheck {
                                Text(String(format: L("Son denetim: %@"), date.formatted(.relative(presentation: .named))))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    NoticeRow(symbol: "hammer.fill", color: .secondary,
                              text: L("Geliştirme sürümü: güncellemeler yalnızca yayın betiğiyle oluşturulan sürümde etkindir."))
                }
            } header: {
                Text(L("Güncellemeler"))
            }

            Section(L("Uygulama Sesleri")) {
                Picker(L("En yüksek ses düzeyi"), selection: $maxBoost) {
                    Text(L("%100 (yükseltme yok)")).tag(1.0)
                    Text("%150").tag(1.5)
                    Text("%200").tag(2.0)
                }.searchAnchor("En yüksek ses düzeyi")
                LabeledContent(L("Kayıtlı uygulama ayarları")) {
                    Button(L("Tümünü Sıfırla…")) { confirmReset = true }
                }
            }
            PageFooter()
        }
        .formStyle(.grouped)
        .confirmationDialog(L("Tüm uygulama ses ayarları sıfırlansın mı?"), isPresented: $confirmReset) {
            Button(L("Sıfırla"), role: .destructive) { mixer.resetAll() }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = String(format: L("Girişte başlatma ayarlanamadı: %@"), error.localizedDescription)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
