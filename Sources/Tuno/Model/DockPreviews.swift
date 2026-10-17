import AppKit
import ApplicationServices
import Observation
import SwiftUI

/// 1.0.3–1.1.0 önizleme açıkken Dock'un otomatik gizlenmesini durduruyordu. macOS bunu gerçek bir ayar
/// değişikliği saydığı için tam boy pencereleri küçültüyordu; artık durdurulmuyor. Bu sürümlerden
/// kalmış olabilecek durdurma, açılışta ve kapanışta `resume()` ile geri alınır.
@MainActor
enum DockAutoHide {
    private typealias Setter = @convention(c) (Bool) -> Void
    private static let library = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
    private static let setEnabled = dlsym(library, "CoreDockSetAutoHideEnabled").map { unsafeBitCast($0, to: Setter.self) }
    private static let pausedKey = "dockAutoHidePaused"

    static func resume() {
        guard UserDefaults.standard.bool(forKey: pausedKey), let setEnabled else { return }
        UserDefaults.standard.removeObject(forKey: pausedKey)
        setEnabled(true)
    }
}

@Observable
@MainActor
final class DockPreviewModel {
    var appName = ""
    var windows: [WindowInfo] = []
    var thumbnails: [CGWindowID: NSImage] = [:]
    var hovered: CGWindowID?
    var onPick: ((WindowInfo) -> Void)?
    var onHover: ((WindowInfo?) -> Void)?
    var onClose: ((WindowInfo) -> Void)?
    var onMinimize: ((WindowInfo) -> Void)?
}

/// İmleç Dock'taki bir uygulama simgesinde beklerken o uygulamanın pencerelerini gösterir.
///
/// Dock simgeleri Erişilebilirlik API'siyle (AXDockItem) imlecin altında bulunur; önizleme
/// simgenin üstünde açılır, imleç simgeden ve önizlemeden ayrılınca kapanır.
@Observable
@MainActor
final class DockPreviews {
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? start() : stop()
        }
    }

    @ObservationIgnored private let model = DockPreviewModel()
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var lastCheck: TimeInterval = 0
    @ObservationIgnored private var hoveredApp: pid_t?
    @ObservationIgnored private var showWork: DispatchWorkItem?
    @ObservationIgnored private var hideWork: DispatchWorkItem?
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?
    @ObservationIgnored private let peek = WindowPeek()
    @ObservationIgnored private var peekWork: DispatchWorkItem?

    private static let enabledKey = "dockPreviews"
    private static let showDelay: TimeInterval = 0.35

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        model.onPick = { [weak self] window in
            self?.hide(immediately: true)
            WindowCatalog.focus(window)
        }
        model.onHover = { [weak self] window in self?.hoverChanged(window) }
        model.onClose = { [weak self] window in
            guard let self else { return }
            self.peek.hide(animated: false)
            WindowCatalog.close(window)
            self.model.windows.removeAll { $0.id == window.id }
            if self.model.windows.isEmpty { self.hide(immediately: true) } else { self.resizePanel() }
        }
        model.onMinimize = { [weak self] window in
            guard let self else { return }
            self.peek.hide(animated: false)
            WindowCatalog.minimize(window)
            if let index = self.model.windows.firstIndex(of: window) { self.model.windows[index] = window.minimized }
        }
        BackgroundCursor.enable()
        if isEnabled { start() }
    }

    /// Ekran Kaydı ve Erişilebilirlik izni yoksa hiç çalışmaz.
    static var isAvailable: Bool { CGPreflightScreenCaptureAccess() && AXIsProcessTrusted() }

    func refreshAvailability() {
        isEnabled && Self.isAvailable ? start() : stop()
    }

    private func start() {
        guard monitors.isEmpty, Self.isAvailable else { return }
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown], handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in
            handler(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    private func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        hide(immediately: true)
    }

    // MARK: - İmleç takibi

    private func mouseMoved() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastCheck > 0.04 else { return }
        lastCheck = now
        let mouse = NSEvent.mouseLocation

        if let panel, panel.isVisible, panel.frame.insetBy(dx: -6, dy: -6).contains(mouse) {
            hideWork?.cancel()
            return
        }
        guard AXIsProcessTrusted(), Self.isNearDock(mouse), let item = Self.dockItem(at: mouse) else {
            leave()
            return
        }
        hideWork?.cancel()
        guard item.pid != hoveredApp else { return }
        hoveredApp = item.pid
        showWork?.cancel()
        let delay = panel?.isVisible == true ? 0.05 : Self.showDelay
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.show(pid: item.pid, name: item.name, iconFrame: item.frame) }
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func leave() {
        showWork?.cancel()
        guard hoveredApp != nil || panel?.isVisible == true else { return }
        guard hideWork == nil || hideWork?.isCancelled == true else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hide(immediately: false) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: - Önizleme

    private func show(pid: pid_t, name: String, iconFrame: NSRect) {
        let windows = WindowCatalog.windows(for: pid)
        guard !windows.isEmpty else {
            hide(immediately: true)
            hoveredApp = pid
            return
        }
        model.appName = name
        model.windows = windows
        model.thumbnails = WindowCatalog.cachedThumbnails.filter { id, _ in windows.contains { $0.id == id } }
        model.hovered = nil
        peekWork?.cancel()
        peek.hide()

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = Self.panelSize(count: windows.count)
        let screen = NSScreen.screens.first { $0.frame.intersects(iconFrame) } ?? NSScreen.main
        let visible = screen?.frame ?? .zero
        var origin = NSPoint(x: iconFrame.midX - size.width / 2, y: iconFrame.maxY + 34)
        switch Self.dockOrientation {
        case "left": origin = NSPoint(x: iconFrame.maxX + 12, y: iconFrame.midY - size.height / 2)
        case "right": origin = NSPoint(x: iconFrame.minX - size.width - 12, y: iconFrame.midY - size.height / 2)
        default: break
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)

        let wasVisible = panel.isVisible
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if !wasVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        }

        thumbnailTask?.cancel()
        thumbnailTask = Task { [model] in
            await WindowCatalog.thumbnails(for: windows, maxDimension: 200) { id, image in
                if model.thumbnails[id] == nil {
                    withAnimation(.easeOut(duration: 0.15)) { model.thumbnails[id] = image }
                } else {
                    model.thumbnails[id] = image
                }
            }
        }
    }

    /// Pencere kapatılınca paneli alt kenarı ve ortası yerinde kalacak şekilde küçültür.
    private func resizePanel() {
        guard let panel else { return }
        let size = Self.panelSize(count: model.windows.count)
        let frame = panel.frame
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY, width: size.width, height: size.height),
                       display: true, animate: true)
    }

    private func hide(immediately: Bool) {
        hoveredApp = nil
        showWork?.cancel()
        hideWork = nil
        thumbnailTask?.cancel()
        peekWork?.cancel()
        model.hovered = nil
        immediately ? peek.hide(animated: false) : peek.hide()
        peek.reset()
        guard let panel, panel.isVisible else { return }
        // Kartlar kaldırılınca canlı görüntü yakalamaları da durur.
        if immediately {
            panel.orderOut(nil)
            model.windows = []
        } else {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 0 }) {
                MainActor.assumeIsolated {
                    guard panel.alphaValue == 0 else { return }
                    panel.orderOut(nil)
                    self.model.windows = []
                }
            }
        }
    }

    /// Bir kartın üzerinde kısa süre durulunca pencere kendi yerinde gösterilir; kartlar arasında
    /// gezinirken hemen değişir, kartlardan çıkınca kaybolur.
    private func hoverChanged(_ window: WindowInfo?) {
        peekWork?.cancel()
        guard let window else {
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.peek.hide() } }
            peekWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.model.hovered == window.id else { return }
                // Zaten en önde olan pencerenin silik hâlini göstermenin anlamı yok.
                guard !WindowCatalog.isFrontmost(window) else { return self.peek.hide() }
                self.peek.show(window, placeholder: self.model.thumbnails[window.id])
            }
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (peek.isShowing ? 0 : 0.2), execute: work)
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingView(rootView: DockPreviewView(model: model))
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        return Glass.panel(content: hosting, cornerRadius: 22, level: .popUpMenu)
    }

    static let card = CGSize(width: 190, height: 150)

    private static func panelSize(count: Int) -> CGSize {
        let columns = min(count, 5)
        let rows = Int(ceil(Double(count) / Double(columns)))
        return CGSize(width: CGFloat(columns) * card.width + CGFloat(columns - 1) * 8 + 24,
                      height: CGFloat(rows) * card.height + CGFloat(rows - 1) * 8 + 24 + 26)
    }

    // MARK: - Dock

    private static var dockOrientation: String {
        UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom"
    }

    /// Erişilebilirlik sorgusunu yalnızca imleç Dock kenarına yakınken yap.
    private static func isNearDock(_ point: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return false }
        let frame = screen.frame, margin: CGFloat = 140
        switch dockOrientation {
        case "left": return point.x - frame.minX < margin
        case "right": return frame.maxX - point.x < margin
        default: return point.y - frame.minY < margin
        }
    }

    private static func dockItem(at point: NSPoint) -> (pid: pid_t, name: String, frame: NSRect)? {
        guard let primary = NSScreen.screens.first else { return nil }
        // Erişilebilirlik koordinatları sol üstten başlar.
        let topLeft = CGPoint(x: point.x, y: primary.frame.maxY - point.y)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(topLeft.x), Float(topLeft.y),
                                               &element) == .success, let element else { return nil }
        var ownerPID: pid_t = 0
        AXUIElementGetPid(element, &ownerPID)
        guard NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier == "com.apple.dock",
              attribute(element, kAXSubroleAttribute) == "AXApplicationDockItem",
              let url: URL = attribute(element, kAXURLAttribute),
              let app = NSWorkspace.shared.runningApplications.first(where: {
                  $0.bundleURL?.standardizedFileURL == url.standardizedFileURL
              }),
              let position: AXValue = attribute(element, kAXPositionAttribute),
              let sizeValue: AXValue = attribute(element, kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(position, .cgPoint, &origin)
        AXValueGetValue(sizeValue, .cgSize, &size)
        let frame = NSRect(x: origin.x, y: primary.frame.maxY - origin.y - size.height, width: size.width, height: size.height)
        return (app.processIdentifier, app.localizedName ?? "", frame)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        if T.self == AXValue.self {
            guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            return unsafeBitCast(value, to: AXValue.self) as? T
        }
        return value as? T
    }
}

private struct DockPreviewView: View {
    let model: DockPreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.appName)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 4)
            let columns = Array(repeating: GridItem(.fixed(DockPreviews.card.width), spacing: 8),
                                count: max(1, min(model.windows.count, 5)))
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(model.windows) { window in
                    WindowCard(window: window, thumbnail: model.thumbnails[window.id],
                               isSelected: model.hovered == window.id, size: DockPreviews.card,
                               onClose: { model.onClose?(window) },
                               onMinimize: window.isMinimized ? nil : { model.onMinimize?(window) })
                        .onContinuousHover { phase in
                            switch phase {
                            case .active:
                                // Tuno öndeki uygulama olmasa da el imleci görünsün.
                                NSCursor.pointingHand.set()
                                guard model.hovered != window.id else { return }
                                model.hovered = window.id
                                model.onHover?(window)
                            case .ended:
                                guard model.hovered == window.id else { return }
                                model.hovered = nil
                                NSCursor.arrow.set()
                                model.onHover?(nil)
                            }
                        }
                        .onTapGesture { model.onPick?(window) }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

