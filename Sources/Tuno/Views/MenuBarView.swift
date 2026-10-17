import SwiftUI

/// Menü çubuğundan açılan, Denetim Merkezi tarzı kompakt mikser.
struct MenuBarView: View {
    @Environment(Mixer.self) private var mixer
    @Environment(DeviceStore.self) private var devices
    @Environment(\.menuActions) private var actions
    @Environment(PanelState.self) private var panelState
    @Environment(ClipboardHistory.self) private var clipboard
    @Environment(DisplayController.self) private var displays
    @Environment(HeadphoneBattery.self) private var battery
    @State private var confirmingQuit = false

    var body: some View {
        VStack(spacing: 10) {
            header
            if confirmingQuit {
                QuitConfirmation(
                    onCancel: { withAnimation(.snappy(duration: 0.25)) { confirmingQuit = false } },
                    onQuit: { NSApp.terminate(nil) })
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
            OutputModule()
            QuickTogglesModule()
            if !battery.devices.isEmpty {
                BatteryModule()
            }
            if !displays.displays.isEmpty {
                DisplaysModule()
            }
            EqualizerModule()
            AppsModule()
        }
        .padding(12)
        .frame(width: 340)
        .onReceive(NotificationCenter.default.publisher(for: .tunoPanelWillOpen)) { _ in
            confirmingQuit = false
            battery.refresh()
        }
        .onChange(of: devices.defaultOutputID) { battery.refresh(force: true) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            TunoIcon(size: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text("Tuno").font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HeaderButton(symbol: "power", help: "Tuno'dan Çık", isActive: confirmingQuit) {
                withAnimation(.snappy(duration: 0.25)) { confirmingQuit.toggle() }
            }
            if clipboard.isEnabled {
                HeaderButton(symbol: "doc.on.clipboard", help: "Pano Geçmişi (⌘⇧V)") {
                    withAnimation(.snappy(duration: 0.25)) { panelState.mode = .clipboard }
                }
            }
            HeaderButton(symbol: "gearshape.fill", help: "Tuno Ayarları") {
                actions.openSettings()
            }
        }
        .padding(.horizontal, 4)
    }

    private var summary: String {
        let playing = mixer.apps.filter(\.isPlaying).count
        return playing == 0 ? "Sessiz" : "\(playing) uygulama ses çalıyor"
    }
}

/// Paneldeki çıkış onayı.
private struct QuitConfirmation: View {
    let onCancel: () -> Void
    let onQuit: () -> Void

    var body: some View {
        Module {
            HStack(spacing: 10) {
                Image(systemName: "power.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white, .red)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Tuno'dan çıkılsın mı?").font(.system(size: 13, weight: .semibold))
                    Text("Uygulama sesleri ve ekolayzer varsayılana döner.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Button(action: onCancel) {
                    Text("Vazgeç").frame(maxWidth: .infinity)
                }
                .buttonStyle(PanelButtonStyle(fill: Color.primary.opacity(0.1), foreground: .primary))
                .keyboardShortcut(.cancelAction)
                Button(action: onQuit) {
                    Text("Çık").frame(maxWidth: .infinity)
                }
                .buttonStyle(PanelButtonStyle(fill: .red, foreground: .white))
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct PanelButtonStyle: ButtonStyle {
    let fill: Color
    let foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.vertical, 6)
            .background(fill.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
            .contentShape(Capsule())
    }
}

private struct HeaderButton: View {
    let symbol: String
    let help: String
    var isActive = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isActive ? Color.white : .secondary)
                .frame(width: 28, height: 28)
                .background(
                    isActive ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.14 : 0.08)),
                    in: Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

extension Notification.Name {
    static let tunoPanelWillOpen = Notification.Name("app.tuno.panelWillOpen")
}

// MARK: - Modüller

private struct Module<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
    }
}

private struct ModuleTitle: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
    }
}

private struct OutputModule: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(Mixer.self) private var mixer
    @State private var showDevices = false

    var body: some View {
        Module {
            let output = DefaultOutputVolume(devices: devices, mixer: mixer)
            let volume = output.volume
            ModuleTitle(title: output.isSoftware ? "Ses · Yazılımsal" : "Ses",
                        trailing: output.isAvailable ? (output.muted ? "Sessiz" : volume.percentText) : nil)

            if output.isAvailable {
                CapsuleSlider(
                    value: Binding(get: { volume }, set: { output.setVolume($0) }),
                    symbol: speakerSymbol(volume: volume, muted: output.muted),
                    isDimmed: output.muted)
                    .onTapGesture(count: 2) { output.toggleMute() }
            } else {
                Label("Bu aygıt ses denetimini desteklemiyor", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                withAnimation(.snappy(duration: 0.25)) { showDevices.toggle() }
            } label: {
                HStack(spacing: 8) {
                    DeviceBadge(symbol: devices.defaultOutput?.symbolName(for: .output) ?? "hifispeaker",
                                isSelected: true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(devices.defaultOutput?.name ?? "Çıkış yok")
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text(devices.defaultOutput?.transportLabel ?? "")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showDevices ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showDevices {
                VStack(spacing: 2) {
                    ForEach(devices.outputDevices.filter { $0.id != devices.defaultOutputID }) { device in
                        HoverRow {
                            devices.setDefault(device, scope: .output)
                        } content: {
                            DeviceBadge(symbol: device.symbolName(for: .output), isSelected: false)
                            Text(device.name).font(.system(size: 12)).lineLimit(1)
                            Spacer()
                        }
                    }
                }
                // Açılırken yukarıdan kayarak belirir; kapanırken panel küçülmeden önce hızla söner.
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity.animation(.easeOut(duration: 0.1))))
            }
        }
    }
}

/// Harici ekranların parlaklığı.
private struct DisplaysModule: View {
    @Environment(DisplayController.self) private var displays

    var body: some View {
        Module {
            ModuleTitle(title: "Ekran Parlaklığı")
            ForEach(displays.displays) { display in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "display").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(display.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer()
                        Text(Float(display.brightness).percentText)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    CapsuleSlider(
                        value: Binding(get: { Float(display.brightness) },
                                       set: { displays.setBrightness(Double($0), for: display.id) }),
                        symbol: "sun.max.fill", height: 20)
                    ResolutionMenu(displayID: display.id)
                }
            }
        }
    }
}

/// Ekran çözünürlüğü seçimi (menü çubuğu paneli ve Ekranlar sayfası).
struct ResolutionMenu: View {
    let displayID: CGDirectDisplayID
    @Environment(DisplayController.self) private var displays
    @State private var current: DisplayModeOption?

    var body: some View {
        Menu {
            ForEach(displays.modes(for: displayID)) { option in
                Button {
                    displays.setMode(option, for: displayID)
                    current = displays.currentMode(for: displayID)
                } label: {
                    if option == current { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.expand.diagonal")
                Text(current?.title ?? "Çözünürlük")
            }
            .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.secondary)
        .onAppear { current = displays.currentMode(for: displayID) }
    }
}

/// Mikrofonu kapatma ve uyku engelleme düğmeleri. Uyanık Tut'un simgesine basınca süresiz açılır
/// ya da kapanır; geri kalanına basınca süre listesi panelin içinde açılır.
private struct QuickTogglesModule: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(KeepAwake.self) private var keepAwake
    @State private var showDurations = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                QuickTile(symbol: devices.microphoneMuted ? "mic.slash.fill" : "mic.fill",
                          title: "Mikrofon", subtitle: devices.microphoneMuted ? "Kapalı" : "Açık",
                          tint: devices.microphoneMuted ? .red : nil,
                          onIcon: { devices.setMicrophoneMuted(!devices.microphoneMuted) },
                          onBody: { devices.setMicrophoneMuted(!devices.microphoneMuted) })
                QuickTile(symbol: keepAwake.isActive ? "cup.and.heat.waves.fill" : "cup.and.saucer.fill",
                          title: "Uyanık Tut", subtitle: awakeSubtitle,
                          tint: keepAwake.isActive ? .orange : nil,
                          accessory: showDurations ? "chevron.up" : "chevron.down",
                          onIcon: { withAnimation(.snappy(duration: 0.25)) { keepAwake.toggle() } },
                          onBody: { withAnimation(.snappy(duration: 0.3)) { showDurations.toggle() } })
            }
            if showDurations {
                Module {
                    VStack(spacing: 2) {
                        ForEach(KeepAwake.durations, id: \.title) { duration in
                            let selected = keepAwake.isActive && keepAwake.minutes == duration.minutes
                            HoverRow {
                                withAnimation(.snappy(duration: 0.3)) {
                                    keepAwake.start(minutes: duration.minutes)
                                    showDurations = false
                                }
                            } content: {
                                Image(systemName: duration.minutes == nil ? "infinity" : "timer")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(selected ? Color.white : .secondary)
                                    .frame(width: 24, height: 24)
                                    .background(selected ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Color.primary.opacity(0.08)),
                                                in: Circle())
                                Text(duration.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                                Spacer()
                                if selected {
                                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.orange)
                                }
                            }
                        }
                        if keepAwake.isActive {
                            Divider().padding(.vertical, 4)
                            HoverRow {
                                withAnimation(.snappy(duration: 0.3)) {
                                    keepAwake.stop()
                                    showDurations = false
                                }
                            } content: {
                                Image(systemName: "moon.zzz.fill")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, height: 24)
                                    .background(Color.primary.opacity(0.08), in: Circle())
                                Text("Uykuya izin ver").font(.system(size: 12))
                                Spacer()
                            }
                        }
                    }
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.97, anchor: .top)),
                    removal: .opacity.animation(.easeOut(duration: 0.12))))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tunoPanelWillOpen)) { _ in showDurations = false }
    }

    private var awakeSubtitle: String {
        guard keepAwake.isActive else { return "Kapalı" }
        guard let end = keepAwake.endsAt else { return "Süresiz" }
        return end.formatted(date: .omitted, time: .shortened) + "'e kadar"
    }
}

/// Simgesi ve gövdesi ayrı ayrı tıklanabilen hızlı düğme.
private struct QuickTile: View {
    let symbol: String
    let title: String
    let subtitle: String
    let tint: Color?
    var accessory: String?
    let onIcon: () -> Void
    let onBody: () -> Void
    @State private var hovering = false
    @State private var hoveringIcon = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onIcon) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint == nil ? Color.primary : .white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28, height: 28)
                    .background(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(Color.primary.opacity(hoveringIcon ? 0.16 : 0.09)),
                                in: Circle())
                    .scaleEffect(hoveringIcon ? 1.06 : 1)
            }
            .buttonStyle(.plain)
            .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hoveringIcon = inside } }

            Button(action: onBody) {
                HStack(spacing: 4) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            .contentTransition(.opacity)
                    }
                    Spacer(minLength: 0)
                    if let accessory {
                        Image(systemName: accessory)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.primary.opacity(hovering ? 0.085 : 0.055)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
    }
}

/// Bağlı kulaklık ve hoparlörlerin pil düzeyleri.
private struct BatteryModule: View {
    @Environment(HeadphoneBattery.self) private var battery

    var body: some View {
        Module {
            ModuleTitle(title: "Pil")
            ForEach(battery.devices) { device in
                HStack(spacing: 8) {
                    Image(systemName: device.isHeadphones ? "headphones" : "hifispeaker.fill")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(device.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    ForEach(device.levels, id: \.label) { level in
                        HStack(spacing: 3) {
                            if !level.label.isEmpty {
                                Text(level.label).foregroundStyle(.secondary)
                            }
                            Image(systemName: Self.symbol(for: level.percent))
                                .foregroundStyle(level.percent <= 20 ? Color.red : .secondary)
                            Text("\(level.percent)%").monospacedDigit()
                        }
                        .font(.system(size: 11))
                    }
                }
            }
        }
    }

    private static func symbol(for percent: Int) -> String {
        switch percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

private struct EqualizerModule: View {
    @Environment(Equalizer.self) private var equalizer
    @Environment(DeviceStore.self) private var devices

    var body: some View {
        @Bindable var equalizer = equalizer
        Module {
            HStack(spacing: 10) {
                SettingsIcon(symbol: "slider.vertical.3", color: equalizer.isEnabled ? .purple : .gray, size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Ekolayzer").font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Menu {
                    ForEach(EQPreset.builtIn) { preset in
                        Button(preset.name) { equalizer.apply(preset) }
                    }
                    if !equalizer.userPresets.isEmpty {
                        Divider()
                        ForEach(equalizer.userPresets) { preset in
                            Button(preset.name) { equalizer.apply(preset) }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                Toggle("Ekolayzer", isOn: $equalizer.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
        }
    }

    private var subtitle: String {
        if let uid = devices.defaultOutput?.uid {
            switch equalizer.profile(for: uid) {
            case .off: return "Bu aygıtta kapalı"
            case .preset(let id): return "\(equalizer.preset(id: id)?.name ?? "Özel") · aygıt profili"
            case .global: break
            }
        }
        return equalizer.isEnabled ? equalizer.presetName : "Kapalı"
    }
}

private struct AppsModule: View {
    @Environment(Mixer.self) private var mixer

    var body: some View {
        Module {
            ModuleTitle(title: "Uygulamalar", trailing: mixer.apps.isEmpty ? nil : "\(mixer.apps.count)")

            if let error = mixer.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if mixer.apps.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "speaker.zzz")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("Ses çalan uygulama yok")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(mixer.apps) { app in
                            MenuAppRow(app: app)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: mixer.apps.count <= 4)
            }
        }
    }
}

private struct MenuAppRow: View {
    let app: AudioApp
    @Environment(Mixer.self) private var mixer
    @AppStorage(PreferenceKey.maxBoost) private var maxBoost = 1.5

    var body: some View {
        let settings = mixer.settings(for: app)
        let boosted = settings.volume > 1.001

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { mixer.toggleMute(app) } label: {
                    Image(nsImage: app.icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                        .saturation(settings.muted ? 0 : 1)
                        .opacity(settings.muted ? 0.5 : 1)
                        .overlay(alignment: .bottomTrailing) {
                            if settings.muted {
                                Image(systemName: "speaker.slash.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white, .red)
                                    .offset(x: 3, y: 3)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(settings.muted ? "Sesi Aç" : "Sessize Al")

                Text(app.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                if app.isPlaying && !settings.muted {
                    Image(systemName: "waveform")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.green)
                        .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
                }

                Spacer(minLength: 4)

                Text(settings.muted ? "Sessiz" : settings.volume.percentText)
                    .font(.system(size: 11, weight: boosted ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(settings.muted ? Color.secondary : BoostStyle.color(for: settings.volume) ?? .secondary)
                    .contentTransition(.numericText())

                AppOutputMenu(app: app)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            CapsuleSlider(
                value: Binding(
                    get: { settings.volume },
                    set: { mixer.setVolume($0.snappedToUnity, for: app) }),
                range: 0...Float(max(maxBoost, 1)),
                marker: maxBoost > 1 ? 1 : nil,
                isDimmed: settings.muted,
                height: 16)
        }
        .contextMenu {
            Button(settings.muted ? "Sesi Aç" : "Sessize Al") { mixer.toggleMute(app) }
            Button("Varsayılana Döndür") { mixer.reset(app) }
        }
    }
}

// MARK: - Küçük bileşenler

private struct DeviceBadge: View {
    let symbol: String
    let isSelected: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isSelected ? Color.white : .primary)
            .frame(width: 26, height: 26)
            .background(isSelected ? Color.accentColor : Color.primary.opacity(0.09), in: Circle())
    }
}

private struct HoverRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) { content }
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
