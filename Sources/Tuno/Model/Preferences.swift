import Foundation

enum PreferenceKey {
    static let showMenuBar = "showMenuBar"
    static let maxBoost = "maxBoost"
}

enum Page: String, CaseIterable, Identifiable, Hashable {
    case mixer, output, input, equalizer, pointer, shortcuts, displays, windows, finder, clipboard, battery, general, privacy, support, about

    var id: Self { self }

    var title: String {
        switch self {
        case .mixer: L("Uygulama Sesleri")
        case .output: L("Çıkış")
        case .input: L("Giriş")
        case .equalizer: L("Ekolayzer")
        case .pointer: L("Fare ve Trackpad")
        case .shortcuts: L("Klavye Kısayolları")
        case .displays: L("Ekranlar")
        case .windows: L("Pencereler")
        case .finder: L("Finder")
        case .clipboard: L("Pano Geçmişi")
        case .battery: L("Pil")
        case .general: L("Genel")
        case .privacy: L("Gizlilik")
        case .support: L("Destek")
        case .about: L("Tuno Hakkında")
        }
    }

    var symbol: String {
        switch self {
        case .mixer: "slider.horizontal.3"
        case .output: "hifispeaker.fill"
        case .input: "mic.fill"
        case .equalizer: "slider.vertical.3"
        case .pointer: "computermouse.fill"
        case .shortcuts: "command"
        case .displays: "sun.max.fill"
        case .windows: "rectangle.on.rectangle"
        case .finder: "folder.fill"
        case .clipboard: "doc.on.clipboard.fill"
        case .battery: "battery.75percent"
        case .general: "gearshape.fill"
        case .privacy: "hand.raised.fill"
        case .support: "lifepreserver.fill"
        case .about: "info"
        }
    }
}

extension Page {
    /// Sayfa başlığının altındaki kısa açıklama.
    var summary: String {
        switch self {
        case .mixer: L("Uygulama başına ses ve çıkış.")
        case .output: L("Çıkış aygıtları ve ses düzeyi.")
        case .input: L("Mikrofon seçimi ve düzeyi.")
        case .equalizer: L("Sistem geneli 10 bantlı ekolayzer.")
        case .pointer: L("Kaydırma yönü, yumuşak kaydırma ve fare tuşları.")
        case .shortcuts: L("Ses, pencere ve pano kısayolları.")
        case .displays: L("Harici ekran parlaklığı ve çözünürlüğü.")
        case .windows: L("Alt-Tab, Dock önizlemesi ve yerleştirme.")
        case .finder: L("Kes, Enter ile aç, Delete ile sil.")
        case .clipboard: L("Pano geçmişi.")
        case .battery: L("Pil sağlığı ve şarj.")
        case .general: L("Dil, görünüm, açılış ve güncellemeler.")
        case .privacy: L("İzinler ve paylaşılan veriler.")
        case .support: L("Kullanıcı ID ve destek modu.")
        case .about: L("Sürüm, bağlantılar ve geri bildirim.")
        }
    }
}
