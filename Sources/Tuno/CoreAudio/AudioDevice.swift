import CoreAudio
import AudioToolbox

enum AudioScope {
    case output, input

    var coreAudio: AudioObjectPropertyScope {
        self == .output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput
    }
}

struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transportType: UInt32
    let outputChannels: Int
    let inputChannels: Int

    var hasOutput: Bool { outputChannels > 0 }
    var hasInput: Bool { inputChannels > 0 }

    init?(id: AudioObjectID) {
        guard let uid = id.readString(.init(kAudioDevicePropertyDeviceUID)) else { return nil }
        self.id = id
        self.uid = uid
        self.name = id.readString(.init(kAudioObjectPropertyName)) ?? L("Adsız Aygıt")
        self.transportType = id.read(.init(kAudioDevicePropertyTransportType), initial: UInt32(0)) ?? 0
        self.outputChannels = id.channelCount(scope: kAudioObjectPropertyScopeOutput)
        self.inputChannels = id.channelCount(scope: kAudioObjectPropertyScopeInput)
    }

    static func all() -> [AudioDevice] {
        AudioObjectID.system
            .readArray(.init(kAudioHardwarePropertyDevices), of: AudioObjectID.self)
            .compactMap(AudioDevice.init(id:))
            .filter { !$0.uid.hasPrefix(AudioTap.aggregateUIDPrefix) }
    }

    var transportLabel: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: L("Dahili")
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: L("Bluetooth")
        case kAudioDeviceTransportTypeUSB: L("USB")
        case kAudioDeviceTransportTypeHDMI: L("HDMI")
        case kAudioDeviceTransportTypeDisplayPort: L("DisplayPort")
        case kAudioDeviceTransportTypeAirPlay: L("AirPlay")
        case kAudioDeviceTransportTypeThunderbolt: L("Thunderbolt")
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: L("Birleşik")
        case kAudioDeviceTransportTypeVirtual: L("Sanal")
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless: L("Süreklilik")
        default: L("Harici")
        }
    }

    func symbolName(for scope: AudioScope) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("beats") || lower.contains("headphone") || lower.contains("kulaklık") {
            return "headphones"
        }
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return scope == .output ? "laptopcomputer" : "mic"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "display"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplay.audio"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate:
            return "waveform"
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless:
            return "iphone"
        default:
            return scope == .output ? "hifispeaker" : "mic"
        }
    }
}

/// Bir aygıtın kullanıcıya açılan denetimleri.
struct DeviceControls: Equatable {
    var volume: Float?
    var canSetVolume = false
    var muted = false
    var canMute = false
    var balance: Float?
    var canSetBalance = false
    var sampleRate: Double = 0
    var sampleRates: [Double] = []

    static let empty = DeviceControls()
}

extension AudioDevice {
    private static func volumeAddress(_ scope: AudioScope) -> AudioObjectPropertyAddress {
        .init(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope.coreAudio)
    }

    private static func muteAddress(_ scope: AudioScope) -> AudioObjectPropertyAddress {
        .init(kAudioDevicePropertyMute, scope.coreAudio)
    }

    private static func balanceAddress(_ scope: AudioScope) -> AudioObjectPropertyAddress {
        .init(kAudioHardwareServiceDeviceProperty_VirtualMainBalance, scope.coreAudio)
    }

    static func controls(of id: AudioObjectID, scope: AudioScope) -> DeviceControls {
        guard id.isValid else { return .empty }
        var c = DeviceControls()
        let volume = volumeAddress(scope)
        c.volume = id.read(volume, initial: Float32(0))
        c.canSetVolume = id.isSettable(volume)
        let mute = muteAddress(scope)
        c.muted = (id.read(mute, initial: UInt32(0)) ?? 0) != 0
        c.canMute = id.isSettable(mute)
        let balance = balanceAddress(scope)
        c.balance = id.read(balance, initial: Float32(0.5))
        c.canSetBalance = id.isSettable(balance)
        c.sampleRate = id.read(.init(kAudioDevicePropertyNominalSampleRate), initial: Float64(0)) ?? 0
        let ranges = id.readArray(
            .init(kAudioDevicePropertyAvailableNominalSampleRates), of: AudioValueRange.self)
        let common: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]
        c.sampleRates = Array(Set(ranges.flatMap { range in
            range.mMinimum == range.mMaximum
                ? [range.mMinimum]
                : common.filter { $0 >= range.mMinimum && $0 <= range.mMaximum }
        })).sorted()
        return c
    }

    static func setVolume(_ value: Float, of id: AudioObjectID, scope: AudioScope) {
        id.write(volumeAddress(scope), Float32(min(max(value, 0), 1)))
    }

    static func setMuted(_ muted: Bool, of id: AudioObjectID, scope: AudioScope) {
        id.write(muteAddress(scope), UInt32(muted ? 1 : 0))
    }

    static func setBalance(_ value: Float, of id: AudioObjectID, scope: AudioScope) {
        id.write(balanceAddress(scope), Float32(min(max(value, 0), 1)))
    }

    static func setSampleRate(_ rate: Double, of id: AudioObjectID) {
        id.write(.init(kAudioDevicePropertyNominalSampleRate), Float64(rate))
    }

    /// Ses düzeyi/sessiz/denge değişimlerini izlemek için adresler.
    static func observedAddresses(_ scope: AudioScope) -> [AudioObjectPropertyAddress] {
        [
            volumeAddress(scope), muteAddress(scope), balanceAddress(scope),
            .init(kAudioDevicePropertyNominalSampleRate),
        ]
    }
}
