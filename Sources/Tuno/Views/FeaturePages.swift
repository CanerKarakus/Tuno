import SwiftUI

// MARK: - Ses aygıtı öncelik kuralları (Çıkış / Giriş sayfaları)

struct DevicePrioritySection: View {
    let scope: AudioScope
    @Environment(DeviceStore.self) private var devices

    private var rules: DeviceRuleSet { devices.rules.rules(scope) }
    private var present: Set<String> {
        Set((scope == .output ? devices.outputDevices : devices.inputDevices).map(\.uid))
    }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { rules.isEnabled },
                                 set: { devices.rules.setEnabled($0, scope: scope) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Öncelik sırasına göre otomatik geç")
                    Text(scope == .output
                         ? "Bir aygıt takıldığında ya da çıkarıldığında listedeki ilk uygun aygıta geçilir."
                         : "Ör. AirPods mikrofonunu engelleyin: ses kalitesi düşmez, MacBook mikrofonu kullanılır.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if rules.isEnabled {
                ForEach(Array(rules.order.enumerated()), id: \.element.uid) { index, device in
                    PriorityRow(device: device, rank: index + 1, isPresent: present.contains(device.uid),
                                isBlocked: rules.blocked.contains(device.uid), isFirst: index == 0,
                                isLast: index == rules.order.count - 1, scope: scope)
                }
            }
        } header: {
            Text("Otomatik Geçiş")
        } footer: {
            if rules.isEnabled {
                Text("Engellenen aygıta macOS kendiliğinden geçerse Tuno geri alır. Bir aygıtı Tuno'dan elle seçerseniz, bir sonraki takma/çıkarmaya kadar seçiminize dokunulmaz.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct PriorityRow: View {
    let device: KnownDevice
    let rank: Int
    let isPresent: Bool
    let isBlocked: Bool
    let isFirst: Bool
    let isLast: Bool
    let scope: AudioScope
    @Environment(DeviceStore.self) private var devices

    var body: some View {
        HStack(spacing: 10) {
            Text("\(rank)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Image(systemName: device.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).strikethrough(isBlocked, color: .secondary)
                Text(isPresent ? device.transport : "\(device.transport) · bağlı değil")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .opacity(isPresent ? 1 : 0.55)
            Spacer()
            Button {
                devices.rules.setBlocked(!isBlocked, uid: device.uid, scope: scope)
            } label: {
                Image(systemName: isBlocked ? "nosign" : "checkmark.circle")
                    .foregroundStyle(isBlocked ? Color.red : .secondary)
            }
            .buttonStyle(.borderless)
            .help(isBlocked ? "Engeli kaldır" : "Asla otomatik seçme")
            Button { devices.rules.move(device.uid, by: -1, scope: scope) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).disabled(isFirst).help("Yukarı taşı")
            Button { devices.rules.move(device.uid, by: 1, scope: scope) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).disabled(isLast).help("Aşağı taşı")
            if !isPresent {
                Button { devices.rules.forget(device.uid, scope: scope) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Listeden kaldır")
            }
        }
    }
}

// MARK: - Ekranlar

struct DisplaysView: View {
    @Environment(DisplayController.self) private var displays
    @Environment(ShortcutCenter.self) private var shortcuts

    var body: some View {
        @Bindable var displays = displays
        Form {
            if displays.displays.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "display").font(.largeTitle).foregroundStyle(.tertiary)
                        Text("Bağlı harici ekran yok").foregroundStyle(.secondary)
                        Text("Bir monitör bağladığınızda parlaklığını buradan ve klavyeden ayarlayabilirsiniz.")
                            .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            } else {
                Section("Parlaklık") {
                    ForEach(displays.displays) { display in
                        LabeledContent {
                            HStack {
                                VolumeSlider(
                                    value: Binding(get: { Float(display.brightness) },
                                                   set: { displays.setBrightness(Double($0), for: display.id) }),
                                    minSymbol: "sun.min.fill", maxSymbol: "sun.max.fill")
                                    .frame(width: 240)
                                Text(Float(display.brightness).percentText)
                                    .monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .trailing)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(display.name)
                                Text(display.supportsDDC ? "Donanımsal (DDC)" : "Yazılımsal karartma")
                                    .font(.caption)
                                    .foregroundStyle(display.supportsDDC ? Color.green : .orange)
                            }
                        }
                    }
                }
                Section("Çözünürlük") {
                    ForEach(displays.displays) { display in
                        LabeledContent(display.name) { ResolutionMenu(displayID: display.id) }
                    }
                }
            }

            Section {
                Toggle(isOn: $displays.brightnessKeysEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Parlaklık tuşları harici ekranı ayarlasın")
                        Text("İmleç hangi ekrandaysa parlaklık tuşları onu ayarlar; dahili ekranda her zamanki gibi çalışır. ⌥⇧ ile ince ayar.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if displays.brightnessKeysEnabled && !shortcuts.isAccessibilityTrusted {
                    HStack {
                        NoticeRow(symbol: "lock.fill", color: .orange,
                                  text: "Parlaklık tuşlarını yakalamak için Erişilebilirlik izni gerekiyor.")
                        Spacer()
                        Button("İzin Ver…") { shortcuts.requestAccessibility() }
                    }
                }
            } footer: {
                Text("Donanımsal ayar monitörün kendi parlaklığını değiştirir (Apple Silicon, DDC/CI destekleyen monitörler). Desteklemeyen ekranlar ve bazı HDMI bağlantıları yazılımsal olarak karartılır.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { displays.refresh() }
    }
}

// MARK: - Pencereler (Alt-Tab, Dock önizlemesi)

struct WindowsView: View {
    @Environment(ShortcutCenter.self) private var shortcuts
    @Environment(DockPreviews.self) private var dock
    @Environment(Permissions.self) private var permissions
    @Environment(WindowSnapper.self) private var snapper
    @Environment(CloseButtonQuitter.self) private var closeQuitter
    @AppStorage(WindowSwitcher.showThumbnailsKey) private var thumbnails = true
    @State private var switcherEnabled = true

    /// Pencere özellikleri Ekran Kaydı ve Erişilebilirlik izni olmadan hiç çalışmaz.
    private var available: Bool {
        permissions.status(.screenRecording) == .granted && permissions.status(.accessibility) == .granted
    }

    var body: some View {
        @Bindable var dock = dock
        @Bindable var snapper = snapper
        @Bindable var closeQuitter = closeQuitter
        Form {
            if !available {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "rectangle.dashed.badge.record").font(.title2).foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Pencere özellikleri için izin gerekiyor").font(.headline)
                                Text("Alt-Tab ve Dock önizlemesi, Ekran Kaydı ve Erişilebilirlik izni verilmeden çalışmaz.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            ForEach([PermissionKind.screenRecording, .accessibility]) { kind in
                                if permissions.status(kind) != .granted {
                                    Button("\(kind.title) İzni Ver…") { Task { await permissions.request(kind) } }
                                }
                            }
                            Spacer()
                            if permissions.screenRecordingNeedsRestart {
                                Button("Tuno'yu Yeniden Başlat") { permissions.relaunch() }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                        if permissions.screenRecordingNeedsRestart {
                            Text("Ekran Kaydı izni, verildikten sonra Tuno yeniden başlatılınca etkinleşir.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                Toggle(isOn: Binding(get: { switcherEnabled },
                                     set: { switcherEnabled = $0; shortcuts.setEnabled($0, for: .switchWindows) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pencereler arasında geçiş (Alt-Tab)")
                        Text("⌘ basılıyken ⇥ ile pencereler arasında gezinin, ⌘'yi bırakınca seçilen pencere öne gelir. ⇧ geri, Esc iptal. Yazmaya başlayınca pencereler süzülür, ↩ ile seçilir.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Pencere önizlemelerini göster", isOn: $thumbnails)
                    .disabled(!switcherEnabled)
            } header: {
                Text("Alt-Tab")
            }
            .disabled(!available)

            Section {
                Toggle(isOn: $dock.isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dock'ta pencere önizlemesi")
                        Text("İmleç Dock'taki bir uygulamanın üzerinde beklerken açık pencereleri gösterilir; tıklayınca o pencere öne gelir.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Dock")
            }
            .disabled(!available)

            Section {
                Toggle(isOn: $snapper.isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Kenara sürükleyerek yerleştir")
                        Text("Pencereyi ekranın sol ya da sağ kenarına sürükleyince yarım, köşesine sürükleyince çeyrek, üst kenarına sürükleyince tam ekrana yerleşir. Açıkken macOS'un kendi kenar döşemesi kapatılır.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $snapper.doubleClickMaximize) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Başlığa çift tıklayınca ekranı kapla")
                        Text("Tekrar çift tıklayınca pencere eski boyutuna döner.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Yerleştirme")
            } footer: {
                Text("Kısayollar ⌃⌥⌘ ile: ← → yarım, ↑ tam ekran, ↓ ortala, ⇧↑ ⇧↓ üst ve alt yarı, D F G üçte bir, E T üçte iki. Tümü Klavye Kısayolları sayfasında.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(permissions.status(.accessibility) != .granted)

            Section {
                Toggle(isOn: $closeQuitter.isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Son pencere kapanınca uygulamayı kapat")
                        Text("Kırmızı düğmeyle bir uygulamanın son penceresi kapatılınca uygulama da tamamen kapanır. Finder hariç.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Kapatma")
            }
            .disabled(permissions.status(.accessibility) != .granted)
        }
        .formStyle(.grouped)
        .onAppear {
            switcherEnabled = shortcuts.isEnabled(.switchWindows)
            permissions.refresh()
        }
    }
}

// MARK: - Pano geçmişi

struct ClipboardSettingsView: View {
    @Environment(ClipboardHistory.self) private var clipboard
    @Environment(ShortcutCenter.self) private var shortcuts
    @State private var shortcutEnabled = true
    @State private var confirmClear = false

    var body: some View {
        @Bindable var clipboard = clipboard
        Form {
            Section {
                Toggle(isOn: $clipboard.isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pano geçmişini kaydet")
                        Text("Kopyaladığınız metin, görsel ve dosyalar saklanır. Parola yöneticilerinin gizli işaretlediği içerikler kaydedilmez.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: Binding(get: { shortcutEnabled },
                                     set: { shortcutEnabled = $0; shortcuts.setEnabled($0, for: .clipboardHistory) })) {
                    HStack {
                        Text("⌘⇧V ile göster")
                        Spacer()
                    }
                }
                .disabled(!clipboard.isEnabled)
                Picker("Saklanacak öğe sayısı", selection: $clipboard.limit) {
                    ForEach([25, 50, 100, 200], id: \.self) { Text("\($0)").tag($0) }
                }
                .disabled(!clipboard.isEnabled)
            } footer: {
                Text("⌘⇧V'ye basınca menü çubuğundaki Tuno paneli geçmişle açılır: yazarak arayın, ↑↓ ile seçin, ↩ ile yapıştırın. Metin ve dosya kayıtları bu Mac'te saklanır; görseller yalnızca Tuno açıkken tutulur.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Kayıtlı öğe") { Text("\(clipboard.items.count)").foregroundStyle(.secondary) }
                LabeledContent("Geçmiş") {
                    Button("Temizle…", role: .destructive) { confirmClear = true }
                        .disabled(clipboard.items.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { shortcutEnabled = shortcuts.isEnabled(.clipboardHistory) }
        .confirmationDialog("Pano geçmişi silinsin mi?", isPresented: $confirmClear) {
            Button("Sil", role: .destructive) { clipboard.clear() }
        }
    }
}

// MARK: - Finder

struct FinderView: View {
    @Environment(FinderCutPaste.self) private var finder
    @Environment(Permissions.self) private var permissions

    var body: some View {
        @Bindable var finder = finder
        Form {
            if permissions.status(.accessibility) != .granted {
                Section {
                    HStack {
                        NoticeRow(symbol: "lock.fill", color: .orange,
                                  text: "Finder kısayolları için Erişilebilirlik izni gerekiyor.")
                        Spacer()
                        Button("İzin Ver…") { Task { await permissions.request(.accessibility) } }
                    }
                }
            }
            Section {
                Toggle(isOn: $finder.isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("⌘X ile kes, ⌘V ile taşı")
                        Text("Kesilen dosyalar yapıştırıldıkları yere taşınır. Dosya adı düzenlenirken metin için her zamanki gibi çalışır.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $finder.deleteToTrash) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Delete ile çöpe at")
                        Text("Klavyedeki Delete (ya da fn ⌫) seçili dosyaları çöpe atar.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $finder.enterOpens) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enter ile aç, F2 ile yeniden adlandır")
                        Text("Enter seçili dosyayı ya da klasörü açar. Ad düzenlenirken ve iletişim kutularında Enter her zamanki gibi çalışır.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(permissions.status(.accessibility) != .granted)
        }
        .formStyle(.grouped)
    }
}
