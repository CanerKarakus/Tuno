import ServiceManagement
import SwiftUI

struct GeneralView: View {
    @Environment(Mixer.self) private var mixer
    @Environment(Permissions.self) private var permissions
    @Environment(OnboardingModel.self) private var onboarding
    @Environment(Updater.self) private var updater
    @Environment(\.openWindow) private var openWindow
    @AppStorage(PreferenceKey.showMenuBar) private var showMenuBar = true
    @AppStorage(PreferenceKey.maxBoost) private var maxBoost = 1.5
    @AppStorage(CrashReporter.policyKey) private var crashPolicy = CrashReporter.Policy.ask.rawValue
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                Toggle("Girişte başlat", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if let loginError {
                    NoticeRow(symbol: "exclamationmark.triangle.fill", color: .orange, text: loginError)
                }
                Toggle("Menü çubuğunda göster", isOn: $showMenuBar)
            } footer: {
                Text("Menü çubuğu simgesi açıkken pencereyi kapatsanız da ses ayarlarınız çalışmaya devam eder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    Button("İzinleri Göster…") {
                        onboarding.showPermissions()
                        openWindow(id: "onboarding")
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("İzinler")
                        Text(permissions.allGranted ? "Tüm izinler verildi" : "\(permissions.missing.count) izin eksik")
                            .font(.caption)
                            .foregroundStyle(permissions.allGranted ? Color.green : .orange)
                    }
                }
            }

            Section {
                LabeledContent("Sürüm", value: updater.version)
                if updater.isConfigured {
                    Toggle("Güncellemeleri otomatik denetle", isOn: Binding(
                        get: { updater.automaticallyChecks },
                        set: { updater.automaticallyChecks = $0 }))
                    LabeledContent {
                        Button("Şimdi Denetle") { updater.checkForUpdates() }
                            .disabled(!updater.canCheck)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Güncellemeler")
                            if let date = updater.lastCheck {
                                Text("Son denetim: \(date.formatted(.relative(presentation: .named)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    NoticeRow(symbol: "hammer.fill", color: .secondary,
                              text: "Geliştirme sürümü: güncellemeler yalnızca yayın betiğiyle oluşturulan sürümde etkindir.")
                }
            } header: {
                Text("Güncellemeler")
            }

            if updater.isConfigured {
                Section {
                    Picker("Çökme raporları", selection: $crashPolicy) {
                        ForEach(CrashReporter.Policy.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                } header: {
                    Text("Gizlilik")
                } footer: {
                    Text("Güncelleme denetimi yalnızca Tuno sürümünü, macOS sürümünü, Mac modelini ve kurulumları saymak için rastgele bir numarayı anonim olarak gönderir. Çökme raporlarında kişisel dosyalar ve adınız yer almaz.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Uygulama Sesleri") {
                Picker("En yüksek ses düzeyi", selection: $maxBoost) {
                    Text("%100 (yükseltme yok)").tag(1.0)
                    Text("%150").tag(1.5)
                    Text("%200").tag(2.0)
                }
                LabeledContent("Kayıtlı uygulama ayarları") {
                    Button("Tümünü Sıfırla…") { confirmReset = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Tüm uygulama ses ayarları sıfırlansın mı?", isPresented: $confirmReset) {
            Button("Sıfırla", role: .destructive) { mixer.resetAll() }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Girişte başlatma ayarlanamadı: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "geliştirme"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    TunoIcon(size: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tuno").font(.title2.weight(.semibold))
                        Text("Sürüm \(version)").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }
            Section("Tuno ile gelenler") {
                Label("Uygulama başına ses düzeyi ve sessize alma", systemImage: "slider.horizontal.3")
                Label("%200'e kadar ses yükseltme", systemImage: "speaker.wave.3.fill")
                Label("Uygulamaya özel çıkış aygıtı", systemImage: "hifispeaker.2.fill")
                Label("HDMI / DisplayPort için yazılımsal ses", systemImage: "display")
                Label("Sistem geneli 10 bant ekolayzer ve aygıt profilleri", systemImage: "slider.vertical.3")
                Label("Klavye kısayolları ve ses göstergesi", systemImage: "command")
                Label("Mikrofon seviye testi", systemImage: "mic.fill")
                Label("Ses aygıtı öncelik kuralları", systemImage: "list.number")
                Label("Trackpad ve fare için ayrı kaydırma yönü", systemImage: "rectangle.and.hand.point.up.left.fill")
                Label("Yumuşak kaydırma, hızlandırma ve fare tuşları", systemImage: "computermouse.fill")
                Label("Trackpad'de üç parmakla orta tık", systemImage: "hand.tap.fill")
                Label("Harici ekran parlaklığı", systemImage: "sun.max.fill")
                Label("Alt-Tab ve Dock pencere önizlemeleri", systemImage: "rectangle.on.rectangle")
                Label("Pano geçmişi (⌘⇧V)", systemImage: "doc.on.clipboard")
            }
        }
        .formStyle(.grouped)
    }
}
