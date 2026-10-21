import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Dynamic Island ayarları: aç/kapat, çalan müzik, zamanlayıcı ve alarm, çentikte görünen uygulamalar.
struct IslandSettingsView: View {
    @Environment(NotchIsland.self) private var island

    var body: some View {
        @Bindable var island = island
        Form {
            Section { PageHeader(page: .island) }
            if NotchIsland.notchedScreen == nil {
                Section {
                    NoticeRow(symbol: "info.circle.fill", color: .blue,
                              text: L("Bu Mac'in ekranında çentik yok. Dynamic Island yalnızca çentikli ekranlarda görünür."))
                }
            }
            Section {
                Toggle(isOn: $island.isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Dynamic Island"))
                        Text(L("Çentiğin üzerine gelince açılır; boştayken görünmez."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.searchAnchor("Dynamic Island")
                Toggle(isOn: $island.showsMusic) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Çalan müziği göster"))
                        Text(L("Spotify ya da Müzik arka plandayken kapak ve ses dalgası görünür; tıklayınca oynatıcı açılır."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.searchAnchor("Çalan müziği göster")
                Toggle(isOn: $island.showsSiri) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Siri"))
                        Text(L("Siri açılınca çentikten sıvı cam bir damla akar; ışığı sesle oynar, cevabı içinde yazar."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.searchAnchor("Siri")
            }
            .disabled(NotchIsland.notchedScreen == nil)

            Section {
                Toggle(isOn: Binding(get: { island.transfersEnabled }, set: { island.setTransfers($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("İndirmeler ve AirDrop"))
                        Text(L("İndirme ve AirDrop ilerlemesi çentikte görünür. İndirilenler klasörü izni ister."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.searchAnchor("İndirmeler ve AirDrop")
                Toggle(isOn: Binding(get: { island.seekEnabled }, set: { island.setSeek($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Spotify'da ileri ve geri sarma"))
                        Text(L("Oynatıcıdaki çubukla şarkıda gezinilir. Spotify'ı denetleme izni ister."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.searchAnchor("Spotify'da ileri ve geri sarma")
            } header: {
                Text(L("İzin Gerektirenler"))
            }
            .disabled(NotchIsland.notchedScreen == nil || !island.isEnabled)

            Section {
                ForEach(island.pinned, id: \.self) { url in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable().frame(width: 22, height: 22)
                        Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
                        Spacer()
                        Button { island.remove(url) } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .help(L("Kaldır"))
                    }
                }
                .onMove { island.move(from: $0, to: $1) }
                if island.pinned.isEmpty {
                    Text(L("Henüz uygulama yok.")).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button(L("Uygulama Ekle…"), action: addApps)
                        .disabled(island.pinned.count >= NotchIsland.maxPinned)
                }
            } header: {
                Text(L("Uygulamalar"))
            } footer: {
                Text(String(format: L("Çentiğin üzerine gelince iki yanında görünür. En çok %d uygulama; sürükleyerek sıralayın."),
                            NotchIsland.maxPinned))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .searchAnchor("Uygulamalar")
            .disabled(NotchIsland.notchedScreen == nil || !island.isEnabled)
            PageFooter()
        }
        .formStyle(.grouped)
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L("Ekle")
        guard panel.runModal() == .OK else { return }
        island.add(panel.urls)
    }
}
