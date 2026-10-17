import AppKit
import ScreenCaptureKit
import SwiftUI

/// Bir pencerenin canlı görüntüsü: pencerede video oynuyorsa önizlemede de oynar. Yakalama görünüm
/// ekrana girince başlar, çıkınca ya da panel kapanınca durur; ilk kare gelene kadar elde olan
/// durağan önizleme gösterilir. Kareler doğrudan katmana verilir, SwiftUI yeniden çizilmez.
struct LiveWindowView: NSViewRepresentable {
    let windowID: CGWindowID
    let placeholder: NSImage?
    /// Akışın en uzun kenarı (nokta); ekranın ölçeğiyle çarpılır.
    var maxDimension: CGFloat = 220
    var framesPerSecond = 10

    func makeNSView(context: Context) -> LiveWindowLayerView {
        let view = LiveWindowLayerView()
        view.configure(windowID: windowID, placeholder: placeholder, maxDimension: maxDimension,
                       framesPerSecond: framesPerSecond)
        return view
    }

    func updateNSView(_ view: LiveWindowLayerView, context: Context) {
        view.configure(windowID: windowID, placeholder: placeholder, maxDimension: maxDimension,
                       framesPerSecond: framesPerSecond)
    }

    static func dismantleNSView(_ view: LiveWindowLayerView, coordinator: ()) {
        view.stop()
    }
}

final class LiveWindowLayerView: NSView {
    private var windowID: CGWindowID = 0
    private var maxDimension: CGFloat = 220
    private var framesPerSecond = 15
    private var stream: WindowStream?
    private var hasFrame = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(windowID: CGWindowID, placeholder: NSImage?, maxDimension: CGFloat, framesPerSecond: Int) {
        if windowID != self.windowID {
            stop()
            self.windowID = windowID
            hasFrame = false
        }
        self.maxDimension = maxDimension
        self.framesPerSecond = framesPerSecond
        if !hasFrame { layer?.contents = placeholder }
        if window != nil { start() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window == nil ? stop() : start()
    }

    private func start() {
        guard stream == nil, windowID != 0, CGPreflightScreenCaptureAccess() else { return }
        let stream = WindowStream { [weak self] image in
            self?.hasFrame = true
            self?.layer?.contents = image
        }
        self.stream = stream
        let id = windowID, dimension = maxDimension, fps = framesPerSecond
        let scale = window?.backingScaleFactor ?? 2
        Task { await stream.start(windowID: id, maxDimension: dimension * scale, framesPerSecond: fps) }
    }

    func stop() {
        stream?.stop()
        stream = nil
    }
}

/// Tek bir pencerenin canlıya yakın görüntüsü: belirli aralıklarla tek kare alınır.
///
/// Sürekli kayıt akışı (SCStream) kullanılmaz: macOS kaydedilen pencerenin sol üst köşesine bir kayıt
/// simgesi koyup pencere düğmelerini örtüyor. Tek kare görüntü almak bu simgeyi göstermez.
final class WindowStream: @unchecked Sendable {
    private let onFrame: @MainActor (CGImage) -> Void
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var stopped = false

    init(onFrame: @escaping @MainActor (CGImage) -> Void) {
        self.onFrame = onFrame
    }

    func start(windowID: CGWindowID, maxDimension: CGFloat, framesPerSecond: Int) async {
        guard let window = await WindowCatalog.shareableWindow(windowID) else { return }
        let scale = min(maxDimension / max(window.frame.width, 1), maxDimension / max(window.frame.height, 1), 2)
        let configuration = SCStreamConfiguration()
        configuration.width = max(Int(window.frame.width * scale), 2)
        configuration.height = max(Int(window.frame.height * scale), 2)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let interval = Duration.milliseconds(1000 / max(framesPerSecond, 1))
        let onFrame = self.onFrame

        let task = Task.detached(priority: .userInitiated) {
            while !Task.isCancelled {
                let started = ContinuousClock.now
                if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration),
                   !Task.isCancelled {
                    await MainActor.run { onFrame(image) }
                }
                // Yakalama uzun sürdüyse beklemeden devam et.
                let elapsed = ContinuousClock.now - started
                if elapsed < interval { try? await Task.sleep(for: interval - elapsed) }
            }
        }
        lock.lock()
        if stopped { task.cancel() } else { self.task = task }
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stopped = true
        task?.cancel()
        task = nil
        lock.unlock()
    }
}
