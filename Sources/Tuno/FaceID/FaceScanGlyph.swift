import SwiftUI

/// Kilit ekranındaki yüz tanıma simgesi (Tuno'nun kendi tasarımı, yeşil).
/// Çember içinde yüz; animasyonsuz gelir, tararken sabit durur.
/// Tanınınca (~0,9 sn): yüz söner, çerçeve çembere döner, çemberden halkalar ayrılıp jiroskop gibi birkaç tur
/// döner, hepsi tek çembere oturur ve içine onay işareti çizilir. Tanınmazsa: simge beyaza döner ve sallanır.
struct FaceScanGlyph: View {
    enum Phase: Equatable { case scanning, success, failure, locked }

    let phase: Phase
    /// Oturmuş çemberin çapı (pt).
    let diameter: CGFloat

    static let green = Color(red: 0.33, green: 0.9, blue: 0.47)

    /// Çevresindeki pay dahil görünümün kenarı.
    static func side(for diameter: CGFloat) -> CGFloat { diameter * 1.9 }

    @State private var draw: CGFloat = 1
    @State private var morph: CGFloat = 0
    @State private var face: CGFloat = 1
    @State private var rings: CGFloat = 0
    @State private var tilt: CGFloat = 0
    @State private var ringStart: Date?
    @State private var check: CGFloat = 0
    @State private var pop: CGFloat = 1
    @State private var shake: CGFloat = 0
    @State private var appear: CGFloat = 1

    var body: some View {
        TimelineView(.animation(paused: ringStart == nil || check >= 1)) { context in
            FaceScanFrame(draw: draw, morph: morph, face: face, rings: rings, tilt: tilt,
                          ringTime: ringStart.map { context.date.timeIntervalSince($0) } ?? 0, check: check,
                          tint: phase == .failure || phase == .locked ? .white : Self.green, size: diameter)
        }
        .frame(width: Self.side(for: diameter), height: Self.side(for: diameter))
        .scaleEffect(pop * (0.86 + 0.14 * appear))
        .opacity(appear)
        .offset(x: shake)
        .onAppear {
            // Animasyonsuz gelir (çentikle birlikte açılır).
            if phase != .scanning { react(phase) }
        }
        .onChange(of: phase) { _, new in react(new) }
    }

    private func react(_ phase: Phase) {
        switch phase {
        case .scanning:
            morph = 0; face = 1; check = 0; pop = 1; rings = 0; tilt = 0; ringStart = nil
        case .success:
            // Yüz söner, çerçeve çembere döner.
            withAnimation(.easeOut(duration: 0.1)) { face = 0 }
            withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) { morph = 1 }
            // Çemberden halkalar ayrılıp jiroskop gibi döner.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                ringStart = Date()
                withAnimation(.easeOut(duration: 0.16)) { rings = 1; tilt = 1 }
            }
            // Halkalar tek çembere oturur, onay işareti çizilir.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { tilt = 0; rings = 0 }
                withAnimation(.easeOut(duration: 0.2).delay(0.16)) { check = 1 }
                withAnimation(.spring(response: 0.2, dampingFraction: 0.5).delay(0.3)) { pop = 1.07 }
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8).delay(0.46)) { pop = 1 }
            }
        case .failure, .locked:
            for (i, value) in [9.0, -8, 6, -4, 2, 0].enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(i)) {
                    withAnimation(.linear(duration: 0.05)) { shake = value }
                }
            }
        }
    }
}

/// Simgenin tek karesi (geçiş değerlerine göre). Test için kare kare çizilebilir.
struct FaceScanFrame: View {
    /// Geliş: köşelerin çizilme oranı.
    var draw: CGFloat = 1
    /// 0: köşe çerçevesi, 1: tam çember.
    let morph: CGFloat
    /// Yüz çizgilerinin görünürlüğü.
    let face: CGFloat
    /// Ayrılan halkaların görünürlüğü.
    var rings: CGFloat = 0
    /// Halkaların eğimi (0: hepsi düz çember, 1: tam eğik).
    var tilt: CGFloat = 0
    /// Halkaların dönüş zamanı (sn).
    var ringTime: Double = 0
    let check: CGFloat
    var tint: Color = FaceScanGlyph.green
    let size: CGFloat

    /// Her halka kendi ekseni etrafında eğilir; eksen döndükçe halka yuvarlanır gibi görünür.
    private static let gyro: [(tilt: Double, spin: Double, offset: Double)] = [
        (62, 540, 0), (70, -470, 75), (56, 610, 160),
    ]

    var body: some View {
        // Çember, yüz, dönen halkalar ve onay işareti aynı kalınlıkta.
        let line = size * 0.058
        ZStack {
            glyph(line: line).blur(radius: size * 0.08).opacity(0.7)   // ışıltı
            glyph(line: line)
        }
        .frame(width: size, height: size)
    }

    private func glyph(line: CGFloat) -> some View {
        ZStack {
            ForEach(Self.gyro.indices, id: \.self) { index in
                let ring = Self.gyro[index]
                let axis = (ring.spin * ringTime + ring.offset) * .pi / 180
                if index == 0 {
                    // Ana halka: köşe çerçevesinin kendisi (çembere dönüşür, sonra o da yuvarlanır).
                    CornerFrame(morph: morph)
                        .trim(from: 0, to: draw)
                        .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
                        .rotation3DEffect(.degrees(ring.tilt * Double(tilt)), axis: (cos(axis), sin(axis), 0), perspective: 0.3)
                } else {
                    Circle()
                        .stroke(tint, lineWidth: line)
                        .rotation3DEffect(.degrees(ring.tilt * Double(tilt)), axis: (cos(axis), sin(axis), 0), perspective: 0.3)
                        .opacity(Double(rings) * 0.9)
                }
            }
            FaceLines()
                .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
                .padding(size * 0.23)
                .scaleEffect(0.7 + 0.3 * face * draw)
                .opacity(face * draw)
            Checkmark()
                .trim(from: 0, to: check)
                .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
                .padding(size * 0.28)
        }
    }
}

/// Yüzün çevresindeki çember (dört çeyrekten çizilir; geliş animasyonunda sırayla belirir).
struct CornerFrame: Shape {
    var morph: CGFloat

    var animatableData: CGFloat {
        get { morph }
        set { morph = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let box = CGRect(x: rect.midX - s / 2, y: rect.midY - s / 2, width: s, height: s)
        let r = s / 2                                   // baştan çember (yüz bunun içinde)
        let leg = s / 2 - r
        var path = Path()
        // Sol üst
        path.move(to: CGPoint(x: box.minX, y: box.minY + r + leg))
        path.addLine(to: CGPoint(x: box.minX, y: box.minY + r))
        path.addArc(center: CGPoint(x: box.minX + r, y: box.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: CGPoint(x: box.minX + r + leg, y: box.minY))
        // Sağ üst
        path.move(to: CGPoint(x: box.maxX - r - leg, y: box.minY))
        path.addLine(to: CGPoint(x: box.maxX - r, y: box.minY))
        path.addArc(center: CGPoint(x: box.maxX - r, y: box.minY + r), radius: r, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: box.maxX, y: box.minY + r + leg))
        // Sağ alt
        path.move(to: CGPoint(x: box.maxX, y: box.maxY - r - leg))
        path.addLine(to: CGPoint(x: box.maxX, y: box.maxY - r))
        path.addArc(center: CGPoint(x: box.maxX - r, y: box.maxY - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: box.maxX - r - leg, y: box.maxY))
        // Sol alt
        path.move(to: CGPoint(x: box.minX + r + leg, y: box.maxY))
        path.addLine(to: CGPoint(x: box.minX + r, y: box.maxY))
        path.addArc(center: CGPoint(x: box.minX + r, y: box.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: box.minX, y: box.maxY - r - leg))
        return path
    }
}

/// Gözler, burun ve gülümseme.
private struct FaceLines: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y) }
        var path = Path()
        path.move(to: p(0.26, 0.2)); path.addLine(to: p(0.26, 0.34))          // sol göz
        path.move(to: p(0.74, 0.2)); path.addLine(to: p(0.74, 0.34))          // sağ göz
        path.move(to: p(0.52, 0.2)); path.addLine(to: p(0.52, 0.56))          // burun
        path.addQuadCurve(to: p(0.42, 0.6), control: p(0.52, 0.62))
        path.move(to: p(0.22, 0.74)); path.addQuadCurve(to: p(0.78, 0.74), control: p(0.5, 0.94))   // gülümseme
        return path
    }
}

/// Onay işareti.
private struct Checkmark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.06, y: rect.minY + rect.height * 0.54))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.84))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.94, y: rect.minY + rect.height * 0.18))
        return path
    }
}
