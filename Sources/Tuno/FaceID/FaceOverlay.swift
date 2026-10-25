import AppKit
import AVFoundation
import Observation
import SwiftUI

/// Yüz tanıma ekranları: kurulum kartı ve kilit ekranındaki tarama simgesi. Çentikli Mac'te çentikten
/// Dynamic Island'ın yaylarıyla büyür; çentiksiz Mac'te ekranın üst ortasında bir kapsülden açılır.
@MainActor
final class FaceOverlayController {
    private var enrollPanel: FacePanel?
    private var lockPanel: FacePanel?
    private let enrollModel = FacePanelModel()
    private let lockModel = FacePanelModel()

    func showEnrollment(_ enrollment: FaceEnrollment) {
        guard let geometry = FaceGeometry.current() else { return }
        enrollModel.configure(geometry, expanded: CGSize(width: 372, height: geometry.notchHeight + 428), radius: 40)
        let panel = enrollPanel ?? FacePanel(canKey: true)
        enrollPanel = panel
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.setFrame(geometry.panelFrame(width: 600, height: 660), display: false)
        panel.contentView = NSHostingView(rootView: FacePanelView(model: enrollModel) {
            FaceEnrollView(enrollment: enrollment, topInset: geometry.notchHeight)
        })
        panel.orderFrontRegardless()
        DispatchQueue.main.async { self.enrollModel.expanded = true }
    }

    func hide() {
        enrollModel.expanded = false
        let panel = enrollPanel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            guard !self.enrollModel.expanded else { return }
            panel?.orderOut(nil)
            panel?.contentView = nil
        }
    }

    /// Ad yazılabilsin diye kurulum kartı klavyeyi alır.
    func focusEnrollment() {
        enrollPanel?.makeKey()
    }

    func showLock(_ unlock: FaceUnlock) {
        guard let geometry = FaceGeometry.current() else { return }
        // Her Mac'te çentiğe oranlı: çember çentik genişliğinin ~%36'sı, ada çentik genişliğinde aşağı uzar.
        let notchWidth = geometry.hasNotch ? geometry.collapsed.width + 8 : 160
        let diameter = min(max(notchWidth * 0.36, 52), 78)
        let side = FaceScanGlyph.side(for: diameter)
        let width = geometry.hasNotch ? max(notchWidth + 12, side) : side + 8
        lockModel.configure(geometry, expanded: CGSize(width: width, height: geometry.notchHeight + side - 4),
                            radius: geometry.hasNotch ? min(side * 0.42, 44) : side * 0.46)
        let panel = lockPanel ?? FacePanel(canKey: false)
        if lockPanel == nil {
            lockPanel = panel
            panel.level = NSWindow.Level(rawValue: Int(Int32.max - 2))
            panel.canBecomeVisibleWithoutLogin = true
            panel.ignoresMouseEvents = true
        }
        panel.setFrame(geometry.panelFrame(width: max(width + 120, 380), height: geometry.notchHeight + side + 120), display: false)
        panel.contentView = NSHostingView(rootView: FacePanelView(model: lockModel) {
            FaceLockView(unlock: unlock, topInset: geometry.notchHeight, diameter: diameter)
        })
        panel.orderFrontRegardless()
        SkyLight.lift(panel)
        DispatchQueue.main.async { self.lockModel.expanded = true }
    }

    func hideLock() {
        lockModel.expanded = false
        let panel = lockPanel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            guard !self.lockModel.expanded else { return }
            panel?.orderOut(nil)
        }
    }
}

private final class FacePanel: NSPanel {
    private let canKey: Bool

    init(canKey: Bool) {
        self.canKey = canKey
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { canKey }
    override var canBecomeMain: Bool { false }
}

/// Kartın konumu: çentikli ekranda çentiğin tam yeri; değilse ana ekranın üst ortası.
@MainActor
struct FaceGeometry {
    let screen: NSScreen
    let hasNotch: Bool
    let collapsed: CGSize
    let centerX: CGFloat

    var notchHeight: CGFloat { hasNotch ? collapsed.height : 0 }

    static func current() -> FaceGeometry? {
        if let screen = NotchIsland.notchedScreen, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return FaceGeometry(screen: screen, hasNotch: true,
                                collapsed: CGSize(width: width - 8, height: screen.safeAreaInsets.top),
                                centerX: left.maxX + width / 2)
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        return FaceGeometry(screen: screen, hasNotch: false, collapsed: CGSize(width: 96, height: 30), centerX: screen.frame.midX)
    }

    func panelFrame(width: CGFloat, height: CGFloat) -> NSRect {
        NSRect(x: centerX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
    }

    /// Çentiksiz ekranda kapsül menü çubuğunun hemen altında açılır.
    var topOffset: CGFloat {
        hasNotch ? 0 : max(screen.frame.maxY - screen.visibleFrame.maxY, 24) + 8
    }
}

@Observable
@MainActor
final class FacePanelModel {
    var expanded = false
    private(set) var hasNotch = true
    private(set) var collapsed: CGSize = .zero
    private(set) var full: CGSize = .zero
    private(set) var radius: CGFloat = 32
    private(set) var topOffset: CGFloat = 0

    func configure(_ geometry: FaceGeometry, expanded size: CGSize, radius: CGFloat) {
        hasNotch = geometry.hasNotch
        collapsed = geometry.collapsed
        full = size
        self.radius = radius
        topOffset = geometry.topOffset
    }
}

/// Siyah ada: kapalıyken çentiğin boyutunda (ya da görünmez bir kapsül), açılınca karta büyür.
struct FacePanelView<Content: View>: View {
    let model: FacePanelModel
    @ViewBuilder let content: () -> Content

    var body: some View {
        let open = model.expanded
        let size = open ? model.full : model.collapsed
        let flare: CGFloat = model.hasNotch && open ? IslandView.flare : 0
        let radius: CGFloat = open ? model.radius : (model.hasNotch ? 9 : model.collapsed.height / 2)
        ZStack(alignment: .top) {
            Group {
                if model.hasNotch {
                    IslandShape(flare: flare, radius: radius).fill(.black)
                        .frame(width: size.width + 2 * flare, height: size.height)
                } else {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.black)
                        .frame(width: size.width, height: size.height)
                        .opacity(open ? 1 : 0)
                }
            }
            .shadow(color: .black.opacity(open ? 0.4 : 0), radius: 18, y: 10)
            content()
                .frame(width: model.full.width, height: model.full.height)
                .scaleEffect(open ? 1 : 0.86, anchor: .top)
                .opacity(open ? 1 : 0)
                .blur(radius: open ? 0 : 6)
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(model.hasNotch
                           ? AnyShape(UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous))
                           : AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous)))
        }
        .padding(.top, model.topOffset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(open ? IslandView.expand : IslandView.collapse, value: open)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Kurulum

private struct FaceEnrollView: View {
    let enrollment: FaceEnrollment
    let topInset: CGFloat
    @FocusState private var nameFocused: Bool

    var body: some View {
        @Bindable var enrollment = enrollment
        VStack(spacing: 0) {
            Color.clear.frame(height: topInset + 22)
            ZStack {
                CameraPreview()
                    .frame(width: 184, height: 184)
                    .clipShape(Circle())
                    .opacity(dimmed ? 0.18 : 1)
                    .scaleEffect(dimmed ? 0.94 : 1)
                TickRing(ticks: enrollment.ticks)
                    .frame(width: 236, height: 236)
                    .opacity(enrollment.phase == .positioning ? 0.35 : 1)
                if dimmed {
                    Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark")
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(failed ? .orange : .green)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .frame(height: 244)

            VStack(spacing: 6) {
                Text(title).font(.system(size: 17, weight: .semibold))
                    .contentTransition(.opacity)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.62))
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: detail)
            }
            .padding(.horizontal, 26)
            .padding(.top, 14)

            Spacer(minLength: 0)
            controls(name: $enrollment.name)
                .padding(.horizontal, 22)
                .padding(.bottom, 20)
        }
        .foregroundStyle(.white)
        .onChange(of: enrollment.phase) { _, phase in
            if phase == .naming {
                FaceID.shared.overlay.focusEnrollment()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { nameFocused = true }
            }
        }
    }

    private var dimmed: Bool {
        switch enrollment.phase {
        case .passDone, .naming, .failed: true
        default: false
        }
    }

    private var failed: Bool { if case .failed = enrollment.phase { true } else { false } }

    private var title: String {
        switch enrollment.phase {
        case .positioning: L("Yüz Tanıma")
        case .scanning(1): L("İlk tarama")
        case .scanning: L("İkinci tarama")
        case .passDone: L("İlk tarama tamamlandı")
        case .naming: L("Yüz tanıma hazır")
        case .failed: L("Tarama tamamlanamadı")
        }
    }

    private var detail: String {
        switch enrollment.phase {
        case .passDone: L("Şimdi başını daha geniş bir daire çizecek şekilde çevireceksin.")
        case .naming: L("Bu yüze bir ad ver.")
        case .failed(let message): message
        default: enrollment.hint
        }
    }

    @ViewBuilder private func controls(name: Binding<String>) -> some View {
        switch enrollment.phase {
        case .passDone:
            HStack(spacing: 10) {
                FaceButton(title: L("İptal"), style: .secondary) { enrollment.cancel() }
                FaceButton(title: L("Devam"), style: .primary) { enrollment.continueToSecondPass() }
            }
        case .naming:
            VStack(spacing: 10) {
                TextField(L("Ad"), text: name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .background(Capsule().fill(.white.opacity(0.12)))
                    .focused($nameFocused)
                    .onSubmit { enrollment.save() }
                FaceButton(title: L("Kaydet"), style: .primary) { enrollment.save() }
            }
        case .failed:
            HStack(spacing: 10) {
                FaceButton(title: L("İptal"), style: .secondary) { enrollment.cancel() }
                FaceButton(title: L("Tekrar Dene"), style: .primary) { enrollment.retry() }
            }
        default:
            FaceButton(title: L("İptal"), style: .secondary) { enrollment.cancel() }
        }
    }
}

private struct FaceButton: View {
    enum Style { case primary, secondary }
    let title: String
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(Capsule().fill(style == .primary ? Color.white : Color.white.opacity(0.14)))
                .foregroundStyle(style == .primary ? Color.black : Color.white)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// iPhone'daki halka: 60 çizgi; dolunca uzar ve yeşile döner.
private struct TickRing: View {
    let ticks: [Bool]

    var body: some View {
        GeometryReader { proxy in
            let radius = min(proxy.size.width, proxy.size.height) / 2
            ZStack {
                ForEach(ticks.indices, id: \.self) { index in
                    let on = ticks[index]
                    Capsule()
                        .fill(on ? Color(red: 0.2, green: 0.84, blue: 0.35) : Color.white.opacity(0.32))
                        .frame(width: 3, height: on ? 15 : 9)
                        .offset(y: -radius + (on ? 7.5 : 4.5))
                        .rotationEffect(.degrees(Double(index) * 360 / Double(ticks.count)))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// Kameranın aynalı canlı görüntüsü.
private struct CameraPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> PreviewView { PreviewView() }
    func updateNSView(_ view: PreviewView, context: Context) { view.mirror() }

    final class PreviewView: NSView {
        private let preview = AVCaptureVideoPreviewLayer(session: FaceCamera.shared.session)

        private var observer: NSObjectProtocol?

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            preview.videoGravity = .resizeAspectFill
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.addSublayer(preview)
            // Bağlantı kamera açılınca oluşur: aynalama o an da uygulanır.
            observer = NotificationCenter.default.addObserver(forName: AVCaptureSession.didStartRunningNotification,
                                                              object: FaceCamera.shared.session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.mirror() }
            }
            for delay in [0.1, 0.4, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.mirror() }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            preview.frame = bounds
            mirror()
        }

        func mirror() {
            guard let connection = preview.connection, connection.isVideoMirroringSupported else { return }
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }
}

// MARK: - Kilit ekranı

private struct FaceLockView: View {
    let unlock: FaceUnlock
    let topInset: CGFloat
    let diameter: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: max(topInset - 6, 0))
            FaceScanGlyph(phase: phase, diameter: diameter)
                .frame(width: FaceScanGlyph.side(for: diameter), height: FaceScanGlyph.side(for: diameter))
                .overlay(alignment: .bottom) {
                    if unlock.scanState == .locked {
                        Text(L("Şifre gerekli"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.bottom, 4)
                            .transition(.opacity)
                    }
                }
            Spacer(minLength: 0)
        }
        .animation(.easeInOut(duration: 0.25), value: unlock.scanState)
    }

    private var phase: FaceScanGlyph.Phase {
        switch unlock.scanState {
        case .success: .success
        case .failure: .failure
        case .locked: .locked
        default: .scanning
        }
    }
}
