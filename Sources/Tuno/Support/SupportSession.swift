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
    @ObservationIgnored var onActiveChange: ((Bool) -> Void)?

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
            if version == UpdateDelegate.currentVersion { notice = "Tuno Destek, Tuno'yu \(version) sürümüne geçirdi." }
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
            case .code: "Kod geçersiz ya da süresi dolmuş. Tuno Destek'ten yeni bir kod iste."
            case .rate: "Çok fazla deneme yapıldı. Birkaç dakika sonra yeniden dene."
            case .network: "Sunucuya ulaşılamadı. İnternet bağlantını kontrol et."
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
        setActive(true)
        startLoop()
    }

    /// Kullanıcı Destek sayfasından ya da menü çubuğundan sonlandırdı.
    func end() {
        guard let token else { return }
        finish(notice: "Destek oturumunu sonlandırdın.")
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
                do {
                    let (status, reply) = try await Self.post(["action": "sync", "token": token, "acks": sending], timeout: 8)
                    guard !Task.isCancelled, self.token == token else { return }
                    guard status == 200, reply["status"] as? String == "active" else {
                        self.finish(notice: Self.endNotice(reply["reason"] as? String))
                        return
                    }
                    failures = 0
                    if let remaining = reply["remaining"] as? Int { self.expires = Date().addingTimeInterval(TimeInterval(remaining)) }
                    for command in reply["commands"] as? [[String: Any]] ?? [] { self.handle(command) }
                } catch {
                    self.acks = sending + self.acks
                    failures += 1
                    // Sunucu 20 saniye haber alamayınca oturumu kapatır; burada da aynı sürede bırakılır.
                    if failures >= 15 { self.finish(notice: "Bağlantı koptuğu için destek oturumu kapandı."); return }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private static func endNotice(_ reason: String?) -> String {
        switch reason {
        case "admin": "Tuno Destek oturumu kapattı."
        case "expired": "Destek oturumunun süresi doldu."
        case "timeout": "Bağlantı koptuğu için destek oturumu kapandı."
        case "replaced": "Tuno Destek yeni bir oturum başlattı."
        default: "Destek oturumu kapandı."
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
            notice = "Tuno Destek normal güncellemelere döndürdü."
            ack(id, "done")
        default:
            ack(id, "failed", "Bu Tuno sürümü bu isteği tanımıyor")
        }
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
        busy = "Tuno \(target.version) indiriliyor ve doğrulanıyor…"
        do {
            let staged = try await VersionSwitcher.prepare(target)
            guard isActive, self.token == token else { return }
            busy = "Tuno \(target.version) kuruluyor…"
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
                finish(notice: "Sürüm değiştirilemedi.")
                throw error
            }
        } catch {
            busy = nil
            ack(id, "failed", error.localizedDescription)
            let alert = NSAlert()
            alert.messageText = "Sürüm değiştirilemedi"
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
