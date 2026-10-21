import CoreAudio
import Foundation
import os

/// Bir uygulamanın sesini susturmadan dinleyip birkaç frekans bandının anlık düzeyini ölçer
/// (Dynamic Island'daki ses dalgası). Ses hiçbir yere çalınmaz ya da kaydedilmez.
///
/// Akış: süreçler ─▶ CATapDescription (unmuted) ─▶ özel birleşik aygıt ─▶ IOProc (bant geçiren süzgeçler → RMS)
final class LevelTap {
    static let frequencies: [Double] = [90, 300, 1_000, 3_200, 9_000]
    static var bandCount: Int { frequencies.count }

    private let meter: BandMeter
    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "app.tuno.level", qos: .userInitiated)
    let processObjects: [AudioObjectID]
    /// true: listedeki süreçler dışındaki tüm çıkış (hoparlöre giden toplam ses) ölçülür.
    private let excluding: Bool

    init(processes: [AudioObjectID], excluding: Bool = false) throws {
        processObjects = processes
        self.excluding = excluding
        meter = BandMeter(count: Self.bandCount)
        do {
            try start()
        } catch {
            invalidate()
            throw error
        }
    }

    deinit { invalidate() }

    /// Bantların son RMS düzeyleri (0…1).
    var levels: [Float] { meter.levels }

    private func start() throws {
        let description: CATapDescription
        if excluding, let output = Self.defaultOutputUID() {
            description = CATapDescription(excludingProcesses: processObjects, deviceUID: output, stream: 0)
        } else {
            description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        }
        description.uuid = UUID()
        description.name = "Tuno – Dalga"
        description.muteBehavior = .unmuted
        description.isPrivate = true

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw CoreAudioError(status: status, context: L("Tap oluşturulamadı")) }

        // Birleşik aygıtın saati için varsayılan çıkış; ses ona yazılmaz.
        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tuno – Dalga",
            kAudioAggregateDeviceUIDKey: AudioTap.aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        if let output = Self.defaultOutputUID() {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = output
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: output]]
        }
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { throw CoreAudioError(status: status, context: L("Birleşik aygıt oluşturulamadı")) }

        // Yalnızca ölçüm: gecikme önemsiz, büyük tampon daha az uyanma (≈23/sn @48 kHz) demek.
        var frames = UInt32(2048)
        var bufferAddress = AudioObjectPropertyAddress(kAudioDevicePropertyBufferFrameSize)
        AudioObjectSetPropertyData(aggregateID, &bufferAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)

        let sampleRate = aggregateID.read(.init(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))
            .flatMap { $0 > 0 ? $0 : nil } ?? 48_000
        meter.configure(frequencies: Self.frequencies, sampleRate: sampleRate)

        let meter = self.meter
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, input, _, _, _ in
            meter.process(input)
        }
        guard status == noErr else { throw CoreAudioError(status: status, context: L("IOProc oluşturulamadı")) }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else { throw CoreAudioError(status: status, context: L("Ses akışı başlatılamadı")) }
    }

    func invalidate() {
        if aggregateID.isValid, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID.isValid {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }
    }

    private static func defaultOutputUID() -> String? {
        guard let device = AudioObjectID.system.read(.init(kAudioHardwarePropertyDefaultOutputDevice), initial: AudioObjectID.unknown),
              device.isValid
        else { return nil }
        return device.readString(.init(kAudioDevicePropertyDeviceUID))
    }
}

/// Ses iş parçacığında çalışan bant ölçer: her bant için bir bant geçiren biquad ve tampon başına RMS.
private final class BandMeter: @unchecked Sendable {
    private let count: Int
    private let coefficients: UnsafeMutablePointer<Biquad>
    private let state: UnsafeMutablePointer<Float>          // bant başına 2
    private let sums: UnsafeMutablePointer<Float>
    private let shared: OSAllocatedUnfairLock<[Float]>

    init(count: Int) {
        self.count = count
        coefficients = .allocate(capacity: count)
        coefficients.initialize(repeating: Biquad(), count: count)
        state = .allocate(capacity: count * 2)
        state.initialize(repeating: 0, count: count * 2)
        sums = .allocate(capacity: count)
        sums.initialize(repeating: 0, count: count)
        shared = OSAllocatedUnfairLock(initialState: [Float](repeating: 0, count: count))
    }

    deinit {
        coefficients.deallocate()
        state.deallocate()
        sums.deallocate()
    }

    var levels: [Float] { shared.withLock { $0 } }

    /// RBJ bant geçiren süzgeç (tepe kazancı 0 dB). IOProc başlamadan önce bir kez çağrılır.
    func configure(frequencies: [Double], sampleRate: Double) {
        for (index, frequency) in frequencies.prefix(count).enumerated() {
            let w0 = 2 * Double.pi * min(frequency, sampleRate * 0.45) / sampleRate
            let alpha = sin(w0) / (2 * 1.1)
            let a0 = 1 + alpha
            var filter = Biquad()
            filter.b0 = Float(alpha / a0); filter.b1 = 0; filter.b2 = Float(-alpha / a0)
            filter.a1 = Float(-2 * cos(w0) / a0); filter.a2 = Float((1 - alpha) / a0)
            coefficients[index] = filter
        }
    }

    func process(_ input: UnsafePointer<AudioBufferList>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        // Birleşik aygıtta tap akışı, alt aygıt girişlerinden sonra gelir.
        guard let source = inputs.last, source.mNumberChannels > 0,
              let data = source.mData?.assumingMemoryBound(to: Float.self)
        else { return }
        let channels = Int(source.mNumberChannels)
        let frames = Int(source.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        guard frames > 0 else { return }

        sums.update(repeating: 0, count: count)
        for frame in 0..<frames {
            let left = data[frame * channels]
            let x = channels > 1 ? (left + data[frame * channels + 1]) * 0.5 : left
            for band in 0..<count {
                let c = coefficients[band]
                let s = state + band * 2
                let y = c.b0 * x + s[0]
                s[0] = c.b1 * x - c.a1 * y + s[1]
                s[1] = c.b2 * x - c.a2 * y
                sums[band] += y * y
            }
        }
        if !state[0].isFinite { state.update(repeating: 0, count: count * 2) }
        shared.withLock { levels in
            for band in 0..<count { levels[band] = (sums[band] / Float(frames)).squareRoot() }
        }
    }
}
