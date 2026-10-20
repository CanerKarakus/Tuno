import AppKit
import SwiftUI

/// Kısayollar ve ses tuşları için ekranın sağ üstünde beliren küçük gösterge.
@MainActor
final class VolumeHUD {
    static let shared = VolumeHUD()

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private let model = HUDModel()

    func show(image: NSImage? = nil, symbol: String? = nil, title: String,
              value: Float? = nil, maximum: Float = 1, muted: Bool = false) {
        model.image = image
        model.symbol = symbol
        model.title = title
        model.value = value
        model.maximum = maximum
        model.muted = muted

        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        if !panel.isVisible || panel.alphaValue < 1 {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            guard let panel else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }) {
                MainActor.assumeIsolated { if panel.alphaValue == 0 { panel.orderOut(nil) } }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 290, height: 64),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let hosting = NSHostingView(rootView: HUDView(model: model))
        hosting.frame = panel.contentLayoutRect
        panel.contentView = hosting
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 12, y: frame.maxY - panel.frame.height - 10))
    }
}

@Observable
@MainActor
private final class HUDModel {
    var image: NSImage?
    var symbol: String?
    var title = ""
    var value: Float?
    var maximum: Float = 1
    var muted = false
}

private struct HUDView: View {
    let model: HUDModel

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image = model.image {
                    Image(nsImage: image).resizable()
                } else {
                    Image(systemName: model.symbol ?? "speaker.wave.2.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(model.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    if let value = model.value {
                        Text(model.muted ? L("Sessiz") : value.percentText)
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(model.muted ? Color.secondary : BoostStyle.color(for: value) ?? .secondary)
                            .contentTransition(.numericText())
                    }
                }
                if let value = model.value {
                    HUDBar(value: model.muted ? 0 : value, maximum: model.maximum)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(width: 290, height: 64)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .animation(.snappy(duration: 0.2), value: model.value)
    }
}

private struct HUDBar: View {
    let value: Float
    let maximum: Float

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fraction = CGFloat(min(max(value / maximum, 0), 1))
            let fill = max(width * fraction, value > 0 ? 6 : 0)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(LinearGradient(
                        stops: BoostStyle.fillStops(base: .primary, maximum: maximum, fillLength: fill) {
                            width * CGFloat($0 / maximum)
                        },
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: fill)
            }
        }
        .frame(height: 6)
    }
}
