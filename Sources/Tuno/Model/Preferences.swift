import Foundation

enum PreferenceKey {
    static let showMenuBar = "showMenuBar"
    static let maxBoost = "maxBoost"
}

enum Page: String, CaseIterable, Identifiable, Hashable {
    case mixer, output, input, equalizer, pointer, shortcuts, displays, windows, finder, clipboard, battery, general, support, about

    var id: Self { self }

    var title: String {
        switch self {
        case .mixer: "Uygulama Sesleri"
        case .output: "Çıkış"
        case .input: "Giriş"
        case .equalizer: "Ekolayzer"
        case .pointer: "Fare ve Trackpad"
        case .shortcuts: "Klavye Kısayolları"
        case .displays: "Ekranlar"
        case .windows: "Pencereler"
        case .finder: "Finder"
        case .clipboard: "Pano Geçmişi"
        case .battery: "Pil"
        case .general: "Genel"
        case .support: "Destek"
        case .about: "Hakkında"
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
        case .support: "lifepreserver.fill"
        case .about: "info"
        }
    }
}
