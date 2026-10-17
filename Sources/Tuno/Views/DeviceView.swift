import SwiftUI

/// Çıkış ve Giriş sayfaları.
struct DeviceView: View {
    let scope: AudioScope
    @Environment(DeviceStore.self) private var devices
    @Environment(Mixer.self) private var mixer
    @Environment(Equalizer.self) private var equalizer
    @Environment(InputMeter.self) private var meter

    private var list: [AudioDevice] { scope == .output ? devices.outputDevices : devices.inputDevices }
    private var current: AudioDevice? { scope == .output ? devices.defaultOutput : devices.defaultInput }
    private var controls: DeviceControls { scope == .output ? devices.output : devices.input }

    var body: some View {
        Form {
            Section(scope == .output ? "Çıkış Aygıtı" : "Giriş Aygıtı") {
                ForEach(list) { device in
                    DeviceRow(device: device, scope: scope, isSelected: device.id == current?.id) {
                        devices.setDefault(device, scope: scope)
                    }
                }
            }

            if let current {
                Section(current.name) {
                    if scope == .input {
                        InputLevelRow()
                    }
                    volumeRows
                    if scope == .output {
                        VolumeLimitRows(uid: current.uid)
                    } else {
                        Toggle(isOn: Binding(get: { devices.microphoneMuted },
                                             set: { devices.setMicrophoneMuted($0) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Mikrofonu kapat")
                                Text("Tüm giriş aygıtları susturulur; kapalıyken menü çubuğunda kırmızı mikrofon görünür. Kısayol: ⌃⌥⇧M")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if controls.sampleRates.count > 1 {
                        Picker("Örnekleme Hızı", selection: Binding(
                            get: { controls.sampleRate },
                            set: { devices.setSampleRate($0, scope: scope) }
                        )) {
                            ForEach(controls.sampleRates, id: \.self) { rate in
                                Text(rate.formatted(.number.precision(.fractionLength(0...1))
                                    .scale(0.001)) + " kHz").tag(rate)
                            }
                        }
                    } else if controls.sampleRate > 0 {
                        LabeledContent("Örnekleme Hızı",
                                       value: (controls.sampleRate / 1000).formatted() + " kHz")
                    }
                    if scope == .output {
                        Picker("Ekolayzer", selection: Binding(
                            get: { equalizer.profile(for: current.uid) },
                            set: { equalizer.setProfile($0, for: current.uid) }
                        )) {
                            Text("Genel ayar (\(equalizer.isEnabled ? equalizer.presetName : "Kapalı"))")
                                .tag(DeviceEQProfile.global)
                            Text("Kapalı").tag(DeviceEQProfile.off)
                            Divider()
                            ForEach(equalizer.allPresets) { preset in
                                Text(preset.name).tag(DeviceEQProfile.preset(preset.id))
                            }
                        }
                    }
                    LabeledContent("Bağlantı", value: current.transportLabel)
                    LabeledContent("Kanal",
                                   value: "\(scope == .output ? current.outputChannels : current.inputChannels)")
                }
            }

            DevicePrioritySection(scope: scope)

            if scope == .output {
                Section {
                    Picker("Uyarı ve sistem sesleri", selection: Binding(
                        get: { devices.systemOutputID },
                        set: { devices.setSystemOutput($0) }
                    )) {
                        ForEach(devices.outputDevices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                } footer: {
                    Text("Bildirim ve uyarı sesleri, müzik ve videolardan farklı bir aygıttan çalabilir.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var volumeRows: some View {
        if let volume = controls.volume, controls.canSetVolume {
            LabeledContent(scope == .output ? "Çıkış Düzeyi" : "Giriş Düzeyi") {
                HStack {
                    VolumeSlider(
                        value: Binding(get: { volume }, set: { devices.setVolume($0, scope: scope) }),
                        minSymbol: scope == .output ? "speaker.fill" : "mic",
                        maxSymbol: scope == .output ? "speaker.wave.3.fill" : "mic.fill")
                    Text(volume.percentText)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
        } else if scope == .output, let current, mixer.usesSoftwareVolume(current.uid) {
            let soft = mixer.softwareVolume(for: current.uid)
            LabeledContent {
                HStack {
                    VolumeSlider(value: Binding(
                        get: { soft.volume },
                        set: { mixer.setSoftwareVolume(SoftwareVolume(volume: $0, muted: false), for: current.uid) }))
                    Text(soft.volume.percentText)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Çıkış Düzeyi")
                    Text("Yazılımsal").font(.caption).foregroundStyle(.blue)
                }
            }
            Toggle("Sessiz", isOn: Binding(
                get: { soft.muted },
                set: { mixer.setSoftwareVolume(SoftwareVolume(volume: soft.volume, muted: $0), for: current.uid) }))
            NoticeRow(
                symbol: "info.circle.fill", color: .blue,
                text: "Bu aygıtın donanım ses denetimi yok (HDMI/DisplayPort'ta sık görülür). Ses Tuno tarafından yazılımsal olarak ayarlanıyor. Klavye ses tuşları için Klavye Kısayolları sayfasına bakın.")
        } else {
            NoticeRow(
                symbol: "info.circle.fill", color: .blue,
                text: scope == .output
                    ? "Bu aygıtın ses düzeyi ayarlanamıyor."
                    : "Bu aygıtın giriş düzeyi ayarlanamıyor.")
        }

        if controls.canMute {
            Toggle("Sessiz", isOn: Binding(
                get: { controls.muted },
                set: { devices.setMuted($0, scope: scope) }))
        }

        if scope == .output, let balance = controls.balance, controls.canSetBalance {
            LabeledContent("Denge") {
                HStack(spacing: 8) {
                    Text("Sol").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { balance }, set: { devices.setBalance(snapCenter($0)) }),
                           in: 0...1)
                    Text("Sağ").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func snapCenter(_ value: Float) -> Float {
        abs(value - 0.5) < 0.03 ? 0.5 : value
    }
}

/// Mikrofon testi: canlı seviye göstergesi.
private struct InputLevelRow: View {
    @Environment(InputMeter.self) private var meter
    @Environment(DeviceStore.self) private var devices

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Giriş Seviyesi") {
                HStack(spacing: 10) {
                    LevelMeter(level: meter.level, peak: meter.peak, isActive: meter.isRunning)
                        .frame(width: 220, height: 10)
                    Button(meter.isRunning ? "Durdur" : "Test Et") { meter.toggle() }
                }
            }
            if let error = meter.error {
                NoticeRow(symbol: "exclamationmark.triangle.fill", color: .orange, text: error)
            }
        }
        .onChange(of: devices.defaultInputID) { meter.restartIfRunning() }
        .onDisappear { meter.stop() }
    }
}

private struct LevelMeter: View {
    let level: Float
    let peak: Float
    let isActive: Bool
    private let segments = 24

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { index in
                let threshold = Float(index) / Float(segments)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color(for: index).opacity(level > threshold ? 1 : (isPeak(index) ? 0.8 : 0.15)))
            }
        }
        .opacity(isActive ? 1 : 0.5)
        .animation(.linear(duration: 0.08), value: level)
    }

    private func isPeak(_ index: Int) -> Bool {
        isActive && Int(peak * Float(segments)) == index
    }

    private func color(for index: Int) -> Color {
        let fraction = Double(index) / Double(segments)
        return fraction > 0.85 ? .red : fraction > 0.65 ? .yellow : .green
    }
}

/// Aygıtın ulaşabileceği en yüksek ses düzeyi.
private struct VolumeLimitRows: View {
    let uid: String
    @Environment(DeviceStore.self) private var devices

    var body: some View {
        let limit = devices.volumeLimit(for: uid)
        Toggle(isOn: Binding(get: { limit != nil }, set: { devices.setVolumeLimit($0 ? 0.7 : nil, for: uid) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ses sınırı")
                Text("Ses tuşlarıyla ya da uygulamalardan bu düzeyin üstüne çıkılamaz.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if let limit {
            LabeledContent("En yüksek düzey") {
                HStack {
                    VolumeSlider(value: Binding(get: { limit }, set: { devices.setVolumeLimit($0, for: uid) }))
                    Text(limit.percentText)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }
}
