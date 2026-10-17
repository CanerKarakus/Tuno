import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

@Observable
@MainActor
final class SwitcherModel {
    var windows: [WindowInfo] = []
    var query = ""
    var selection = 0
    var thumbnails: [CGWindowID: NSImage] = [:]
    var isLive = true
    /// Panel açıldığında imlecin yeri: imleç oynatılana kadar üzerinde durduğu kart seçilmez.
    var openedAt: NSPoint?
    var onPick: ((Int) -> Void)?
    var onClose: ((WindowInfo) -> Void)?
    var onMinimize: ((WindowInfo) -> Void)?

    /// Aramaya uyan pencereler (uygulama adı ya da pencere başlığı).
    var visible: [WindowInfo] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return windows }
        return windows.filter { $0.appName.localizedStandardContains(text) || $0.title.localizedStandardContains(text) }
    }
}

/// Windows'taki Alt-Tab, Mac'te ⌘⇥: ⌘ basılı tutuldukça pencereler arasında gezinir, ⌘ bırakılınca
/// seçili pencereyi öne getirir. ⇧ ile geri, oklarla gezinme, Esc iptal. Açıkken yazmaya
/// başlanırsa pencereler süzülür; bu durumda ⌘ bırakılsa da açık kalır, ↩ ile seçilir.
///
/// Liste en son kullanılan pencere başta olacak şekilde sıralıdır; hızlı bir ⌘⇥ panel görünmeden
/// bir önceki pencereye geçer (macOS'taki gibi panel kısa bir gecikmeyle açılır).
///
/// Klavye olayları yakalayıcıda hiç bekletilmez: pencere listesini hazırlamak ve pencereyi öne
/// getirmek yavaş olabilir, yakalayıcı geç cevap verirse macOS onu kapatıp basışlar kaçıyordu.
@MainActor
final class WindowSwitcher {
    private let model = SwitcherModel()
    private var panel: NSPanel?
    private var thumbnailTask: Task<Void, Never>?
    /// Arama başladıysa ⌘ bırakılınca kapanmaz.
    private var isSearching = false
    /// ⌘⇥ ile başlayan geçiş sürüyor (panel henüz görünmüyor olabilir).
    private var isActive = false
    /// Liste hazırlanmadan gelen ⇥ basışları.
    private var pendingMoves = 0
    private var showWork: DispatchWorkItem?
    private weak var shortcuts: ShortcutCenter?

    static let showThumbnailsKey = "switcherThumbnails"

    private var isShowing: Bool { panel?.isVisible == true }

    init(shortcuts: ShortcutCenter) {
        self.shortcuts = shortcuts
        model.onPick = { [weak self] index in
            self?.model.selection = index
            self?.commit()
        }
        model.onClose = { [weak self] window in
            WindowCatalog.close(window)
            self?.remove(window)
        }
        model.onMinimize = { [weak self] window in
            WindowCatalog.minimize(window)
            guard let self, let index = self.model.windows.firstIndex(of: window) else { return }
            self.model.windows[index] = window.minimized
        }
    }

    // MARK: - Klavye

    /// KeyboardTap'ten gelen olaylar; olayı üstlenirse `true`.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        guard isActive else {
            guard type == .keyDown, keyCode == kVK_Tab, flags.contains(.maskCommand),
                  !flags.contains(.maskControl), !flags.contains(.maskAlternate),
                  shortcuts?.isEnabled(.switchWindows) == true, shortcuts?.isAvailable(.switchWindows) == true
            else { return false }
            begin(backward: flags.contains(.maskShift))
            return true
        }

        switch type {
        case .flagsChanged:
            if !flags.contains(.maskCommand) && !isSearching { later { $0.commit() } }
            return false
        case .keyUp:
            return true
        case .keyDown:
            break
        default:
            return false
        }

        switch keyCode {
        case kVK_Tab: move(flags.contains(.maskShift) ? -1 : 1)
        case kVK_LeftArrow: move(-1)
        case kVK_RightArrow: move(1)
        case kVK_UpArrow: move(-Self.columns(count: model.visible.count))
        case kVK_DownArrow: move(Self.columns(count: model.visible.count))
        case kVK_Escape: cancel()
        case kVK_Return, kVK_ANSI_KeypadEnter: later { $0.commit() }
        case kVK_Delete:
            if !model.query.isEmpty { setQuery(String(model.query.dropLast())) }
        default:
            guard let text = NSEvent(cgEvent: event)?.charactersIgnoringModifiers, !text.isEmpty,
                  text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { return true }
            isSearching = true
            setQuery(model.query + text)
        }
        return true
    }

    /// Yakalayıcının dışında, sıradaki ana döngü turunda çalıştırır.
    private func later(_ body: @escaping (WindowSwitcher) -> Void) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { if let self { body(self) } }
        }
    }

    private func begin(backward: Bool) {
        isActive = true
        isSearching = false
        pendingMoves = backward ? -1 : 1
        model.windows = []
        model.query = ""
        later { $0.load() }
    }

    /// Pencere listesini hazırlar; panel, ⌘ kısa sürede bırakılmazsa açılır.
    private func load() {
        guard isActive, model.windows.isEmpty else { return }
        guard CGPreflightScreenCaptureAccess(), AXIsProcessTrusted() else { return hide() }
        let windows = WindowCatalog.windows()
        guard !windows.isEmpty else { return hide() }
        model.windows = windows
        model.query = ""
        isSearching = false
        let showThumbnails = UserDefaults.standard.bool(forKey: Self.showThumbnailsKey, default: true)
        // Önceki görüntüler hemen görünür; yenileri hazır oldukça tek tek değişir.
        model.thumbnails = showThumbnails ? WindowCatalog.cachedThumbnails.filter { id, _ in windows.contains { $0.id == id } } : [:]
        // İlk basışta bir önceki pencere (listede ikinci) seçili gelir; bekleyen basışlar uygulanır.
        model.selection = 0
        let moves = pendingMoves
        pendingMoves = 0
        move(moves)
        model.isLive = showThumbnails
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isActive, !self.isShowing else { return }
                self.model.openedAt = NSEvent.mouseLocation
                self.show()
            }
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)

        if showThumbnails {
            thumbnailTask?.cancel()
            thumbnailTask = Task { [model] in
                await WindowCatalog.thumbnails(for: windows, maxDimension: 220) { id, image in
                    // Önbellekteki görüntünün yerine geçerken solup belirmesin.
                    if model.thumbnails[id] == nil {
                        withAnimation(.easeOut(duration: 0.15)) { model.thumbnails[id] = image }
                    } else {
                        model.thumbnails[id] = image
                    }
                }
            }
        }
    }

    private func move(_ offset: Int) {
        let count = model.visible.count
        guard count > 0 else {
            if model.windows.isEmpty { pendingMoves += offset }
            return
        }
        model.selection = ((model.selection + offset) % count + count) % count
    }

    private func setQuery(_ query: String) {
        model.query = query
        model.selection = 0
        layout(animated: true)
    }

    private func remove(_ window: WindowInfo) {
        model.windows.removeAll { $0.id == window.id }
        if model.visible.isEmpty && model.query.isEmpty { return cancel() }
        model.selection = min(model.selection, max(model.visible.count - 1, 0))
        layout(animated: true)
    }

    private func commit() {
        guard isActive else { return }
        load()
        let visible = model.visible
        let window = visible.indices.contains(model.selection) ? visible[model.selection] : nil
        hide()
        if let window { WindowCatalog.focus(window) }
    }

    private func cancel() { hide() }

    // MARK: - Panel

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        layout(animated: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
    }

    /// Paneli pencere sayısına göre boyutlandırıp imlecin bulunduğu ekranın ortasına koyar.
    private func layout(animated: Bool) {
        guard let panel else { return }
        let size = Self.panelSize(count: max(model.visible.count, 1), searching: !model.query.isEmpty)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let frame = NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: true, animate: animated && panel.isVisible)
    }

    private func hide() {
        isActive = false
        pendingMoves = 0
        showWork?.cancel()
        showWork = nil
        isSearching = false
        thumbnailTask?.cancel()
        panel?.orderOut(nil)
        // Kartlar kaldırılınca canlı görüntü yakalamaları da durur.
        model.windows = []
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingView(rootView: SwitcherView(model: model))
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        return Glass.panel(content: hosting, cornerRadius: 26, level: .popUpMenu)
    }

    static let card = CGSize(width: 200, height: 170)
    static let spacing: CGFloat = 12
    static let padding: CGFloat = 18
    static let searchHeight: CGFloat = 40

    static func columns(count: Int) -> Int {
        let screenWidth = NSScreen.main?.visibleFrame.width ?? 1440
        let fit = Int((screenWidth * 0.85 - padding * 2 + spacing) / (card.width + spacing))
        return max(1, min(count, fit, 7))
    }

    private static func panelSize(count: Int, searching: Bool) -> CGSize {
        let columns = columns(count: count)
        let rows = Int(ceil(Double(count) / Double(columns)))
        return CGSize(
            width: max(CGFloat(columns) * card.width + CGFloat(columns - 1) * spacing + padding * 2, 320),
            height: CGFloat(rows) * card.height + CGFloat(rows - 1) * spacing + padding * 2
                + (searching ? searchHeight : 0))
    }
}

private struct SwitcherView: View {
    let model: SwitcherModel

    var body: some View {
        let windows = model.visible
        let columns = Array(repeating: GridItem(.fixed(WindowSwitcher.card.width), spacing: WindowSwitcher.spacing),
                            count: WindowSwitcher.columns(count: max(windows.count, 1)))
        VStack(spacing: 0) {
            if !model.query.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text(model.query).font(.system(size: 15, weight: .medium))
                    Spacer()
                    if windows.isEmpty {
                        Text("Pencere yok").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 6)
                .frame(height: WindowSwitcher.searchHeight - 8)
                .padding(.bottom, 8)
            }
            LazyVGrid(columns: columns, spacing: WindowSwitcher.spacing) {
                ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                    WindowCard(window: window, thumbnail: model.thumbnails[window.id],
                               isSelected: index == model.selection, isLive: model.isLive,
                               onClose: { model.onClose?(window) },
                               onMinimize: window.isMinimized ? nil : { model.onMinimize?(window) })
                        .onContinuousHover { phase in
                            guard case .active = phase else { return }
                            if let start = model.openedAt {
                                let mouse = NSEvent.mouseLocation
                                guard hypot(mouse.x - start.x, mouse.y - start.y) > 4 else { return }
                                model.openedAt = nil
                            }
                            if model.selection != index { model.selection = index }
                        }
                        .onTapGesture { model.onPick?(index) }
                }
            }
        }
        .padding(WindowSwitcher.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.snappy(duration: 0.15), value: model.selection)
    }
}

/// Alt-Tab ve Dock önizlemesinde kullanılan pencere kartı. Üzerine gelince kapatma ve
/// küçültme düğmeleri görünür.
struct WindowCard: View {
    let window: WindowInfo
    let thumbnail: NSImage?
    let isSelected: Bool
    var size = WindowSwitcher.card
    /// Pencere canlı akıtılsın mı (video oynuyorsa önizlemede de oynar).
    var isLive = true
    var onClose: (() -> Void)?
    var onMinimize: (() -> Void)?
    @State private var hovering = false
    @State private var aspect: CGFloat?

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if isLive, !window.isMinimized, let ratio = thumbnail.map({ $0.size.width / max($0.size.height, 1) }) ?? aspect {
                    LiveWindowView(windowID: window.id, placeholder: thumbnail,
                                   maxDimension: max(size.width, size.height))
                        .aspectRatio(ratio, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                } else if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                        .transition(.opacity)
                } else {
                    Image(nsImage: window.icon)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .opacity(window.isMinimized ? 0.6 : 1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                if thumbnail != nil || (isLive && aspect != nil && !window.isMinimized) {
                    Image(nsImage: window.icon).resizable().frame(width: 30, height: 30).offset(x: 4, y: 6)
                }
            }

            HStack(spacing: 4) {
                if window.isMinimized {
                    Image(systemName: "minus.circle.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text(window.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(height: 16)
        }
        .padding(10)
        .frame(width: size.width, height: size.height)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.0001)))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.9) : .clear, lineWidth: 2))
        .overlay(alignment: .topTrailing) {
            if hovering, onClose != nil || onMinimize != nil {
                HStack(spacing: 4) {
                    if let onMinimize { CardButton(symbol: "minus", help: "Küçült", action: onMinimize) }
                    if let onClose { CardButton(symbol: "xmark", help: "Kapat", action: onClose) }
                }
                .padding(6)
                .transition(.opacity)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .onAppear { if aspect == nil { aspect = WindowCatalog.aspectRatio(of: window.id) } }
    }
}

private struct CardButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(hovering && symbol == "xmark" ? Color.white : .primary)
                .frame(width: 22, height: 22)
                .background(hovering && symbol == "xmark" ? AnyShapeStyle(Color.red) : AnyShapeStyle(.regularMaterial),
                            in: Circle())
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
