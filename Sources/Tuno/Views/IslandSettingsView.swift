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
                Toggle(isOn: $island.alertsEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Sistem bildirimleri"))
                        Text(L("Pil azalınca, Düşük Güç Modu değişince, Bluetooth cihazı (klavye, fare, hoparlör) bağlanınca ve Wi-Fi ya da VPN değişince çentikte kısa bir bildirim görünür."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.searchAnchor("Sistem bildirimleri")
                Toggle(isOn: $island.shelfEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Dosya rafı"))
                        Text(L("Dosyayı çentiğe sürükleyince rafa girer; oradan başka uygulamaya sürüklenir. Raftaki dosya yalnızca “Link al”a basınca Tuno sunucusuna yüklenir (en çok 5 GB, 6 saat sonra silinir)."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.searchAnchor("Dosya rafı")
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
                Toggle(isOn: Binding(get: { island.focusEnabled }, set: { island.setFocus($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Odak modu"))
                        Text(L("Odak açılıp kapanınca çentikte kısa bir bildirim görünür. Odak durumu izni ister."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.searchAnchor("Odak modu")
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
            if NotchIsland.showsTestButtons {
                Section {
                    TestRow(title: L("Pil azaldı (%20)")) { island.signals.lowBattery(percent: 20) }
                    TestRow(title: L("Pil çok az (%10)")) { island.signals.lowBattery(percent: 10) }
                    TestRow(title: L("Düşük Güç Modu")) { island.signals.lowPowerMode(on: true) }
                    TestRow(title: L("Odak modu")) { island.signals.focusMode(on: true) }
                    TestRow(title: L("Bluetooth klavye")) { island.signals.bluetoothConnected(name: "Magic Keyboard", battery: 86) }
                    TestRow(title: L("Bluetooth fare")) { island.signals.bluetoothConnected(name: "Magic Mouse", battery: 64) }
                    TestRow(title: L("Wi-Fi bağlandı")) { island.signals.networkNotice(vpn: false, connected: true) }
                    TestRow(title: L("Wi-Fi koptu")) { island.signals.networkNotice(vpn: false, connected: false) }
                    TestRow(title: L("VPN bağlandı")) { island.signals.networkNotice(vpn: true, connected: true) }
                    TestRow(title: L("Dosya rafı")) { island.demoShelf() }
                    TestRow(title: L("AirPods")) { island.demoAirPods() }
                } header: {
                    Text(L("Dene"))
                }
                .disabled(NotchIsland.notchedScreen == nil || !island.isEnabled)
            }
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

/// Deneme satırı: düğmeye basınca ilgili bildirim adada örnek olarak görünür.
private struct TestRow: View {
    let title: String
    let action: () -> Void

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button(L("Dene"), action: action)
        }
    }
}
