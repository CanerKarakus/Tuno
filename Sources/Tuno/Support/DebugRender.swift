#if DEBUG
import AppKit
import SwiftUI

/// Yalnızca geliştirme: TUNO_RENDER=<klasör> ile açılınca onboarding adımlarını PNG olarak yazar ve çıkar
/// (tasarımı ekran kaydı izni olmadan görmek için).
@MainActor
enum DebugRender {
    static func runIfRequested(_ app: AppDelegate) {
        guard let folder = ProcessInfo.processInfo.environment["TUNO_RENDER"] else { return }
        let url = URL(fileURLWithPath: folder)
        // Yüz tanıma taramasının kareleri tek resimde (TUNO_RENDER_FACE=1).
        if ProcessInfo.processInfo.environment["TUNO_RENDER_FACE"] == "1" {
            // (draw, morph, face, rings, tilt, ringTime, check)
            let frames: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, Double, CGFloat)] = [
                (0.5, 0, 1, 0, 0, 0, 0), (1, 0, 1, 0, 0, 0, 0), (1, 0.6, 0.2, 0, 0, 0, 0), (1, 1, 0, 0.6, 0.6, 0.05, 0),
                (1, 1, 0, 1, 1, 0.18, 0), (1, 1, 0, 1, 1, 0.32, 0), (1, 1, 0, 1, 1, 0.46, 0), (1, 1, 0, 0.4, 0.4, 0.55, 0),
                (1, 1, 0, 0, 0, 0.6, 0.5), (1, 1, 0, 0, 0, 0.6, 1)]
            let sheet = HStack(spacing: 14) {
                ForEach(frames.indices, id: \.self) { i in
                    let f = frames[i]
                    FaceScanFrame(draw: f.0, morph: f.1, face: f.2, rings: f.3, tilt: f.4, ringTime: f.5, check: f.6, size: 64)
                        .frame(width: 110, height: 110)
                }
            }
            .padding(24)
            .background(Color.black)
            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: url.appending(path: "face-scan.png"))
            }
            exit(0)
        }
        let dark = ProcessInfo.processInfo.environment["TUNO_RENDER_DARK"] == "1"
        func save<V: View>(_ name: String, _ view: V, scheme: ColorScheme) {
            let renderer = ImageRenderer(content: view
                .environment(app.onboarding).environment(app.permissions)
                .environment(LanguageStore.shared).environment(ThemeStore.shared)
                .environment(\.colorScheme, scheme)
                .frame(width: 780, height: 590))
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: url.appending(path: "\(name).png"))
            }
        }
        let scheme: ColorScheme = dark ? .dark : .light
        save("1-language", ZStack { OnboardingBackground(dark: true); LanguageStep(selection: .constant(.tr)) }, scheme: .dark)
        save("2-theme", ZStack { OnboardingBackground(dark: dark); ThemeStep(selection: .constant(.system)) }, scheme: scheme)
        save("3-permissions", ZStack { OnboardingBackground(dark: dark); PermissionsStep() }, scheme: scheme)
        save("4-ready", ZStack { OnboardingBackground(dark: dark); ReadyStep() }, scheme: scheme)
        for (index, amount) in [0.35, 0.7, 1.0].enumerated() {
            save("0-hello-\(index)", ZStack {
                HelloBackground()
                HelloScript().trim(from: 0, to: amount)
                    .stroke(.white, style: StrokeStyle(lineWidth: 8.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 380, height: 190)
            }, scheme: .dark)
        }
        exit(0)
    }
}
#endif
