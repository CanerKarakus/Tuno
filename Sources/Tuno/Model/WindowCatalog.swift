import AppKit
import ApplicationServices
import ScreenCaptureKit
import os

private let log = Logger(subsystem: "app.tuno.mac", category: "windows")

struct WindowInfo: Identifiable, Hashable {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let isMinimized: Bool

    var icon: NSImage {
        NSRunningApplication(processIdentifier: pid)?.icon ?? NSWorkspace.shared.icon(for: .application)
    }

    var displayTitle: String { title.isEmpty ? appName : title }

    var minimized: WindowInfo { WindowInfo(id: id, pid: pid, appName: appName, title: title, isMinimized: true) }
}

/// Açık pencereleri listeler, öne getirir ve küçük önizlemelerini alır.
///
/// Pencere başlıkları ve küçültülmüş pencereler Erişilebilirlik API'sinden, sıralama
/// (en son kullanılan önde) pencere sunucusundan gelir. Önizlemeler ScreenCaptureKit ile
/// alınır ve Ekran Kaydı izni gerektirir.
@MainActor
enum WindowCatalog {
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindow: GetWindow? = {
        let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW)
        return handle.flatMap { dlsym($0, "_AXUIElementGetWindow") }.map { unsafeBitCast($0, to: GetWindow.self) }
    }()

    static var canCaptureScreen: Bool { CGPreflightScreenCaptureAccess() }

    static func requestScreenCapture() {
        CGRequestScreenCaptureAccess()
    }

    /// Önden arkaya sıralı pencereler; ardından başka masaüstlerindekiler, en sonda küçültülmüşler.
    static func windows(for pid: pid_t? = nil) -> [WindowInfo] {
        let ownPID = getpid()
        // Tuno da Dock'ta göründüğü sürece (ayarlar penceresi açıkken) listelenir; arka plandayken değil.
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && (pid == nil || $0.processIdentifier == pid)
        }
        let appsByPID = Dictionary(apps.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })

        // Erişilebilirlik: her uygulamanın standart pencereleri (başlık, küçültülme durumu).
        var axWindows: [CGWindowID: WindowInfo] = [:]
        for app in apps {
            // Tuno'nun kendi pencereleri doğrudan AppKit'ten: kendine Erişilebilirlik sorgusu ana iş parçacığını bekletir.
            if app.processIdentifier == ownPID {
                for window in ownWindows() {
                    axWindows[CGWindowID(window.windowNumber)] = WindowInfo(
                        id: CGWindowID(window.windowNumber), pid: ownPID, appName: app.localizedName ?? "Tuno",
                        title: window.title, isMinimized: window.isMiniaturized)
                }
                continue
            }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.25)
            for window in children(of: element, kAXWindowsAttribute) {
                guard let id = windowID(window), id != 0,
                      (attribute(window, kAXSubroleAttribute) as String?) == (kAXStandardWindowSubrole as String)
                else { continue }
                axWindows[id] = WindowInfo(
                    id: id, pid: app.processIdentifier, appName: app.localizedName ?? "",
                    title: attribute(window, kAXTitleAttribute) ?? "",
                    isMinimized: attribute(window, kAXMinimizedAttribute) ?? false)
            }
        }

        // Pencere sunucusu sırası (önden arkaya). Erişilebilirlik yalnızca bu masaüstündeki pencereleri
        // verir; diğer masaüstlerindeki ve tam ekran pencereler buradan eklenir.
        let all = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]) ?? []
        let normal = all.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
        let isOnScreen = { (entry: [String: Any]) in entry[kCGWindowIsOnscreen as String] as? Bool ?? false }
        // Ekrandakiler önden arkaya: en son kullanılan pencere en önde.
        let stacked = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]) ?? []
        var ordered: [WindowInfo] = []
        var seen: Set<CGWindowID> = []
        for entry in stacked where (entry[kCGWindowLayer as String] as? Int) == 0 {
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let info = axWindows[id], !seen.contains(id)
            else { continue }
            ordered.append(info)
            seen.insert(id)
        }

        let visibleSpaces = spaces(of: normal.filter(isOnScreen).compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        var elsewhere: [WindowInfo] = []
        for entry in normal where !isOnScreen(entry) {
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID, axWindows[id] == nil, !seen.contains(id),
                  let owner = entry[kCGWindowOwnerPID as String] as? pid_t, owner != ownPID, let app = appsByPID[owner],
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = (entry[kCGWindowBounds as String] as? NSDictionary)
                      .flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }),
                  bounds.width >= 120, bounds.height >= 120
            else { continue }
            // Hiçbir masaüstünde olmayanlar gizli yardımcı pencerelerdir; görünen masaüstündekiler
            // ise sekme gibi Erişilebilirlik'te zaten bulunmayan arka plan pencereleri.
            let windowSpaces = spaces(of: [id])
            guard !windowSpaces.isEmpty, windowSpaces.isDisjoint(with: visibleSpaces) else { continue }
            elsewhere.append(WindowInfo(id: id, pid: owner, appName: app.localizedName ?? "",
                                        title: entry[kCGWindowName as String] as? String ?? "", isMinimized: false))
            seen.insert(id)
        }

        let rest = axWindows.values.filter { !seen.contains($0.id) }
            .sorted { ($0.isMinimized ? 1 : 0, $0.appName) < ($1.isMinimized ? 1 : 0, $1.appName) }
        return ordered + elsewhere + rest
    }

    /// Tuno'nun Alt-Tab'da gösterilecek pencereleri: başlıklı, normal düzeyde, görünür ya da küçültülmüş.
    private static func ownWindows() -> [NSWindow] {
        NSApp.windows.filter {
            $0.styleMask.contains(.titled) && !($0 is NSPanel) && $0.level == .normal && ($0.isVisible || $0.isMiniaturized)
        }
    }

    private static func ownWindow(_ info: WindowInfo) -> NSWindow? {
        guard info.pid == getpid() else { return nil }
        return ownWindows().first { CGWindowID($0.windowNumber) == info.id }
    }

    /// Pencereyi (gerekirse küçültülmüşten çıkararak) öne getirir ve uygulamasını etkinleştirir.
    static func focus(_ info: WindowInfo) {
        if let window = ownWindow(info) {
            // Tuno kapatılmış ya da erişilebilirlik modunda (Dock'tan gizli) olabilir; önce normal moda geçilir,
            // yoksa pencere öne gelmez. Alt-Tab paneli kapandıktan sonra çalışsın diye bir tur sonra.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    NSApp.setActivationPolicy(.regular)
                    if window.isMiniaturized { window.deminiaturize(nil) }
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                }
            }
            return
        }
        let found = raise(info)
        let app = AXUIElementCreateApplication(info.pid)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: info.pid)?.activate()
        // Uygulama etkinleşirken kendi ön penceresini öne alabilir; seçilen pencereyi yeniden öne getir.
        // Başka masaüstündeki pencere ise ancak oraya geçildikten sonra Erişilebilirlik'te görünür.
        DispatchQueue.main.asyncAfter(deadline: .now() + (found ? 0.05 : 0.4)) {
            MainActor.assumeIsolated { _ = raise(info) }
        }
    }

    /// Pencereyi kapat düğmesine basarak kapatır (kaydedilmemiş belgede uygulama kendisi sorar).
    static func close(_ info: WindowInfo) {
        if let own = ownWindow(info) { own.performClose(nil); return }
        guard let window = element(for: info) else { return }
        var button: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button) == .success,
           let button, CFGetTypeID(button) == AXUIElementGetTypeID() {
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        }
        cachedThumbnails[info.id] = nil
    }

    static func minimize(_ info: WindowInfo) {
        if let own = ownWindow(info) { own.miniaturize(nil); return }
        guard let window = element(for: info) else { return }
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }

    private static func element(for info: WindowInfo) -> AXUIElement? {
        let app = AXUIElementCreateApplication(info.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        return children(of: app, kAXWindowsAttribute).first { windowID($0) == info.id }
    }

    @discardableResult
    private static func raise(_ info: WindowInfo) -> Bool {
        let app = AXUIElementCreateApplication(info.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        for window in children(of: app, kAXWindowsAttribute) where windowID(window) == info.id {
            if (attribute(window, kAXMinimizedAttribute) as Bool?) == true {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            return true
        }
        return false
    }

    // MARK: - Önizlemeler

    /// Son alınan önizlemeler: panel açılır açılmaz bunlar gösterilir, yenileri geldikçe değişir.
    private(set) static var cachedThumbnails: [CGWindowID: NSImage] = [:]

    /// Pencerelerin küçük önizlemeleri (Ekran Kaydı izni yoksa hiçbiri). Her önizleme hazır olur olmaz
    /// `update` ile verilir; yavaş bir pencere diğerlerini bekletmez.
    static func thumbnails(for windows: [WindowInfo], maxDimension: CGFloat,
                           update: @escaping @MainActor (CGWindowID, NSImage) -> Void) async {
        guard canCaptureScreen, !windows.isEmpty else { return }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            log.error("Pencere listesi alınamadı: \(error.localizedDescription, privacy: .public)")
            return
        }
        let wanted = Set(windows.filter { !$0.isMinimized }.map(\.id))
        let targets = content.windows.filter { wanted.contains($0.windowID) }

        await withTaskGroup(of: (CGWindowID, NSImage?).self) { group in
            for window in targets {
                group.addTask {
                    let scale = min(maxDimension / max(window.frame.width, 1), maxDimension / max(window.frame.height, 1), 1)
                    let image = await capture(window, pixelSize: CGSize(width: window.frame.width * scale * 2,
                                                                        height: window.frame.height * scale * 2))
                    let size = NSSize(width: window.frame.width * scale, height: window.frame.height * scale)
                    return (window.windowID, image.map { NSImage(cgImage: $0, size: size) })
                }
            }
            for await (id, image) in group {
                guard let image, !Task.isCancelled else { continue }
                cachedThumbnails[id] = image
                update(id, image)
            }
        }
    }

    private static var shareableCache: (task: Task<SCShareableContent?, Never>, date: Date)?

    /// Canlı akış için pencere. Bir panelde onlarca akış aynı anda açıldığı için liste bir kez
    /// istenir ve kısa süre paylaşılır.
    static func shareableWindow(_ id: CGWindowID) async -> SCWindow? {
        guard canCaptureScreen else { return nil }
        if let cache = shareableCache, Date().timeIntervalSince(cache.date) < 1.5,
           let window = await cache.task.value?.windows.first(where: { $0.windowID == id }) {
            return window
        }
        let task = Task { try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        shareableCache = (task, Date())
        return await task.value?.windows.first { $0.windowID == id }
    }

    /// Pencerenin en-boy oranı (canlı görüntünün çerçevesi için).
    static func aspectRatio(of id: CGWindowID) -> CGFloat? {
        frame(of: id).flatMap { $0.height > 0 ? $0.width / $0.height : nil }
    }

    /// Pencerenin tam boyutlu görüntüsü ve ekrandaki yeri (AppKit koordinatlarında).
    static func snapshot(of id: CGWindowID) async -> (image: NSImage, frame: NSRect)? {
        guard canCaptureScreen,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let window = content.windows.first(where: { $0.windowID == id }), let frame = frame(of: id)
        else { return nil }
        let scale = NSScreen.screens.first { $0.frame.intersects(frame) }?.backingScaleFactor ?? 2
        guard let image = await capture(window, pixelSize: CGSize(width: frame.width * scale, height: frame.height * scale))
        else { return nil }
        return (NSImage(cgImage: image, size: frame.size), frame)
    }

    /// Pencere, ekrandaki normal pencerelerin en önünde mi (Tuno'nun kendi pencereleri hariç)?
    static func isFrontmost(_ info: WindowInfo) -> Bool {
        let own = getpid()
        let front = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]])?.first {
                ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowOwnerPID as String] as? pid_t) != own
            }
        return front?[kCGWindowNumber as String] as? CGWindowID == info.id
    }

    /// Pencerenin ekrandaki yeri (AppKit koordinatları: sol alttan).
    static func frame(of id: CGWindowID) -> NSRect? {
        guard let entry = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first,
              let bounds = (entry[kCGWindowBounds as String] as? NSDictionary)
                  .flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }),
              let primary = NSScreen.screens.first
        else { return nil }
        return NSRect(x: bounds.minX, y: primary.frame.maxY - bounds.maxY, width: bounds.width, height: bounds.height)
    }

    nonisolated private static func capture(_ window: SCWindow, pixelSize: CGSize) async -> CGImage? {
        let configuration = SCStreamConfiguration()
        configuration.width = max(Int(pixelSize.width), 2)
        configuration.height = max(Int(pixelSize.height), 2)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            log.error("Yakalanamadı \(window.windowID): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Masaüstleri (Spaces)

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private static let mainConnection: MainConnection? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSMainConnectionID")
        .map { unsafeBitCast($0, to: MainConnection.self) }
    private static let copySpaces: CopySpaces? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSCopySpacesForWindows")
        .map { unsafeBitCast($0, to: CopySpaces.self) }

    /// Pencerelerin bulunduğu masaüstleri (tümü).
    private static func spaces(of ids: [CGWindowID]) -> Set<UInt64> {
        guard !ids.isEmpty, let mainConnection, let copySpaces,
              let array = copySpaces(mainConnection(), 0x7, ids.map { NSNumber(value: $0) } as CFArray)?
                  .takeRetainedValue() as? [NSNumber]
        else { return [] }
        return Set(array.map(\.uint64Value))
    }

    // MARK: - Erişilebilirlik yardımcıları

    /// Erişilebilirlik penceresinin pencere sunucusu numarası.
    static func windowNumber(of window: AXUIElement) -> CGWindowID? { windowID(window) }

    private static func windowID(_ window: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard let getWindow, getWindow(window, &id) == .success else { return nil }
        return id
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func children(of element: AXUIElement, _ name: String) -> [AXUIElement] {
        attribute(element, name) ?? []
    }
}
