import SwiftUI

struct ShortcutsView: View {
    @Environment(ShortcutCenter.self) private var shortcuts
    @Environment(Mixer.self) private var mixer
    @Environment(KeyboardIndicator.self) private var indicator

    var body: some View {
        @Bindable var shortcuts = shortcuts
        @Bindable var indicator = indicator
        Form {
            Section { PageHeader(page: .shortcuts) }
            Section {
                Toggle(isOn: $indicator.isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Caps Lock ve klavye dili göstergesi"))
                        Text(L("Caps Lock ve klavye dili değişince kısa bir gösterge çıkar."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }.searchAnchor("Caps Lock ve klavye dili göstergesi")
            }

            Section {
                ForEach(Shortcut.listed) { shortcut in
                    ShortcutRow(shortcut: shortcut)
                }
            } header: {
                Text(L("Genel Kısayollar"))
            } footer: {
                Text(L("Kısayollar her uygulamadayken çalışır. \"Öndeki uygulama\", o an kullandığınız uygulamadır (ör. Safari'deyken Safari)."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $shortcuts.mediaKeysEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Ses tuşlarını yazılımsal ses için kullan"))
                        Text(L("HDMI ve DisplayPort ekranlarda ses tuşları Tuno'nun sesini ayarlar."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }.searchAnchor("Ses tuşlarını yazılımsal ses için kullan")

                if shortcuts.mediaKeysEnabled && !shortcuts.isAccessibilityTrusted {
                    HStack {
                        NoticeRow(symbol: "lock.fill", color: .orange,
                                  text: L("Ses tuşlarını yakalamak için Erişilebilirlik izni gerekiyor."))
                        Spacer()
                        Button(L("İzin Ver…")) { shortcuts.requestAccessibility() }
                    }
                } else if shortcuts.mediaKeysEnabled {
                    NoticeRow(symbol: "checkmark.circle.fill", color: .green,
                              text: mixer.defaultUsesSoftwareVolume
                                ? L("Etkin: ses tuşları şu anki aygıtın yazılımsal sesini ayarlıyor.")
                                : L("Hazır: donanım sesi olan aygıtlarda ses tuşları her zamanki gibi çalışır."))
                }
            } header: {
                Text(L("Klavye Ses Tuşları"))
            }
            PageFooter()
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutRow: View {
    let shortcut: Shortcut
    @Environment(ShortcutCenter.self) private var shortcuts

    var body: some View {
        let enabled = shortcuts.isEnabled(shortcut)
        HStack {
            Toggle(shortcut.title, isOn: Binding(
                get: { enabled },
                set: { shortcuts.setEnabled($0, for: shortcut) }))
                .toggleStyle(.checkbox)
            Spacer()
            HStack(spacing: 3) {
                ForEach(shortcut.keys, id: \.self) { key in
                    KeyCap(key)
                }
            }
            .opacity(enabled ? 1 : 0.4)
        }
    }
}

private struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .frame(minWidth: 22, minHeight: 22)
            .padding(.horizontal, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
                    .shadow(color: .black.opacity(0.15), radius: 0, y: 1))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1)))
    }
}
