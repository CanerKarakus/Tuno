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
                    Text(L("Öncelik sırasına göre otomatik geç"))
                    Text(scope == .output
                         ? L("Bir aygıt takıldığında ya da çıkarıldığında listedeki ilk uygun aygıta geçilir.")
                         : L("Ör. AirPods mikrofonunu engelleyin: ses kalitesi düşmez, MacBook mikrofonu kullanılır."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.searchAnchor("Öncelik sırasına göre otomatik geç")
            if rules.isEnabled {
                ForEach(Array(rules.order.enumerated()), id: \.element.uid) { index, device in
                    PriorityRow(device: device, rank: index + 1, isPresent: present.contains(device.uid),
                                isBlocked: rules.blocked.contains(device.uid), isFirst: index == 0,
                                isLast: index == rules.order.count - 1, scope: scope)
                }
            }
        } header: {
            Text(L("Otomatik Geçiş"))
        } footer: {
            if rules.isEnabled {
                Text(L("Engellenen aygıta macOS geçerse Tuno geri alır."))
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
                Text(isPresent ? device.transport : String(format: L("%@ · bağlı değil"), device.transport))
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
            .help(isBlocked ? L("Engeli kaldır") : L("Asla otomatik seçme"))
            Button { devices.rules.move(device.uid, by: -1, scope: scope) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).disabled(isFirst).help(L("Yukarı taşı"))
            Button { devices.rules.move(device.uid, by: 1, scope: scope) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).disabled(isLast).help(L("Aşağı taşı"))
            if !isPresent {
                Button { devices.rules.forget(device.uid, scope: scope) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help(L("Listeden kaldır"))
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
            Section { PageHeader(page: .displays) }
            if displays.displays.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "display").font(.largeTitle).foregroundStyle(.tertiary)
                        Text(L("Bağlı harici ekran yok")).foregroundStyle(.secondary)
                        Text(L("Bir monitör bağladığınızda parlaklığını buradan ve klavyeden ayarlayabilirsiniz."))
                            .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            } else {
                Section(L("Parlaklık")) {
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
                                Text(display.supportsDDC ? L("Donanımsal (DDC)") : L("Yazılımsal karartma"))
                                    .font(.caption)
                                    .foregroundStyle(display.supportsDDC ? Color.green : .orange)
                            }
                        }
                    }
                }
                Section(L("Çözünürlük")) {
                    ForEach(displays.displays) { display in
                        LabeledContent(display.name) { ResolutionMenu(displayID: display.id) }
                    }
                }
            }

            Section {
                Toggle(isOn: $displays.brightnessKeysEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Parlaklık tuşları harici ekranı ayarlasın"))
                        Text(L("Parlaklık tuşları imlecin bulunduğu ekranı ayarlar. ⌥⇧ ile ince ayar."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.searchAnchor("Parlaklık tuşları harici ekranı ayarlasın")
                if displays.brightnessKeysEnabled && !shortcuts.isAccessibilityTrusted {
                    HStack {
                        NoticeRow(symbol: "lock.fill", color: .orange,
                                  text: L("Parlaklık tuşlarını yakalamak için Erişilebilirlik izni gerekiyor."))
                        Spacer()
                        Button(L("İzin Ver…")) { shortcuts.requestAccessibility() }
                    }
                }
            } footer: {
                Text(L("Donanımsal ayar monitörün kendi parlaklığını değiştirir (DDC/CI). Desteklemeyen ekranlar yazılımsal karartılır."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            PageFooter()
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

    /// Pencere özellikleri Ekran Kaydı ve Erişilebilirlik izni olmadan hiç çalışmaz.
    private var available: Bool {
        permissions.status(.screenRecording) == .granted && permissions.status(.accessibility) == .granted
    }

    var body: some View {
        @Bindable var dock = dock
        @Bindable var snapper = snapper
        @Bindable var closeQuitter = closeQuitter
        Form {
            Section { PageHeader(page: .windows) }
            if !available {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "rectangle.dashed.badge.record").font(.title2).foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("Pencere özellikleri için izin gerekiyor")).font(.headline)
                                Text(L("Alt-Tab ve Dock önizlemesi, Ekran Kaydı ve Erişilebilirlik izni verilmeden çalışmaz."))
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            ForEach([PermissionKind.screenRecording, .accessibility]) { kind in
                                if permissions.status(kind) != .granted {
                                    Button(String(format: L("%@ İzni Ver…"), kind.title)) { Task { await permissions.request(kind) } }
                                }
                            }
                            Spacer()
                            if permissions.screenRecordingNeedsRestart {
                                Button(L("Tuno'yu Yeniden Başlat")) { permissions.relaunch() }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                        if permissions.screenRecordingNeedsRestart {
                            Text(L("Ekran Kaydı izni, verildikten sonra Tuno yeniden başlatılınca etkinleşir."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                Toggle(isOn: Binding(get: { shortcuts.isEnabled(.switchWindows) },
                                     set: { shortcuts.setEnabled($0, for: .switchWindows) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Pencereler arasında geçiş (Alt-Tab)"))
                        Text(L("⌘⇥ ile pencereler arasında gezinin, ⌘'yi bırakınca seçilen öne gelir. Yazarak süzün."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.searchAnchor("Pencereler arasında geçiş (Alt-Tab)")
                Toggle(L("Pencere önizlemelerini göster"), isOn: $thumbnails).searchAnchor("Pencere önizlemelerini göster")
                    .disabled(!shortcuts.isEnabled(.switchWindows))
            } header: {
                Text("Alt-Tab")
            }
            .disabled(!available)

            Section {
                Toggle(isOn: $dock.isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Dock'ta pencere önizlemesi"))
                        Text(L("Dock'ta bir uygulamanın üzerinde bekleyince pencereleri gösterilir."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.searchAnchor("Dock'ta pencere önizlemesi")
            } header: {
                Text("Dock")
            }
            .disabled(!available)

            Section {
                Toggle(isOn: $snapper.isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Kenara sürükleyerek yerleştir"))
                        Text(L("Kenara sürükleyince yarım, köşeye çeyrek, üste tam ekran yerleşir."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.searchAnchor("Kenara sürükleyerek yerleştir")
                Toggle(isOn: $snapper.doubleClickMaximize) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Başlığa çift tıklayınca ekranı kapla"))
                        Text(L("Tekrar çift tıklayınca pencere eski boyutuna döner."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.searchAnchor("Başlığa çift tıklayınca ekranı kapla")
            } header: {
                Text(L("Yerleştirme"))
            } footer: {
                Text(L("⌃⌥⌘ ile ← → yarım, ↑ tam ekran, ↓ ortala. Tümü Klavye Kısayolları'nda."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(permissions.status(.accessibility) != .granted)

            Section {
                Toggle(isOn: $closeQuitter.isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Son pencere kapanınca uygulamayı kapat"))
                        Text(L("Son pencere kapanınca uygulama da kapanır (Finder hariç)."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.searchAnchor("Son pencere kapanınca uygulamayı kapat")
            } header: {
                Text(L("Kapatma"))
            }
            .disabled(permissions.status(.accessibility) != .granted)
            PageFooter()
        }
        .formStyle(.grouped)
        .onAppear { permissions.refresh() }
    }
}

// MARK: - Pano geçmişi

struct ClipboardSettingsView: View {
    @Environment(ClipboardHistory.self) private var clipboard
    @Environment(ShortcutCenter.self) private var shortcuts
    @State private var confirmClear = false

    var body: some View {
        @Bindable var clipboard = clipboard
        Form {
            Section { PageHeader(page: .clipboard) }
            Section {
                Toggle(isOn: $clipboard.isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Pano geçmişini kaydet"))
                        Text(L("Parola yöneticilerinin gizli işaretlediği içerikler kaydedilmez."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.searchAnchor("Pano geçmişini kaydet")
                Toggle(isOn: Binding(get: { shortcuts.isEnabled(.clipboardHistory) },
                                     set: { shortcuts.setEnabled($0, for: .clipboardHistory) })) {
                    HStack {
                        Text(L("⌘⇧V ile göster"))
                        Spacer()
                    }
                }.searchAnchor("⌘⇧V ile göster")
                .disabled(!clipboard.isEnabled)
                Picker(L("Saklanacak öğe sayısı"), selection: $clipboard.limit) {
                    ForEach([25, 50, 100, 200], id: \.self) { Text("\($0)").tag($0) }
                }.searchAnchor("Saklanacak öğe sayısı")
                .disabled(!clipboard.isEnabled)
            } footer: {
                Text(L("⌘⇧V ile geçmişi açın, yazarak arayın, ↩ ile yapıştırın. Görseller yalnızca Tuno açıkken tutulur."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent(L("Kayıtlı öğe")) { Text("\(clipboard.items.count)").foregroundStyle(.secondary) }
                LabeledContent(L("Geçmiş")) {
                    Button(L("Temizle…"), role: .destructive) { confirmClear = true }
                        .disabled(clipboard.items.isEmpty)
                }
            }
            PageFooter()
        }
        .formStyle(.grouped)
        .confirmationDialog(L("Pano geçmişi silinsin mi?"), isPresented: $confirmClear) {
            Button(L("Sil"), role: .destructive) { clipboard.clear() }
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
            Section { PageHeader(page: .finder) }
            if permissions.status(.accessibility) != .granted {
                Section {
                    HStack {
                        NoticeRow(symbol: "lock.fill", color: .orange,
                                  text: L("Finder kısayolları için Erişilebilirlik izni gerekiyor."))
                        Spacer()
                        Button(L("İzin Ver…")) { Task { await permissions.request(.accessibility) } }
                    }
                }
            }
            Section {
                Toggle(isOn: $finder.isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("⌘X ile kes, ⌘V ile taşı"))
                        Text(L("Kesilen dosyalar yapıştırıldıkları yere taşınır."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.searchAnchor("⌘X ile kes, ⌘V ile taşı")
                Toggle(isOn: $finder.deleteToTrash) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Delete ile çöpe at"))
                        Text(L("Klavyedeki Delete (ya da fn ⌫) seçili dosyaları çöpe atar."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.searchAnchor("Delete ile çöpe at")
                Toggle(isOn: $finder.enterOpens) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Enter ile aç, F2 ile yeniden adlandır"))
                        Text(L("Enter seçili öğeyi açar; ad düzenlenirken her zamanki gibi çalışır."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.searchAnchor("Enter ile aç, F2 ile yeniden adlandır")
            }
            .disabled(permissions.status(.accessibility) != .granted)
            PageFooter()
        }
        .formStyle(.grouped)
    }
}
