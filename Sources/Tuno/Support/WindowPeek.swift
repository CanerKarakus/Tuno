import AppKit

/// Windows'taki "göz atma": önizlemedeki bir pencerenin üzerine gelince o pencere kendi yerinde ve
/// boyutunda, hafif saydam olarak öne çıkar; ekranın geri kalanı biraz kararır. Tıklanmadıkça
/// pencere gerçekten öne gelmez.
@MainActor
final class WindowPeek {
    private var panel: NSPanel?
    /// Pencerenin canlı görüntüsü; ilk kare gelene kadar altındaki küçük önizleme görünür.
    private let liveView = LiveWindowLayerView()
    private var current: CGWindowID?

    var isShowing: Bool { current != nil }

    /// Önce elde olan küçük önizleme gösterilir, canlı görüntü gelince onun yerini alır.
    func show(_ window: WindowInfo, placeholder: NSImage?) {
        guard current != window.id else { return }
        current = window.id
        guard !window.isMinimized, let frame = WindowCatalog.frame(of: window.id),
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) })
        else { return hide() }

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(screen.frame, display: false)
        let local = frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        liveView.frame = local
        liveView.configure(windowID: window.id, placeholder: placeholder, maxDimension: max(frame.width, frame.height),
                           framesPerSecond: 15)
        if !panel.isVisible || panel.alphaValue < 1 {
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        }
    }

    func hide(animated: Bool = true) {
        current = nil
        liveView.stop()
        liveView.configure(windowID: 0, placeholder: nil, maxDimension: 0, framesPerSecond: 0)
        guard let panel, panel.isVisible else { return }
        guard animated else {
            panel.alphaValue = 0
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { if panel.alphaValue == 0 { panel.orderOut(nil) } }
        }
    }

    func reset() {
        hide()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // Normal pencerelerin üstünde, Dock'un ve önizleme panelinin altında.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.alphaValue = 0

        let backdrop = NSView()
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        liveView.alphaValue = 0.88
        backdrop.addSubview(liveView)
        panel.contentView = backdrop
        return panel
    }
}

/// Tuno öndeki uygulama değilken de imleci değiştirebilsin (ör. önizlemede el imleci).
/// Normalde macOS arka plandaki uygulamaların imleç değiştirmesini yok sayar.
@MainActor
enum BackgroundCursor {
    private typealias Connection = @convention(c) () -> Int32
    private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    private static var enabled = false

    static func enable() {
        guard !enabled else { return }
        enabled = true
        let handle = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
        guard let connection = dlsym(handle, "_CGSDefaultConnection").map({ unsafeBitCast($0, to: Connection.self) }),
              let setProperty = dlsym(handle, "CGSSetConnectionProperty").map({ unsafeBitCast($0, to: SetProperty.self) })
        else { return }
        let id = connection()
        _ = setProperty(id, id, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}
