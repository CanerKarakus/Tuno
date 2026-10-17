import CoreAudio
import Foundation

/// RBJ "Audio EQ Cookbook" biquad katsayıları (a0'a normalize edilmiş).
struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0

    enum Kind { case peak, lowShelf, highShelf }

    init() {}

    init(kind: Kind, frequency: Double, gainDB: Double, q: Double, sampleRate: Double) {
        guard sampleRate > 0, abs(gainDB) > 0.01, frequency < sampleRate / 2 else { return }
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosW = cos(w0), sinW = sin(w0)
        let alpha = sinW / (2 * q)
        var (b0, b1, b2, a0, a1, a2): (Double, Double, Double, Double, Double, Double)
        switch kind {
        case .peak:
            b0 = 1 + alpha * a; b1 = -2 * cosW; b2 = 1 - alpha * a
            a0 = 1 + alpha / a; a1 = -2 * cosW; a2 = 1 - alpha / a
        case .lowShelf:
            let s = 2 * sqrt(a) * alpha
            b0 = a * ((a + 1) - (a - 1) * cosW + s)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosW)
            b2 = a * ((a + 1) - (a - 1) * cosW - s)
            a0 = (a + 1) + (a - 1) * cosW + s
            a1 = -2 * ((a - 1) + (a + 1) * cosW)
            a2 = (a + 1) + (a - 1) * cosW - s
        case .highShelf:
            let s = 2 * sqrt(a) * alpha
            b0 = a * ((a + 1) + (a - 1) * cosW + s)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosW)
            b2 = a * ((a + 1) + (a - 1) * cosW - s)
            a0 = (a + 1) - (a - 1) * cosW + s
            a1 = 2 * ((a - 1) - (a + 1) * cosW)
            a2 = (a + 1) - (a - 1) * cosW - s
        }
        self.b0 = Float(b0 / a0); self.b1 = Float(b1 / a0); self.b2 = Float(b2 / a0)
        self.a1 = Float(a1 / a0); self.a2 = Float(a2 / a0)
    }

    /// Verilen frekanstaki genlik yanıtı (dB) — arayüzdeki eğri için.
    func magnitudeDB(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2 * w), sin(2 * w))
        let nr = Double(b0) + Double(b1) * c1 + Double(b2) * c2
        let ni = -(Double(b1) * s1 + Double(b2) * s2)
        let dr = 1 + Double(a1) * c1 + Double(a2) * c2
        let di = -(Double(a1) * s1 + Double(a2) * s2)
        let magnitude = sqrt((nr * nr + ni * ni) / max(dr * dr + di * di, 1e-12))
        return 20 * log10(max(magnitude, 1e-9))
    }
}

/// Bir tap'in gerçek zamanlı işleme durumu. Ana iş parçacığı parametreleri yazar,
/// ses iş parçacığı okur. Katsayılar çift tamponla değiştirilir; ses iş parçacığında
/// bellek ayırma veya kilit yoktur.
final class TapDSP: @unchecked Sendable {
    static let maxBands = 10
    static let maxFrames = 8192

    /// Uygulama kazancı × aygıt yazılım sesi × EQ ön kazancı.
    var target: Float
    private var current: Float
    private var envelope: Float = 0

    private let coefficients: UnsafeMutablePointer<Biquad>   // 2 × maxBands
    private var activeBank: Int32 = 0
    private var bandCount: Int32 = 0                         // 0 → EQ kapalı
    private let state: UnsafeMutablePointer<Float>           // 2 kanal × maxBands × (z1, z2)
    private let scratch: UnsafeMutablePointer<Float>         // 2 kanal × maxFrames

    init(target: Float, current: Float) {
        self.target = target
        self.current = current
        coefficients = .allocate(capacity: 2 * Self.maxBands)
        coefficients.initialize(repeating: Biquad(), count: 2 * Self.maxBands)
        state = .allocate(capacity: 2 * Self.maxBands * 2)
        state.initialize(repeating: 0, count: 2 * Self.maxBands * 2)
        scratch = .allocate(capacity: 2 * Self.maxFrames)
        scratch.initialize(repeating: 0, count: 2 * Self.maxFrames)
    }

    deinit {
        coefficients.deallocate()
        state.deallocate()
        scratch.deallocate()
    }

    /// Ana iş parçacığından çağrılır. Boş dizi EQ'yu kapatır.
    func setFilters(_ filters: [Biquad]) {
        let count = min(filters.count, Self.maxBands)
        let inactive = Int(1 - activeBank)
        for i in 0..<count { coefficients[inactive * Self.maxBands + i] = filters[i] }
        if bandCount == 0 && count > 0 {
            state.update(repeating: 0, count: 2 * Self.maxBands * 2)
        }
        activeBank = Int32(inactive)
        bandCount = Int32(count)
    }

    private static let smoothing: Float = 0.0015   // ~15 ms @48 kHz
    private static let release: Float = 0.0002     // ~100 ms @48 kHz
    private static let ceiling: Float = 0.95

    /// Tap girişini işleyip çıkış tamponlarına yazar.
    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)

        // Birleşik aygıtta tap akışı, alt aygıt girişlerinden sonra gelir.
        guard let source = inputs.last, source.mNumberChannels > 0,
              let sourceData = source.mData?.assumingMemoryBound(to: Float.self)
        else {
            for buffer in outputs { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
            current = target
            return
        }
        let inChannels = Int(source.mNumberChannels)
        let frames = min(Int(source.mDataByteSize) / (MemoryLayout<Float>.size * inChannels), Self.maxFrames)

        // 1) Stereo karalama tamponuna kazanç + EQ + limiter uygula.
        let left = scratch, right = scratch + Self.maxFrames
        let bands = Int(bandCount)
        let bank = coefficients + Int(activeBank) * Self.maxBands
        let goal = target
        var g = current
        var env = envelope

        for frame in 0..<frames {
            g += (goal - g) * Self.smoothing
            var l = sourceData[frame * inChannels] * g
            var r = (inChannels > 1 ? sourceData[frame * inChannels + 1] : sourceData[frame * inChannels]) * g

            for band in 0..<bands {
                let c = bank[band]
                let sl = state + band * 2, sr = state + (Self.maxBands + band) * 2
                let yl = c.b0 * l + sl[0]
                sl[0] = c.b1 * l - c.a1 * yl + sl[1]
                sl[1] = c.b2 * l - c.a2 * yl
                l = yl
                let yr = c.b0 * r + sr[0]
                sr[0] = c.b1 * r - c.a1 * yr + sr[1]
                sr[1] = c.b2 * r - c.a2 * yr
                r = yr
            }

            // Zarf takipli limiter: kırpılma yerine kazancı yumuşakça düşürür.
            let peak = max(abs(l), abs(r))
            env = peak > env ? peak : env + (peak - env) * Self.release
            if env > Self.ceiling {
                let reduction = Self.ceiling / env
                l *= reduction; r *= reduction
            }
            if !l.isFinite || !r.isFinite {   // kararsız filtreye karşı güvenlik
                state.update(repeating: 0, count: 2 * Self.maxBands * 2)
                l = 0; r = 0; env = 0
            }
            if abs(l) > 1 { l = tanh(l) }
            if abs(r) > 1 { r = tanh(r) }
            left[frame] = l
            right[frame] = r
        }
        current = g
        envelope = env

        // 2) Çıkış kanallarına dağıt (stereo → n kanal).
        for buffer in outputs {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self), buffer.mNumberChannels > 0 else {
                continue
            }
            let outChannels = Int(buffer.mNumberChannels)
            let outFrames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * outChannels)
            let count = min(frames, outFrames)
            for frame in 0..<count {
                for channel in 0..<outChannels {
                    data[frame * outChannels + channel] = channel % 2 == 0 ? left[frame] : right[frame]
                }
            }
            if outFrames > count {
                memset(data + count * outChannels, 0, (outFrames - count) * outChannels * MemoryLayout<Float>.size)
            }
        }
    }
}
