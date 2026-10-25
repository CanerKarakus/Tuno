import SwiftUI

/// Aramada bulunabilen bir ayar: başlığı, açıklaması ve bulunduğu sayfa. Anahtarlar Türkçe metinlerdir
/// (`L()` ile çevrilir); `anchor` sayfadaki satırın kimliğidir (`.searchAnchor(_:)`).
struct SettingEntry: Hashable {
    let page: Page
    let title: String
    var hint: String?

    var anchor: String { title }

    static let all: [SettingEntry] = [
        .init(page: .mixer, title: "%100 üzerindeki değerler sesi yükseltir."),
        .init(page: .output, title: "Öncelik sırasına göre otomatik geç", hint: "Engellenen aygıta macOS geçerse Tuno geri alır."),
        .init(page: .output, title: "Ses sınırı", hint: "Ses tuşlarıyla ya da uygulamalardan bu düzeyin üstüne çıkılamaz."),
        .init(page: .output, title: "Uyarı ve sistem sesleri", hint: "Bildirim ve uyarı sesleri, müzik ve videolardan farklı bir aygıttan çalabilir."),
        .init(page: .input, title: "Mikrofonu kapat", hint: "Tüm mikrofonlar susturulur; menü çubuğunda kırmızı mikrofon görünür."),
        .init(page: .input, title: "Öncelik sırasına göre otomatik geç", hint: "Engellenen aygıta macOS geçerse Tuno geri alır."),
        .init(page: .equalizer, title: "Ekolayzer", hint: "Bantları sürükleyin, sıfırlamak için çift tıklayın."),
        .init(page: .pointer, title: "Yumuşak kaydırma"),
        .init(page: .pointer, title: "İşaretçi hızlandırmasını kapat", hint: "İmleç hızdan bağımsız hep aynı oranda gider. Trackpad etkilenmez."),
        .init(page: .pointer, title: "Üç parmakla dokunma: orta tık"),
        .init(page: .shortcuts, title: "Caps Lock ve klavye dili göstergesi", hint: "Caps Lock ve klavye dili değişince kısa bir gösterge çıkar."),
        .init(page: .shortcuts, title: "Ses tuşlarını yazılımsal ses için kullan", hint: "HDMI ve DisplayPort ekranlarda ses tuşları Tuno'nun sesini ayarlar."),
        .init(page: .displays, title: "Parlaklık tuşları harici ekranı ayarlasın", hint: "Parlaklık tuşları imlecin bulunduğu ekranı ayarlar. ⌥⇧ ile ince ayar."),
        .init(page: .windows, title: "Pencereler arasında geçiş (Alt-Tab)", hint: "⌘⇥ ile pencereler arasında gezinin, ⌘'yi bırakınca seçilen öne gelir. Yazarak süzün."),
        .init(page: .windows, title: "Pencere önizlemelerini göster"),
        .init(page: .windows, title: "Dock'ta pencere önizlemesi", hint: "Dock'ta bir uygulamanın üzerinde bekleyince pencereleri gösterilir."),
        .init(page: .windows, title: "Kenara sürükleyerek yerleştir", hint: "Kenara sürükleyince yarım, köşeye çeyrek, üste tam ekran yerleşir."),
        .init(page: .windows, title: "Başlığa çift tıklayınca ekranı kapla", hint: "Tekrar çift tıklayınca pencere eski boyutuna döner."),
        .init(page: .windows, title: "Son pencere kapanınca uygulamayı kapat", hint: "Son pencere kapanınca uygulama da kapanır (Finder hariç)."),
        .init(page: .island, title: "Dynamic Island", hint: "Çentiğin üzerine gelince açılır; boştayken görünmez."),
        .init(page: .island, title: "Çalan müziği göster", hint: "Spotify ya da Müzik arka plandayken kapak ve ses dalgası görünür; tıklayınca oynatıcı açılır."),
        .init(page: .island, title: "Siri", hint: "Siri açılınca çentikten sıvı cam bir damla akar; ışığı sesle oynar, cevabı içinde yazar."),
        .init(page: .island, title: "İndirmeler ve AirDrop", hint: "İndirme ve AirDrop ilerlemesi çentikte görünür. İndirilenler klasörü izni ister."),
        .init(page: .island, title: "Spotify'da ileri ve geri sarma", hint: "Oynatıcıdaki çubukla şarkıda gezinilir. Spotify'ı denetleme izni ister."),
        .init(page: .island, title: "Uygulamalar"),
        .init(page: .faceID, title: "Mac'in kilidini yüzle aç", hint: "Kilit ekranında çentikten tarar; Touch ID de çalışmaya devam eder."),
        .init(page: .faceID, title: "Uzaklaşınca kilitle", hint: "Klavye ve fare 30 saniye kullanılmazsa kamera bakar; kimse yoksa müzik durur ve ekran kilitlenir."),
        .init(page: .faceID, title: "Başkası bakarsa gizle", hint: "Arkanda tanınmayan biri belirince bildirimler ve pano gizlenir."),
        .init(page: .faceID, title: "Yüz Ekle…"),
        .init(page: .clipboard, title: "Pano geçmişini kaydet", hint: "Parola yöneticilerinin gizli işaretlediği içerikler kaydedilmez."),
        .init(page: .clipboard, title: "⌘⇧V ile göster", hint: "⌘⇧V ile geçmişi açın, yazarak arayın, ↩ ile yapıştırın. Görseller yalnızca Tuno açıkken tutulur."),
        .init(page: .clipboard, title: "Saklanacak öğe sayısı"),
        .init(page: .finder, title: "⌘X ile kes, ⌘V ile taşı", hint: "Kesilen dosyalar yapıştırıldıkları yere taşınır."),
        .init(page: .finder, title: "Delete ile çöpe at", hint: "Klavyedeki Delete (ya da fn ⌫) seçili dosyaları çöpe atar."),
        .init(page: .finder, title: "Enter ile aç, F2 ile yeniden adlandır", hint: "Enter seçili öğeyi açar; ad düzenlenirken her zamanki gibi çalışır."),
        .init(page: .general, title: "Uygulama dili"),
        .init(page: .general, title: "Girişte başlat"),
        .init(page: .general, title: "Menü çubuğunda göster", hint: "Pencereyi kapatsanız da ayarlarınız çalışmaya devam eder."),
        .init(page: .general, title: "Güncellemeleri otomatik denetle"),
        .init(page: .general, title: "Menü çubuğu simgelerini gizle", hint: "Gizlemek istediğin simgeleri ⌘ tuşuna basılı tutup çizginin soluna sürükle. Oka tıklayınca görünürler."),
        .init(page: .privacy, title: "Çökme raporları"),
        .init(page: .privacy, title: "Sistem Sesi Kaydı", hint: "Uygulama başına ses, ses yükseltme, ekolayzer ve HDMI ses denetimi. Ses kaydedilmez."),
        .init(page: .privacy, title: "Mikrofon", hint: "Giriş sayfasındaki mikrofon seviye testi."),
        .init(page: .privacy, title: "Erişilebilirlik", hint: "Kısayollar, fare tuşları ve kaydırma, orta tık, parlaklık tuşları, pencereleri öne getirme."),
        .init(page: .privacy, title: "Ekran Kaydı", hint: "Alt-Tab ve Dock pencere önizlemeleri. İzin verildikten sonra Tuno yeniden başlatılmalıdır."),
        .init(page: .about, title: "Geri Bildirim Gönder"),
        .init(page: .general, title: "En yüksek ses düzeyi"),
    ]
}

struct SearchResult: Identifiable {
    let page: Page
    let setting: SettingEntry?

    var id: String { "\(page.rawValue)|\(setting?.anchor ?? "")" }
    var title: String { setting.map { L($0.title) } ?? page.title }
}

/// Sayfalar (ad ve açıklama) ve ayarlar (başlık ve açıklama); büyük/küçük harf ve aksan duyarsız.
@MainActor
func SearchResults(query: String) -> [SearchResult] {
    let text = query.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return [] }
    func matches(_ value: String?) -> Bool { value.map { $0.localizedStandardContains(text) } ?? false }
    let pages = Page.allCases.filter { page in
        (page != .battery || MacBattery.isAvailable) && (page != .island || NotchIsland.notchedScreen != nil) && (matches(page.title) || matches(page.summary))
    }
    let settings = SettingEntry.all.filter { matches(L($0.title)) || matches($0.hint.map(L)) }
    return pages.map { SearchResult(page: $0, setting: nil) }
        + settings.map { SearchResult(page: $0.page, setting: $0) }
}

/// Aramadan açılan ayar; her seçim yeni bir değer olur, aynı ayar yeniden seçilince de vurgulanır.
struct SearchReveal: Equatable {
    let key: String
    let token = UUID()
}

extension EnvironmentValues {
    @Entry var searchReveal: SearchReveal?
}

extension View {
    /// Aramadan bu ayara gelinince satır kısa süre vurgulanır.
    func searchAnchor(_ key: String) -> some View { modifier(SearchAnchor(key: key)) }
}

private struct SearchAnchor: ViewModifier {
    let key: String
    @Environment(\.searchReveal) private var reveal
    @State private var lit = false

    func body(content: Content) -> some View {
        content
            .id(key)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(lit ? 0.18 : 0))
                    .strokeBorder(Color.accentColor.opacity(lit ? 0.7 : 0), lineWidth: 1.5)
                    .padding(-6)
            }
            .onAppear { flashIfNeeded(reveal) }
            .onChange(of: reveal) { _, new in flashIfNeeded(new) }
    }

    private func flashIfNeeded(_ reveal: SearchReveal?) {
        guard reveal?.key == key else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            withAnimation(.spring(duration: 0.35, bounce: 0.3)) { lit = true }
            try? await Task.sleep(for: .milliseconds(1600))
            withAnimation(.easeOut(duration: 0.8)) { lit = false }
        }
    }
}
