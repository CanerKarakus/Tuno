import AppKit
import Observation
import QuartzCore

/// Uzaklaşınca kilitle: klavye ve fare 30 sn kullanılmazsa kamera sessizce (animasyonsuz) en çok 2 sn bakar.
/// Yüz yoksa çalan müzik durur ve ekran kilitlenir; yüz varsa (ör. video izleniyor) 1 dk sonra yeniden bakılır.
/// Uyanık Tut açıkken hiç bakılmaz.
@Observable
@MainActor
final class FacePresence {
    private static let enabledKey = "faceAwayLock"
    static let idleDelay: Double = 30
    private static let recheck: CFTimeInterval = 60

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey); refresh() }
    }

    @ObservationIgnored private weak var keepAwake: KeepAwake?
    @ObservationIgnored private var pauseMedia: (() -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastCheck: CFTimeInterval = 0
    @ObservationIgnored private var checking = false

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    func start(keepAwake: KeepAwake, pauseMedia: @escaping () -> Void) {
        self.keepAwake = keepAwake
        self.pauseMedia = pauseMedia
        refresh()
    }

    private func refresh() {
        timer?.invalidate()
        timer = nil
        guard isEnabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 1
    }

    private func tick() {
        let idle = SystemLock.idleSeconds
        // Kullanıcı yeniden dokununca bir sonraki boşta kalmada hemen bakılabilsin.
        if idle < Self.idleDelay { lastCheck = 0; return }
        guard !checking, keepAwake?.isActive != true, !SystemLock.isLocked, CGDisplayIsAsleep(CGMainDisplayID()) == 0,
              FaceCamera.isAvailable, CACurrentMediaTime() - lastCheck >= Self.recheck else { return }
        checking = true
        lastCheck = CACurrentMediaTime()
        look { [weak self] present in
            guard let self else { return }
            self.checking = false
            // Bakarken kullanıcı döndüyse ya da Uyanık Tut açıldıysa vazgeç.
            guard !present, SystemLock.idleSeconds >= Self.idleDelay, self.keepAwake?.isActive != true, !SystemLock.isLocked
            else { return }
            SupportLog.log("faceid", "Uzaklaşıldı: müzik durdu, ekran kilitlendi")
            self.pauseMedia?()
            SystemLock.lock()
        }
    }

    /// Kameraya en çok 2 sn bakar; bir yüz görünce hemen biter.
    private func look(_ done: @escaping (Bool) -> Void) {
        nonisolated(unsafe) var finished = false
        nonisolated(unsafe) var token: UUID?
        let lock = NSLock()
        func finish(_ present: Bool) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            lock.unlock()
            FaceCamera.shared.unsubscribe(token)
            Task { @MainActor in done(present) }
        }
        token = FaceCamera.shared.subscribe(fps: 8) { pixels in
            let width = CGFloat(CVPixelBufferGetWidth(pixels))
            if Self.rects(pixels).contains(where: { $0.width / width > 0.06 }) { finish(true) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { finish(false) }
    }

    /// Yalnızca Vision (model gerekmez).
    nonisolated private static func rects(_ pixels: CVPixelBuffer) -> [CGRect] {
        FaceGuard.faceRects(pixels)
    }
}
