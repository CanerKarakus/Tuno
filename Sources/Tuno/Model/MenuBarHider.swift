import AppKit
import Observation

/// Menü çubuğu simgelerini gizleme. Tuno'nun simgesinin solunda bir ok ve ince bir ayraç durur; ⌘ ile ayraçın
/// soluna sürüklenen simgeler gizlenir, oka tıklayınca görünür. Gizliyken ayraç çok uzun olur ve solundaki
/// simgeleri ekranın dışına iter (çentikli Mac'lerde çentiğin arkasında kalan simgeler de böylece toparlanır).
/// Konumları macOS hatırlar.
@Observable
@MainActor
final class MenuBarHider {
    static let shared = MenuBarHider()

    private static let enabledKey = "menuBarHider"
    private static let autoKey = "menuBarHiderAuto"
    private static let hiddenLength: CGFloat = 10_000
    private static let autoDelay: TimeInterval = 10

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? install() : uninstall()
        }
    }
    /// Gösterildikten 10 sn sonra yeniden gizle.
    var autoHide: Bool {
        didSet { UserDefaults.standard.set(autoHide, forKey: Self.autoKey) }
    }
    private(set) var collapsed = true

    @ObservationIgnored private var toggle: NSStatusItem?
    @ObservationIgnored private var separator: NSStatusItem?
    @ObservationIgnored private var autoWork: DispatchWorkItem?

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        autoHide = UserDefaults.standard.bool(forKey: Self.autoKey, default: true)
    }

    /// Açılışta (Tuno'nun kendi simgesinden sonra) çağrılır: ok onun soluna, ayraç okun soluna yerleşir.
    func start() {
        if isEnabled { install() }
    }

    private func install() {
        guard toggle == nil else { return }
        let toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        toggle.autosaveName = "TunoHiderToggle"
        toggle.button?.target = self
        toggle.button?.action = #selector(toggleClicked)
        toggle.button?.toolTip = L("Gizli simgeleri göster ya da gizle")
        self.toggle = toggle

        let separator = NSStatusBar.system.statusItem(withLength: 10)
        separator.autosaveName = "TunoHiderSeparator"
        separator.button?.image = Self.separatorImage
        separator.button?.toolTip = L("Gizlemek istediğin simgeleri ⌘ tuşuna basılı tutup bu çizginin soluna sürükle.")
        self.separator = separator
        // İlk kurulumda simgeler yerleşebilsin diye önce açık başlar, sonra gizlenir.
        expand(schedule: true)
        SupportLog.log("menubar", "Simge gizleme açık")
    }

    private func uninstall() {
        autoWork?.cancel()
        if let toggle { NSStatusBar.system.removeStatusItem(toggle) }
        if let separator { NSStatusBar.system.removeStatusItem(separator) }
        toggle = nil
        separator = nil
        collapsed = true
    }

    @objc private func toggleClicked() {
        collapsed ? expand(schedule: autoHide) : collapse()
    }

    func expand(schedule: Bool) {
        separator?.length = 10
        collapsed = false
        toggle?.button?.image = Self.symbol("chevron.compact.right")
        autoWork?.cancel()
        guard schedule else { return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.collapse() } }
        autoWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoDelay, execute: work)
    }

    func collapse() {
        autoWork?.cancel()
        separator?.length = Self.hiddenLength
        collapsed = true
        toggle?.button?.image = Self.symbol("chevron.compact.left")
    }

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: L("Gizli simgeler"))?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        image?.isTemplate = true
        return image
    }

    /// İnce dikey çizgi.
    private static let separatorImage: NSImage = {
        let image = NSImage(size: NSSize(width: 4, height: 16), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1.25, y: 2, width: 1.5, height: 12), xRadius: 0.75, yRadius: 0.75).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
