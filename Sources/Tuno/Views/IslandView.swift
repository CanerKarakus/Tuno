import AppKit
import AVKit
import SwiftUI

/// Dynamic Island görünümü. Panelin üst ortasında, çentikle aynı yerde durur (sitedeki adayla aynı dil:
/// yaylı açılış, pembe dalga, kapak + ad + ilerleme + kontroller).
///
/// Kapak ve dalga her durumda var olan tek bir katmandır: kapanınca çentiğin ortasına kayıp küçülür,
/// açılınca oradan yanlara, oynatıcıda büyük yerine kayar. Ada boştayken solmaz, çentiğin içine küçülür.
/// İkinci bir etkinlik varsa adanın sağında yuvarlak bir baloncukta durur.
struct IslandView: View {
    let island: NotchIsland
    /// Üst köşelerdeki ters kıvrım: ada menü çubuğundan akarak çıkıyormuş gibi görünür.
    static let flare: CGFloat = 8
    /// Son çizilen alan: değişikliğin büyüme mi küçülme mi olduğunu ayırmak için.
    @State private var lastArea: CGFloat = 0

    /// iPhone'daki ada: açılırken hafifçe esneyen, kapanırken taşmasız yay. Tüm değişiklikler (durum, fare,
    /// baloncuk) tek animasyonla oynar; ayrı animasyonlar birbirine karışıp takılma yapıyordu.
    static let expand = Animation.spring(response: 0.5, dampingFraction: 0.74)
    static let collapse = Animation.spring(response: 0.42, dampingFraction: 0.92)
    /// Yana açılırken ada kısa bir an hafifçe şişip yerine oturur (iPhone'daki esneklik).
    @State private var bulge: CGFloat = 0
    /// Yandaki baloncuk ve ayrılma ilerlemesi (0: adanın içinde, 1: yerinde).
    @State private var shownSecondary: NotchIsland.Live?
    @State private var split: CGFloat = 0
    /// Siri'nin cevabının yüksekliği: damla buna göre uzar.
    @State private var answerHeight: CGFloat = 0

    private struct LayoutKey: Equatable {
        let mode: NotchIsland.Mode
        let hovering: Bool
        let apps: Int
    }

    var body: some View {
        let size = island.size
        let mode = island.mode
        let idle = mode == .idle
        let flare = idle ? 0 : Self.flare
        let bubble = island.notch.height
        let area = size.width * size.height
        // Büyük kart, oval kapsül ya da çentik kanatları.
        let card = mode.isCard
        let pill = mode.isPill || (mode.isAirPods && island.hovering)
        let radius: CGFloat = card ? 32 : pill ? 28 : (idle ? 9 : min(size.height / 2, 14))
        let key = LayoutKey(mode: mode, hovering: island.hovering, apps: island.pinned.count)
        ZStack(alignment: .top) {
            IslandShape(flare: flare, radius: radius)
                .fill(.black)
                .frame(width: size.width + 2 * flare, height: size.height)
                // Şişme boyuta değil görüntüye uygulanır: genişlik kendi yayıyla açılmaya devam eder.
                .scaleEffect(x: 1, y: 1 + bulge, anchor: .top)
                // Siyah alanın her yeri tıklanabilir (içeriğin boş kalan yerleri dahil).
                .contentShape(IslandShape(flare: flare, radius: radius))
                .onTapGesture { island.tapIsland() }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in accept(providers) }
                .shadow(color: .black.opacity(card || pill ? 0.35 : 0), radius: 14, y: 8)
            // Baloncuk içeriğin altında: sıvı köprü adanın ucunu çizer, içeriği örtmemeli.
            if let shownSecondary {
                LiquidBubble(island: island, live: shownSecondary, split: split, edge: size.width / 2,
                             radius: radius, diameter: bubble) { island.promote(shownSecondary) }
            }
            ZStack(alignment: .topLeading) {
                content(mode).id(mode.contentID)
                MediaLayer(island: island, mode: mode, size: size)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipShape(.rect(bottomLeadingRadius: radius, bottomTrailingRadius: radius))

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Siri: iOS 27'deki gibi çentikten akan sıvı cam damla; ışığı sesle oynar (SiriGlass).
        .overlay {
            GeometryReader { proxy in
                let notch = island.notch
                let rect = CGRect(x: (proxy.size.width - notch.width) / 2, y: 0, width: notch.width, height: notch.height)
                // Yanlara az taşar: çentikten ~20 pt geniş (iPhone ölçüsü 170 pt). Üstü çentiğe gömülür (arada boşluk olmasın).
                let scale = (notch.width + 20) / 170
                // Cevap: damla aşağı uzayıp genişler; ışık çizgisinin altındaki camda Siri'nin sonuç kartı belirir.
                let answer = island.siriActive && island.siriAnswer != nil
                let top = notch.height - 12
                let line = top + 126 * scale * (0.5 + 0.035)   // ışık çizgisi (sabit kalır)
                // Damla kart kadar aşağı uzar: ışık çizgisiyle kart arasında 26, kartın altında (dipteki kavis için) 30 pt.
                let lower = top + 126 * scale - line
                let stretch = answer ? max(40, answerHeight + 56 - lower) : 0
                let cardTop = top + 126 * scale + stretch - 30 - answerHeight
                DropView(placement: .notch(rect, scale: scale, gap: -12), binding: nil,
                         fixed: island.siriShown ? .listening : .idle, audio: .feed(island.siriFeed), stretch: stretch)
                if answer {
                    SiriResultCard(parts: island.siriAnswerParts)
                        .frame(width: ((170 + 2 * 0.3 * stretch / scale) * scale) * 0.7)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { answerHeight = $0 }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, max(cardTop, line + 26))   // uzayan alt kısımda, dibe yakın
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)).animation(.easeOut(duration: 0.3).delay(0.15)))
                        .allowsHitTesting(false)
                }
            }
        }
        .animation(area >= lastArea ? Self.expand : Self.collapse, value: key)
        .onChange(of: key) {
            // Yalnızca büyürken ve yükseklik çok değişmiyorsa (yana açılan hâller) şişer.
            if area > lastArea * 1.05, size.height < island.notch.height + 10 {
                withAnimation(.easeOut(duration: 0.16)) { bulge = 0.14 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.55)) { bulge = 0 }
                }
            }
            lastArea = area
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.78), value: island.siriAnswer)
        .onChange(of: island.secondary) { _, new in
            if let new {
                let fresh = shownSecondary == nil
                shownSecondary = new
                guard fresh else { return }
                split = 0
                withAnimation(.spring(response: 0.85, dampingFraction: 0.7)) { split = 1 }
            } else if shownSecondary != nil {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) { split = 0 } completion: {
                    if island.secondary == nil { shownSecondary = nil }
                }
            }
        }
        .onAppear {
            shownSecondary = island.secondary
            split = island.secondary == nil ? 0 : 1
        }
        .environment(\.colorScheme, .dark)
    }

    /// Çentiğe bırakılan dosyalar rafa girer.
    private func accept(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        nonisolated(unsafe) var urls: [URL] = []
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let dropped = urls
            MainActor.assumeIsolated { island.dropFiles(dropped) }
        }
        return true
    }

    @ViewBuilder private func content(_ mode: NotchIsland.Mode) -> some View {
        switch mode {
        case .idle: Color.clear
        case .apps: AppsRow(island: island).transition(.islandWide)
        case .compact(let live):
            if case .media = live {
                Color.clear.contentShape(.rect)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture { island.toggleExpanded(live) }
            } else {
                CompactRow(island: island, live: live)
                    .contentShape(.rect)
                    .onTapGesture { island.toggleExpanded(live) }
                    .transition(.islandWide)
            }
        case .expanded(let live):
            Group {
                switch live {
                case .media(let id): if let player = island.player(id) { PlayerView(island: island, player: player) }
                case .call: CallView(island: island)
                case .timer: TimerView(island: island)
                case .transfer: TransferView(island: island)
                case .shelf: ShelfView(island: island)
                }
            }
            .transition(.island)
        case .banner(let banner): BannerView(island: island, banner: banner).transition(mode.isPill ? .island : .islandWide)
        case .siri: Color.clear
        case .drop: DropZone(island: island).transition(.island)
        }
    }
}

private extension NotchIsland.Mode {
    /// Büyük kart: oynatıcı ve AirPods ayrıntısı.
    var isCard: Bool {
        switch self {
        case .expanded(.media): true
        default: false
        }
    }

    /// AirPods bildirimi: üzerine gelince büyük karta döner.
    var isAirPods: Bool {
        if case .banner(let banner) = self, case .airpods = banner.kind { true } else { false }
    }

    /// Biraz büyüyen oval kapsül: küçük işlerin büyümüş hâli ve alarm.
    var isPill: Bool {
        switch self {
        case .expanded(.media): false
        case .expanded: true
        case .drop: true
        case .banner(let banner): if case .alarm = banner.kind { true } else { false }
        default: false
        }
    }

    /// İçerik türü değişince geçiş animasyonu oynasın diye kimlik.
    var contentID: String {
        switch self {
        case .idle: "idle"
        case .apps: "apps"
        case .compact(let live): "compact-\(live)"
        case .expanded(let live): "expanded-\(live)"
        case .banner(let banner): "banner-\(banner.id)"
        case .siri: "siri"
        case .drop: "drop"
        }
    }
}

extension AnyTransition {
    /// iPhone'daki gibi içerik adayla birlikte büyür: üstten hafifçe ölçeklenip belirir; kapanırken adadan
    /// önce kaybolur ki ada boşken küçülsün.
    static var island: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: Reveal(amount: 1), identity: Reveal(amount: 0))
                .animation(.spring(response: 0.46, dampingFraction: 0.82)),
            removal: .modifier(active: Reveal(amount: 1), identity: Reveal(amount: 0))
                .animation(.easeIn(duration: 0.1)))
    }
}

extension AnyTransition {
    /// Yana uzanan hâllerde içerik çentiğin ortasından yanlara doğru açılır; kapanırken ortaya toplanır.
    static var islandWide: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: Spread(amount: 1), identity: Spread(amount: 0))
                .animation(.spring(response: 0.46, dampingFraction: 0.82)),
            removal: .modifier(active: Spread(amount: 1), identity: Spread(amount: 0))
                .animation(.easeIn(duration: 0.12)))
    }
}

private struct Spread: ViewModifier {
    let amount: CGFloat
    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 1 - 0.45 * amount, y: 1 - 0.25 * amount, anchor: .center)
            .opacity(1 - amount)
            .blur(radius: 2 * amount)
    }
}

private struct Reveal: ViewModifier {
    let amount: CGFloat
    func body(content: Content) -> some View {
        content
            .opacity(1 - amount)
            .scaleEffect(1 - 0.1 * amount, anchor: .top)
            .blur(radius: 3 * amount)
    }
}

/// Yandaki baloncuk adanın sağından sıvı gibi kopar (metaball): adanın ucu ve baloncuk bulanıklaştırılıp
/// keskinleştirilir, yakınken aralarında bir boyun oluşur. Baloncuk uzaklaştıkça bulanıklık azalır, boyun kopar.
private struct LiquidBubble: View {
    let island: NotchIsland
    let live: NotchIsland.Live
    let split: CGFloat
    /// Adanın gövdesinin sağ kenarı (merkezden).
    let edge: CGFloat
    let radius: CGFloat
    let diameter: CGFloat
    let onTap: () -> Void

    private let overlap: CGFloat = 30

    var body: some View {
        let gap = NotchIsland.bubbleGap
        let start = overlap - diameter, end = overlap + gap
        let x = start + (end - start) * split
        let width = overlap + gap + diameter + 10
        // Kopana kadar kalın bir boyun: bulanıklık ayrılmanın sonuna doğru hızla azalır.
        let blur = 0.3 + 10 * pow(max(0, 1 - min(split, 1)), 0.65)
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                context.addFilter(.alphaThreshold(min: 0.5, color: .black))
                context.addFilter(.blur(radius: blur))
                context.drawLayer { layer in
                    // Adanın ucu: üstü ekranın dışına taşar, altı adayla aynı yuvarlaklıkta.
                    let r = min(radius, diameter / 2)
                    layer.fill(Path(roundedRect: CGRect(x: -r, y: -r, width: overlap + r, height: diameter + r), cornerRadius: r),
                               with: .color(.black))
                    layer.fill(Path(ellipseIn: CGRect(x: x - 1, y: -1, width: diameter + 2, height: diameter + 2)), with: .color(.black))
                }
            }
            Bubble(island: island, live: live)
                .frame(width: diameter, height: diameter)
                .contentShape(.circle)
                .onTapGesture(perform: onTap)
                .scaleEffect(0.4 + 0.6 * split)
                .opacity(Double(max(0, min(1, split * 1.6 - 0.45))))
                .offset(x: x)
        }
        .frame(width: width, height: diameter, alignment: .topLeading)
        .offset(x: edge - overlap + width / 2)
    }
}

/// Üstte ekran kenarına yapışık, alt köşeleri yuvarlak; üst köşelerde içe kıvrılan çentik biçimi.
struct IslandShape: Shape {
    var flare: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(flare, radius) }
        set { flare = newValue.first; radius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let f = flare, r = max(min(radius, rect.height / 2, (rect.width - 2 * f) / 2), 0)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + f, y: rect.minY + f), control: CGPoint(x: rect.minX + f, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + f, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + f + r, y: rect.maxY), control: CGPoint(x: rect.minX + f, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - f - r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - f, y: rect.maxY - r), control: CGPoint(x: rect.maxX - f, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - f, y: rect.minY + f))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - f, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Ortak parçalar

private enum IslandColor {
    static let pink = Color(red: 1, green: 0.216, blue: 0.373)
    static let pinkLight = Color(red: 1, green: 0.392, blue: 0.51)
    static let green = Color(red: 0.2, green: 0.84, blue: 0.29)
    static let orange = Color(red: 1, green: 0.62, blue: 0.04)
    static let blue = Color(red: 0.04, green: 0.52, blue: 1)
    static let secondary = Color.white.opacity(0.6)
}

private enum IslandIcon {
    static let airDrop = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app")

    static func app(_ bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}

/// "4:05" ya da "1:02:03".
private func clock(_ seconds: TimeInterval) -> String {
    let value = max(Int(seconds.rounded(.up)), 0)
    let hours = value / 3600, minutes = value / 60 % 60, rest = value % 60
    return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
}

/// Siri'nin sonuç kartı, damlanın uzamış alt kısmında. Hava durumu Siri'nin kendi kartı gibi (konum, büyük sıcaklık,
/// simge, durum, en yüksek/en düşük); diğer cevaplar okunaklı bir metin kartı.
private struct SiriResultCard: View {
    let parts: [String]

    private var temperatureIndex: Int? {
        parts.firstIndex { $0.range(of: #"^-?\d+°$"#, options: .regularExpression) != nil }
    }

    /// "04:55" ya da "1:02:03": sayaç ya da alarm.
    private var timeIndex: Int? {
        parts.firstIndex { $0.range(of: #"^\d{1,2}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil }
    }

    var body: some View {
        Group {
            if let index = temperatureIndex {
                weather(temperature: parts[index], index: index)
            } else if let index = timeIndex {
                clock(time: parts[index], labels: parts.enumerated().filter { $0.offset != index }.map(\.element))
            } else {
                Text(parts.joined(separator: " "))
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Camın üstünde hafif koyu, yarı saydam zemin ve ince kenar.
        .background(.black.opacity(0.38), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12), lineWidth: 0.5))
    }

    /// Tek satır: simge, konum ve durum, sıcaklık.
    private func weather(temperature: String, index: Int) -> some View {
        let location = index > 0 ? parts[index - 1] : ""
        let rest = Array(parts.dropFirst(index + 1))
        let condition = rest.first ?? ""
        let detail = ([condition] + rest.dropFirst()).filter { !$0.isEmpty }.joined(separator: " · ")
        return HStack(spacing: 9) {
            Image(systemName: Self.symbol(for: condition)).font(.system(size: 19)).symbolRenderingMode(.multicolor)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 3) {
                    Text(location).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Image(systemName: "location.fill").font(.system(size: 8))
                }
                Text(detail).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 4)
            Text(temperature).font(.system(size: 24, weight: .light)).fixedSize()
        }
    }

    /// Tek satır: süre ve etiket; sağda sayaçta turuncu halkalı duraklat, alarmda yeşil anahtar (yalnızca görüntü).
    private func clock(time: String, labels: [String]) -> some View {
        let label = labels.joined(separator: " · ")
        let alarm = labels.contains { $0.lowercased().contains("alarm") }
        let orange = Color(red: 1, green: 0.62, blue: 0.04)
        return HStack(spacing: 8) {
            Text(time)
                .font(.system(size: 22, weight: .light).monospacedDigit())
                .contentTransition(.numericText(countsDown: !alarm))
                .animation(.easeOut(duration: 0.25), value: time)
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            Spacer(minLength: 4)
            if alarm {
                Capsule().fill(Color(red: 0.2, green: 0.84, blue: 0.29))
                    .frame(width: 32, height: 19)
                    .overlay(alignment: .trailing) { Circle().fill(.white).padding(2) }
            } else {
                Circle().stroke(orange, lineWidth: 2)
                    .frame(width: 24, height: 24)
                    .overlay { Image(systemName: "pause.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(orange) }
            }
        }
    }

    /// Durum adından simge; açık havada gece ay, gündüz güneş.
    private static func symbol(for condition: String) -> String {
        let text = condition.lowercased()
        let night = { let hour = Calendar.current.component(.hour, from: Date()); return hour >= 19 || hour < 6 }()
        if text.contains("yağmur") || text.contains("rain") { return "cloud.rain.fill" }
        if text.contains("kar") || text.contains("snow") { return "cloud.snow.fill" }
        if text.contains("fırtına") || text.contains("storm") || text.contains("thunder") { return "cloud.bolt.rain.fill" }
        if text.contains("sis") || text.contains("fog") { return "cloud.fog.fill" }
        if text.contains("parçalı") || text.contains("partly") { return night ? "cloud.moon.fill" : "cloud.sun.fill" }
        if text.contains("bulut") || text.contains("cloud") { return "cloud.fill" }
        return night ? "moon.fill" : "sun.max.fill"
    }
}

/// Yuvarlak ilerleme halkası; oran bilinmiyorsa (nil) kısa bir yay döner.
private struct Ring: View {
    let fraction: Double?
    let color: Color
    var lineWidth: CGFloat = 3
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: lineWidth)
            if let fraction {
                Circle().trim(from: 0, to: max(min(fraction, 1), 0.001))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                Circle().trim(from: 0, to: 0.28)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true } }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: fraction)
    }
}

/// Çentiğin iki yanında duran kısa içerik: solda simge, sağda değer.
private struct Wings<Left: View, Right: View>: View {
    let notch: CGSize
    @ViewBuilder let left: Left
    @ViewBuilder let right: Right

    var body: some View {
        HStack(spacing: 0) {
            left.frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: notch.width)
            right.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 11)
        .frame(height: notch.height)
    }
}

/// Oval kapsül: üstte çentiğin iki yanı, altında tek satır (düğmeler ya da çubuk).
private struct PillBody<Left: View, Right: View, Bottom: View>: View {
    let notch: CGSize
    @ViewBuilder let left: Left
    @ViewBuilder let right: Right
    @ViewBuilder let bottom: Bottom

    var body: some View {
        VStack(spacing: 0) {
            Wings(notch: notch) { left } right: { right }
            bottom
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 18)
                .padding(.bottom, 6)
        }
        .foregroundStyle(.white)
    }
}

/// Kapsül içindeki küçük düğme.
private struct PillButton: View {
    var symbol: String?
    var title: String?
    var tint: Color = .white.opacity(0.14)
    var foreground: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).contentTransition(.symbolEffect(.replace)) }
                if let title { Text(title) }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 11)
            .frame(minWidth: 28, minHeight: 24)
            .background(tint, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(PressScale())
    }
}

/// Büyümüş adanın içeriği: çentiğin altından başlar.
private struct ExpandedBody<Content: View>: View {
    let notch: CGSize
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 14) { content }
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.top, notch.height + 10)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct RoundButton: View {
    let symbol: String
    var tint: Color = .white.opacity(0.16)
    var foreground: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 38, height: 38)
                .background(tint, in: .circle)
                .contentShape(.circle)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressScale())
    }
}

// MARK: - Uygulamalar

private struct AppsRow: View {
    let island: NotchIsland

    var body: some View {
        HStack(spacing: 0) {
            side(island.leftApps)
            Spacer(minLength: island.notch.width)
            if island.pinned.isEmpty {
                IslandButton(symbol: "plus", help: L("Uygulama ekle")) { island.openSettings() }
                    .frame(maxWidth: .infinity)
            } else {
                side(island.rightApps)
            }
        }
        .frame(height: island.notch.height)
    }

    @ViewBuilder private func side(_ apps: [URL]) -> some View {
        if island.pinned.isEmpty {
            IslandButton(symbol: "gearshape", help: L("Dynamic Island ayarları")) { island.openSettings() }
                .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 10) {
                ForEach(apps, id: \.self) { url in
                    AppIcon(url: url) { island.open(url) }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct AppIcon: View {
    let url: URL
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 24, height: 24)
                .scaleEffect(hover ? 1.18 : 1)
        }
        .buttonStyle(.plain)
        .onHover { value in withAnimation(.spring(duration: 0.3, bounce: 0.4)) { hover = value } }
        .help(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
    }
}

private struct IslandButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 26, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Baloncuk ve kısa etkinlikler

/// İkinci etkinlik: yuvarlak, siyah. Tıklanınca büyük alana geçer.
private struct Bubble: View {
    let island: NotchIsland
    let live: NotchIsland.Live

    var body: some View {
        ZStack {
            Circle().fill(.black)
            switch live {
            case .media(let id):
                Artwork(image: island.player(id)?.artwork, size: island.notch.height - 10, radius: island.notch.height)
            case .call:
                Image(systemName: "phone.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(IslandColor.green)
            case .timer:
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let countdown = island.countdown
                    Ring(fraction: countdown.map { $0.end.timeIntervalSince(context.date) / max($0.total, 1) } ?? 0,
                         color: IslandColor.orange, lineWidth: 2.5)
                        .padding(7)
                }
            case .transfer:
                Ring(fraction: island.transfer?.fraction ?? 0, color: IslandColor.blue, lineWidth: 2.5).padding(7)
            case .shelf:
                Image(systemName: "tray.full.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(IslandColor.blue)
            }
        }
    }
}

private struct CompactRow: View {
    let island: NotchIsland
    let live: NotchIsland.Live

    var body: some View {
        switch live {
        case .call:
            // iPhone'daki gibi: solda yeşil telefon ve süre, sağda canlı mikrofon dalgası.
            let muted = island.devices?.microphoneMuted == true
            Wings(notch: island.notch) {
                HStack(spacing: 5) {
                    Image(systemName: "phone.fill").font(.system(size: 12, weight: .semibold))
                    if let start = island.call?.start {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(clock(context.date.timeIntervalSince(start))).lineLimit(1).fixedSize()
                        }
                    }
                }
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(IslandColor.green)
            } right: {
                if muted {
                    Image(systemName: "mic.slash.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.red)
                } else {
                    MicBars(meter: island.inputMeter, muted: muted)
                }
            }
        case .timer:
            Wings(notch: island.notch) {
                Image(systemName: island.countdown?.isAlarm == true ? "alarm.fill" : "timer")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(IslandColor.orange)
            } right: {
                if let end = island.countdown?.end {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(clock(end.timeIntervalSince(context.date))).lineLimit(1).fixedSize()
                    }
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(IslandColor.orange)
                }
            }
        case .transfer:
            Wings(notch: island.notch) {
                TransferIcon(airdrop: island.transfer?.airdrop ?? false, size: 20)
            } right: {
                Ring(fraction: island.transfer?.fraction ?? 0, color: IslandColor.blue).frame(width: 17, height: 17)
            }
        case .shelf:
            Wings(notch: island.notch) {
                Image(systemName: "tray.full.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(IslandColor.blue)
            } right: {
                Text("\(island.shelf.items.count)")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(IslandColor.blue)
            }
        case .media:
            EmptyView()
        }
    }
}

private struct TransferIcon: View {
    let airdrop: Bool
    let size: CGFloat

    var body: some View {
        if airdrop {
            Image(nsImage: IslandIcon.airDrop).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: size * 0.85))
                .foregroundStyle(IslandColor.blue)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Büyümüş küçük işler (oval kapsül)

private struct CallView: View {
    let island: NotchIsland

    var body: some View {
        let muted = island.devices?.microphoneMuted == true
        PillBody(notch: island.notch) {
            HStack(spacing: 6) {
                if let bundleID = island.call?.bundleID, let icon = IslandIcon.app(bundleID) {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                }
                Text(island.call?.name ?? "").font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
        } right: {
            if let start = island.call?.start {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(clock(context.date.timeIntervalSince(start)))
                }
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(IslandColor.green)
            }
        } bottom: {
            HStack(spacing: 10) {
                PillButton(symbol: muted ? "mic.slash.fill" : "mic.fill",
                           tint: muted ? .white : .white.opacity(0.14), foreground: muted ? .black : .white) {
                    island.toggleMicrophone()
                }
                .help(muted ? L("Mikrofonu aç") : L("Mikrofonu kapat"))
                MicBars(meter: island.inputMeter, muted: muted, height: 18)
                PillButton(symbol: "arrow.up.forward.app") {
                    if let bundleID = island.call?.bundleID {
                        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
                    }
                }
                .help(L("Uygulamaya git"))
            }
        }
    }
}

private struct TimerView: View {
    let island: NotchIsland

    var body: some View {
        if let countdown = island.countdown {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = countdown.end.timeIntervalSince(context.date)
                PillBody(notch: island.notch) {
                    HStack(spacing: 6) {
                        Ring(fraction: remaining / max(countdown.total, 1), color: IslandColor.orange, lineWidth: 2.5)
                            .frame(width: 16, height: 16)
                        Text(countdown.fromClock ? L("Saat") : countdown.isAlarm ? L("Alarm") : L("Zamanlayıcı"))
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(IslandColor.secondary)
                            .lineLimit(1).fixedSize()
                    }
                } right: {
                    Text(clock(remaining))
                        .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                        .lineLimit(1).fixedSize()
                        .foregroundStyle(IslandColor.orange)
                        .contentTransition(.numericText(countsDown: true))
                } bottom: {
                    HStack(spacing: 10) {
                        if countdown.fromClock {
                            PillButton(symbol: "clock", title: L("Saat'te aç")) { island.cancelCountdown() }
                        } else {
                            if !countdown.isAlarm {
                                PillButton(symbol: "plus", title: L("1 dk")) { island.addMinute() }
                            }
                            PillButton(symbol: "xmark", title: L("İptal"), tint: IslandColor.orange.opacity(0.22),
                                       foreground: IslandColor.orange) { island.cancelCountdown() }
                        }
                    }
                }
            }
        }
    }
}

private struct TransferView: View {
    let island: NotchIsland

    var body: some View {
        if let transfer = island.transfer {
            PillBody(notch: island.notch) {
                HStack(spacing: 6) {
                    TransferIcon(airdrop: transfer.airdrop, size: 18)
                    Text(transfer.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                }
            } right: {
                if let fraction = transfer.fraction {
                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(IslandColor.blue)
                } else {
                    Ring(fraction: nil, color: IslandColor.blue).frame(width: 16, height: 16)
                }
            } bottom: {
                GeometryReader { proxy in
                    Capsule().fill(.white.opacity(0.2)).overlay(alignment: .leading) {
                        Capsule().fill(IslandColor.blue).frame(width: proxy.size.width * (transfer.fraction ?? 0))
                    }
                }
                .frame(height: 5)
                .animation(.easeInOut(duration: 0.3), value: transfer.fraction)
            }
        }
    }
}

// MARK: - Bildirimler

private struct BannerView: View {
    let island: NotchIsland
    let banner: NotchIsland.Banner

    var body: some View {
        content
            .contentShape(.rect)
            .onTapGesture { island.tapBanner() }
    }

    @ViewBuilder private var content: some View {
        let notch = island.notch
        switch banner.kind {
        case .airpods(let name, let symbol, let levels):
            // Üzerine gelince ayrıntı, fare çekilince küçük hâl.
            if island.hovering {
                AirPodsPill(notch: notch, name: name, symbol: symbol, levels: levels).transition(.island)
            } else {
                AirPodsCompact(notch: notch, symbol: symbol, levels: levels).transition(.islandWide)
            }
        case .charging(let percent):
            Wings(notch: notch) {
                HStack(spacing: 5) {
                    Image(systemName: "bolt.fill").foregroundStyle(IslandColor.green)
                    Text(L("Şarj oluyor"))
                }
            } right: {
                HStack(spacing: 6) {
                    Text(String(format: L("%%%d"), percent)).foregroundStyle(IslandColor.green).monospacedDigit()
                    BatteryBar(percent: percent)
                }
            }
            .font(.system(size: 13, weight: .semibold))
        case .copied(let text):
            Wings(notch: notch) {
                Text(L("Kopyalandı"))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).fixedSize()
                    .help(text)
            } right: {
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(IslandColor.blue)
                    .symbolEffect(.bounce, value: text)
            }
        case .keepAwake(let active, let detail):
            Wings(notch: notch) {
                HStack(spacing: 5) {
                    Image(systemName: active ? "cup.and.heat.waves.fill" : "cup.and.saucer.fill")
                        .foregroundStyle(active ? IslandColor.orange : IslandColor.secondary)
                        .symbolEffect(.bounce, value: active)
                    Text(L("Uyanık tut"))
                }
                .font(.system(size: 13, weight: .semibold))
            } right: {
                Text(detail).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(active ? IslandColor.orange : IslandColor.secondary)
            }
        case .received(let name, _, let airdrop):
            Wings(notch: notch) {
                HStack(spacing: 6) {
                    TransferIcon(airdrop: airdrop, size: 18)
                    Text(airdrop ? L("Alındı") : L("İndirildi")).font(.system(size: 13, weight: .semibold))
                }
            } right: {
                Text(name).font(.system(size: 12)).foregroundStyle(IslandColor.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        case .notice(let symbol, let tone, let title, let detail):
            // İnce bildirim: yana ince büyür; solda simge ve başlık, sağda ayrıntı.
            Wings(notch: notch) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).foregroundStyle(tone.color).symbolEffect(.bounce, value: banner.id)
                    Text(title).lineLimit(1)
                }
            } right: {
                Text(detail).foregroundStyle(tone.color).monospacedDigit().lineLimit(1)
            }
            .font(.system(size: 13, weight: .semibold))
        case .alarm(let title, let ringing):
            PillBody(notch: notch) {
                Image(systemName: "alarm.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(IslandColor.orange)
                    .symbolEffect(.bounce, options: .repeating)
            } right: {
                Text(Date.now.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(IslandColor.orange)
            } bottom: {
                HStack {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer()
                    PillButton(title: ringing ? L("Durdur") : L("Tamam"), tint: IslandColor.orange, foreground: .black) {
                        island.dismissBanner()
                    }
                }
            }
        }
    }
}

/// AirPods bağlanınca önce küçük (iPhone'daki gibi): solda kulaklık, sağda yalnızca yeşil pil halkası.
private struct AirPodsCompact: View {
    let notch: CGSize
    let symbol: String
    let levels: [HeadphoneBattery.Device.Level]

    var body: some View {
        // Kutu ortalamaya katılmaz (kulaklıkların pili).
        let buds = levels.filter { $0.label != L("Kutu") }
        let average = buds.isEmpty ? nil : buds.map(\.percent).reduce(0, +) / buds.count
        Wings(notch: notch) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(.white)
        } right: {
            Ring(fraction: average.map { Double($0) / 100 }, color: (average ?? 100) <= 20 ? .red : IslandColor.green,
                 lineWidth: 3)
                .frame(width: 18, height: 18)
                .help(average.map { String(format: L("%%%d"), $0) } ?? "")
        }
    }
}

private struct BatteryBar: View {
    let percent: Int

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5).stroke(.white.opacity(0.4), lineWidth: 1)
                RoundedRectangle(cornerRadius: 2)
                    .fill(IslandColor.green)
                    .frame(width: max(2, 20 * CGFloat(percent) / 100))
                    .padding(1.5)
            }
            .frame(width: 25, height: 12)
            RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.4)).frame(width: 1.5, height: 4)
        }
    }
}

/// AirPods'un üzerine gelinmiş hâli: küçük hâlden biraz büyüyen kapsül; altta her parçanın pili.
private struct AirPodsPill: View {
    let notch: CGSize
    let name: String
    let symbol: String
    let levels: [HeadphoneBattery.Device.Level]
    @State private var appeared = false

    var body: some View {
        PillBody(notch: notch) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 16))
                Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
        } right: {
            Text(L("Bağlandı")).font(.system(size: 12, weight: .semibold)).foregroundStyle(IslandColor.green)
        } bottom: {
            HStack(spacing: 16) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    HStack(spacing: 5) {
                        Ring(fraction: appeared ? Double(level.percent) / 100 : 0,
                             color: level.percent <= 20 ? .red : IslandColor.green, lineWidth: 2.5)
                            .frame(width: 15, height: 15)
                        Text(String(format: L("%%%d"), level.percent))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        if !level.label.isEmpty {
                            Text(level.label).font(.system(size: 11)).foregroundStyle(IslandColor.secondary)
                        }
                    }
                }
                if levels.isEmpty { Ring(fraction: nil, color: IslandColor.green).frame(width: 15, height: 15) }
            }
            .animation(.easeOut(duration: 0.7).delay(0.1), value: appeared)
        }
        .onAppear { appeared = true }
    }
}

// MARK: - Müzik

private struct Artwork: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        ZStack {
            Color.white.opacity(0.12)
            Image(systemName: "music.note").font(.system(size: size * 0.45)).foregroundStyle(.white.opacity(0.6))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .transition(.opacity.animation(.easeInOut(duration: 0.3)))
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: radius))
    }
}

/// Kapak ve dalga: konumları ve boyutları duruma göre değişir, yayla kayarak yer değiştirir.
private struct MediaLayer: View {
    let island: NotchIsland
    let mode: NotchIsland.Mode
    let size: CGSize

    private static let waveWidth: CGFloat = 25, artLarge: CGFloat = 52, artSmall: CGFloat = 22

    /// Gösterilen müzik uygulaması; gizlenirken de son gösterilenin kapağı kayarak kaybolur.
    private var playerID: String? {
        switch mode {
        case .compact(.media(let id)), .expanded(.media(let id)): id
        default: island.activities.compactMap { if case .media(let id) = $0 { id } else { nil } }.first
        }
    }

    /// (büyük oynatıcı mı, görünüyor mu)
    private var state: (Bool, Bool) {
        switch mode {
        case .expanded(.media): (true, true)
        case .compact(.media): (false, true)
        default: (false, false)
        }
    }

    var body: some View {
        let notch = island.notch.height
        let (expanded, shown) = state
        let player = playerID.flatMap(island.player)
        let art: CGFloat = expanded ? Self.artLarge : Self.artSmall
        // Gizliyken ikisi de çentiğin ortasında, küçük ve bulanık durur.
        let artX = shown ? (expanded ? 22 : 9) : size.width / 2 - art / 2
        let artY = expanded ? notch + 10 : (notch - art) / 2
        let waveX = shown ? size.width - (expanded ? 22 : 9) - Self.waveWidth : size.width / 2 - Self.waveWidth / 2
        let waveY = expanded ? notch + 14 : (notch - 20) / 2

        Artwork(image: player?.artwork, size: art, radius: expanded ? 12 : 6)
            .scaleEffect(shown ? 1 : 0.6)
            .opacity(shown ? 1 : 0)
            .offset(x: artX, y: artY)
            .onTapGesture {
                guard let player else { return }
                expanded ? player.activate() : island.toggleExpanded(.media(player.id))
            }
            .allowsHitTesting(shown)
        LevelWave(island: island, height: 20, playing: player?.isPlaying ?? false)
            .frame(width: Self.waveWidth)
            .scaleEffect(shown ? (expanded ? 1 : 0.7) : 0.4)
            .opacity(shown ? 1 : 0)
            .offset(x: waveX, y: waveY)
            .allowsHitTesting(false)
    }
}

private struct PlayerView: View {
    let island: NotchIsland
    let player: MediaPlayer

    var body: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(player.track?.title ?? "")
                    .font(.system(size: 15, weight: .semibold))
                Text(player.track?.artist ?? "")
                    .font(.system(size: 13))
                    .foregroundStyle(IslandColor.secondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .padding(.leading, 52 + 12)
            .padding(.trailing, 25 + 12)
            if (player.track?.duration ?? 0) > 0 { Progress(player: player, seekable: player.canSeek(scriptAllowed: island.seekEnabled)) }
            ZStack {
                HStack(spacing: 40) {
                    ControlButton(symbol: "backward.fill", size: 18) { player.previous() }
                    ControlButton(symbol: player.isPlaying ? "pause.fill" : "play.fill", size: 24) { player.playPause() }
                    ControlButton(symbol: "forward.fill", size: 18) { player.next() }
                }
                HStack {
                    Spacer()
                    AirPlayButton().frame(width: 26, height: 26).help(L("AirPlay"))
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.top, island.notch.height + 10)
        .padding(.bottom, 24)
    }
}

/// İlerleme çubuğu: sürükleyerek ya da tıklayarak şarkıda gezilir. Apple Music'teki gibi üzerine gelince kalınlaşır.
private struct Progress: View {
    let player: MediaPlayer
    let seekable: Bool
    @State private var dragging: Double?
    @State private var hover = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = max(player.track?.duration ?? 0, 1)
            let elapsed = dragging.map { $0 * duration } ?? player.elapsed(at: context.date)
            let active = seekable && (hover || dragging != nil)
            HStack(spacing: 10) {
                Text(Self.time(elapsed)).frame(width: 36, alignment: .leading)
                GeometryReader { proxy in
                    let width = proxy.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(.white).frame(width: width * min(elapsed / duration, 1))
                    }
                    .frame(height: active ? 9 : 5)
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
                    .gesture(!seekable ? nil : DragGesture(minimumDistance: 0)
                        .onChanged { dragging = min(max($0.location.x / width, 0), 1) }
                        .onEnded {
                            player.seek(to: min(max($0.location.x / width, 0), 1))
                            dragging = nil
                        })
                }
                .frame(height: 14)
                .onHover { hover = $0 }
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: active)
                Text("-" + Self.time(duration - elapsed)).frame(width: 40, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(active ? 0.85 : 0.6))
        }
    }

    static func time(_ seconds: TimeInterval) -> String {
        let value = max(Int(seconds), 0)
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

/// Ses çıkışını seçme (AirPlay); sistemin kendi seçicisi.
private struct AirPlayButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        picker.setRoutePickerButtonColor(.white, for: .normal)
        picker.setRoutePickerButtonColor(NSColor.white.withAlphaComponent(0.7), for: .normalHighlighted)
        return picker
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

private struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 34)
                .background(.white.opacity(hover ? 0.1 : 0), in: .rect(cornerRadius: 10))
                .contentShape(.rect)
        }
        .buttonStyle(PressScale())
        .onHover { hover = $0 }
    }
}

private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

// MARK: - Dalga

/// Müzik uygulamasının sesinden ölçülen gerçek bant düzeyleri. Ölçüm yokken (duraklatıldı, izin yok)
/// çubuklar düzleşir; ses yokken de düz durur.
private struct LevelWave: NSViewRepresentable {
    let island: NotchIsland
    let height: CGFloat
    let playing: Bool

    func makeNSView(context: Context) -> WaveBarsView { WaveBarsView(height: height, colors: WaveBarsView.pink) }

    func updateNSView(_ view: WaveBarsView, context: Context) {
        let tap = island.levelTap
        view.targets = { WaveLevels.music(tap?.levels) }
        view.active = playing && tap != nil
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WaveBarsView, context: Context) -> CGSize? {
        CGSize(width: WaveBarsView.width, height: height)
    }
}

/// Görüşmede mikrofon düzeyi (InputMeter); mikrofon kapalıyken düz.
private struct MicBars: NSViewRepresentable {
    let meter: InputMeter?
    let muted: Bool
    var height: CGFloat = 16

    func makeNSView(context: Context) -> WaveBarsView { WaveBarsView(height: height, colors: WaveBarsView.green) }

    func updateNSView(_ view: WaveBarsView, context: Context) {
        let meter = meter
        view.targets = {
            // Ortam gürültüsü ~0,35: üstü konuşma sayılır; çubuklar ortası yüksek bir dağılımla.
            let level = CGFloat(max(0, ((meter?.level ?? 0) - 0.35) / 0.45))
            return [0.55, 0.85, 1, 0.8, 0.6].map { min(level * $0, 1) }
        }
        view.active = !muted && meter?.isRunning == true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WaveBarsView, context: Context) -> CGSize? {
        CGSize(width: WaveBarsView.width, height: height)
    }
}

/// Beş çubuk; SwiftUI dışında, doğrudan Core Animation katmanlarıyla saniyede 20 kez güncellenir: adanın
/// görünüm ağacı yeniden hesaplanmaz (işlemci ve pil). Hızlı yükselir, yavaş iner.
final class WaveBarsView: NSView {
    static let width: CGFloat = 25
    static let pink = [NSColor(red: 1, green: 0.216, blue: 0.373, alpha: 1), NSColor(red: 1, green: 0.392, blue: 0.51, alpha: 1)]
    static let green = [NSColor(red: 0.2, green: 0.84, blue: 0.29, alpha: 1), NSColor(red: 0.42, green: 0.9, blue: 0.47, alpha: 1)]

    /// 0…1 hedef yükseklikler.
    var targets: (() -> [CGFloat])?
    var active = false {
        didSet { guard active != oldValue else { return }; active ? start() : flatten() }
    }

    private let height: CGFloat
    private var bars: [CALayer] = []
    private var values = [CGFloat](repeating: 0, count: 5)
    private var timer: Timer?

    init(height: CGFloat, colors: [NSColor]) {
        self.height = height
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: height))
        wantsLayer = true
        for index in 0..<values.count {
            let bar = CALayer()
            bar.backgroundColor = colors[index % colors.count].cgColor
            bar.cornerRadius = 1.5
            layer?.addSublayer(bar)
            bars.append(bar)
        }
        apply(duration: 0)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { timer?.invalidate(); timer = nil } else if active { start() }
    }

    private func start() {
        guard timer == nil, window != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.01
    }

    private func tick() {
        let goal = targets?() ?? []
        for index in values.indices {
            let target = index < goal.count ? goal[index] : 0
            values[index] += (target - values[index]) * (target > values[index] ? 0.7 : 0.25)
        }
        apply(duration: 1.0 / 20)
    }

    private func flatten() {
        timer?.invalidate()
        timer = nil
        values = values.map { _ in 0 }
        apply(duration: 0.35)
    }

    /// Çubuklar dikeyde ortalı; en az 3 nokta (düz çizgi).
    private func apply(duration: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: duration > 0.1 ? .easeOut : .linear))
        CATransaction.setDisableActions(duration == 0)
        for (index, bar) in bars.enumerated() {
            let barHeight = max(3, height * values[index])
            bar.frame = CGRect(x: CGFloat(index) * 5.5, y: (height - barHeight) / 2, width: 3, height: barHeight)
        }
        CATransaction.commit()
    }
}

/// Ham RMS'i desibele çevirip 0…1 çubuk yüksekliğine çevirir.
enum WaveLevels {
    /// Yüksek bantların enerjisi doğal olarak düşük; görsel denge için eklenen kazanç (dB).
    private static let tilt: [Float] = [0, 3, 7, 11, 15]

    static func music(_ levels: [Float]?) -> [CGFloat] {
        guard let levels else { return [] }
        return levels.indices.map { index in
            let db = 20 * log10(max(levels[index], 1e-6)) + (index < tilt.count ? tilt[index] : 15)
            return CGFloat(min(max((db + 48) / 40, 0), 1))
        }
    }
}

private extension IslandSignals.Notice.Tone {
    var color: Color {
        switch self {
        case .green: IslandColor.green
        case .yellow: Color(red: 1, green: 0.84, blue: 0.04)
        case .red: Color(red: 1, green: 0.27, blue: 0.23)
        case .blue: IslandColor.blue
        case .orange: IslandColor.orange
        case .purple: Color(red: 0.75, green: 0.35, blue: 0.95)
        }
    }
}

// MARK: - Dosya rafı

/// Dosya çentiğe yaklaşınca: bırakma alanı.
private struct DropZone: View {
    let island: NotchIsland

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: island.notch.height)
            HStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(IslandColor.blue)
                    .symbolEffect(.bounce.down, options: .repeat(.periodic(delay: 0.6)))
                Text(L("Dosyayı buraya bırak")).font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Raf: dosyalar yan yana; her birinin altında "Link al". Sürüklenince Finder gibi kopyalanır.
private struct ShelfView: View {
    let island: NotchIsland

    var body: some View {
        let shelf = island.shelf
        VStack(spacing: 0) {
            Wings(notch: island.notch) {
                Text(L("Dosya rafı")).font(.system(size: 12, weight: .semibold)).foregroundStyle(IslandColor.secondary)
            } right: {
                Button { shelf.clear() } label: {
                    Text(L("Temizle")).font(.system(size: 12, weight: .semibold)).foregroundStyle(IslandColor.secondary)
                }
                .buttonStyle(.plain)
            }
            HStack(alignment: .top, spacing: 10) {
                ForEach(shelf.items) { item in ShelfTile(shelf: shelf, item: item) }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // Gizli dosya varsa raf açılınca kameraya bakılır (Yüz Tanıma).
        .onAppear { if shelf.hasHidden { Task { _ = await FaceID.shared.verify() } } }
    }
}

private struct ShelfTile: View {
    let shelf: IslandShelf
    let item: IslandShelf.Item

    private var locked: Bool { item.hidden && !FaceID.shared.isRevealed }

    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if locked {
                        Image(systemName: FaceID.shared.verifying ? "faceid" : "lock.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(IslandColor.secondary)
                            .symbolEffect(.pulse, options: .repeating, isActive: FaceID.shared.verifying)
                            .frame(width: 40, height: 40)
                            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .onTapGesture { Task { _ = await FaceID.shared.verify() } }
                    } else {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                            .resizable().frame(width: 40, height: 40)
                            // Raftan başka bir uygulamaya sürüklenir (özgün dosya kopyalanır).
                            .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
                    }
                }
                .contextMenu {
                    if FaceID.shared.isUsable || item.hidden {
                        Button(item.hidden ? L("Gizlemeyi Kaldır") : L("Gizle"), systemImage: item.hidden ? "eye" : "eye.slash") {
                            shelf.setHidden(item.id, !item.hidden)
                        }
                        .disabled(locked)
                    }
                }
                Button { shelf.remove(item.id) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7), .black)
                }
                .buttonStyle(.plain)
                .offset(x: 7, y: -5)
            }
            Text(locked ? L("Gizli dosya") : item.name).font(.system(size: 10, weight: .medium)).lineLimit(1).truncationMode(.middle)
            if locked { Color.clear.frame(height: 22) } else { action }
        }
        .frame(width: 82)
    }

    @ViewBuilder private var action: some View {
        switch item.state {
        case .uploading(let fraction):
            HStack(spacing: 5) {
                Ring(fraction: fraction, color: IslandColor.blue, lineWidth: 2).frame(width: 13, height: 13)
                Text("%\(Int(fraction * 100))").font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(IslandColor.secondary)
            }
            .frame(height: 22)
        case .linked(let url):
            PillButton(symbol: "link", title: L("Kopyala"), tint: IslandColor.green, foreground: .black) {
                shelf.copyLink(url)
            }
            .controlSize(.small)
        case .failed(let message):
            PillButton(symbol: "arrow.clockwise", title: message) { shelf.upload(item.id) }
        case .idle:
            if item.isFolder {
                Text(L("Klasör")).font(.system(size: 10)).foregroundStyle(IslandColor.secondary).frame(height: 22)
            } else if item.tooLarge {
                Text(L("5 GB'tan büyük")).font(.system(size: 10)).foregroundStyle(IslandColor.secondary).frame(height: 22)
            } else {
                PillButton(symbol: "link", title: L("Link al"), tint: IslandColor.blue, foreground: .white) {
                    shelf.upload(item.id)
                }
            }
        }
    }
}
