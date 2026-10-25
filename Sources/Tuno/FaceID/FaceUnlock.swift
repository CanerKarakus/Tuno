import AppKit
import CoreGraphics
import IOKit.pwr_mgt
import OpenDirectory
import Observation
import QuartzCore

/// Mac'in kilidini yüzle açma. Kilitlenince kamera sessizce izler; ekrana bakan biri görülünce çentikten
/// tarama yapılır; kayıtlı yüz ve canlılık doğrulanınca Anahtar Zinciri'ndeki Mac şifresi kilit ekranına yazılır.
/// Touch ID her zamanki gibi çalışmaya devam eder. 5 başarısız taramadan sonra Mac bir kez başka yolla açılmadan
/// yüzle açılmaz. Mac yeniden başlatıldıktan sonraki ilk giriş her zaman şifre ister (Tuno o sırada çalışmıyor).
@Observable
@MainActor
final class FaceUnlock {
    enum ScanState: Equatable { case scanning, success, failure, locked }

    private static let enabledKey = "faceUnlockEnabled"
    private static let passwordAccount = "mac-password"
    private static let passwordSetKey = "faceUnlockPasswordSet"
    private static let invalidKey = "faceUnlockPasswordInvalid"
    private static let maxFailures = 5

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }
    private(set) var hasPassword: Bool
    /// Yazılan şifre kilidi açmadı (Mac şifresi değişmiş olabilir): yeniden girilene kadar kapalı.
    private(set) var passwordInvalid: Bool

    private(set) var scanState: ScanState?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var scanning = false
    /// Şifre yazılıyor: kendi tuş olaylarımız yeni bir taramayı tetiklemesin.
    @ObservationIgnored private var unlocking = false
    @ObservationIgnored private var lastScanEnd: CFTimeInterval = 0
    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private var subscription: UUID?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Taramanın neden başlamadığı (her kilitte bir kez günlüğe yazılır).
    @ObservationIgnored private var blockedReason: String?

    init() {
        hasPassword = UserDefaults.standard.bool(forKey: Self.passwordSetKey)
        passwordInvalid = UserDefaults.standard.bool(forKey: Self.invalidKey)
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    var isActive: Bool { isEnabled && hasPassword && !passwordInvalid }

    // MARK: - Şifre

    /// Mac şifresini doğrular ve Anahtar Zinciri'ne kaydeder.
    func setPassword(_ password: String) -> Bool {
        guard Self.verify(password), Keychain.write(Self.passwordAccount, Data(password.utf8)) else { return false }
        hasPassword = true
        passwordInvalid = false
        UserDefaults.standard.set(true, forKey: Self.passwordSetKey)
        UserDefaults.standard.set(false, forKey: Self.invalidKey)
        SupportLog.log("faceid", "Kilit açma şifresi kaydedildi")
        return true
    }

    func clearPassword() {
        Keychain.delete(Self.passwordAccount)
        hasPassword = false
        UserDefaults.standard.set(false, forKey: Self.passwordSetKey)
    }

    private static func verify(_ password: String) -> Bool {
        guard let node = try? ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication)),
              let record = try? node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
        else { return false }
        return (try? record.verifyPassword(password)) != nil
    }

    // MARK: - Kilit ekranı

    /// Kilitlenince (ya da ekran uyanınca, dokununca) kamera bu süre boyunca sessizce izler.
    private static let watchWindow: CFTimeInterval = 180

    @ObservationIgnored private var watchToken: UUID?
    @ObservationIgnored private var watchUntil: CFTimeInterval = 0
    @ObservationIgnored private var attentiveFrames = 0
    /// Tanınmayan yüz gidip gelmeden (ya da dokunulmadan) yeniden taranmaz.
    @ObservationIgnored private var needFreshFace = false
    @ObservationIgnored private var displayAssertion: IOPMAssertionID = 0

    func start() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.locked() }
        })
        observers.append(center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.unlocked() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // Kilit ekranı yeniden göründü: yüz aranmadan hemen taranır.
            MainActor.assumeIsolated { if SystemLock.isLocked { self?.beginScan() } }
        })
        if SystemLock.isLocked { locked() }
    }

    /// Kilitlenince 1 sn sonra hemen taranır (yüz olmasa da). Kimse yoksa sessizce kapanır ve kamera izlemeye geçer:
    /// ekrana bakan biri görülünce yeniden taranır.
    private func locked() {
        SupportLog.log("faceid", "Ekran kilitlendi")
        blockedReason = nil
        failures = 0
        needFreshFace = false
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, SystemLock.isLocked else { return }
            self.watchUntil = CACurrentMediaTime() + Self.watchWindow
            self.beginScan()
        }
    }

    private func unlocked() {
        unlocking = false
        poll?.invalidate()
        poll = nil
        failures = 0
        stopWatching()
        stopScan()
        releaseDisplay()
        FaceID.shared.overlay.hideLock()
        // Onay işareti kapanana kadar ekranda kalsın (simge yüze geri dönmesin).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, !self.scanning else { return }
            self.scanState = nil
        }
    }

    private func tick() {
        guard SystemLock.isLocked else { unlocked(); return }
        if SystemLock.hardwareIdleSeconds < 0.6, !unlocking {
            needFreshFace = false
            watch(reason: "dokunuldu")
        }
        if watchToken != nil, !scanning, CACurrentMediaTime() > watchUntil {
            stopWatching()
            SupportLog.log("faceid", "İzleme bitti (kimse bakmadı)")
        }
    }

    /// Hazır değilse nedenini (kilit başına bir kez) günlüğe yazar.
    private func readyEngine() -> FaceEngine? {
        let faceID = FaceID.shared
        let reason: String? = !isEnabled ? "kapalı" : !hasPassword ? "şifre yok" : passwordInvalid ? "şifre geçersiz"
            : !SystemLock.isLocked ? "kilitli değil" : !faceID.isUsable ? "yüz tanıma hazır değil"
            : !FaceCamera.isAvailable ? "kamera yok" : !AXIsProcessTrusted() ? "Erişilebilirlik izni yok"
            : failures >= Self.maxFailures ? "5 başarısız deneme" : faceID.engine == nil ? "model yok" : nil
        if let reason {
            if blockedReason != reason { blockedReason = reason; SupportLog.log("faceid", "Tarama başlamadı: \(reason)") }
            return nil
        }
        return faceID.engine
    }

    /// Kameraya bakan biri var mı diye izler (ekranda hiçbir şey görünmez).
    private func watch(reason: String) {
        watchUntil = CACurrentMediaTime() + Self.watchWindow
        guard watchToken == nil, !scanning, !unlocking, let engine = readyEngine() else { return }
        attentiveFrames = 0
        watchToken = FaceCamera.shared.subscribe(fps: 6) { [weak self] pixels in
            let faces = engine.detect(pixels)
            // Ekrana dönük, yeterince büyük ve net bir yüz (boşlukta yanlış "yüz" bulunmasın).
            let attentive = faces.first.map { $0.widthFraction > 0.08 && $0.quality > 0.3 && abs($0.pose.x) < 0.32 } ?? false
            let present = !faces.isEmpty
            Task { @MainActor in self?.watched(present: present, attentive: attentive) }
        }
        SupportLog.log("faceid", "İzleniyor (\(reason))")
    }

    private func watched(present: Bool, attentive: Bool) {
        guard watchToken != nil, !scanning, !unlocking else { return }
        if !present { needFreshFace = false }
        guard attentive, !needFreshFace else { attentiveFrames = 0; return }
        attentiveFrames += 1
        if attentiveFrames >= 2 { beginScan() }
    }

    private func stopWatching() {
        FaceCamera.shared.unsubscribe(watchToken)
        watchToken = nil
        attentiveFrames = 0
    }

    private func beginScan() {
        guard !scanning, !unlocking, let engine = readyEngine() else { return }
        let faceID = FaceID.shared
        scanning = true
        scanState = .scanning
        holdDisplay()
        faceID.overlay.showLock(self)
        SupportLog.log("faceid", "Kilit ekranı taraması")

        let matcher = faceID.store.matcher
        let unlockThreshold = FaceID.unlockThreshold, livenessThreshold = FaceID.livenessThreshold
        nonisolated(unsafe) var window: [(score: Float, live: Float, id: UUID?, embedding: [Float])] = []
        nonisolated(unsafe) var decided = false
        subscription = FaceCamera.shared.subscribe(fps: 15) { [weak self] pixels in
            guard !decided, let face = engine.detect(pixels, quality: false).first, face.widthFraction > 0.07,
                  let embedding = engine.embedding(pixels, face) else { return }
            let match = matcher.best(embedding)
            let live = engine.liveness(pixels, face)
            window.append((match?.score ?? 0, live, match?.face.id, embedding))
            if window.count > 6 { window.removeFirst() }
            let good = window.filter { $0.score >= unlockThreshold }
            let liveAverage = good.isEmpty ? 0 : good.map(\.live).reduce(0, +) / Float(good.count)
            let strong = (good.map(\.score).max() ?? 0) >= unlockThreshold + 0.1
            guard good.count >= (strong ? 2 : 3), liveAverage >= livenessThreshold else { return }
            decided = true
            let best = good.max { $0.score < $1.score }
            Task { @MainActor in
                self?.succeeded(faceID: best?.id, embedding: best?.embedding, score: best?.score ?? 0, live: liveAverage)
            }
        }
        // İzleme aboneliği tarama başladıktan sonra bırakılır: kamera kapanıp yeniden açılmaz.
        stopWatching()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self, self.scanning, self.scanState == .scanning else { return }
            decided = true
            guard !window.isEmpty else {
                // Bakan gitti: deneme sayılmaz, sessizce kapanır ve izlemeye dönülür.
                SupportLog.log("faceid", "Tarama: yüz yok")
                self.stopScan()
                self.endScan()
                self.watch(reason: "yeniden")
                return
            }
            let detail = window.map { String(format: "%.2f/%.2f", $0.score, $0.live) }.joined(separator: " ")
            SupportLog.log("faceid", "Tanınmadı: \(detail)")
            if let best = window.max(by: { $0.score < $1.score }), let id = best.id {
                FaceStore.shared.record(id, score: best.score, liveness: best.live, outcome: .failed)
            }
            self.failed()
        }
    }

    private func succeeded(faceID id: UUID?, embedding: [Float]?, score: Float, live: Float) {
        stopScan()
        scanState = .success
        unlocking = true
        Haptic.success()
        SupportLog.log("faceid", String(format: "Tanındı: benzerlik %.2f, canlılık %.2f", score, live))
        if let id { FaceStore.shared.record(id, score: score, liveness: live, outcome: .unlocked) }
        // Kullanıcı o sırada şifresini yazıyorsa karışmayalım.
        guard SystemLock.secondsSinceKey > 1.5, let data = Keychain.read(Self.passwordAccount, allowUI: false),
              let password = String(data: data, encoding: .utf8) else {
            unlocking = false
            endScan()
            return
        }
        // Tuşlar arka planda gönderilir (animasyon donmasın): şifre tek seferde, ardından hemen Enter.
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.12) {
            SystemLock.type(password, whole: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard SystemLock.isLocked else { return self.adapt(id, embedding, score) }
                // Alan tek seferde yazılanı almadıysa harf harf bir kez daha.
                DispatchQueue.global(qos: .userInteractive).async {
                    SystemLock.type(password, whole: false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        guard SystemLock.isLocked else { return self.adapt(id, embedding, score) }
                        self.passwordInvalid = true
                        UserDefaults.standard.set(true, forKey: Self.invalidKey)
                        SupportLog.log("faceid", "Şifre kilidi açmadı: yüzle açma durduruldu")
                        self.unlocking = false
                        self.endScan()
                    }
                }
            }
        }
    }

    private func adapt(_ id: UUID?, _ embedding: [Float]?, _ score: Float) {
        if let id, let embedding, score >= FaceID.unlockThreshold { FaceStore.shared.adapt(id, with: embedding) }
    }

    private func failed() {
        stopScan()
        failures += 1
        needFreshFace = true
        scanState = failures >= Self.maxFailures ? .locked : .failure
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard let self else { return }
            self.endScan()
            if self.failures < Self.maxFailures { self.watch(reason: "yeniden") }
        }
    }

    private func endScan() {
        lastScanEnd = CACurrentMediaTime()
        releaseDisplay()
        FaceID.shared.overlay.hideLock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, !self.scanning else { return }
            self.scanState = nil
        }
    }

    /// Tarama sırasında ekran kararmasın; kararmışsa uyansın.
    private func holdDisplay() {
        var activity: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Tuno yüz tanıma" as CFString, kIOPMUserActiveLocal, &activity)
        guard displayAssertion == 0 else { return }
        IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "Tuno yüz tanıma" as CFString, &displayAssertion)
    }

    private func releaseDisplay() {
        guard displayAssertion != 0 else { return }
        IOPMAssertionRelease(displayAssertion)
        displayAssertion = 0
    }

    private func stopScan() {
        FaceCamera.shared.unsubscribe(subscription)
        subscription = nil
        scanning = false
    }
}

/// Kilit ekranı yardımcıları: durum, kilitleme, boşta kalma süresi ve şifre yazma.
enum SystemLock {
    static var isLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Son fare/klavye olayından bu yana geçen süre.
    static var idleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Donanım düzeyinde son olay (kilit ekranındayken de güncellenir).
    static var hardwareIdleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    static var secondsSinceKey: Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
    }

    static func lock() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return }
        typealias Lock = @convention(c) () -> Int32
        _ = unsafeBitCast(symbol, to: Lock.self)()
    }

    /// Kilit ekranındaki alana yazar: alanı uyandırır, temizler, şifreyi yazar ve Enter'a basar.
    /// `whole`: şifre tek tuş olayıyla (20 karakterlik parçalar) gönderilir; değilse harf harf.
    nonisolated static func type(_ text: String, whole: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        func key(_ code: CGKeyCode, flags: CGEventFlags = [], gap: useconds_t = 4_000) {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
                event?.flags = flags
                event?.post(tap: .cghidEventTap)
                usleep(gap)
            }
        }
        func send(_ units: [UniChar], gap: useconds_t) {
            var units = units
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                event?.post(tap: .cghidEventTap)
                usleep(gap)
            }
        }
        key(56)                                  // Shift: alanı uyandırır
        usleep(whole ? 60_000 : 200_000)
        key(0, flags: .maskCommand)              // ⌘A
        key(51)                                  // Delete
        usleep(whole ? 20_000 : 80_000)
        let units = Array(text.utf16)
        if whole {
            stride(from: 0, to: units.count, by: 20).forEach { send(Array(units[$0..<min($0 + 20, units.count)]), gap: 3_000) }
            usleep(30_000)
        } else {
            units.forEach { send([$0], gap: 15_000) }
            usleep(150_000)
        }
        key(36)                                  // Return
    }
}

/// Pencereyi kilit ekranının üstündeki katmana taşır (SkyLight; kilit ekranı 300, üstü 400).
enum SkyLight {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SetLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
    private static func symbol<T>(_ name: String, _: T.Type) -> T? {
        dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
    }

    nonisolated(unsafe) private static var space: (connection: Int32, id: Int32)?

    static func lift(_ window: NSWindow) {
        guard let add = symbol("SLSSpaceAddWindowsAndRemoveFromSpaces", AddWindows.self) else { return }
        if space == nil,
           let main = symbol("SLSMainConnectionID", MainConnection.self),
           let create = symbol("SLSSpaceCreate", SpaceCreate.self),
           let setLevel = symbol("SLSSpaceSetAbsoluteLevel", SetLevel.self),
           let show = symbol("SLSShowSpaces", ShowSpaces.self) {
            let connection = main()
            let id = create(connection, 1, 0)
            _ = setLevel(connection, id, 400)
            _ = show(connection, [id] as CFArray)
            space = (connection, id)
        }
        guard let space else { return }
        _ = add(space.connection, space.id, [window.windowNumber] as CFArray, 7)
    }
}
