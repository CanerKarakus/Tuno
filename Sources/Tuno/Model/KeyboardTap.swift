import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Observation

/// Klavye olaylarını sistemden önce gören yakalayıcı (Erişilebilirlik izni gerektirir).
/// ⌘⇥ pencere değiştiricisi ve Finder'da kes-yapıştır bunu kullanır. Sırayla her işleyiciye
/// sorulur; biri olayı üstlenirse olay öndeki uygulamaya gitmez.
@MainActor
final class KeyboardTap {
    typealias Handler = (CGEventType, CGEvent) -> Bool

    var handlers: [Handler] = []
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    fileprivate static weak var current: KeyboardTap?

    init() { Self.current = self }

    /// Erişilebilirlik izni varsa yakalayıcıyı açar; izin yoksa kapalı kalır.
    func refresh() {
        if AXIsProcessTrusted() { start() } else { stop() }
    }

    private func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, _ in
                MainActor.assumeIsolated { KeyboardTap.current?.handle(type, event) }
            }, userInfo: nil)
        else { return }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        self.tap = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard !SyntheticEvent.isMarked(event) else { return Unmanaged.passUnretained(event) }
        for handler in handlers where handler(type, event) { return nil }
        return Unmanaged.passUnretained(event)
    }
}

/// Windows'taki gibi Finder'da ⌘X ile kesip ⌘V ile taşıma. ⌘X dosyaları kopyalar ve "kesildi"
/// olarak işaretler; ardından ⌘V, macOS'un "Öğeyi Buraya Taşı" (⌥⌘V) komutunu çalıştırır.
/// Dosya adı düzenlenirken ⌘X/⌘V her zamanki gibi metin için çalışır.
@Observable
@MainActor
final class FinderCutPaste {
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            cutChangeCount = nil
        }
    }

    /// Enter dosyayı açar, F2 yeniden adlandırır (macOS'ta Enter yeniden adlandırır).
    var enterOpens: Bool {
        didSet { UserDefaults.standard.set(enterOpens, forKey: Self.enterKey) }
    }

    /// Delete (⌦) seçili dosyayı çöpe atar (macOS'ta ⌘⌫).
    var deleteToTrash: Bool {
        didSet { UserDefaults.standard.set(deleteToTrash, forKey: Self.deleteKey) }
    }

    @ObservationIgnored private var cutChangeCount: Int?
    private static let enabledKey = "finderCutPaste"
    private static let enterKey = "finderEnterOpens"
    private static let deleteKey = "finderDeleteToTrash"

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey, default: true)
        enterOpens = UserDefaults.standard.bool(forKey: Self.enterKey, default: true)
        deleteToTrash = UserDefaults.standard.bool(forKey: Self.deleteKey, default: true)
    }

    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if handleEnter(type, event) { return true }
        guard type == .keyDown, isEnabled,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder",
              event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]) == .maskCommand,
              let key = NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.lowercased(),
              key == "x" || key == "v", !Self.isEditingText()
        else { return false }

        if key == "x" {
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return true }
            SyntheticEvent.postKey(KeyboardLayout.keyCode(for: "c", fallback: 8), flags: .maskCommand)
            // Finder panoyu kopyalamayı bitirince hangi içeriğin "kesildiğini" hatırla.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                MainActor.assumeIsolated { self?.cutChangeCount = NSPasteboard.general.changeCount }
            }
            VolumeHUD.shared.show(symbol: "scissors", title: "Kesildi")
            return true
        }
        guard let cut = cutChangeCount, NSPasteboard.general.changeCount == cut else { return false }
        cutChangeCount = nil
        SyntheticEvent.postKey(KeyboardLayout.keyCode(for: "v", fallback: 9), flags: [.maskCommand, .maskAlternate])
        return true
    }

    private func handleEnter(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let isEnter = keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter || keyCode == kVK_F2
        guard type == .keyDown, (enterOpens && isEnter) || (deleteToTrash && keyCode == kVK_ForwardDelete),
              event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]).isEmpty,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder",
              Self.isBrowsingFiles()
        else { return false }
        if keyCode == kVK_ForwardDelete {
            SyntheticEvent.postKey(kVK_Delete, flags: .maskCommand)        // ⌘⌫ = çöpe at
        } else if keyCode == kVK_F2 {
            SyntheticEvent.postKey(kVK_Return, flags: [])          // macOS'ta Enter = yeniden adlandır
        } else {
            SyntheticEvent.postKey(kVK_DownArrow, flags: .maskCommand)   // ⌘↓ = aç
        }
        return true
    }

    /// Finder'da dosya listesindeyiz (ad düzenlenmiyor, iletişim kutusu ya da arama alanı değil).
    private static func isBrowsingFiles() -> Bool {
        guard let focused = focusedElement() else { return false }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &role)
        guard ![kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, kAXButtonRole].map({ $0 as String })
            .contains(role as? String ?? "") else { return false }
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return true }   // masaüstü
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXSubroleAttribute as CFString, &subrole)
        return (subrole as? String) == (kAXStandardWindowSubrole as String)
    }

    private static func focusedElement() -> AXUIElement? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return (focused as! AXUIElement)
    }

    /// Finder'da bir metin alanı (dosya adı, arama) düzenleniyor mu?
    private static func isEditingText() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return false }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXRoleAttribute as CFString, &role)
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].map { $0 as String }.contains(role as? String ?? "")
    }
}
