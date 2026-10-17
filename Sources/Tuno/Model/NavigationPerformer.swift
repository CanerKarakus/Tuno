import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum NavigationDirection {
    case back, forward

    fileprivate var keyEquivalent: String { self == .back ? "[" : "]" }
    /// ⌘[ / ⌘] kısayolunun bulunduğu fiziksel tuş (ABD düzeninde "[" / "]").
    fileprivate var keyCode: Int { self == .back ? kVK_ANSI_LeftBracket : kVK_ANSI_RightBracket }
    fileprivate var mouseButton: Int64 { self == .back ? 3 : 4 }
}

/// Öndeki uygulamada geri / ileri gider.
///
/// Klavye kısayolu göndermek klavye düzenine bağlıdır (ör. Türkçe Q'da "[" başka tuştadır),
/// bu yüzden Erişilebilirlik API'siyle menüde ⌘[ / ⌘] kısayoluna sahip öğe (Safari, Chrome,
/// Finder… "Geri" / "İleri") bulunup doğrudan çalıştırılır. Böyle bir öğe yoksa farenin
/// geri / ileri yan tuşu gönderilir.
final class NavigationPerformer: @unchecked Sendable {
    static let shared = NavigationPerformer()

    private let queue = DispatchQueue(label: "app.tuno.navigation", qos: .userInteractive)
    private var cache: [pid_t: [String: AXUIElement]] = [:]

    /// Herhangi bir iş parçacığından çağrılabilir. Klavye düzeni (TIS) yalnızca ana iş
    /// parçacığında okunabildiği için önce oraya, menü araması için arka plana geçilir.
    func perform(_ direction: NavigationDirection) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.dispatch(direction) }
        }
    }

    @MainActor
    private func dispatch(_ direction: NavigationDirection) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        // Menüler kısayolları klavye düzenine göre yerelleştirir (Türkçe Q'da ⌘[ → ⌘Ğ);
        // aynı fiziksel tuşun o anki düzende ürettiği karakteri de kabul et.
        let back = Self.acceptedCharacters(for: .back)
        let forward = Self.acceptedCharacters(for: .forward)
        queue.async { self.navigate(direction, pid: pid, back: back, forward: forward) }
    }

    private func navigate(_ direction: NavigationDirection, pid: pid_t, back: Set<String>, forward: Set<String>) {
        let key = direction.keyEquivalent
        if let item = cache[pid]?[key], press(item) { return }

        let items = Self.findNavigationItems(pid: pid, back: back, forward: forward)
        cache[pid] = items
        if cache.count > 20 { cache = [pid: items] }
        if let item = items[key], press(item) { return }
        Self.postMouseButton(direction)
    }

    /// Menü öğesine basar. Erişilebilirlik'in bildirdiği "etkin" durumu menü açılana kadar
    /// güncellenmeyebildiği için ona bakılmaz; öğe gerçekten devre dışıysa uygulama yok sayar.
    /// `false`: öğe artık geçersiz (uygulama yeniden başlatılmış vb.), yeniden aranmalı.
    private func press(_ item: AXUIElement) -> Bool {
        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        return result != .invalidUIElement && result != .illegalArgument
    }

    /// Doğrudan "[" / "]" ve fiziksel tuşun geçerli klavye düzenindeki karakteri (büyük harf).
    @MainActor
    private static func acceptedCharacters(for direction: NavigationDirection) -> Set<String> {
        var result: Set<String> = [direction.keyEquivalent]
        if let localized = KeyboardLayout.character(forKeyCode: direction.keyCode) { result.insert(localized.uppercased()) }
        return result
    }

    private static func findNavigationItems(
        pid: pid_t, back: Set<String>, forward: Set<String>
    ) -> [String: AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let menuBar: AXUIElement = attribute(app, kAXMenuBarAttribute) else { return [:] }
        var found: [String: AXUIElement] = [:]
        for menuBarItem in children(menuBar) {
            for menu in children(menuBarItem) {
                for item in children(menu) {
                    guard let raw: String = attribute(item, kAXMenuItemCmdCharAttribute),
                          let modifiers: Int = attribute(item, kAXMenuItemCmdModifiersAttribute),
                          modifiers == 0   // yalnızca ⌘
                    else { continue }
                    let char = raw.uppercased()
                    let key = back.contains(char) ? "[" : forward.contains(char) ? "]" : nil
                    if let key, found[key] == nil { found[key] = item }
                }
            }
            if found.count == 2 { break }
        }
        return found
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) ?? []
    }

    private static func postMouseButton(_ direction: NavigationDirection) {
        SyntheticEvent.postMouseButton(direction.mouseButton)
    }

}

