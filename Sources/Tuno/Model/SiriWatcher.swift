import AppKit
import CoreGraphics

/// Siri açık mı. Bu macOS sürümünde Siri ayrı bir pencere değil, Bildirim Merkezi sürecinin ekranı kaplayan bir
/// katmanıdır (pencere düzeyi 21). Pencere listesi yarım saniyede bir yoklanır (pencere adları okunmaz, izin gerekmez).
@MainActor
final class SiriWatcher {
    var onChange: ((Bool) -> Void)?
    private(set) var active = false

    private static let bundleID = "com.apple.notificationcenterui"
    private static let siriLayer = 21
    private var timer: Timer?
    private var observer: AXObserver?
    private var observedPID: pid_t = 0

    deinit {
        MainActor.assumeIsolated {
            timer?.invalidate()
            fastTimer?.invalidate()
            if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        }
    }

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.attach()
                self?.check()
            }
        }
        timer?.tolerance = 0.1
        attach()
    }

    /// Bildirim Merkezi bir pencere açıp kapatınca macOS anında haber verir: Siri gecikmeden algılanır. Siri'nin
    /// alanı pencereden biraz sonra çizildiği için ilk 0,4 saniyede birkaç kez daha bakılır.
    private func attach() {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first?.processIdentifier,
              pid != observedPID
        else { return }
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
        observedPID = pid
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<SiriWatcher>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.burst() }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowCreatedNotification, kAXUIElementDestroyedNotification, kAXFocusedUIElementChangedNotification,
                     kAXLayoutChangedNotification] {
            AXObserverAddNotification(created, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
    }

    private func burst() {
        check()
        for delay in [0.05, 0.12, 0.22, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.check() }
            }
        }
    }

    /// Siri açıkken kapanışı hemen yakalamak için hızlı yoklama (yalnızca pencere listesi; ucuz).
    private var fastTimer: Timer?
    private var misses = 0

    private func check() {
        // Siri açıkken yalnızca katmanın hâlâ ekranda olduğuna bakılır; erişilebilirlik taraması açılışta bir kez
        // yapılır (Siri'nin arayüzü de Bildirim Merkezi sürecinde çalışır, sık sorgu onu yavaşlatabilir).
        let value = active ? Self.overlayShowing() : Self.isShowing()
        // Siri cevap verirken arayüzünü yeniden çizer, katman bir an listeden düşebilir: kapandığına ancak üst
        // üste 3 kontrolde (~0,36 sn) yoksa karar verilir.
        if active, !value {
            misses += 1
            guard misses >= 3 else { return }
        }
        misses = 0
        guard value != active else { return }
        active = value
        fastTimer?.invalidate()
        fastTimer = nil
        if value {
            fastTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
        }
        onChange?(value)
    }

    private static func isShowing() -> Bool {
        guard overlayShowing(),
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
        else { return false }
        // Bildirim Merkezi paneli de aynı tam ekran katmanı açar; Siri'de "Siri'ye Yaz" alanı vardır.
        return showsSiriField(pid: pid)
    }

    /// Bildirim Merkezi'nin ekranı kaplayan katmanı açık mı (Siri ya da Bildirim Merkezi paneli).
    private static func overlayShowing() -> Bool {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier,
              let screen = NSScreen.main?.frame,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let overlay = windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == siriLayer,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat]
            else { return false }
            return (bounds["Width"] ?? 0) >= screen.width - 1 && (bounds["Height"] ?? 0) >= screen.height * 0.9
        }
        return overlay
    }

    /// Katmanın erişilebilirlik ağacında bir yazı alanı ya da "Siri" geçen bir öğe var mı (sınırlı arama).
    private static func showsSiriField(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        func text(_ element: AXUIElement, _ attribute: String) -> String {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            return (value as? String) ?? ""
        }
        var visited = 0
        func walk(_ element: AXUIElement, depth: Int) -> Bool {
            visited += 1
            guard depth < 14, visited < 500 else { return false }
            let role = text(element, kAXRoleAttribute)
            if role == kAXTextFieldRole || role == kAXTextAreaRole { return true }
            let label = [kAXIdentifierAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXPlaceholderValueAttribute]
                .map { text(element, $0) }.joined(separator: " ").lowercased()
            if label.contains("siri") { return true }
            var children: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
            return ((children as? [AXUIElement]) ?? []).contains { walk($0, depth: depth + 1) }
        }
        var windows: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
        // Yalnızca tam ekran sistem penceresi (araç takımları ayrı pencerelerdir).
        return ((windows as? [AXUIElement]) ?? []).contains { window in
            text(window, kAXSubroleAttribute) == "AXSystemDialog" && walk(window, depth: 0)
        }
    }

    /// Teşhis: Bildirim Merkezi'nin pencereleri değiştikçe (düzey, boyut, ad, saydamlık) destek günlüğüne yazar.
    static func logWindows(for seconds: TimeInterval) {
        var last = ""
        let end = Date().addingTimeInterval(seconds)
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { timer in
            guard Date() < end,
                  let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier,
                  let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
            else { timer.invalidate(); return }
            let text = windows.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }.map { window in
                let b = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
                return "[\(window[kCGWindowLayer as String] ?? "?") \(Int(b["X"] ?? 0)),\(Int(b["Y"] ?? 0)) \(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0)) "
                    + "ad=\(window[kCGWindowName as String] ?? "-") a=\(window[kCGWindowAlpha as String] ?? "?")]"
            }.joined(separator: " ")
            guard text != last else { return }
            last = text
            SupportLog.log("siri", text.isEmpty ? "(pencere yok)" : text)
            SupportLog.log("siri", "AX: " + axSummary(pid: pid))
        }
    }

    /// Teşhis: Bildirim Merkezi'nin erişilebilirlik ağacının ilk katmanları (rol, alt rol, kimlik, açıklama).
    static func axSummary(pid: pid_t) -> String {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        func text(_ element: AXUIElement, _ attribute: String) -> String? {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            return (value as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        var parts: [String] = []
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 4, parts.count < 40 else { return }
            let info = [kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
                .compactMap { text(element, $0) }.joined(separator: "/")
            if !info.isEmpty { parts.append("\(depth):\(info)") }
            var children: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
            for child in ((children as? [AXUIElement]) ?? []).prefix(6) { walk(child, depth: depth + 1) }
        }
        var windows: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
        for window in (windows as? [AXUIElement]) ?? [] { walk(window, depth: 0) }
        return parts.joined(separator: " | ")
    }

    /// Siri katmanındaki metinler (soru ve cevap), ekrandaki sırayla. Yazı alanı ve kısa düğme adları atlanır.
    static func texts() -> [String] {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
        else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        func text(_ element: AXUIElement, _ attribute: String) -> String {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            return (value as? String) ?? ""
        }
        var found: [String] = []
        var visited = 0
        func walk(_ element: AXUIElement, depth: Int) {
            visited += 1
            guard depth < 18, visited < 700 else { return }
            let role = text(element, kAXRoleAttribute)
            if role == kAXTextFieldRole || role == kAXTextAreaRole { return }
            if role == kAXStaticTextRole {
                let value = text(element, kAXValueAttribute).trimmingCharacters(in: .whitespacesAndNewlines)
                if value.count > 2, !found.contains(value) { found.append(value) }
            }
            var children: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
            for child in (children as? [AXUIElement]) ?? [] { walk(child, depth: depth + 1) }
        }
        var windows: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
        for window in (windows as? [AXUIElement]) ?? [] where text(window, kAXSubroleAttribute) == "AXSystemDialog" {
            walk(window, depth: 0)
        }
        return found
    }
}
