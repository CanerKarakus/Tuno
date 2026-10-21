//
//  ScreenLens.swift
//  Tuno
//
//  Siri damlasının arkasında ne var: Tuno'nun paneli dışarıda bırakılarak, damlanın bölgesi saniyede ~15 kez
//  yakalanır (Ekran Kaydı izniyle). Damla bu görüntüyü bir mercek shader'ından geçirir; macOS'un hazır camı
//  menü çubuğu düzeyindeki şeffaf bir panelde arkadaki pencereleri bükmüyor.
//
//  Sürekli kayıt akışı (SCStream) yerine tek kareler: akış menü çubuğunda kayıt göstergesi açık tutar.
//

import AppKit
import Observation
import ScreenCaptureKit

@Observable
@MainActor
final class ScreenLens {
    static let shared = ScreenLens()

    /// Son kare ve panelin görünüm koordinatlarındaki yeri (sol üst köşe başlangıç).
    private(set) var image: CGImage?
    private(set) var rect: CGRect = .zero
    private(set) var scale: CGFloat = 2

    @ObservationIgnored private var task: Task<Void, Never>?

    /// `viewRect`: panelin içinde yakalanacak bölge.
    func start(panel: NSWindow, viewRect: CGRect) {
        stop()
        guard CGPreflightScreenCaptureAccess(), let screen = panel.screen else { return }
        rect = viewRect
        scale = screen.backingScaleFactor
        // Ekranın kendi koordinatları: sol üst başlangıç, nokta.
        let source = CGRect(x: panel.frame.minX - screen.frame.minX + viewRect.minX,
                            y: screen.frame.maxY - panel.frame.maxY + viewRect.minY,
                            width: viewRect.width, height: viewRect.height)
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let windowID = CGWindowID(panel.windowNumber)
        let scale = self.scale
        task = Task { [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let display = content.displays.first(where: { $0.displayID == displayID })
            else { return }
            let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { $0.windowID == windowID })
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = source
            configuration.width = Int(source.width * scale)
            configuration.height = Int(source.height * scale)
            configuration.showsCursor = false
            while !Task.isCancelled {
                let started = ContinuousClock.now
                if let frame = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration),
                   !Task.isCancelled {
                    self?.image = frame
                }
                let elapsed = ContinuousClock.now - started
                if elapsed < .milliseconds(66) { try? await Task.sleep(for: .milliseconds(66) - elapsed) }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        image = nil
    }
}
