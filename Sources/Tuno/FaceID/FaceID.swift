import AppKit
import Observation

/// Yüz tanıma: modeller, kayıtlı yüzler, kurulum ve dört özellik (kilit açma, gizli öğeler, uzaklaşınca kilitle,
/// başkası bakarsa). Her şey Mac'te çalışır; yüz verisi hiçbir yere gönderilmez.
@Observable
@MainActor
final class FaceID {
    static let shared = FaceID()

    let models = FaceModels.shared
    let store = FaceStore.shared
    let unlock = FaceUnlock()
    let presence = FacePresence()
    let guardian = FaceGuard()
    let overlay = FaceOverlayController()

    /// Modeller yüklendi (ilk yükleme birkaç saniye sürer).
    @ObservationIgnored private(set) var engine: FaceEngine?
    private(set) var engineReady = false
    private(set) var enrollment: FaceEnrollment?
    /// Gizli öğeler yüzle açıldı mı (60 sn geçerli).
    private(set) var revealedUntil: Date?
    /// Gizli öğeler için kameraya bakılıyor.
    private(set) var verifying = false

    /// Kayıtlı yüz ve izinlerle her şey hazır.
    var isUsable: Bool { engineReady && !store.faces.isEmpty && FaceCamera.isAuthorized }

    /// İndirme bitince ilk tarama kendiliğinden başlasın (onboarding'den indirildiyse).
    private static let autoEnrollKey = "faceAutoEnroll"
    var autoEnroll: Bool {
        get { UserDefaults.standard.bool(forKey: Self.autoEnrollKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoEnrollKey) }
    }
    /// Onboarding penceresi açıkken otomatik tarama bekler.
    var holdAutoEnroll = false {
        didSet { if !holdAutoEnroll { startAutoEnrollIfNeeded() } }
    }

    // Eşikler (deneme için UserDefaults ile değiştirilebilir).
    static var matchThreshold: Float { threshold("faceMatchThreshold", 0.42) }
    static var unlockThreshold: Float { threshold("faceUnlockThreshold", 0.75) }
    static var livenessThreshold: Float { threshold("faceLivenessThreshold", 0.55) }
    private static func threshold(_ key: String, _ value: Float) -> Float {
        let stored = UserDefaults.standard.float(forKey: key)
        return stored > 0 ? stored : value
    }

    private init() {}

    /// AppDelegate açılışta çağırır.
    func start(keepAwake: KeepAwake, pauseMedia: @escaping () -> Void, privacyChanged: @escaping (Bool) -> Void) {
        models.onReady = { [weak self] in self?.loadEngine() }
        models.resumeIfNeeded()
        unlock.start()
        presence.start(keepAwake: keepAwake, pauseMedia: pauseMedia)
        guardian.onChange = privacyChanged
    }

    private func loadEngine() {
        guard engine == nil else { startAutoEnrollIfNeeded(); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = try? FaceEngine.load()
            Task { @MainActor in
                guard let loaded else {
                    SupportLog.log("faceid", "Modeller yüklenemedi")
                    return
                }
                self.engine = loaded
                self.engineReady = true
                self.store.refreshInUse()
                SupportLog.log("faceid", "Modeller yüklendi")
                self.guardian.refresh()
                self.startAutoEnrollIfNeeded()
            }
        }
    }

    private func startAutoEnrollIfNeeded() {
        guard autoEnroll, !holdAutoEnroll, engineReady, store.faces.isEmpty, enrollment == nil else { return }
        autoEnroll = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.startEnrollment() }
    }

    // MARK: - Kurulum

    func startEnrollment() {
        guard enrollment == nil, let engine else { return }
        Task {
            guard await FaceCamera.requestAccess() else { return }
            let session = FaceEnrollment(engine: engine, name: store.suggestedName)
            session.onFinish = { [weak self] templates, name in
                guard let self else { return }
                if let templates { _ = self.store.add(name: name, templates: templates) }
                self.overlay.hide()
                self.enrollment = nil
                self.guardian.refresh()
            }
            enrollment = session
            overlay.showEnrollment(session)
            session.start()
        }
    }

    // MARK: - Doğrulama (gizli öğeler)

    /// Kameraya en çok 2,5 sn bakar; kayıtlı bir yüz tanınırsa gizli öğeler 60 sn açık kalır.
    func verify() async -> Bool {
        if let revealedUntil, revealedUntil > Date() { return true }
        guard isUsable, let engine, !guardian.strangerPresent else { return false }
        let matcher = store.matcher
        let threshold = Self.matchThreshold
        verifying = true
        defer { verifying = false }
        let matched: Bool = await withCheckedContinuation { continuation in
            let lock = NSLock()
            nonisolated(unsafe) var done = false
            nonisolated(unsafe) var hits = 0
            nonisolated(unsafe) var token: UUID?
            func finish(_ value: Bool) {
                lock.lock(); defer { lock.unlock() }
                guard !done else { return }
                done = true
                FaceCamera.shared.unsubscribe(token)
                continuation.resume(returning: value)
            }
            token = FaceCamera.shared.subscribe(fps: 10) { pixels in
                guard let face = engine.detect(pixels, quality: false).first, face.widthFraction > 0.08,
                      let embedding = engine.embedding(pixels, face),
                      let match = matcher.best(embedding), match.score >= threshold else { return }
                hits += 1
                if hits >= 2 {
                    let live = engine.liveness(pixels, face)
                    Task { @MainActor in FaceStore.shared.record(match.face.id, score: match.score, liveness: live, outcome: .verified) }
                    finish(true)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { finish(false) }
        }
        if matched { revealedUntil = Date().addingTimeInterval(60) }
        return matched
    }

    /// Gizli öğeleri yeniden kilitle (panel kapanınca, biri bakınca).
    func relock() { revealedUntil = nil }

    var isRevealed: Bool { (revealedUntil ?? .distantPast) > Date() }

    // MARK: - Kaldırma

    /// Modeller, kayıtlı yüzler ve Mac şifresi silinir; özellikler kapanır.
    func removeEverything() {
        NotificationCenter.default.post(name: .tunoFaceIDRemoved, object: nil)
        enrollment?.cancel()
        unlock.clearPassword()
        unlock.isEnabled = false
        presence.isEnabled = false
        guardian.isEnabled = false
        store.removeAll()
        Keychain.delete("data-key")
        engine = nil
        engineReady = false
        models.remove()
        store.refreshInUse()
        SupportLog.log("faceid", "Yüz tanıma kaldırıldı")
    }
}
