import AppKit

/// macOS 26+: Liquid Glass; daha eski sürümlerde bulanık popover malzemesi.
@MainActor
enum Glass {
    static func make(content: NSView, cornerRadius: CGFloat) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            clip(glass, cornerRadius: cornerRadius)
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = roundedMask(radius: cornerRadius)
        content.autoresizingMask = [.width, .height]
        effect.addSubview(content)
        clip(effect, cornerRadius: cornerRadius)
        return effect
    }

    /// Yuvarlak köşelerin dışında hiçbir şey (kare gölge/arka plan) çizilmesin.
    private static func clip(_ view: NSView, cornerRadius: CGFloat) {
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
    }

    /// Cam arka planlı, uygulamayı öne getirmeyen, saydam bir panel.
    static func panel(content: NSView, cornerRadius: CGFloat, level: NSWindow.Level) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Pencere gölgesi pencerenin kare alanından hesaplanıp köşelerde kare bir kenar
        // bırakıyordu; cam kendi kenar ışığını çizer.
        panel.hasShadow = false
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Cam, pencerenin kendi piksellerini saydam bırakır; varsayılan ayarda saydam alana gelen
        // tıklamalar ve imleç alttaki pencereye geçiyordu. Panelin tamamı olayları alsın.
        panel.ignoresMouseEvents = false
        let background = make(content: content, cornerRadius: cornerRadius)
        background.wantsLayer = true
        panel.contentView = background
        return panel
    }

    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
