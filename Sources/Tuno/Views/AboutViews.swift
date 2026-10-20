import AppKit
import SwiftUI

/// gettuno.info bağlantıları; Türkçe ve İspanyolca sayfalar dil önekiyle açılır.
enum Site {
    static let email = "tuno@geidostudio.com"

    static func url(_ path: String = "/") -> URL {
        let prefix = AppLanguage.current == .en ? "" : "/\(AppLanguage.current.rawValue)"
        return URL(string: "https://gettuno.info\(prefix)\(path)")!
    }
}

/// Her sayfanın en altındaki site bağlantısı.
struct PageFooter: View {
    var body: some View {
        Section {
            EmptyView()
        } footer: {
            Link("gettuno.info", destination: Site.url())
                .font(.footnote)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
    }
}

/// Dışarı açılan bağlantı satırı.
struct LinkRow: View {
    let title: String
    let symbol: String
    let url: URL
    var value: String?

    var body: some View {
        Link(destination: url) {
            HStack {
                Label(title, systemImage: symbol).foregroundStyle(.primary)
                Spacer()
                if let value { Text(value).foregroundStyle(.secondary) }
                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

struct PrivacyView: View {
    @Environment(Permissions.self) private var permissions
    @Environment(Updater.self) private var updater
    @AppStorage(CrashReporter.policyKey) private var crashPolicy = CrashReporter.Policy.ask.rawValue

    /// Aramadaki anahtar (Türkçe başlık).
    private func anchor(_ kind: PermissionKind) -> String {
        switch kind {
        case .audioCapture: "Sistem Sesi Kaydı"
        case .microphone: "Mikrofon"
        case .accessibility: "Erişilebilirlik"
        case .screenRecording: "Ekran Kaydı"
        }
    }

    var body: some View {
        Form {
            Section { PageHeader(page: .privacy) }

            Section {
                ForEach(PermissionKind.allCases) { kind in
                    LabeledContent {
                        if permissions.status(kind) == .granted {
                            Label(L("Verildi"), systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Button(L("İzin Ver")) { Task { await permissions.request(kind) } }
                        }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.title)
                                Text(kind.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: kind.symbol).foregroundStyle(.tint)
                        }
                    }
                    .searchAnchor(anchor(kind))
                }
                if permissions.screenRecordingNeedsRestart {
                    LabeledContent(L("Ekran Kaydı için Tuno yeniden başlatılmalı.")) {
                        Button(L("Yeniden Başlat")) { permissions.relaunch() }
                    }
                }
            } header: {
                Text(L("İzinler"))
            } footer: {
                Text(L("İzinler yalnızca bu Mac'te kullanılır; Sistem Ayarları › Gizlilik ve Güvenlik'ten değiştirebilirsiniz."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if updater.isConfigured {
                    Picker(L("Çökme raporları"), selection: $crashPolicy) {
                        ForEach(CrashReporter.Policy.allCases) { Text($0.title).tag($0.rawValue) }
                    }.searchAnchor("Çökme raporları")
                }
                LinkRow(title: L("Gizlilik Politikası"), symbol: "hand.raised", url: Site.url("/privacy/"))
            } header: {
                Text(L("Paylaşılan Veriler"))
            } footer: {
                Text(L("Güncelleme denetimi yalnızca sürüm, Mac modeli, dil, görünüm ve anonim bir numara gönderir."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            PageFooter()
        }
        .formStyle(.grouped)
    }
}

struct AboutView: View {
    private enum SendState { case idle, sending, sent, failed }

    @State private var message = ""
    @State private var email = ""
    @State private var state = SendState.idle

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L("geliştirme")
    }

    private var canSend: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state != .sending
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    TunoIcon(size: 72)
                    Text("Tuno").font(.title.weight(.bold))
                    Text(String(format: L("Sürüm %@"), version)).foregroundStyle(.secondary)
                    Text(L("Tuno, Mac'i daha kullanışlı hale getirmek için geliştirilen ücretsiz ve açık kaynaklı bir uygulamadır. Caner Karakuş tarafından Geido Studio çatısı altında geliştirilir."))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 440)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }

            Section(L("Bağlantılar")) {
                LinkRow(title: L("Web Sitesi"), symbol: "globe", url: Site.url())
                LinkRow(title: L("Destek"), symbol: "lifepreserver", url: Site.url("/support/"))
                LinkRow(title: L("Sürüm Notları"), symbol: "sparkles", url: Site.url("/releases/"))
                LinkRow(title: L("Gizlilik Politikası"), symbol: "hand.raised", url: Site.url("/privacy/"))
                LinkRow(title: L("E-posta"), symbol: "envelope", url: URL(string: "mailto:\(Site.email)")!, value: Site.email)
            }

            Section {
                TextEditor(text: $message)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 110)
                    .overlay(alignment: .topLeading) {
                        if message.isEmpty {
                            Text(L("Öneri, hata ya da düşünceleriniz…"))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .onChange(of: message) { if state != .sending { state = .idle } }
                    .searchAnchor("Geri Bildirim Gönder")
                TextField(L("E-posta (isteğe bağlı)"), text: $email)
                    .textContentType(.emailAddress)
                HStack {
                    switch state {
                    case .sent: Label(L("Teşekkürler, mesajınız bize ulaştı."), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed: Label(L("Gönderilemedi. İnternet bağlantınızı denetleyip yeniden deneyin."), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    default: EmptyView()
                    }
                    Spacer()
                    if state == .sending { ProgressView().controlSize(.small) }
                    Button(L("Gönder"), action: send)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSend)
                }
                .font(.callout)
            } header: {
                Text(L("Geri Bildirim Gönder"))
            } footer: {
                Text(L("Mesajınızla birlikte Tuno Kullanıcı ID'niz, Tuno ve macOS sürümü ve Mac modeli gönderilir. Yanıt almak isterseniz e-posta adresinizi yazın."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                EmptyView()
            } footer: {
                Text("© 2026 Geido Studio").font(.footnote).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
            }
            PageFooter()
        }
        .formStyle(.grouped)
    }

    private func send() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        state = .sending
        Task {
            let ok = await Feedback.send(message: text, email: email.trimmingCharacters(in: .whitespaces))
            state = ok ? .sent : .failed
            if ok { message = "" }
        }
    }
}

/// Geri bildirim yönetim panelinin Mesajlar bölümüne gider; Mac'i tanımak için Tuno Kullanıcı ID'si ve sürüm bilgisi eklenir.
enum Feedback {
    private static let endpoint = URL(string: "https://gettuno.info/feedback.php")!

    static func send(message: String, email: String) async -> Bool {
        let body: [String: String] = [
            "message": message,
            "email": email,
            "sid": SupportID.value,
            "version": UpdateDelegate.currentVersion,
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
            "os": SystemInfo.osVersion,
            "model": SystemInfo.model,
            "lang": AppLanguage.current.rawValue,
            "theme": AppTheme.current.rawValue,
        ]
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, response) = try? await URLSession(configuration: .ephemeral).data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
