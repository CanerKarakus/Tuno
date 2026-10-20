import SwiftUI

struct MixerView: View {
    @Environment(Mixer.self) private var mixer
    @Environment(DeviceStore.self) private var devices

    var body: some View {
        Form {
            Section { PageHeader(page: .mixer) }
            Section {
                MasterVolumeRow()
            }

            if let error = mixer.lastError {
                Section {
                    NoticeRow(symbol: "exclamationmark.triangle.fill", color: .orange, text: error)
                    Button(L("Gizlilik Ayarlarını Aç")) {
                        NSWorkspace.shared.open(URL(
                            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                    }
                }
            }

            Section {
                if mixer.apps.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 6) {
                            Image(systemName: "speaker.slash")
                                .font(.largeTitle)
                                .foregroundStyle(.tertiary)
                            Text(L("Şu anda ses çalan bir uygulama yok"))
                                .foregroundStyle(.secondary)
                            Text(L("Bir uygulama ses çalmaya başladığında burada görünür."))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 24)
                        Spacer()
                    }
                } else {
                    ForEach(mixer.apps) { app in
                        AppVolumeRow(app: app)
                    }
                }
            } header: {
                Text(L("Uygulamalar"))
            } footer: {
                Text(L("%100 üzerindeki değerler sesi yükseltir.")).searchAnchor("%100 üzerindeki değerler sesi yükseltir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            PageFooter()
        }
        .formStyle(.grouped)
        .onAppear { mixer.setPageVisible(true) }
        .onDisappear { mixer.setPageVisible(false) }
    }
}

/// Varsayılan çıkış aygıtının ana ses düzeyi (Windows mikserindeki "Hoparlörler" satırı).
struct MasterVolumeRow: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(Mixer.self) private var mixer

    var body: some View {
        let output = DefaultOutputVolume(devices: devices, mixer: mixer)
        let volume = output.volume
        LabeledContent {
            if output.isAvailable {
                HStack(spacing: 10) {
                    MuteButton(isMuted: output.muted) { output.toggleMute() }
                        .disabled(!output.canMute)
                    Slider(value: Binding(get: { volume }, set: { output.setVolume($0) }))
                        .frame(width: 220)
                    Text(volume.percentText)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                    Color.clear.frame(width: AppVolumeRow.menuWidth, height: 1)
                }
            } else {
                Text(L("Donanım ses denetimi yok"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } label: {
            HStack(spacing: 10) {
                SettingsIcon(symbol: devices.defaultOutput?.symbolName(for: .output) ?? "hifispeaker.fill",
                             color: .blue, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(devices.defaultOutput?.name ?? L("Çıkış aygıtı yok")).lineLimit(1)
                    Text(output.isSoftware ? L("Yazılımsal ses düzeyi") : L("Sistem ses düzeyi"))
                        .font(.caption)
                        .foregroundStyle(output.isSoftware ? Color.blue : .secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct AppVolumeRow: View {
    let app: AudioApp
    @Environment(Mixer.self) private var mixer
    @Environment(DeviceStore.self) private var devices
    @AppStorage(PreferenceKey.maxBoost) private var maxBoost = 1.5

    var body: some View {
        let settings = mixer.settings(for: app)
        LabeledContent {
            controls(settings)
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: app.icon).resizable().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).lineLimit(1)
                    statusLine(settings)
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu { Button(L("Varsayılana Döndür")) { mixer.reset(app) } }
    }

    static let menuWidth: CGFloat = 22

    private func controls(_ settings: AppAudioSettings) -> some View {
        HStack(spacing: 10) {
            MuteButton(isMuted: settings.muted) { mixer.toggleMute(app) }
            Slider(value: Binding(
                get: { settings.volume },
                set: { mixer.setVolume($0.snappedToUnity, for: app) }
            ), in: 0...Float(max(maxBoost, 1)))
            .frame(width: 220)
            .tint(BoostStyle.color(for: settings.volume))
            .opacity(settings.muted ? 0.45 : 1)
            Text(settings.volume.percentText)
                .monospacedDigit()
                .foregroundStyle(BoostStyle.color(for: settings.volume) ?? .secondary)
                .frame(width: 44, alignment: .trailing)
            AppOutputMenu(app: app)
                .frame(width: Self.menuWidth)
        }
    }

    private func statusLine(_ settings: AppAudioSettings) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(app.isPlaying ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(statusText(settings))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func statusText(_ settings: AppAudioSettings) -> String {
        if let uid = settings.outputUID, let device = devices.device(uid: uid) { return device.name }
        return app.isPlaying ? L("Çalıyor") : L("Beklemede")
    }
}

/// Uygulamanın çıkış aygıtını seçme menüsü.
struct AppOutputMenu: View {
    let app: AudioApp
    @Environment(Mixer.self) private var mixer
    @Environment(DeviceStore.self) private var devices

    var body: some View {
        let settings = mixer.settings(for: app)
        Menu {
            Picker(L("Çıkış"), selection: Binding(
                get: { settings.outputUID },
                set: { mixer.setOutput($0, for: app) }
            )) {
                Text(String(format: L("Sistem Varsayılanı (%@)"), devices.defaultOutput?.name ?? "—")).tag(String?.none)
                Divider()
                ForEach(devices.outputDevices) { device in
                    Text(device.name).tag(Optional(device.uid))
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button(L("Varsayılana Döndür")) { mixer.reset(app) }
        } label: {
            Image(systemName: settings.outputUID == nil ? "hifispeaker" : "hifispeaker.fill")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("Çıkış aygıtı"))
    }
}

struct MuteButton: View {
    let isMuted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .foregroundStyle(isMuted ? Color.red : .secondary)
                .frame(width: 20)
        }
        .buttonStyle(.borderless)
        .help(isMuted ? L("Sesi Aç") : L("Sessize Al"))
    }
}
