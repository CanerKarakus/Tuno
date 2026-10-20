import CoreAudio
import Foundation

/// Sesi yakalayıp (orijinalini susturarak) işlenmiş hâlde bir çıkış aygıtına yeniden çalan
/// Core Audio process tap'i.
///
/// Akış: kaynak ─▶ CATapDescription (mutedWhenTapped) ─▶ özel birleşik aygıt
///       ─▶ IOProc (TapDSP: kazanç + EQ + limiter) ─▶ çıkış aygıtı
final class AudioTap {
    static let aggregateUIDPrefix = "app.tuno.aggregate."

    enum Source: Equatable {
        /// Belirli uygulama süreçlerinin sesi.
        case processes([AudioObjectID])
        /// Aygıta giden ve listedeki süreçler dışında kalan tüm ses ("geri kalan her şey").
        case device(excluding: [AudioObjectID])
    }

    private(set) var source: Source
    let outputUID: String
    let dsp: TapDSP
    private(set) var sampleRate: Double = 48_000

    private var description: CATapDescription?
    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "app.tuno.tap", qos: .userInteractive)

    init(name: String, source: Source, outputUID: String, gain: Float, filters: [Biquad] = []) throws {
        self.source = source
        self.outputUID = outputUID
        // Kaynak tap'ten önce %100 çalıyordu; oradan hedefe kayarak geçmek ani seviye sıçramasını önler.
        self.dsp = TapDSP(target: gain, current: 1)
        do {
            try start(name: name)
        } catch {
            invalidate()
            throw error
        }
        dsp.setFilters(filters)
    }

    deinit { invalidate() }

    private func start(name: String) throws {
        let description: CATapDescription
        switch source {
        case .processes(let objects):
            description = CATapDescription(stereoMixdownOfProcesses: objects)
        case .device(let excluded):
            description = CATapDescription(excludingProcesses: excluded, deviceUID: outputUID, stream: 0)
        }
        description.uuid = UUID()
        description.name = "Tuno – \(name)"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        self.description = description

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw CoreAudioError(status: status, context: L("Tap oluşturulamadı")) }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tuno – \(name)",
            kAudioAggregateDeviceUIDKey: Self.aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { throw CoreAudioError(status: status, context: L("Birleşik aygıt oluşturulamadı")) }

        sampleRate = aggregateID.read(.init(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))
            .flatMap { $0 > 0 ? $0 : nil } ?? 48_000

        let dsp = self.dsp
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, input, _, output, _ in
            dsp.render(input: input, output: output)
        }
        guard status == noErr else { throw CoreAudioError(status: status, context: L("IOProc oluşturulamadı")) }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else { throw CoreAudioError(status: status, context: L("Ses akışı başlatılamadı")) }
    }

    /// Tap'i yıkmadan süreç listesini (dahil edilen ya da hariç tutulan) günceller.
    func update(source newSource: Source) -> Bool {
        guard newSource != source else { return true }
        guard tapID.isValid, var description else { return false }
        switch (source, newSource) {
        case (.processes, .processes(let objects)), (.device, .device(let objects)):
            description.processes = objects
        default:
            return false
        }
        var address = AudioObjectPropertyAddress(kAudioTapPropertyDescription)
        let status = withUnsafeMutablePointer(to: &description) { pointer in
            AudioObjectSetPropertyData(
                tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), pointer)
        }
        guard status == noErr else { return false }
        source = newSource
        return true
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
}

extension AudioProcess {
    /// Tuno'nun kendi süreç nesnesi; "geri kalan her şey" tap'inin kendi çıkışını
    /// yakalayıp geri besleme oluşturmaması için hariç tutulur.
    static func ownObjectID() -> AudioObjectID {
        var address = AudioObjectPropertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var object = AudioObjectID.unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            .system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr ? object : .unknown
    }
}
