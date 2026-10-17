import SwiftUI

struct ContentView: View {
    @State private var selection: Page? = .mixer
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(240)
        } detail: {
            detail
                .navigationTitle((selection ?? .mixer).title)
        }
        .onAppear { WindowOpener.action = openWindow }
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .mixer {
        case .mixer: MixerView()
        case .output: DeviceView(scope: .output)
        case .input: DeviceView(scope: .input)
        case .equalizer: EqualizerView()
        case .pointer: PointerView()
        case .shortcuts: ShortcutsView()
        case .displays: DisplaysView()
        case .windows: WindowsView()
        case .finder: FinderView()
        case .clipboard: ClipboardSettingsView()
        case .battery: BatteryView()
        case .general: GeneralView()
        case .about: AboutView()
        }
    }
}

private struct Sidebar: View {
    @Binding var selection: Page?
    @Environment(DeviceStore.self) private var devices

    var body: some View {
        List(selection: $selection) {
            SidebarHeader(subtitle: devices.defaultOutput?.name ?? "Çıkış aygıtı yok")
                .selectionDisabled()
                .listRowSeparator(.hidden)
                .padding(.bottom, 6)

            Section {
                row(.mixer)
                row(.output)
                row(.input)
            }
            Section {
                row(.equalizer)
            }
            Section {
                row(.pointer)
                row(.shortcuts)
            }
            Section {
                row(.displays)
                row(.windows)
                row(.finder)
                row(.clipboard)
                if MacBattery.isAvailable { row(.battery) }
            }
            Section {
                row(.general)
                row(.about)
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ page: Page) -> some View {
        Label {
            Text(page.title)
        } icon: {
            SettingsIcon(symbol: page.symbol, color: page.tint, size: 22)
        }
        .tag(page)
    }
}

private struct SidebarHeader: View {
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            TunoIcon(size: 40)

            VStack(alignment: .leading, spacing: 1) {
                Text("Tuno").font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

extension Page {
    var tint: Color {
        switch self {
        case .mixer: .pink
        case .output: .blue
        case .input: .orange
        case .equalizer: .purple
        case .pointer: .teal
        case .shortcuts: .indigo
        case .displays: .yellow
        case .windows: .cyan
        case .finder: .blue
        case .clipboard: .brown
        case .battery: .green
        case .general, .about: .gray
        }
    }
}
