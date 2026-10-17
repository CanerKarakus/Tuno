import AVFoundation
import Observation

/// Varsayılan giriş aygıtının anlık seviyesini ölçer (mikrofon testi).
@Observable
@MainActor
final class InputMeter {
    private(set) var isRunning = false
    /// 0…1 aralığında (−60 dB … 0 dB).
    private(set) var level: Float = 0
    private(set) var peak: Float = 0
    private(set) var error: String?

    @ObservationIgnored private var engine: AVAudioEngine?

    func toggle() { isRunning ? stop() : start() }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startEngine()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in granted ? self.startEngine() : self.denied() }
            }
        default:
            denied()
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
        level = 0
        peak = 0
    }

    /// Giriş aygıtı değişince yeni aygıtla yeniden başlat.
    func restartIfRunning() {
        guard isRunning else { return }
        stop()
        start()
    }

    private func denied() {
        error = "Mikrofon izni yok. Sistem Ayarları › Gizlilik ve Güvenlik › Mikrofon bölümünden izin verin."
    }

    private func startEngine() {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            error = "Giriş aygıtı kullanılamıyor."
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frames { sum += data[0][i] * data[0][i] }
            let rms = sqrt(sum / Float(max(frames, 1)))
            let db = 20 * log10(max(rms, 1e-7))
            let normalized = min(max((db + 60) / 60, 0), 1)
            Task { @MainActor in self?.push(normalized) }
        }
        do {
            try engine.start()
            self.engine = engine
            isRunning = true
            error = nil
        } catch {
            self.error = "Mikrofon başlatılamadı: \(error.localizedDescription)"
        }
    }

    private func push(_ value: Float) {
        guard isRunning else { return }
        // Hızlı yükselme, yavaş düşme — klasik VU davranışı.
        level = value > level ? value : level * 0.8 + value * 0.2
        peak = max(level, peak - 0.01)
    }
}
