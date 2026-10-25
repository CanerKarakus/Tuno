import CryptoKit
import Foundation
import LocalAuthentication
import Observation
import Security

/// Kayıtlı bir yüz. Fotoğraf saklanmaz; yalnızca yüz özetleri (512 sayı) tutulur.
struct EnrolledFace: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    let created: Date
    /// Kurulumdaki iki taramadan gelen özetler.
    var templates: [[Float]]
    /// Başarılı tanımalardan öğrenilen son özetler (sakal, gözlük, ışık değişince uyum için).
    var adaptive: [[Float]] = []
    /// Son denemeler (Ayarlar › Yüz Tanıma › … › Benzerlik Geçmişi). Eski kayıtlarda yoktur.
    var history: [FaceAttempt]?
}

/// Bir tanıma denemesi: bu yüze benzerlik ve canlılık.
struct FaceAttempt: Codable, Equatable, Sendable, Identifiable {
    enum Outcome: String, Codable, Sendable { case unlocked, failed, verified }
    var id: Date { date }
    let date: Date
    let score: Float
    let liveness: Float
    let outcome: Outcome
}

/// Eşleştirme için kayıtlı yüzlerin anlık kopyası (kamera kuyruğunda kullanılır).
struct FaceMatcher: Sendable {
    let faces: [EnrolledFace]

    struct Match: Sendable {
        let face: EnrolledFace
        let score: Float
    }

    var isEmpty: Bool { faces.isEmpty }

    /// En iyi eşleşme. Puan: yüzün tüm özetleriyle benzerliklerinden en yüksek üçünün ortalaması.
    func best(_ embedding: [Float]) -> Match? {
        var best: Match?
        for face in faces {
            let scores = (face.templates + face.adaptive).map { FaceEngine.cosine($0, embedding) }.sorted(by: >)
            guard !scores.isEmpty else { continue }
            let top = scores.prefix(3)
            let score = top.reduce(0, +) / Float(top.count)
            if score > (best?.score ?? -1) { best = Match(face: face, score: score) }
        }
        return best
    }
}

/// Kayıtlı yüzler. Diskte AES-GCM ile şifreli durur; anahtar Anahtar Zinciri'ndedir.
@Observable
@MainActor
final class FaceStore {
    static let shared = FaceStore()

    private(set) var faces: [EnrolledFace] = []
    var matcher: FaceMatcher { FaceMatcher(faces: faces) }

    private static let adaptiveLimit = 12
    /// Güncelleme denetimiyle giden tek bilgi (yönetim panelinde kullanan sayısı).
    nonisolated static let inUseKey = "faceInUse"

    private static var fileURL: URL {
        FaceModels.folder.appending(path: "faces.bin")
    }

    private init() { load() }

    func add(name: String, templates: [[Float]]) -> EnrolledFace {
        let face = EnrolledFace(id: UUID(), name: name, created: Date(), templates: templates)
        faces.append(face)
        save()
        SupportLog.log("faceid", "Yüz eklendi (\(templates.count) özet)")
        return face
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = faces.firstIndex(where: { $0.id == id }) else { return }
        faces[index].name = trimmed
        save()
    }

    func remove(_ id: UUID) {
        faces.removeAll { $0.id == id }
        save()
        SupportLog.log("faceid", "Yüz silindi")
    }

    func removeAll() {
        faces = []
        try? FileManager.default.removeItem(at: Self.fileURL)
        refreshInUse()
    }

    func refreshInUse() {
        UserDefaults.standard.set(!faces.isEmpty && FaceModels.shared.isReady, forKey: Self.inUseKey)
    }

    /// Denemeyi yüzün geçmişine ekler (en çok 60).
    func record(_ id: UUID, score: Float, liveness: Float, outcome: FaceAttempt.Outcome) {
        guard let index = faces.firstIndex(where: { $0.id == id }) else { return }
        var history = faces[index].history ?? []
        history.append(FaceAttempt(date: Date(), score: score, liveness: liveness, outcome: outcome))
        if history.count > 60 { history.removeFirst(history.count - 60) }
        faces[index].history = history
        save()
    }

    /// Kesin bir tanımadan sonra özet eklenir (en eskisi çıkar).
    func adapt(_ id: UUID, with embedding: [Float]) {
        guard let index = faces.firstIndex(where: { $0.id == id }) else { return }
        faces[index].adaptive.append(embedding)
        if faces[index].adaptive.count > Self.adaptiveLimit { faces[index].adaptive.removeFirst() }
        save()
    }

    /// Yeni kişi için önerilen ad: ilk yüz Mac kullanıcısının adı, sonrakiler "Yüz 2", "Yüz 3"…
    var suggestedName: String {
        if faces.isEmpty {
            let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
            if !first.isEmpty { return first }
        }
        return String(format: L("Yüz %d"), faces.count + 1)
    }

    // MARK: - Disk

    private func load() {
        guard let sealed = try? Data(contentsOf: Self.fileURL), let key = Keychain.faceKey(create: false),
              let box = try? AES.GCM.SealedBox(combined: sealed), let plain = try? AES.GCM.open(box, using: key),
              let decoded = try? JSONDecoder().decode([EnrolledFace].self, from: plain) else { return }
        faces = decoded
    }

    private func save() {
        guard let key = Keychain.faceKey(create: true), let plain = try? JSONEncoder().encode(faces),
              let sealed = try? AES.GCM.seal(plain, using: key).combined else { return }
        defer { refreshInUse() }
        try? FileManager.default.createDirectory(at: FaceModels.folder, withIntermediateDirectories: true)
        try? sealed.write(to: Self.fileURL, options: .atomic)
    }
}

/// Anahtar Zinciri: yüz verisinin şifreleme anahtarı ve (isteğe bağlı) Mac şifresi.
enum Keychain {
    private static let service = "app.tuno.faceid"

    static func faceKey(create: Bool) -> SymmetricKey? {
        if let data = read("data-key") { return SymmetricKey(data: data) }
        guard create else { return nil }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        return write("data-key", data) ? key : nil
    }

    /// `allowUI`: Anahtar Zinciri gerekirse izin sorabilir (ör. imza değiştiyse). Kilit ekranında soru penceresi
    /// açılamaz; orada `false` verilir ve soru gerekirse sessizce başarısız olur.
    static func read(_ account: String, allowUI: Bool = true) -> Data? {
        let context = LAContext()
        context.interactionNotAllowed = !allowUI
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    static func write(_ account: String, _ data: Data) -> Bool {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Varsa üzerine yazılır (silinemeyen eski bir kayıt yüzünden ekleme başarısız olmasın).
        if SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return true }
        delete(account)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Tuno Face",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Gizli öğelerin diskteki içeriği: yüz verisiyle aynı anahtarla AES-GCM.
enum FaceSecret {
    static func seal(_ data: Data) -> Data? {
        guard let key = Keychain.faceKey(create: true) else { return nil }
        return try? AES.GCM.seal(data, using: key).combined
    }

    static func open(_ data: Data) -> Data? {
        guard let key = Keychain.faceKey(create: false), let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }
}

extension Notification.Name {
    /// Yüz tanıma kaldırıldı: gizli öğeler açılır (anahtar silinmeden önce gönderilir).
    static let tunoFaceIDRemoved = Notification.Name("tunoFaceIDRemoved")
}
