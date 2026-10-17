// Uygulama simgesini (AppIcon.icns) üretir: swift scripts/make-icon.swift <çıktı-klasörü>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build")
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let size = CGFloat(px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS simge ızgarası: 1024 tuvalde 824'lük yuvarlatılmış kare.
    let inset = size * 0.0977
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    // Sitedeki simgeyle aynı: koyu griden siyaha geçen zemin üzerinde altı beyaz çubuk.
    NSGradient(colors: [
        NSColor(srgbRed: 0.245, green: 0.246, blue: 0.27, alpha: 1),
        NSColor(srgbRed: 0.040, green: 0.041, blue: 0.060, alpha: 1),
    ])!.draw(in: path, angle: -90)

    // Ölçüler 512'lik site simgesinden: çubuk genişliği 22, aralık 34,8, yükseklikler aşağıda.
    let unit = size / 512
    let heights: [CGFloat] = [44, 130, 206, 106, 163, 68]
    let barWidth = 22 * unit, step = 34.8 * unit
    let firstX = size / 2 - step * CGFloat(heights.count - 1) / 2
    NSColor.white.setFill()
    for (index, height) in heights.enumerated() {
        let barHeight = height * unit
        let bar = NSRect(x: firstX + step * CGFloat(index) - barWidth / 2, y: size / 2 - barHeight / 2,
                         width: barWidth, height: barHeight)
        NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
