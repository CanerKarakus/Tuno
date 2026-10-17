import SwiftUI

/// Varsayılan çıkışın ses düzeyi: aygıtın donanım sesi ya da (HDMI/DisplayPort gibi
/// donanım sesi olmayan aygıtlarda) Tuno'nun yazılımsal sesi.
@MainActor
struct DefaultOutputVolume {
    let devices: DeviceStore
    let mixer: Mixer

    private var uid: String? { devices.defaultOutput?.uid }
    var isSoftware: Bool { mixer.defaultUsesSoftwareVolume }
    var isAvailable: Bool { isSoftware || (devices.output.volume != nil && devices.output.canSetVolume) }

    private var software: SoftwareVolume { uid.map { mixer.softwareVolume(for: $0) } ?? SoftwareVolume() }

    var volume: Float { isSoftware ? software.volume : devices.output.volume ?? 0 }
    var muted: Bool { isSoftware ? software.muted : devices.output.muted }
    var canMute: Bool { isSoftware || devices.output.canMute }

    func setVolume(_ value: Float) {
        if isSoftware, let uid {
            mixer.setSoftwareVolume(SoftwareVolume(volume: value, muted: false), for: uid)
        } else {
            devices.setVolume(value, scope: .output)
        }
    }

    func toggleMute() {
        if isSoftware, let uid {
            var value = software
            value.muted.toggle()
            mixer.setSoftwareVolume(value, for: uid)
        } else {
            devices.setMuted(!devices.output.muted, scope: .output)
        }
    }
}
