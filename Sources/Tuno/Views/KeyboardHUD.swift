import AppKit
import SwiftUI

/// Caps Lock ve klavye dili göstergesi: ses göstergesiyle aynı yerde ve boyutta (ekranın sağ üstü).
/// Hafif büyükten yerine oturarak belirir, solarak kaybolur.
@MainActor
final class KeyboardHUD {
    static let shared = KeyboardHUD()

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private let model = KeyboardHUDModel()
    private static let size = CGSize(width: 290, height: 64)

    func show(symbol: String, title: String) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let wasVisible = panel.isVisible && model.isShown
        model.symbol = symbol
        model.title = title
        position(panel)
        panel.orderFrontRegardless()
        if !wasVisible {
            // Önce büyük ve görünmez; sonra yaylı bir animasyonla yerine oturur.
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                model.isLeaving = false
                model.isShown = false
            }
            DispatchQueue.main.async { [model] in
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { model.isShown = true }
            }
        }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }

    private func hide() {
        model.isLeaving = true
        withAnimation(.easeOut(duration: 0.35)) { model.isShown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.model.isShown else { return }
                self.panel?.orderOut(nil)
            }
        }
    }

    private func makePanel() -> NSPanel {
        // Büyüyerek belirirken kenarlar kesilmesin diye panel kutudan biraz büyük.
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: CGSize(width: Self.size.width * 1.3 + 40,
                                                                             height: Self.size.height * 1.3 + 40)),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let hosting = NSHostingView(rootView: KeyboardHUDView(model: model, size: Self.size))
        hosting.frame = panel.contentLayoutRect
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }

    /// Kutu, ses göstergesiyle aynı yerde: ekranın sağ üstü. Panel kutudan büyük olduğu için kaydırılır.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        let box = NSPoint(x: area.maxX - Self.size.width - 12, y: area.maxY - Self.size.height - 10)
        panel.setFrameOrigin(NSPoint(x: box.x - (panel.frame.width - Self.size.width) / 2,
                                     y: box.y - (panel.frame.height - Self.size.height) / 2))
    }
}

@Observable
@MainActor
private final class KeyboardHUDModel {
    var symbol = "capslock.fill"
    var title = ""
    var isShown = false
    /// Giderken yalnızca solar, büyümez.
    var isLeaving = false
}

private struct KeyboardHUDView: View {
    let model: KeyboardHUDModel
    let size: CGSize

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 30)
            Text(model.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .contentTransition(.opacity)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(width: size.width, height: size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .scaleEffect(model.isShown || model.isLeaving ? 1 : 1.2)
        .opacity(model.isShown ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
