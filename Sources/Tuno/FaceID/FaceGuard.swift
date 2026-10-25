import AppKit
import Observation
import SwiftUI
import Vision

/// Başkası bakarsa gizle: kamera (özellik açıkken) sürekli açıktır, saniyede 4 kare bakar. Çerçevede en az iki
/// yüz varken tanınmayan biri belirirse sağ üstteki bildirim alanının üstüne buzlu cam bir katman gelir;
/// pano paneli, dosya rafı ve gizli öğeler kapanır. Yabancı 2,5 sn görünmeyince her şey geri gelir.
@Observable
@MainActor
final class FaceGuard {
    private static let enabledKey = "faceGuard"

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey); refresh() }
    }
    private(set) var strangerPresent = false {
        didSet {
            guard strangerPresent != oldValue else { return }
            strangerPresent ? shield.show() : shield.hide()
            if strangerPresent { FaceID.shared.relock() }
            onChange?(strangerPresent)
            SupportLog.log("faceid", strangerPresent ? "Başka biri bakıyor: gizlendi" : "Yabancı gitti")
        }
    }
    @ObservationIgnored var onChange: ((Bool) -> Void)?

    @ObservationIgnored private var subscription: UUID?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let shield = PrivacyShield()
    @ObservationIgnored private var lastStranger: Date = .distantPast
    @ObservationIgnored private var recent: [Bool] = []

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        let center = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            observers.append(center.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    /// Kamerayı gerektiği gibi açar ya da kapatır (açık + hazır + kilitli değil + ekran uyanık).
    func refresh() {
        let faceID = FaceID.shared
        let should = isEnabled && faceID.isUsable && !SystemLock.isLocked && CGDisplayIsAsleep(CGMainDisplayID()) == 0
        if should, subscription == nil, let engine = faceID.engine {
            let matcher = faceID.store.matcher
            let threshold = FaceID.matchThreshold - 0.07
            subscription = FaceCamera.shared.subscribe(fps: 4) { [weak self] pixels in
                let faces = engine.detect(pixels, quality: false).filter { $0.widthFraction > 0.07 }
                var stranger = false
                if faces.count >= 2 {
                    for face in faces {
                        guard let embedding = engine.embedding(pixels, face) else { continue }
                        if (matcher.best(embedding)?.score ?? 0) < threshold { stranger = true; break }
                    }
                }
                Task { @MainActor in self?.observe(stranger) }
            }
        } else if !should, subscription != nil {
            FaceCamera.shared.unsubscribe(subscription)
            subscription = nil
            recent = []
            strangerPresent = false
        }
    }

    private func observe(_ stranger: Bool) {
        recent.append(stranger)
        if recent.count > 3 { recent.removeFirst() }
        if stranger { lastStranger = Date() }
        if recent.filter({ $0 }).count >= 2 {
            strangerPresent = true
        } else if strangerPresent, Date().timeIntervalSince(lastStranger) > 2.5 {
            strangerPresent = false
        }
    }

    /// Hızlı yüz kutuları (model gerekmez).
    nonisolated static func faceRects(_ pixels: CVPixelBuffer) -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up)
        guard (try? handler.perform([request])) != nil else { return [] }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        return (request.results ?? []).map { VNImageRectForNormalizedRect($0.boundingBox, width, height) }
    }
}

/// Bildirimlerin çıktığı sağ üst alanın üstünde buzlu cam.
@MainActor
private final class PrivacyShield {
    private var windows: [NSWindow] = []

    func show() {
        guard windows.isEmpty else { return }
        for screen in NSScreen.screens {
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            let width: CGFloat = 400, height = min(screen.frame.height * 0.62, 640)
            let frame = NSRect(x: screen.frame.maxX - width - 8, y: screen.frame.maxY - menuBar - height - 4,
                               width: width, height: height)
            let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) - 2)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.contentView = NSHostingView(rootView: ShieldView())
            window.alphaValue = 0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25; window.animator().alphaValue = 1 }
            windows.append(window)
        }
    }

    func hide() {
        let closing = windows
        windows = []
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            for window in closing { window.animator().alphaValue = 0 }
        } completionHandler: {
            for window in closing { window.orderOut(nil) }
        }
    }
}

private struct ShieldView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "eye.slash.fill").font(.system(size: 30, weight: .semibold))
                    Text(L("Biri ekranına bakıyor")).font(.headline)
                    Text(L("Bildirimler gizlendi.")).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.15)))
    }
}
