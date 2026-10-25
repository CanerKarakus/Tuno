import AppKit
import Observation
import QuartzCore
import SwiftUI

/// iPhone'daki gibi yüz kurulumu: önce yüz ortalanır ve düz bakış örnekleri alınır, sonra baş yavaşça daire
/// çizerek döndürülür; bakılan yöndeki çizgiler dolar. İki tur: 1. derin (küçük açılar, yoğun örnek),
/// 2. geniş (büyük açılar). Bitince ad sorulur.
@Observable
@MainActor
final class FaceEnrollment {
    enum Phase: Equatable {
        case positioning
        case scanning(Int)
        case passDone(Int)
        case naming
        case failed(String)
    }

    static let tickCount = 60

    private(set) var phase: Phase = .positioning
    private(set) var ticks = Array(repeating: false, count: FaceEnrollment.tickCount)
    private(set) var hint = ""
    private(set) var faceVisible = false
    /// Yüz bulunduysa önizlemede baş yönünün işareti (−1…1).
    private(set) var direction: CGPoint = .zero
    var name: String

    /// Bitince (iptalde nil) çağrılır.
    @ObservationIgnored var onFinish: (([[Float]]?, String) -> Void)?

    @ObservationIgnored private let engine: FaceEngine
    @ObservationIgnored private var subscription: UUID?
    @ObservationIgnored private var frontal: [[Float]] = []
    @ObservationIgnored private var scanned: [[Float]] = []
    @ObservationIgnored private var baselineSamples: [CGPoint] = []
    @ObservationIgnored private var baseline: CGPoint?
    /// Dilim başına bu turda alınan özet sayısı.
    @ObservationIgnored private var captured: [Int: Int] = [:]
    @ObservationIgnored private var lastCapture: CFTimeInterval = 0
    @ObservationIgnored private var lastTick: Int?
    @ObservationIgnored private var smoothed: CGPoint?
    @ObservationIgnored private var history: [(time: CFTimeInterval, point: CGPoint)] = []
    @ObservationIgnored private var lastFaceTime: CFTimeInterval = CACurrentMediaTime()
    @ObservationIgnored private var slowUntil: CFTimeInterval = 0
    @ObservationIgnored private var finishing = false

    /// Tur başına gereken en küçük baş açısı (göz arası mesafeye oranla; ~0,1 ≈ 10°).
    private static let reach: [CGFloat] = [0.1, 0.2]
    /// Yukarı/aşağı bakış yatay dönüşten daha az görünür: dikey eksen büyütülür.
    private static let verticalGain: CGFloat = 1.7
    /// Düz bakış örnekleri.
    private static let frontalCount = 8
    /// Halka 12 dilime bölünür; her dilimden tur başına bir özet alınır.
    private static let sectors = 12

    init(engine: FaceEngine, name: String) {
        self.engine = engine
        self.name = name
        hint = L("Yüzünü çerçevenin içine getir.")
    }

    var filledCount: Int { ticks.filter { $0 }.count }

    func start() {
        let engine = engine
        nonisolated(unsafe) var lastEmbed: CFTimeInterval = 0
        subscription = FaceCamera.shared.subscribe(fps: 15) { [weak self] pixels in
            let faces = engine.detect(pixels)
            var embedding: [Float]?
            let now = CACurrentMediaTime()
            // Baş dönükken Vision'ın kalite puanı düşer: eşik düşük tutulur (asıl eleme ortalamaya uzaklıkla yapılır).
            if faces.count == 1, let face = faces.first, face.quality > 0.08, now - lastEmbed > 0.12 {
                embedding = engine.embedding(pixels, face)
                lastEmbed = now
            }
            let result = (faces: faces, embedding: embedding)
            Task { @MainActor in self?.process(result.faces, result.embedding) }
        }
    }

    func cancel() {
        stopCamera()
        onFinish?(nil, name)
        onFinish = nil
    }

    /// 1. tur bitti: 2. tura geç.
    func continueToSecondPass() {
        guard phase == .passDone(1) else { return }
        withSpring {
            ticks = Array(repeating: false, count: Self.tickCount)
            phase = .scanning(2)
        }
        captured = [:]
        lastTick = nil
        hint = L("Bir kez daha: başını daha geniş bir daire çizecek şekilde çevir.")
    }

    func save() {
        guard phase == .naming else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { name = trimmed }
        onFinish?(cleanedTemplates(), name)
        onFinish = nil
    }

    func retry() {
        frontal = []
        scanned = []
        baselineSamples = []
        baseline = nil
        captured = [:]
        lastTick = nil
        finishing = false
        withSpring {
            ticks = Array(repeating: false, count: Self.tickCount)
            phase = .positioning
        }
        hint = L("Yüzünü çerçevenin içine getir.")
        if subscription == nil { start() }
    }

    private func stopCamera() {
        FaceCamera.shared.unsubscribe(subscription)
        subscription = nil
    }

    // MARK: - Kareler

    private func process(_ faces: [DetectedFace], _ embedding: [Float]?) {
        let now = CACurrentMediaTime()
        switch phase {
        case .positioning, .scanning: break
        default: return
        }
        guard let face = faces.first else {
            faceVisible = false
            if now - lastFaceTime > 0.6 { hint = L("Yüzünü çerçevenin içine getir.") }
            return
        }
        lastFaceTime = now
        faceVisible = true
        if faces.count > 1, faces[1].widthFraction > face.widthFraction * 0.5 {
            hint = L("Çerçevede yalnızca sen ol.")
            return
        }
        if face.widthFraction < 0.15 { hint = L("Biraz yaklaş."); return }
        if face.widthFraction > 0.62 { hint = L("Biraz uzaklaş."); return }
        if face.brightness < 0.14 { hint = L("Ortam çok karanlık."); return }

        switch phase {
        case .positioning: position(face, embedding)
        case .scanning(let pass): scan(face, embedding, pass: pass, now: now)
        default: break
        }
    }

    private func position(_ face: DetectedFace, _ embedding: [Float]?) {
        guard abs(face.pose.x) < 0.14 else {
            hint = L("Kameraya düz bak.")
            return
        }
        hint = L("Kameraya bak…")
        baselineSamples.append(face.pose)
        if let embedding, face.eyesOpen, frontal.count < Self.frontalCount { frontal.append(embedding) }
        guard baselineSamples.count >= 10, frontal.count >= Self.frontalCount else { return }
        let xs = baselineSamples.map(\.x).sorted(), ys = baselineSamples.map(\.y).sorted()
        baseline = CGPoint(x: xs[xs.count / 2], y: ys[ys.count / 2])
        withSpring { phase = .scanning(1) }
        hint = L("Başını yavaşça daire çizecek şekilde çevir.")
        Haptic.tap()
    }

    private func scan(_ face: DetectedFace, _ embedding: [Float]?, pass: Int, now: CFTimeInterval) {
        guard let baseline else { return }
        let raw = CGPoint(x: face.pose.x - baseline.x, y: (face.pose.y - baseline.y) * Self.verticalGain)
        // Titreşim hız sanılmasın: yön yumuşatılır, hız son 0,3 sn'deki yer değiştirmeden ölçülür.
        let vector = smoothed.map { CGPoint(x: $0.x * 0.55 + raw.x * 0.45, y: $0.y * 0.55 + raw.y * 0.45) } ?? raw
        smoothed = vector
        history.append((now, vector))
        history.removeAll { now - $0.time > 0.45 }
        let reach = Self.reach[pass - 1]
        direction = CGPoint(x: max(-1, min(1, vector.x / (reach * 1.6))), y: max(-1, min(1, vector.y / (reach * 1.6))))

        var tooFast = false
        if let oldest = history.first, now - oldest.time > 0.25 {
            let speed = hypot(vector.x - oldest.point.x, vector.y - oldest.point.y) / CGFloat(now - oldest.time)
            tooFast = speed > reach * 6
            if tooFast { slowUntil = now + 1.2 }
        }
        if now < slowUntil {
            hint = L("Daha yavaş.")
        } else {
            hint = pass == 1 ? L("Başını yavaşça daire çizecek şekilde çevir.")
                             : L("Bir kez daha: başını daha geniş bir daire çizecek şekilde çevir.")
        }

        let magnitude = hypot(vector.x, vector.y)
        guard magnitude >= reach else { lastTick = nil; return }
        // Çizgiler tepeden başlayıp saat yönünde dizilir.
        let angle = atan2(vector.y, vector.x) * 180 / .pi
        let tick = (Int(((90 - angle) / 6).rounded()) % Self.tickCount + Self.tickCount) % Self.tickCount
        fill(from: lastTick, to: tick)
        lastTick = tick

        let sector = tick * Self.sectors / Self.tickCount
        if let embedding, !tooFast, captured[sector, default: 0] < 2, now - lastCapture > 0.25 {
            if captured[sector, default: 0] == 0 { Haptic.tap() }
            captured[sector, default: 0] += 1
            scanned.append(embedding)
            lastCapture = now
        }

        if filledCount >= Self.tickCount - 3, !finishing { completePass(pass) }
    }

    /// İki çizgi arası kısa yoldan doldurulur (baş hızlıca geçtiyse aradakiler de dolar).
    private func fill(from start: Int?, to end: Int) {
        var indices = [end]
        if let start {
            let forward = (end - start + Self.tickCount) % Self.tickCount
            let backward = (start - end + Self.tickCount) % Self.tickCount
            if min(forward, backward) <= 8 {
                let step = forward <= backward ? 1 : -1
                var i = start
                while i != end {
                    indices.append(i)
                    i = (i + step + Self.tickCount) % Self.tickCount
                }
            }
        }
        let fresh = indices.filter { !ticks[$0] }
        guard !fresh.isEmpty else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            for i in fresh { ticks[i] = true }
        }
    }

    private func completePass(_ pass: Int) {
        finishing = true
        withAnimation(.easeOut(duration: 0.3)) { ticks = Array(repeating: true, count: Self.tickCount) }
        Haptic.success()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.finishing = false
            if pass == 1 {
                self.withSpring { self.phase = .passDone(1) }
                self.hint = L("İlk tarama tamamlandı.")
            } else {
                self.stopCamera()
                let cleaned = self.cleanedTemplates()
                SupportLog.log("faceid", "Kurulum: düz \(self.frontal.count), tarama \(self.scanned.count), kullanılan \(cleaned.count)")
                guard cleaned.count >= 12 else {
                    self.withSpring { self.phase = .failed(L("Yeterli örnek alınamadı. Başını daha yavaş çevirip tekrar dene.")) }
                    return
                }
                self.withSpring { self.phase = .naming }
                self.hint = L("Tarama tamamlandı.")
            }
        }
    }

    /// Düz bakış ortalamasına çok uzak özetler (başka biri girdiyse) atılır.
    private func cleanedTemplates() -> [[Float]] {
        guard !frontal.isEmpty else { return [] }
        var mean = [Float](repeating: 0, count: frontal[0].count)
        for e in frontal { for i in mean.indices { mean[i] += e[i] } }
        FaceEngine.normalize(&mean)
        return (frontal + scanned).filter { FaceEngine.cosine($0, mean) > 0.3 }
    }

    private func withSpring(_ change: () -> Void) {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82), change)
    }
}

/// Trackpad titreşimi (parmak trackpad'deyse hissedilir).
enum Haptic {
    static func tap() { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    static func success() { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
}
