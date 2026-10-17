import AppKit
import ApplicationServices
import Observation

/// Windows'taki Snap: pencere ekranın kenarına sürüklenince yarım, köşesine sürüklenince çeyrek
/// ekrana, üst kenara sürüklenince ekranın tamamına yerleşir. Sürükleme başlayınca ekran kenarlarında
/// bırakılabilecek yerler silik çizgilerle, bir kenara gelince yerleşeceği alan pencerenin arkasında
/// hafif bir çerçeveyle gösterilir. Kısayollarla da yerleştirilebilir.
///
/// macOS'un kendi kenara sürükleyerek döşemesi ikisinin aynı anda çalışmaması için Tuno'nunki
/// açıkken kapatılır, kapatılınca eski hâline döner.
@Observable
@MainActor
final class WindowSnapper {
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            refresh()
        }
    }

    /// Başlığa çift tıklayınca ekranı kapla, tekrar çift tıklayınca eski boyutuna dön.
    var doubleClickMaximize: Bool {
        didSet {
            UserDefaults.standard.set(doubleClickMaximize, forKey: Self.doubleClickKey)
            refresh()
        }
    }

    enum Zone: Equatable {
        case left, right, maximize, topLeft, topRight, bottomLeft, bottomRight, center
        case topHalf, bottomHalf, leftThird, centerThird, rightThird, leftTwoThirds, rightTwoThirds
    }

    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var tapSource: CFRunLoopSource?
    fileprivate static weak var current: WindowSnapper?
    @ObservationIgnored private var window: AXUIElement?
    @ObservationIgnored private var startPosition: CGPoint?
    @ObservationIgnored private var moved = false
    @ObservationIgnored private var zone: Zone?
    @ObservationIgnored private var lastDrag: TimeInterval = 0
    @ObservationIgnored private var overlay: NSPanel?
    @ObservationIgnored private var hints: NSPanel?
    /// Büyütülen pencerelerin eski yerleri.
    @ObservationIgnored private var restoreFrames: [CGWindowID: NSRect] = [:]

    private static let enabledKey = "windowSnapping"
    private static let doubleClickKey = "doubleClickMaximize"

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey, default: true)
        doubleClickMaximize = UserDefaults.standard.bool(forKey: Self.doubleClickKey, default: true)
        Self.current = self
        refresh()
    }

    /// İzin ya da ayar değişince sürükleme takibini ve macOS'un döşemesini günceller.
    func refresh() {
        let trusted = AXIsProcessTrusted()
        NativeTiling.setSuppressed(isEnabled && trusted)
        NativeDoubleClick.setSuppressed(doubleClickMaximize && trusted)
        if (isEnabled || doubleClickMaximize) && trusted { start() } else { stop() }
    }

    func shutdown() {
        stop()
        NativeTiling.setSuppressed(false)
        NativeDoubleClick.setSuppressed(false)
    }

    /// Pencereyi başlığından sürüklerken macOS fare olaylarını uygulamalara göndermiyor; bu yüzden
    /// genel izleyici yerine olayları yalnızca dinleyen (değiştirmeyen) bir yakalayıcı kullanılır.
    private func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: { _, type, event, _ in
                MainActor.assumeIsolated {
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        WindowSnapper.current?.reenableTap()
                    } else {
                        WindowSnapper.current?.handle(type, clicks: event.getIntegerValueField(.mouseEventClickState))
                    }
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: nil)
        else { return }
        self.tap = tap
        tapSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func reenableTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        }
        tap = nil
        tapSource = nil
        reset()
    }

    // MARK: - Sürükleme

    private func handle(_ type: CGEventType, clicks: Int64) {
        if type == .leftMouseDown, clicks == 2, doubleClickMaximize, Self.titleBarWindow(at: NSEvent.mouseLocation) != nil {
            // Fare bırakılmadan değiştirilirse uygulama sürüklemeye başlayabiliyor; bırakıldıktan hemen sonra.
            let point = NSEvent.mouseLocation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                MainActor.assumeIsolated { self?.toggleMaximize(at: point) }
            }
            return
        }
        guard isEnabled else { return }
        switch type {
        case .leftMouseDown:
            reset()
            guard let window = Self.window(at: NSEvent.mouseLocation) else { return }
            self.window = window
            startPosition = Self.position(of: window)
        case .leftMouseDragged:
            guard let window, let startPosition else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastDrag > 1.0 / 60 else { return }
            lastDrag = now
            if !moved {
                // Pencerenin kendisi taşınıyor mu (içerikte seçim yapmak ya da kaydırmak değil)?
                guard let position = Self.position(of: window),
                      abs(position.x - startPosition.x) + abs(position.y - startPosition.y) > 2 else { return }
                moved = true
            }
            let mouse = NSEvent.mouseLocation
            if let screen = Self.screen(at: mouse) { showHints(on: screen) }
            let zone = Self.zone(at: mouse)
            if zone != self.zone {
                self.zone = zone
                if let zone, let screen = Self.screen(at: mouse) {
                    showOverlay(Self.frame(for: zone, on: screen, window: window),
                                below: WindowCatalog.windowNumber(of: window))
                } else {
                    hideOverlay()
                }
            }
        case .leftMouseUp:
            if moved, let window, let zone, let screen = Self.screen(at: NSEvent.mouseLocation) {
                Self.place(window, in: Self.frame(for: zone, on: screen, window: window))
            }
            reset()
        default:
            break
        }
    }

    private func reset() {
        window = nil
        startPosition = nil
        moved = false
        zone = nil
        hideOverlay()
        hideHints()
    }

    // MARK: - Çift tıklama

    private func toggleMaximize(at point: NSPoint) {
        guard let window = Self.titleBarWindow(at: point), let frame = Self.frame(of: window),
              let id = WindowCatalog.windowNumber(of: window),
              let screen = NSScreen.screens.max(by: { $0.frame.intersection(frame).area < $1.frame.intersection(frame).area })
        else { return }
        let filled = Self.frame(for: .maximize, on: screen, window: window)
        let isFilled = abs(frame.minX - filled.minX) < 12 && abs(frame.maxY - filled.maxY) < 12
            && abs(frame.width - filled.width) < 24 && abs(frame.height - filled.height) < 24
        if isFilled, let previous = restoreFrames.removeValue(forKey: id) {
            Self.place(window, in: previous)
        } else {
            restoreFrames[id] = frame
            Self.place(window, in: filled)
        }
    }

    /// İmleç bir pencerenin başlık çubuğunda mı (araç çubuğunun boş yeri dahil)?
    private static func titleBarWindow(at point: NSPoint) -> AXUIElement? {
        guard let primary = NSScreen.screens.first else { return nil }
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x),
                                               Float(primary.frame.maxY - point.y), &element) == .success,
              let element else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != getpid() else { return nil }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let roleName = role as? String ?? ""
        guard [kAXWindowRole, kAXToolbarRole, kAXStaticTextRole].map({ $0 as String }).contains(roleName),
              let window = Self.window(at: point), let frame = Self.frame(of: window)
        else { return nil }
        // Başlık bandı: pencerenin üst kısmı (araç çubuklu pencerelerde biraz daha geniş).
        let band: CGFloat = roleName == (kAXToolbarRole as String) ? 90 : 56
        return frame.maxY - point.y <= band ? window : nil
    }

    // MARK: - Kısayollar

    func snapFocusedWindow(_ shortcut: Shortcut) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return }
        let window = focused as! AXUIElement
        guard let frame = Self.frame(of: window),
              let screen = NSScreen.screens.max(by: { $0.frame.intersection(frame).area < $1.frame.intersection(frame).area })
        else { return }
        let zone: Zone = switch shortcut {
        case .snapLeft: .left
        case .snapRight: .right
        case .snapMaximize: .maximize
        case .snapTopHalf: .topHalf
        case .snapBottomHalf: .bottomHalf
        case .snapLeftThird: .leftThird
        case .snapCenterThird: .centerThird
        case .snapRightThird: .rightThird
        case .snapLeftTwoThirds: .leftTwoThirds
        case .snapRightTwoThirds: .rightTwoThirds
        default: .center
        }
        Self.place(window, in: Self.frame(for: zone, on: screen, window: window))
    }

    // MARK: - Alanlar

    /// İmleç ekranın dış kenarına dayandıysa hangi alana bırakılacağı.
    private static func zone(at point: NSPoint) -> Zone? {
        guard let screen = screen(at: point) else { return nil }
        let frame = screen.frame
        let edge: CGFloat = 3, corner = min(frame.height * 0.18, 140)
        // Yanında başka ekran olan kenarlar yerleştirme kenarı sayılmaz.
        let open = { (offset: CGVector) in
            !NSScreen.screens.contains { NSMouseInRect(NSPoint(x: point.x + offset.dx, y: point.y + offset.dy), $0.frame, false) }
        }
        let nearLeft = point.x - frame.minX <= edge && open(CGVector(dx: -8, dy: 0))
        let nearRight = frame.maxX - point.x <= edge + 1 && open(CGVector(dx: 8, dy: 0))
        let nearTop = frame.maxY - point.y <= edge + 1 && open(CGVector(dx: 0, dy: 8))
        let inTopCorner = frame.maxY - point.y <= corner
        let inBottomCorner = point.y - frame.minY <= corner
        if nearLeft { return inTopCorner ? .topLeft : inBottomCorner ? .bottomLeft : .left }
        if nearRight { return inTopCorner ? .topRight : inBottomCorner ? .bottomRight : .right }
        if nearTop { return .maximize }
        return nil
    }

    /// Alanın ekrandaki yeri (AppKit koordinatları, menü çubuğu ve Dock hariç).
    private static func frame(for zone: Zone, on screen: NSScreen, window: AXUIElement) -> NSRect {
        let area = screen.visibleFrame
        let halfWidth = (area.width / 2).rounded(), halfHeight = (area.height / 2).rounded()
        let third = (area.width / 3).rounded()
        switch zone {
        case .topHalf: return NSRect(x: area.minX, y: area.maxY - halfHeight, width: area.width, height: halfHeight)
        case .bottomHalf: return NSRect(x: area.minX, y: area.minY, width: area.width, height: halfHeight)
        case .leftThird: return NSRect(x: area.minX, y: area.minY, width: third, height: area.height)
        case .centerThird: return NSRect(x: area.minX + third, y: area.minY, width: area.width - third * 2, height: area.height)
        case .rightThird: return NSRect(x: area.maxX - third, y: area.minY, width: third, height: area.height)
        case .leftTwoThirds: return NSRect(x: area.minX, y: area.minY, width: area.width - third, height: area.height)
        case .rightTwoThirds: return NSRect(x: area.minX + third, y: area.minY, width: area.width - third, height: area.height)
        case .left: return NSRect(x: area.minX, y: area.minY, width: halfWidth, height: area.height)
        case .right: return NSRect(x: area.maxX - halfWidth, y: area.minY, width: halfWidth, height: area.height)
        case .maximize: return area
        case .topLeft: return NSRect(x: area.minX, y: area.maxY - halfHeight, width: halfWidth, height: halfHeight)
        case .topRight: return NSRect(x: area.maxX - halfWidth, y: area.maxY - halfHeight, width: halfWidth, height: halfHeight)
        case .bottomLeft: return NSRect(x: area.minX, y: area.minY, width: halfWidth, height: halfHeight)
        case .bottomRight: return NSRect(x: area.maxX - halfWidth, y: area.minY, width: halfWidth, height: halfHeight)
        case .center:
            let size = frame(of: window)?.size ?? CGSize(width: area.width * 0.6, height: area.height * 0.7)
            let width = min(size.width, area.width), height = min(size.height, area.height)
            return NSRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height).integral
        }
    }

    // MARK: - Önizleme

    /// Yerleşeceği alan: sürüklenen pencerenin arkasında, hafif renkli bir çerçeve.
    private func showOverlay(_ frame: NSRect, below windowNumber: CGWindowID?) {
        let overlay = self.overlay ?? Self.makeOverlay()
        self.overlay = overlay
        let target = frame.insetBy(dx: 4, dy: 4)
        let order = { if let windowNumber { overlay.order(.below, relativeTo: Int(windowNumber)) } else { overlay.orderFront(nil) } }
        if overlay.isVisible && overlay.alphaValue > 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.allowsImplicitAnimation = true
                overlay.animator().setFrame(target, display: true)
            }
            order()
        } else {
            overlay.setFrame(target.insetBy(dx: target.width * 0.04, dy: target.height * 0.04), display: false)
            overlay.alphaValue = 0
            order()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                overlay.animator().setFrame(target, display: true)
                overlay.animator().alphaValue = 1
            }
        }
    }

    private func hideOverlay() {
        guard let overlay, overlay.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; overlay.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { if overlay.alphaValue == 0 { overlay.orderOut(nil) } }
        }
    }

    private static func makeOverlay() -> NSPanel {
        let panel = transparentPanel(level: .normal)
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.cornerCurve = .continuous
        view.layer?.borderWidth = 2
        view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
        view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        panel.contentView = view
        return panel
    }

    /// Sürükleme sürerken ekranın bırakılabilecek kenarlarında silik çizgiler.
    private func showHints(on screen: NSScreen) {
        let hints = self.hints ?? Self.transparentPanel(level: .floating)
        self.hints = hints
        guard hints.frame != screen.frame || !hints.isVisible else { return }
        hints.setFrame(screen.frame, display: false)
        hints.contentView = Self.hintsView(size: screen.frame.size, menuBar: screen.frame.maxY - screen.visibleFrame.maxY)
        if !hints.isVisible {
            hints.alphaValue = 0
            hints.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25; hints.animator().alphaValue = 1 }
        }
    }

    private func hideHints() {
        guard let hints, hints.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; hints.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { if hints.alphaValue == 0 { hints.orderOut(nil) } }
        }
    }

    private static func hintsView(size: CGSize, menuBar: CGFloat) -> NSView {
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        let thickness: CGFloat = 4, inset = size.height * 0.08
        let strips = [
            NSRect(x: 2, y: inset, width: thickness, height: size.height - inset * 2 - menuBar),          // sol
            NSRect(x: size.width - thickness - 2, y: inset, width: thickness, height: size.height - inset * 2 - menuBar), // sağ
            NSRect(x: size.width * 0.2, y: size.height - thickness - 2, width: size.width * 0.6, height: thickness), // üst
        ]
        for strip in strips {
            let layer = CAGradientLayer()
            layer.frame = strip
            layer.cornerRadius = thickness / 2
            let accent = NSColor.controlAccentColor
            layer.colors = [accent.withAlphaComponent(0).cgColor, accent.withAlphaComponent(0.55).cgColor,
                            accent.withAlphaComponent(0).cgColor]
            if strip.width > strip.height {
                layer.startPoint = CGPoint(x: 0, y: 0.5)
                layer.endPoint = CGPoint(x: 1, y: 0.5)
            }
            view.layer?.addSublayer(layer)
        }
        return view
    }

    private static func transparentPanel(level: NSWindow.Level) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        return panel
    }

    // MARK: - Erişilebilirlik

    /// İmlecin altındaki standart pencere (başka uygulamaların; Tuno'nun kendi pencereleri hariç).
    private static func window(at point: NSPoint) -> AXUIElement? {
        guard let primary = NSScreen.screens.first else { return nil }
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x),
                                               Float(primary.frame.maxY - point.y), &element) == .success,
              let element else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != getpid() else { return nil }
        var window: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &window) != .success {
            window = element
        }
        guard let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        let result = window as! AXUIElement
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(result, kAXSubroleAttribute as CFString, &subrole)
        return (subrole as? String) == (kAXStandardWindowSubrole as String) ? result : nil
    }

    private static func position(of window: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(value as! AXValue, .cgPoint, &point)
        return point
    }

    /// Pencerenin yeri (AppKit koordinatları).
    private static func frame(of window: AXUIElement) -> NSRect? {
        var value: CFTypeRef?
        guard let origin = position(of: window), let primary = NSScreen.screens.first,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        AXValueGetValue(value as! AXValue, .cgSize, &size)
        return NSRect(x: origin.x, y: primary.frame.maxY - origin.y - size.height, width: size.width, height: size.height)
    }

    private static func place(_ window: AXUIElement, in frame: NSRect) {
        guard let primary = NSScreen.screens.first else { return }
        var origin = CGPoint(x: frame.minX, y: primary.frame.maxY - frame.maxY)
        var size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin), let dimensions = AXValueCreate(.cgSize, &size) else { return }
        // Boyut ekranı aşmasın diye önce yer, sonra boyut; uygulama sınırladıysa yer yeniden.
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
    }

    private static func screen(at point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }
}

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

/// macOS'un kendi "pencereleri ekran kenarına sürükleyerek döşe" ayarları.
@MainActor
enum NativeTiling {
    private static let domain = "com.apple.WindowManager" as CFString
    private static let keys = ["EnableTilingByEdgeDrag", "EnableTopTilingByEdgeDrag"]
    private static let savedKey = "nativeTilingSaved"

    static func setSuppressed(_ suppressed: Bool) {
        if suppressed {
            guard UserDefaults.standard.dictionary(forKey: savedKey) == nil else { return }
            var saved: [String: Bool] = [:]
            for key in keys {
                saved[key] = (CFPreferencesCopyAppValue(key as CFString, domain) as? Bool) ?? true
                CFPreferencesSetAppValue(key as CFString, false as CFBoolean, domain)
            }
            UserDefaults.standard.set(saved, forKey: savedKey)
        } else {
            guard let saved = UserDefaults.standard.dictionary(forKey: savedKey) as? [String: Bool] else { return }
            for key in keys { CFPreferencesSetAppValue(key as CFString, (saved[key] ?? true) as CFBoolean, domain) }
            UserDefaults.standard.removeObject(forKey: savedKey)
        }
        CFPreferencesAppSynchronize(domain)
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.apple.WindowManager.PreferencesChanged"), object: nil, deliverImmediately: true)
    }
}

/// macOS'un "pencere başlığına çift tıklayınca" ayarı. Tuno'nunki açıkken "hiçbir şey" yapılır ki
/// ikisi aynı anda çalışmasın; kapatılınca eski değeri geri yüklenir.
@MainActor
enum NativeDoubleClick {
    private static let key = "AppleActionOnDoubleClick" as CFString
    private static let savedKey = "nativeDoubleClickSaved"

    static func setSuppressed(_ suppressed: Bool) {
        let defaults = UserDefaults.standard
        if suppressed {
            guard defaults.object(forKey: savedKey) == nil else { return }
            let current = CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                                                 kCFPreferencesAnyHost) as? String ?? ""
            defaults.set(current, forKey: savedKey)
            write("None")
        } else {
            guard let saved = defaults.string(forKey: savedKey) else { return }
            write(saved.isEmpty ? nil : saved)
            defaults.removeObject(forKey: savedKey)
        }
    }

    private static func write(_ value: String?) {
        CFPreferencesSetValue(key, value as CFString?, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                              kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}
