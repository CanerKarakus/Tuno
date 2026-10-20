import AppKit
import CryptoKit
import Foundation
import Observation

/// Tuno Kullanıcı ID'si: destek ekibine iletilen kısa numara (K7Q-2M9-XDR gibi). Rastgele kurulum numarasından
/// tek yönlü türetilir; güncellemelerde değişmez. Yönetim panelindeki `support_id()` ile aynı hesap.
enum SupportID {
    static let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
    /// Destek kodu tüm harf ve rakamlardan oluşur (yönetim panelindeki SUPPORT_CODE_ALPHABET).
    static let codeCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    static var value: String { make(from: InstallID.value) }

    static func make(from install: String) -> String {
        let digest = Array(SHA256.hash(data: Data("tuno-support-id|\(install)".utf8)))
        let bits = digest.prefix(6).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }   // ilk 48 bit, kullanılan 45
        let characters = (0..<9).map { alphabet[Int(bits >> UInt64(43 - 5 * $0) & 31)] }
        let text = String(characters)
        return [text.prefix(3), text.dropFirst(3).prefix(3), text.suffix(3)].joined(separator: "-")
    }
}

/// Destekle eski bir sürüme geçen Mac o sürümde tutulur; Sparkle güncelleme önermez (UpdateDelegate).
/// Kullanıcı Destek sayfasından ya da destek ekibi panelden kaldırınca normal güncellemelere dönülür.
enum SupportPin {
    private static let key = "supportPinnedVersion"
    /// Bir sonraki açılışta "Tuno Destek, Tuno'yu … sürümüne geçirdi" bilgisi için.
    static let switchedKey = "supportSwitchedVersion"

    static var version: String? { UserDefaults.standard.string(forKey: key) }
    static func set(_ version: String?) { UserDefaults.standard.set(version, forKey: key) }
}

/// Destek modu: kullanıcı, destek ekibinin panelde ürettiği 6 haneli kodu yazıp onaylayınca 30 dakikalık bir
/// oturum açılır. Oturum boyunca Tuno saniyede bir sunucuyla haberleşir ve gelen istekleri (ör. sürüm değiştirme)
/// önce kullanıcıya sorar. Kullanıcı sonlandırınca, panelden kapatılınca, süre dolunca ya da Tuno kapanınca biter;
/// 20 saniye haber alamayan sunucu oturumu kendisi kapatır.
@Observable
@MainActor
final class SupportSession {
    private(set) var isActive = false
    private(set) var expires: Date?
    /// Sürüm indirilirken gösterilen kısa durum.
    private(set) var busy: String?
    /// Son oturumun nasıl bittiği ya da destekle yapılan son değişiklik.
    private(set) var notice: String?
    private(set) var pinnedVersion = SupportPin.version
    /// Bu oturumda destek ekibinin yaptıkları (Destek sayfasında listelenir).
    private(set) var activity: [String] = []
    private(set) var verboseUntil = SupportLog.verboseUntil
    @ObservationIgnored var onActiveChange: ((Bool) -> Void)?
    /// Ayarları okumak ve değiştirmek için (AppDelegate açılışta bağlar).
    @ObservationIgnored weak var app: AppDelegate?
    @ObservationIgnored private var sentState: String?

    @ObservationIgnored private let updater: Updater
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var acks: [[String: Any]] = []
    @ObservationIgnored private var handled = Set<Int>()

    private static let endpoint = URL(string: "https://gettuno.info/support-session.php")!
    private static let session = URLSession(configuration: .ephemeral)

    init(updater: Updater) {
        self.updater = updater
        if let version = UserDefaults.standard.string(forKey: SupportPin.switchedKey) {
            UserDefaults.standard.removeObject(forKey: SupportPin.switchedKey)
            if version == UpdateDelegate.currentVersion { notice = String(format: L("Tuno Destek, Tuno'yu %@ sürümüne geçirdi."), version) }
        }
        // Sabitlenen sürümden elle başka bir sürüme geçildiyse sabitleme kalkar.
        if let pinned = pinnedVersion, pinned != UpdateDelegate.currentVersion { unpin() }
    }

    var remaining: TimeInterval { max(0, expires?.timeIntervalSinceNow ?? 0) }

    // MARK: - Oturum

    enum JoinError: LocalizedError {
        case code, rate, network
        var errorDescription: String? {
            switch self {
            case .code: L("Kod geçersiz ya da süresi dolmuş. Tuno Destek'ten yeni bir kod iste.")
            case .rate: L("Çok fazla deneme yapıldı. Birkaç dakika sonra yeniden dene.")
            case .network: L("Sunucuya ulaşılamadı. İnternet bağlantını kontrol et.")
            }
        }
    }

    func join(code: String) async throws {
        guard !isActive else { return }
        let body: [String: Any] = [
            "action": "join", "id": InstallID.value, "code": code,
            "version": UpdateDelegate.currentVersion, "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0",
            "os": SystemInfo.osVersion, "model": SystemInfo.model, "arch": SystemInfo.architecture,
        ]
        let (status, reply): (Int, [String: Any])
        do { (status, reply) = try await Self.post(body, timeout: 15) } catch { throw JoinError.network }
        guard status == 200, let token = reply["token"] as? String, token.count == 64 else {
            throw status == 429 ? JoinError.rate : status >= 500 ? JoinError.network : JoinError.code
        }
        self.token = token
        expires = Date().addingTimeInterval(TimeInterval(reply["remaining"] as? Int ?? 1800))
        notice = nil
        handled = []
        acks = []
        activity = []
        sentState = nil
        SupportLog.log("destek", "Destek oturumu açıldı")
        setActive(true)
        startLoop()
    }

    /// Kullanıcı Destek sayfasından ya da menü çubuğundan sonlandırdı.
    func end() {
        guard let token else { return }
        finish(notice: L("Destek oturumunu sonlandırdın."))
        Task { _ = try? await Self.post(["action": "end", "token": token, "reason": "user"], timeout: 8) }
    }

    /// Tuno kapanıyor: sunucuya hemen haber verilir (en fazla 2 saniye beklenir).
    func endForQuit() {
        guard let token else { return }
        self.token = nil
        loop?.cancel()
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 2)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["action": "end", "token": token, "reason": "quit"])
        let done = DispatchSemaphore(value: 0)
        Self.session.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 2)
    }

    func stopVerbose() {
        SupportLog.setVerbose(false)
        verboseUntil = nil
    }

    func unpin() {
        SupportPin.set(nil)
        pinnedVersion = nil
        updater.checkInBackground()
    }

    private func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        onActiveChange?(active)
    }

    private func finish(notice: String) {
        if token != nil { SupportLog.log("destek", "Destek oturumu kapandı: \(notice)") }
        token = nil
        loop?.cancel()
        loop = nil
        expires = nil
        busy = nil
        self.notice = notice
        setActive(false)
    }

    private func startLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self, let token = self.token else { return }
                let sending = self.acks
                self.acks = []
                // Ayarlar yalnızca değiştiyse gönderilir (panel canlı görünümü bundan çizer).
                var body: [String: Any] = ["action": "sync", "token": token, "acks": sending]
                let state = self.stateJSON()
                if let state, state.text != self.sentState { body["state"] = state.object }
                do {
                    let (status, reply) = try await Self.post(body, timeout: 8)
                    guard !Task.isCancelled, self.token == token else { return }
                    guard status == 200, reply["status"] as? String == "active" else {
                        self.finish(notice: Self.endNotice(reply["reason"] as? String))
                        return
                    }
                    failures = 0
                    if let state, body["state"] != nil { self.sentState = state.text }
                    if let remaining = reply["remaining"] as? Int { self.expires = Date().addingTimeInterval(TimeInterval(remaining)) }
                    for command in reply["commands"] as? [[String: Any]] ?? [] { self.handle(command) }
                } catch {
                    self.acks = sending + self.acks
                    failures += 1
                    // Sunucu 20 saniye haber alamayınca oturumu kapatır; burada da aynı sürede bırakılır.
                    if failures >= 15 { self.finish(notice: L("Bağlantı koptuğu için destek oturumu kapandı.")); return }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private static func endNotice(_ reason: String?) -> String {
        switch reason {
        case "admin": L("Tuno Destek oturumu kapattı.")
        case "expired": L("Destek oturumunun süresi doldu.")
        case "timeout": L("Bağlantı koptuğu için destek oturumu kapandı.")
        case "replaced": L("Tuno Destek yeni bir oturum başlattı.")
        default: L("Destek oturumu kapandı.")
        }
    }

    // MARK: - İstekler

    private func ack(_ id: Int, _ status: String, _ result: String = "") {
        acks.append(["id": id, "status": status, "result": result])
    }

    private func handle(_ command: [String: Any]) {
        guard let id = command["id"] as? Int, handled.insert(id).inserted else { return }
        let payload = command["payload"] as? [String: Any] ?? [:]
        switch command["kind"] as? String {
        case "version":
            Task { await switchVersion(id: id, payload: payload) }
        case "unpin":
            unpin()
            record(L("Normal güncellemelere döndürüldü"))
            ack(id, "done")
        case "set":
            guard let app, let key = payload["key"] as? String, let value = payload["value"] else { ack(id, "failed", "Geçersiz istek"); return }
            do {
                let change = try SupportSettings(app: app).apply(key: key, value: value)
                record(change)
                ack(id, "done", change)
            } catch {
                ack(id, "failed", error.localizedDescription)
            }
        case "diagnostics":
            Task { await sendDiagnostics(id: id) }
        case "verbose":
            let on = payload["on"] as? Bool ?? false
            SupportLog.setVerbose(on)
            verboseUntil = SupportLog.verboseUntil
            record(on ? L("Ayrıntılı günlük açıldı (24 saat)") : L("Ayrıntılı günlük kapatıldı"))
            ack(id, "done")
        case "message":
            guard let text = payload["text"] as? String, !text.isEmpty else { ack(id, "failed", "Boş mesaj"); return }
            record(String(format: L("Mesaj: %@"), text))
            ack(id, "done", "Gösterildi")
            Task { Self.showMessage(String(text.prefix(500))) }
        case "reset", "restore":
            Task { await restoreSettings(id: id, backup: command["kind"] as? String == "restore" ? payload["id"] as? String : nil) }
        default:
            ack(id, "failed", "Bu Tuno sürümü bu isteği tanımıyor")
        }
    }

    private func record(_ text: String) {
        activity.insert("\(Date().formatted(date: .omitted, time: .shortened)) · \(text)", at: 0)
        SupportLog.log("destek", text)
    }

    /// Panelin canlı görünümü için ayarlar; değişiklik denetimi metin üzerinden yapılır.
    private func stateJSON() -> (object: [String: Any], text: String)? {
        guard let app else { return nil }
        let object: [String: Any] = [
            "pages": SupportSettings(app: app).json(),
            "verbose": SupportLog.verboseUntil.map { Int($0.timeIntervalSince1970) } as Any,
            "pinned": SupportPin.version as Any,
            "backups": SettingsBackup.list().map { ["id": $0.id, "date": Int($0.date.timeIntervalSince1970), "reason": $0.reason] },
            "version": UpdateDelegate.currentVersion,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return (object, text)
    }

    private func sendDiagnostics(id: Int) async {
        guard let app, Diagnostics.confirm() else { ack(id, "declined"); return }
        guard isActive, let token else { return }
        ack(id, "running")
        let package = Diagnostics.build(app: app)
        do {
            let (status, _) = try await Self.post(["action": "upload", "token": token, "command": id, "kind": "diagnostics", "data": package], timeout: 60)
            guard status == 200 else { throw URLError(.badServerResponse) }
            record(L("Tanılama paketi gönderildi"))
            ack(id, "done", "Paket alındı")
        } catch {
            ack(id, "failed", "Paket gönderilemedi")
        }
    }

    private func restoreSettings(id: Int, backup: String?) async {
        let alert = NSAlert()
        if let backup, let item = SettingsBackup.list().first(where: { $0.id == backup }) {
            alert.messageText = L("Tuno Destek ayarlarını bir yedeğe döndürmek istiyor")
            alert.informativeText = String(format: L("Ayarların %@ tarihindeki haline döner (%@). "), item.date.formatted(date: .long, time: .shortened), item.reason)
                + L("Şu anki ayarların önce yedeklenir. Tuno kapanıp yeniden açılır.")
        } else if backup != nil {
            ack(id, "failed", "Yedek bulunamadı")
            return
        } else {
            alert.messageText = L("Tuno Destek ayarlarını sıfırlamak istiyor")
            alert.informativeText = L("Tuno'nun tüm ayarları varsayılana döner. Şu anki ayarların önce yedeklenir; istersen sonra geri dönebilirsin. ")
                + L("Pano geçmişin silinmez. Tuno kapanıp yeniden açılır.")
        }
        alert.addButton(withTitle: L("Onayla"))
        alert.addButton(withTitle: L("Vazgeç"))
        alert.icon = NSApp.applicationIconImage
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { ack(id, "declined"); return }
        guard isActive, let token else { return }
        ack(id, "done", "Tuno yeniden açılıyor")
        let pending = acks
        acks = []
        _ = try? await Self.post(["action": "sync", "token": token, "acks": pending], timeout: 5)
        _ = try? await Self.post(["action": "end", "token": token, "reason": "update"], timeout: 5)
        self.token = nil
        loop?.cancel()
        SupportLog.log("destek", backup == nil ? "Ayarlar sıfırlandı" : "Ayarlar yedeğe döndürüldü: \(backup!)")
        do {
            if let backup { try SettingsBackup.restoreAndRelaunch(backup) } else { try SettingsBackup.resetAndRelaunch() }
        } catch {
            finish(notice: L("Ayarlar değiştirilemedi."))
        }
    }

    private static func showMessage(_ text: String) {
        let alert = NSAlert()
        alert.messageText = L("Tuno Destek'ten mesaj")
        alert.informativeText = text
        alert.icon = NSApp.applicationIconImage
        NSApp.activate()
        alert.runModal()
    }

    private func switchVersion(id: Int, payload: [String: Any]) async {
        let target: VersionSwitcher.Target
        do { target = try VersionSwitcher.Target(payload) } catch {
            ack(id, "failed", error.localizedDescription)
            return
        }
        guard VersionSwitcher.confirm(target) else { ack(id, "declined"); return }
        // Kullanıcı düşünürken oturum kapanmış olabilir.
        guard isActive, let token else { return }
        ack(id, "running")
        busy = String(format: L("Tuno %@ indiriliyor ve doğrulanıyor…"), target.version)
        do {
            let staged = try await VersionSwitcher.prepare(target)
            guard isActive, self.token == token else { return }
            busy = String(format: L("Tuno %@ kuruluyor…"), target.version)
            ack(id, "done", "Tuno yeniden açılıyor")
            let pending = acks
            acks = []
            _ = try? await Self.post(["action": "sync", "token": token, "acks": pending], timeout: 5)
            _ = try? await Self.post(["action": "end", "token": token, "reason": "update"], timeout: 5)
            self.token = nil
            loop?.cancel()
            let previousPin = SupportPin.version
            SupportPin.set(target.pin ? target.version : nil)
            UserDefaults.standard.set(target.version, forKey: SupportPin.switchedKey)
            do { try VersionSwitcher.relaunch(with: staged) } catch {
                SupportPin.set(previousPin)
                UserDefaults.standard.removeObject(forKey: SupportPin.switchedKey)
                finish(notice: L("Sürüm değiştirilemedi."))
                throw error
            }
        } catch {
            busy = nil
            ack(id, "failed", error.localizedDescription)
            let alert = NSAlert()
            alert.messageText = L("Sürüm değiştirilemedi")
            alert.informativeText = error.localizedDescription
            NSApp.activate()
            alert.runModal()
        }
    }

    private static func post(_ body: [String: Any], timeout: TimeInterval) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }
}
