import CoreAudio
import Observation

/// Ses aygıtlarını, varsayılanları ve varsayılan aygıtların denetimlerini izler.
@Observable
@MainActor
final class DeviceStore {
    private(set) var outputDevices: [AudioDevice] = []
    private(set) var inputDevices: [AudioDevice] = []
    private(set) var defaultOutputID = AudioObjectID.unknown
    private(set) var defaultInputID = AudioObjectID.unknown
    private(set) var systemOutputID = AudioObjectID.unknown
    private(set) var output = DeviceControls.empty
    private(set) var input = DeviceControls.empty
    /// Aygıt başına en yüksek ses düzeyi (ör. kulaklıkta kulak sağlığı için).
    private(set) var volumeLimits: [String: Float] = [:]
    /// Mikrofon tüm giriş aygıtlarında Tuno tarafından kapatıldı mı?
    private(set) var microphoneMuted = false
    let rules = DeviceRules()

    /// Varsayılan çıkış ya da aygıt listesi değişince mikserin tap'leri yeniden kurması için.
    @ObservationIgnored var onRoutingChange: (() -> Void)?
    @ObservationIgnored var onMicrophoneMuteChange: ((Bool) -> Void)?
    /// Sessize alınırken aygıtların eski hâli: ses denetimi olmayanlarda eski düzey.
    @ObservationIgnored private var mutedInputs: [AudioObjectID: Float?] = [:]
    private static let limitsKey = "volumeLimits"

    @ObservationIgnored private var systemListeners: [PropertyListener] = []
    @ObservationIgnored private var outputListeners: [PropertyListener] = []
    @ObservationIgnored private var inputListeners: [PropertyListener] = []

    init() {
        let selectors = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultSystemOutputDevice,
        ]
        systemListeners = selectors.map { selector in
            PropertyListener(.system, .init(selector)) { [weak self] in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
        volumeLimits = UserDefaults.standard.dictionary(forKey: Self.limitsKey) as? [String: Float] ?? [:]
        reload()
    }

    var defaultOutput: AudioDevice? { outputDevices.first { $0.id == defaultOutputID } }
    var defaultInput: AudioDevice? { inputDevices.first { $0.id == defaultInputID } }

    func device(uid: String) -> AudioDevice? { outputDevices.first { $0.uid == uid } }

    func reload() {
        let devices = AudioDevice.all()
        outputDevices = devices.filter(\.hasOutput)
        inputDevices = devices.filter(\.hasInput)

        let newOutput = AudioObjectID.system.read(
            .init(kAudioHardwarePropertyDefaultOutputDevice), initial: AudioObjectID.unknown) ?? .unknown
        let newInput = AudioObjectID.system.read(
            .init(kAudioHardwarePropertyDefaultInputDevice), initial: AudioObjectID.unknown) ?? .unknown
        systemOutputID = AudioObjectID.system.read(
            .init(kAudioHardwarePropertyDefaultSystemOutputDevice), initial: AudioObjectID.unknown) ?? .unknown

        if newOutput != defaultOutputID || outputListeners.isEmpty {
            defaultOutputID = newOutput
            outputListeners = observe(newOutput, scope: .output)
        }
        if newInput != defaultInputID || inputListeners.isEmpty {
            defaultInputID = newInput
            inputListeners = observe(newInput, scope: .input)
        }
        refreshControls()
        if microphoneMuted { muteInputs() }
        onRoutingChange?()
        applyRules()
    }

    /// Öncelik kurallarına göre gerekiyorsa varsayılan aygıtı değiştirir.
    private func applyRules() {
        if let target = rules.evaluate(scope: .output, devices: outputDevices, current: defaultOutput) {
            switchDefault(to: target, scope: .output)
        }
        if let target = rules.evaluate(scope: .input, devices: inputDevices, current: defaultInput) {
            switchDefault(to: target, scope: .input)
        }
    }

    private func observe(_ id: AudioObjectID, scope: AudioScope) -> [PropertyListener] {
        guard id.isValid else { return [] }
        return AudioDevice.observedAddresses(scope).map { address in
            PropertyListener(id, address) { [weak self] in
                MainActor.assumeIsolated { self?.refreshControls() }
            }
        }
    }

    private func refreshControls() {
        output = AudioDevice.controls(of: defaultOutputID, scope: .output)
        input = AudioDevice.controls(of: defaultInputID, scope: .input)
        // Ses tuşlarıyla ya da başka bir uygulamadan sınırın üstüne çıkılırsa geri indir.
        if let limit = defaultOutput.flatMap({ volumeLimit(for: $0.uid) }), let volume = output.volume,
           output.canSetVolume, volume > limit + 0.001 {
            AudioDevice.setVolume(limit, of: defaultOutputID, scope: .output)
            output.volume = limit
        }
    }

    // MARK: - Ses sınırı

    func volumeLimit(for uid: String) -> Float? { volumeLimits[uid] }

    func setVolumeLimit(_ limit: Float?, for uid: String) {
        volumeLimits[uid] = limit.map { min(max($0, 0.05), 1) }
        UserDefaults.standard.set(volumeLimits, forKey: Self.limitsKey)
        refreshControls()
        onRoutingChange?()
    }

    // MARK: - Mikrofon

    func setMicrophoneMuted(_ muted: Bool) {
        guard muted != microphoneMuted else { return }
        microphoneMuted = muted
        if muted { muteInputs() } else { restoreInputs() }
        input = AudioDevice.controls(of: defaultInputID, scope: .input)
        onMicrophoneMuteChange?(muted)
    }

    /// Tüm giriş aygıtlarını susturur; susturma düğmesi olmayanların düzeyini sıfırlar.
    private func muteInputs() {
        for device in inputDevices where mutedInputs[device.id] == nil {
            let controls = AudioDevice.controls(of: device.id, scope: .input)
            if controls.canMute {
                AudioDevice.setMuted(true, of: device.id, scope: .input)
                mutedInputs[device.id] = .some(nil)
            } else if controls.canSetVolume, let volume = controls.volume {
                AudioDevice.setVolume(0, of: device.id, scope: .input)
                mutedInputs[device.id] = .some(volume)
            }
        }
    }

    private func restoreInputs() {
        for (id, volume) in mutedInputs {
            if let volume { AudioDevice.setVolume(volume, of: id, scope: .input) }
            else { AudioDevice.setMuted(false, of: id, scope: .input) }
        }
        mutedInputs = [:]
    }

    // MARK: - Eylemler

    /// Kullanıcının seçimi: öncelik kuralları bir sonraki takma/çıkarmaya kadar buna dokunmaz.
    func setDefault(_ device: AudioDevice, scope: AudioScope) {
        rules.noteManualSelection(device.uid, scope: scope)
        switchDefault(to: device, scope: scope)
    }

    private func switchDefault(to device: AudioDevice, scope: AudioScope) {
        let selector = scope == .output
            ? kAudioHardwarePropertyDefaultOutputDevice
            : kAudioHardwarePropertyDefaultInputDevice
        AudioObjectID.system.write(.init(selector), device.id)
    }

    func setSystemOutput(_ id: AudioObjectID) {
        AudioObjectID.system.write(.init(kAudioHardwarePropertyDefaultSystemOutputDevice), id)
    }

    func setVolume(_ value: Float, scope: AudioScope) {
        var value = value
        if scope == .output, let limit = defaultOutput.flatMap({ volumeLimit(for: $0.uid) }) { value = min(value, limit) }
        let id = scope == .output ? defaultOutputID : defaultInputID
        AudioDevice.setVolume(value, of: id, scope: scope)
        if scope == .output { output.volume = value } else { input.volume = value }
    }

    func setMuted(_ muted: Bool, scope: AudioScope) {
        let id = scope == .output ? defaultOutputID : defaultInputID
        AudioDevice.setMuted(muted, of: id, scope: scope)
        if scope == .output { output.muted = muted } else { input.muted = muted }
    }

    func setBalance(_ value: Float) {
        AudioDevice.setBalance(value, of: defaultOutputID, scope: .output)
        output.balance = value
    }

    func setSampleRate(_ rate: Double, scope: AudioScope) {
        let id = scope == .output ? defaultOutputID : defaultInputID
        AudioDevice.setSampleRate(rate, of: id)
    }
}
