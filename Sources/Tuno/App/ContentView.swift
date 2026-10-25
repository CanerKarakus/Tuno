import SwiftUI

struct ContentView: View {
    @State private var selection: Page? = .mixer
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var query = ""
    @State private var searching = false
    @State private var reveal: SearchReveal?
    @Environment(\.openWindow) private var openWindow
    @Environment(LanguageStore.self) private var language
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar(selection: $selection, query: query, open: open)
                .id(language.current)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(230)
        } detail: {
            detail
                .navigationTitle((selection ?? .mixer).title)
                // En küçük boyut yalnızca sağ sütunda: tüm pencereye verilince kenar çubuğu açılırken sağ taraf daralmıyor, takılıyordu.
                .frame(minWidth: 640, minHeight: 600)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        ToolbarSearch(text: $query, isOpen: $searching.animation(.spring(duration: 0.45, bounce: 0.3))) {
                            if columns == .detailOnly { withAnimation { columns = .all } }
                        } onSubmit: {
                            if let first = SearchResults(query: query).first { open(first) }
                        }
                    }
                }
        }
        .onAppear { WindowOpener.action = openWindow }
        .onReceive(NotificationCenter.default.publisher(for: .tunoOpenPage)) { note in
            if let page = note.object as? Page { selection = page }
        }
        // Dil seçilmeden ana pencere kullanılamaz (menü çubuğundan açılsa bile); seçim tek seferliktir.
        .overlay {
            if !language.isChosen || !theme.isChosen {
                SetupOverlay().transition(.opacity)
            }
        }
    }

    /// Arama sonucu: sayfayı açar, ayarsa o satıra kaydırıp vurgular.
    private func open(_ result: SearchResult) {
        selection = result.page
        reveal = result.setting.map { SearchReveal(key: $0.anchor) }
    }

    /// Dil değişince sayfa yeniden çizilir (sayfa seçimi korunur).
    @ViewBuilder private var detail: some View {
        ScrollViewReader { proxy in
            pageView
                .id(language.current)
                .environment(\.searchReveal, reveal)
                .task(id: reveal) {
                    guard let key = reveal?.key else { return }
                    try? await Task.sleep(for: .milliseconds(120))
                    withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(key, anchor: .center) }
                }
        }
    }

    @ViewBuilder private var pageView: some View {
        switch selection ?? .mixer {
        case .mixer: MixerView()
        case .output: DeviceView(scope: .output)
        case .input: DeviceView(scope: .input)
        case .equalizer: EqualizerView()
        case .pointer: PointerView()
        case .shortcuts: ShortcutsView()
        case .displays: DisplaysView()
        case .windows: WindowsView()
        case .island: IslandSettingsView()
        case .faceID: FaceIDSettingsView()
        case .finder: FinderView()
        case .clipboard: ClipboardSettingsView()
        case .battery: BatteryView()
        case .general: GeneralView()
        case .privacy: PrivacyView()
        case .support: SupportView()
        case .about: AboutView()
        }
    }
}

private struct Sidebar: View {
    @Binding var selection: Page?
    let query: String
    let open: (SearchResult) -> Void

    var body: some View {
        List(selection: $selection) {
            HStack(spacing: 8) {
                TunoWave(height: 18)
                Text("Tuno").font(.title2.weight(.bold))
            }
            .foregroundStyle(.primary)
            .selectionDisabled()
            .padding(.bottom, 4)
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                Section(L("Ses")) {
                    row(.mixer)
                    row(.output)
                    row(.input)
                    row(.equalizer)
                }
                Section(L("Fare ve Klavye")) {
                    row(.pointer)
                    row(.shortcuts)
                }
                Section(L("Araçlar")) {
                    row(.displays)
                    row(.windows)
                    if NotchIsland.notchedScreen != nil { row(.island) }
                    row(.faceID)
                    row(.finder)
                    row(.clipboard)
                    if MacBattery.isAvailable { row(.battery) }
                }
                Section("Tuno") {
                    row(.general)
                    row(.privacy)
                    row(.support)
                    row(.about)
                }
            } else {
                let results = SearchResults(query: query)
                if results.isEmpty {
                    Text(L("Sonuç yok")).foregroundStyle(.secondary)
                }
                ForEach(results) { result in
                    Button { open(result) } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(result.title).lineLimit(2)
                                if result.setting != nil {
                                    Text(result.page.title).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            if result.page == .island {
                                Image(nsImage: IslandSymbol.image(side: 16)).renderingMode(.template)
                            } else {
                                Image(systemName: result.page.sidebarSymbol)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ page: Page) -> some View {
        Group {
            if page == .island {
                Label { Text(page.title) } icon: { Image(nsImage: IslandSymbol.image(side: 16)).renderingMode(.template) }
            } else if page == .faceID {
                FaceIDSidebarLabel()
            } else {
                Label(page.title, systemImage: page.sidebarSymbol)
            }
        }
        .tag(page)
    }
}

/// Araç çubuğundaki arama: büyüteç düğmesi, basınca yaylı bir animasyonla kutuya açılır.
/// Boşken odak çıkınca ya da Esc ile kapanır.
private struct ToolbarSearch: View {
    @Binding var text: String
    @Binding var isOpen: Bool
    let onOpen: () -> Void
    let onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(isOpen ? .secondary : .primary)
            if isOpen {
                TextField(L("Ara"), text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .frame(width: 170)
                    .onSubmit(onSubmit)
                    .onExitCommand(perform: close)
                    .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .leading)))
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .opacity(text.isEmpty ? 0 : 1)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, isOpen ? 10 : 6)
        .frame(height: 28)
        .background {
            if isOpen { Capsule().fill(.quaternary.opacity(0.6)).transition(.opacity) }
        }
        .contentShape(.capsule)
        .onTapGesture { if !isOpen { open() } }
        .help(L("Ara"))
        .onChange(of: focused) { _, now in
            if !now && text.isEmpty { close() }
        }
    }

    private func open() {
        isOpen = true
        onOpen()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
    }

    private func close() {
        text = ""
        isOpen = false
    }
}

extension Page {
    /// Kenar çubuğunda sade (dolgusuz) sistem simgesi.
    var sidebarSymbol: String {
        self == .about ? "info.circle" : symbol.replacingOccurrences(of: ".fill", with: "")
    }

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
        case .island: .black
        case .faceID: .green
        case .finder: .blue
        case .clipboard: .brown
        case .battery: .green
        case .privacy: .blue
        case .support: .red
        case .general, .about: .gray
        }
    }
}
