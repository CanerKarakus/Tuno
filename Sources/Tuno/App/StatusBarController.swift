import AppKit
import SwiftUI

/// Menü çubuğu simgesi ve ona bağlı panel.
///
/// `MenuBarExtra` animasyon ve arka plan özelleştirmesine izin vermediği için panel AppKit
/// ile yönetilir. Denetim Merkezi gibi simgenin hizasından hafifçe büyüyerek ve saydamlığı
/// artarak açılır; macOS 26+ sürümünde arka plan Liquid Glass'tır.
@MainActor
final class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: DropdownPanel
    private let background: NSView
    private let hosting: NSView
    /// İçeriğin SwiftUI'dan bildirilen son gerçek yüksekliği (panel kapalıyken de güncellenir).
    private var contentHeight: CGFloat = 0
    private var heightAnimation: (from: CGFloat, to: CGFloat, top: CGFloat, start: CFTimeInterval)?
    private var displayLink: CADisplayLink?
    private var isOpen = false
    private var lastClose = Date.distantPast
    private var monitors: [Any] = []
    /// Panelde gösterilen görünüm (mikser / pano geçmişi).
    let state = PanelState()

    private static let width: CGFloat = 340
    private static let cornerRadius: CGFloat = 22
    private static let startScale: CGFloat = 0.88

    init<Content: View>(@ViewBuilder content: () -> Content) {
        panel = DropdownPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 10),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)

        let heightSink = HeightSink()
        let root = DropdownRoot(content: content(), sink: heightSink)
        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        self.hosting = hosting
        background = Glass.make(content: hosting, cornerRadius: Self.cornerRadius)
        super.init()

        heightSink.onChange = { [weak self] height in self?.contentHeightChanged(height) }
        hosting.rootView = AnyView(root
            .environment(state)
            .environment(\.menuActions, MenuActions(
                close: { [weak self] in self?.close() },
                openSettings: { [weak self] in
                    self?.close()
                    WindowOpener.openMain()
                })))

        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Pencere gölgesi kare alandan hesaplanıp yuvarlak köşelerin dışında kare bir kenar
        // bırakıyordu; cam kendi kenar ışığını çizer.
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.onCancel = { [weak self] in self?.close() }

        // Cam doğrudan pencerenin içeriğidir; boyutunu pencere yönetir. İçerik görünümünün
        // boyutuna elle dokunmak macOS'un gecikmeli yeniden boyutlandırmasıyla çakışıyordu.
        background.wantsLayer = true
        panel.contentView = background

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Tuno")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked)
        }
        updateVisibility()
        NotificationCenter.default.addObserver(
            self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
    }

    // MARK: - Açma / kapama

    @objc private func statusItemClicked() {
        if isOpen {
            close()
        } else if Date().timeIntervalSince(lastClose) > 0.4 {
            // Aynı tıklama paneli az önce "dışarı tıklama" olarak kapattıysa yeniden açma.
            open(mode: .mixer)
        }
    }

    /// Kısayol için: kapalıysa bu görünümde açar, başka görünümdeyse geçer, aynıysa kapatır.
    func toggle(mode: PanelMode) {
        if !isOpen {
            open(mode: mode)
        } else if state.mode != mode {
            withAnimation(.snappy(duration: 0.25)) { state.mode = mode }
            NotificationCenter.default.post(name: .tunoPanelWillOpen, object: nil)
        } else {
            close()
        }
    }

    func open(mode: PanelMode = .mixer) {
        guard !isOpen, let anchor = statusItem.button?.window?.frame else { return }
        isOpen = true
        state.mode = mode
        state.isOpen = true
        hosting.layoutSubtreeIfNeeded()
        NotificationCenter.default.post(name: .tunoPanelWillOpen, object: nil)
        statusItem.button?.highlight(true)

        // Yükseklik: içeriğin bildirdiği gerçek değer. Henüz bildirim gelmediyse (ilk açılış)
        // ölçümle başla; gerçek değer gelince panel kendini ona göre ayarlar.
        let height = contentHeight > 0 ? contentHeight : hosting.fittingSize.height
        heightAnimation = nil
        panel.setFrame(frame(height: max(height, 120), below: anchor), display: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)

        // Denetim Merkezi gibi: üst-orta noktadan büyüyerek ve belirerek aç.
        let spring = CASpringAnimation(keyPath: "transform")
        spring.mass = 1
        spring.stiffness = 340
        spring.damping = 30
        spring.fromValue = scaleTransform(Self.startScale)
        spring.toValue = CATransform3DIdentity
        spring.duration = spring.settlingDuration
        background.layer?.transform = CATransform3DIdentity
        background.layer?.add(spring, forKey: "zoom")

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.panel.invalidateShadow() }
        }
        installMonitors()
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        state.isOpen = false
        lastClose = Date()
        NotificationCenter.default.post(name: .tunoPanelDidClose, object: nil)
        statusItem.button?.highlight(false)
        removeMonitors()

        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = CATransform3DIdentity
        shrink.toValue = scaleTransform(0.94)
        shrink.duration = 0.16
        shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
        shrink.fillMode = .forwards
        shrink.isRemovedOnCompletion = false
        background.layer?.add(shrink, forKey: "zoom")

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isOpen else { return }
                self.panel.orderOut(nil)
                self.background.layer?.removeAnimation(forKey: "zoom")
            }
        }
    }

    /// Katmanı üst-orta nokta etrafında ölçekler (AppKit katmanlarının çapası sol alttadır).
    private func scaleTransform(_ scale: CGFloat) -> CATransform3D {
        let bounds = background.bounds
        let pivotX = bounds.midX, pivotY = bounds.maxY
        var transform = CATransform3DMakeTranslation(pivotX, pivotY, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -pivotX, -pivotY, 0)
    }

    /// İçerik büyüyüp küçüldüğünde (ör. aygıt listesi açılınca) pencere üst kenarı sabit
    /// kalarak kare kare aşağı doğru uzar ya da yukarı doğru toplanır.
    private func contentHeightChanged(_ height: CGFloat) {
        contentHeight = height
        guard isOpen, let anchor = statusItem.button?.window?.frame else { return }
        let target = frame(height: height, below: anchor)
        guard abs(target.height - (heightAnimation?.to ?? panel.frame.height)) > 0.5 else { return }

        heightAnimation = (panel.frame.height, target.height, target.maxY, CACurrentMediaTime())
        if displayLink == nil {
            let link = background.displayLink(target: self, selector: #selector(stepHeight))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    @objc private func stepHeight(_ link: CADisplayLink) {
        guard let animation = heightAnimation, isOpen else {
            heightAnimation = nil
            link.invalidate()
            displayLink = nil
            return
        }
        let progress = min((CACurrentMediaTime() - animation.start) / 0.3, 1)
        let eased = 1 - pow(1 - progress, 3)   // ease-out
        let height = (animation.from + (animation.to - animation.from) * eased).rounded()
        var frame = panel.frame
        frame.size.height = height
        frame.origin.y = animation.top - height   // üst kenar sabit
        panel.setFrame(frame, display: true)
        if progress >= 1 {
            heightAnimation = nil
            link.invalidate()
            displayLink = nil
            panel.invalidateShadow()
        }
    }

    private func frame(height: CGFloat, below anchor: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let clampedHeight = min(height, visible.height - 12)
        var x = anchor.midX - Self.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - Self.width - 8)
        let top = anchor.minY - 6
        return NSRect(x: x, y: top - clampedHeight, width: Self.width, height: clampedHeight)
    }

    // MARK: - Dışarı tıklayınca kapanma

    private var statusItemFrame: NSRect { statusItem.button?.window?.frame ?? .zero }

    private func installMonitors() {
        removeMonitors()
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
                MainActor.assumeIsolated {
                    // Menü çubuğu simgesine tıklama başka bir süreç üzerinden gelebilir;
                    // onu aç/kapa eylemine bırak.
                    guard let self, !self.statusItemFrame.contains(NSEvent.mouseLocation) else { return }
                    self.close()
                }
            }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: {
            [weak self] event in
            MainActor.assumeIsolated {
                // Tuno'nun kendi normal pencerelerine (Ayarlar) tıklanırsa kapan; menüler ve simgenin kendisi hariç.
                if let self, let window = event.window, window !== self.panel,
                   window !== self.statusItem.button?.window, window.level == .normal {
                    self.close()
                }
            }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    // MARK: - Görünürlük

    @objc private func defaultsChanged() {
        updateVisibility()
    }

    /// En son uygulanan görünürlük. macOS simgeyi gösterirken (görünür olmadan önce) ayar değişikliği bildirimi
    /// yayınlar; bu kayıt olmadan içeri yeniden giren çağrı simgeyi tekrar tekrar göstermeye çalışıp Tuno'yu çökertiyordu.
    private var appliedVisibility: Bool?

    private func updateVisibility() {
        let visible = UserDefaults.standard.bool(forKey: PreferenceKey.showMenuBar, default: true)
        guard visible != appliedVisibility else { return }
        appliedVisibility = visible
        if statusItem.isVisible != visible { statusItem.isVisible = visible }
        if !visible { close() }
    }
}

/// Anahtar pencere olabilen (Esc ve klavye odağı için) ama uygulamayı öne getirmeyen panel.
final class DropdownPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

enum PanelMode { case mixer, clipboard }

@Observable
@MainActor
final class PanelState {
    var mode = PanelMode.mixer
    /// Panel ekranda mı: görünüm kapalıyken de yaşadığı için sürekli animasyonlar buna bağlıdır (pil).
    var isOpen = false
}

@MainActor
private final class HeightSink {
    var onChange: ((CGFloat) -> Void)?
}

private struct DropdownRoot<Content: View>: View {
    let content: Content
    let sink: HeightSink

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sink.onChange?($0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Panel içinden kullanılan eylemler

struct MenuActions {
    var close: () -> Void = {}
    var openSettings: () -> Void = {}
}

extension EnvironmentValues {
    @Entry var menuActions = MenuActions()
}

/// AppKit tarafından SwiftUI ana penceresini açabilmek için `openWindow` eylemini saklar.
@MainActor
enum WindowOpener {
    static var action: OpenWindowAction?

    static func openMain() {
        // Pencere kapatılınca Dock'tan kaldırılmıştı; açılırken geri gelir.
        NSApp.setActivationPolicy(.regular)
        if let action {
            action(id: "main")
        } else if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }
}





