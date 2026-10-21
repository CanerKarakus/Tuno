//
//  DropView.swift
//  SiriGlass
//  Tuno'ya uyarlandı (macOS, Mac çentiği): Haplo LLC'nin SiriGlass'ı, MIT lisansı (LICENSE-SiriGlass.txt).
//
//  Draws one drop. The glass is the system's own Liquid Glass (iOS 26),
//  in the drop's outline, so it bends whatever is behind it, SwiftUI or
//  UIKit, live; the ink and light are SiriGlass.metal, laid over it. Before
//  iOS 26 a thin material stands in for the glass.
//
//  The drop is an overlay: nothing behind it is re-rendered or flattened,
//  so lists, maps, text fields and video keep working under it.
//

import AppKit
import SwiftUI

struct DropView: View {
    enum Placement: Equatable {
        /// Mac'in çentiğinden (görünümün koordinatlarında), `scale` kat büyüklükte; damla çentiğin `gap` altında asılır.
        case notch(CGRect, scale: Double, gap: Double)
        case orb
    }

    let placement: Placement
    let binding: Binding<SiriGlassState>?
    let fixed: SiriGlassState
    let audio: SiriGlassAudio
    /// Tuno: cevap yazılırken damlanın aşağı uzaması (nokta).
    var stretch: Double = 0

    @Environment(\.siriGlassTake) private var take
    @Environment(\.siriGlassProbe) private var probe
    @Environment(\.colorScheme) private var colorScheme

    @State private var engine = DropEngine()
    /// True once the drop is home and still: the timeline stops ticking.
    @State private var resting = true

    private var requested: SiriGlassState { binding?.wrappedValue ?? fixed }

    var body: some View {
        let paused = take == nil && resting && requested == .idle
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: nil, paused: paused)) { context in
                drop(at: context.date, in: proxy)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onDisappear {
            engine.stop()
            resting = true
        }
    }

    @ViewBuilder
    private func drop(at date: Date, in proxy: GeometryProxy) -> some View {
        let space = layout(in: proxy)
        let backdrop = placement == .orb ? (colorScheme == .light ? 1.0 : 0.35) : 0
        let out = engine.frame(at: date, requested: requested, audio: audio, writable: binding != nil,
                               take: take, layout: space.layout, backdrop: backdrop, stretch: stretch)
        let _ = commit(out)
        ZStack(alignment: .topLeading) {
            if placement == .orb {
                OrbShadow(frame: out.frame, strength: backdrop)
            }
            // Tuno: cam damla büyüyünce belirir (açılıp kapanırken ince beyaz kenar olmasın). Arkadaki görüntü
            // yakalanabiliyorsa gerçek mercek (yazılar bükülür), yoksa sistem camı.
            Group {
                if let lens = ScreenLens.shared.image {
                    LensGlass(image: lens, rect: ScreenLens.shared.rect, scale: ScreenLens.shared.scale,
                              frame: out.frame, points: out.outline, size: space.size)
                } else {
                    DropGlass(points: out.outline)
                }
            }
            .opacity(min(max((Double(out.frame.extra.x) - 0.7) / 0.3, 0), 1))
            Rectangle()
                .fill(.white)
                .colorEffect(out.frame.shader)
        }
        .frame(width: space.size.width, height: space.size.height)
        .offset(space.offset)
    }

    /// Where the drop goes. Under the island its layer covers the top of the
    /// window, wherever this view sits in it; as an orb, this view's bounds.
    private func layout(in proxy: GeometryProxy) -> (layout: DropEngine.Layout, size: CGSize, offset: CGSize) {
        switch placement {
        case .notch(let rect, let scale, let gap):
            return (.island(rect, scale: scale, top: rect.maxY + gap), proxy.size, .zero)
        case .orb:
            let size = proxy.size
            // The orb keeps the drop's proportions, with room to swell.
            let scale = max(min(size.width / DropGeometry.size.width, size.height / DropGeometry.size.height) / 1.08, 0.05)
            return (.orb(centre: CGPoint(x: size.width / 2, y: size.height / 2), scale: scale), size, .zero)
        }
    }

    /// Hands what the frame decided back to SwiftUI, after the update.
    private func commit(_ out: DropEngine.Output) {
        probe?.record(out, state: engine.mode)
        if let request = out.request, let binding {
            DispatchQueue.main.async {
                if binding.wrappedValue == request.from { binding.wrappedValue = request.to }
            }
        }
        if out.resting != resting {
            let now = out.resting
            DispatchQueue.main.async { resting = now }
        }
    }
}

/// The drop's glass: Liquid Glass in its outline, or a material before
/// iOS 26. Always in the hierarchy, empty while the drop is home, so it
/// never has to be inserted mid-animation.
struct DropGlass: View {
    let points: [CGPoint]

    var body: some View {
        let outline = DropOutline(points: points)
        if #available(macOS 26, *) {
            // Tuno: SwiftUI'nin camı macOS'ta yalnızca kendi penceresini örnekler; Tuno'nun paneli boş olduğundan
            // düz gri kalıyordu. AppKit'in camı arkadaki masaüstünü ve pencereleri büker; damlanın biçimiyle maskelenir.
            WindowGlass(path: outline.path(in: .zero).cgPath)
        } else {
            outline.fill(.ultraThinMaterial)
        }
    }
}

@available(macOS 26, *)
private struct WindowGlass: NSViewRepresentable {
    let path: CGPath

    func makeNSView(context: Context) -> MaskedGlassView { MaskedGlassView() }
    func updateNSView(_ view: MaskedGlassView, context: Context) { view.outline = path }
}

/// NSGlassEffectView (sade cam), damlanın çevresiyle maskelenmiş.
@available(macOS 26, *)
final class MaskedGlassView: NSView {
    private let glass = NSGlassEffectView()
    private let mask = CAShapeLayer()

    var outline: CGPath? {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mask.path = outline
            CATransaction.commit()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glass.style = .clear
        glass.cornerRadius = 0
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        layer?.mask = mask
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        mask.frame = bounds
    }
}

/// Tuno: arkadaki ekran görüntüsü, damlanın merkezine göre kalın bir mercekten geçip damlanın biçimiyle kırpılır.
struct LensGlass: View {
    let image: CGImage
    let rect: CGRect
    let scale: CGFloat
    let frame: DropFrame
    let points: [CGPoint]
    let size: CGSize

    var body: some View {
        let f = frame
        ZStack(alignment: .topLeading) {
            Image(decorative: image, scale: scale)
                .resizable()
                .frame(width: rect.width, height: rect.height)
                .layerEffect(ShaderLibrary.default.siriLens(
                    .float2(Float(rect.minX), Float(rect.minY)),
                    .float4(Float(f.island.minX), Float(f.island.minY), Float(f.island.width), Float(f.island.height)),
                    .float4(f.drop.x, f.drop.y, f.drop.z, f.drop.w),
                    .float4(f.exponent, f.presence, f.neck, f.time),
                    .float4(f.extra.x, f.extra.y, f.extra.z, f.extra.w)),
                    maxSampleOffset: CGSize(width: 60, height: 60))
                .offset(x: rect.minX, y: rect.minY)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .mask(DropOutline(points: points))
    }
}

/// The soft shadow an orb casts on a light backdrop.
struct OrbShadow: View {
    let frame: DropFrame
    let strength: Double

    var body: some View {
        let scale = frame.scale
        let w = Double(frame.drop.z) * scale, h = Double(frame.drop.w) * scale
        let opacity = 0.24 * strength * Double(frame.presence)
        Ellipse()
            .fill(RadialGradient(colors: [.black.opacity(opacity), .black.opacity(opacity * 0.4), .black.opacity(0)],
                                 center: .center, startRadius: 0, endRadius: w * 0.86))
            .frame(width: w * 1.72, height: h * 0.24)
            .position(x: Double(frame.drop.x), y: Double(frame.drop.y) + h * 1.13)
            .opacity(frame.isVisible ? 1 : 0)
    }
}
