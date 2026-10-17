import SwiftUI

struct ShortcutsView: View {
    @Environment(ShortcutCenter.self) private var shortcuts
    @Environment(Mixer.self) private var mixer
    @Environment(KeyboardIndicator.self) private var indicator

    var body: some View {
        @Bindable var shortcuts = shortcuts
        @Bindable var indicator = indicator
        Form {
            Section {
                Toggle(isOn: $indicator.isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Caps Lock ve klavye dili göstergesi")
                        Text("Caps Lock açılıp kapanınca ve klavye dili değişince ekranda kısa bir gösterge çıkar.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                ForEach(Shortcut.listed) { shortcut in
                    ShortcutRow(shortcut: shortcut)
                }
            } header: {
                Text("Genel Kısayollar")
            } footer: {
                Text("Kısayollar her uygulamadayken çalışır. \"Öndeki uygulama\", o an kullandığınız uygulamadır (ör. Safari'deyken Safari).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $shortcuts.mediaKeysEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ses tuşlarını yazılımsal ses için kullan")
                        Text("HDMI ve DisplayPort ekranlarda klavyenin ses tuşları Tuno'nun yazılımsal sesini ayarlar. ⌥⇧ ile ince ayar yapılır.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if shortcuts.mediaKeysEnabled && !shortcuts.isAccessibilityTrusted {
                    HStack {
                        NoticeRow(symbol: "lock.fill", color: .orange,
                                  text: "Ses tuşlarını yakalamak için Erişilebilirlik izni gerekiyor.")
                        Spacer()
                        Button("İzin Ver…") { shortcuts.requestAccessibility() }
                    }
                } else if shortcuts.mediaKeysEnabled {
                    NoticeRow(symbol: "checkmark.circle.fill", color: .green,
                              text: mixer.defaultUsesSoftwareVolume
                                ? "Etkin: ses tuşları şu anki aygıtın yazılımsal sesini ayarlıyor."
                                : "Hazır: donanım sesi olan aygıtlarda ses tuşları her zamanki gibi çalışır.")
                }
            } header: {
                Text("Klavye Ses Tuşları")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutRow: View {
    let shortcut: Shortcut
    @Environment(ShortcutCenter.self) private var shortcuts
    @State private var enabled = true

    var body: some View {
        HStack {
            Toggle(shortcut.title, isOn: Binding(
                get: { enabled },
                set: { enabled = $0; shortcuts.setEnabled($0, for: shortcut) }))
                .toggleStyle(.checkbox)
            Spacer()
            HStack(spacing: 3) {
                ForEach(shortcut.keys, id: \.self) { key in
                    KeyCap(key)
                }
            }
            .opacity(enabled ? 1 : 0.4)
        }
        .onAppear { enabled = shortcuts.isEnabled(shortcut) }
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
