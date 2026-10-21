import AppKit
import SwiftUI

// MARK: - Yenilikler (1.6)

/// Güncelleyenlere bir kez: çentikteki ada hâlden hâle geçer; altta Siri anahtarı.
/// Anahtar açıkken gerçek Siri damlası çentikte görünür (OnboardingRoot önizlemeyi yönetir).
struct WhatsNewStep: View {
    @Environment(NotchIsland.self) private var island

    var body: some View {
        @Bindable var island = island
        VStack(spacing: 18) {
            IslandShowcase()
                .padding(.top, 26)
                .appearIn(0.05)

            VStack(spacing: 10) {
                Text(L("Tuno 1.6'da yeni"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color.blue.opacity(0.12)))
                    .appearIn(0.4)
                OnboardingTitle(title: L("Dynamic Island geldi"),
                                subtitle: L("Müzik, aramalar, zamanlayıcılar ve indirmeler artık çentikte görünür."))
            }

            SiriCard(on: $island.showsSiri)
                .frame(width: 540)
                .appearIn(0.5)
        }
    }
}

/// Siri satırı: Siri simgesi, durum yazısı ve anahtar.
private struct SiriCard: View {
    @Binding var on: Bool
    var title = L("Siri artık çentikten açılıyor")

    var body: some View {
        GlassCard(corner: 18) {
            HStack(spacing: 14) {
                SiriIcon(on: on)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    HStack(spacing: 5) {
                        if on {
                            Image(systemName: "arrow.up")
                                .font(.caption.weight(.bold))
                                .symbolEffect(.bounce.up, options: .repeat(.periodic(delay: 1.2)))
                                .transition(.opacity.combined(with: .scale))
                        }
                        Text(on ? L("Şu an çentikte görünüyor.") : L("Kapalı. Siri her zamanki gibi açılır."))
                            .contentTransition(.opacity)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $on.animation(.smooth(duration: 0.3)))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.large)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
    }
}

/// iOS 27'deki Siri simgesi gibi: koyu kare içinde sıvı cam bir kabarcık ve ortasından geçen renkli ışık
/// telleri. Açıkken teller konuşur gibi dalgalanır; kapalıyken durulur ve griye döner.
private struct SiriIcon: View {
    let on: Bool
    var side: CGFloat = 44

    private static let strands: [(Color, Double, Double, Double)] = [   // renk, genlik, hız, faz
        (Color(red: 0.25, green: 0.85, blue: 1), 1, 2.1, 0),
        (Color(red: 1, green: 0.3, blue: 0.65), 0.8, 2.9, 2.1),
        (Color(red: 1, green: 0.62, blue: 0.25), 0.6, 3.7, 4.2)
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !on)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.25, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.03)], startPoint: .top, endPoint: .bottom))
                ZStack {
                    Circle().fill(RadialGradient(colors: [.white.opacity(0.14), .white.opacity(0.02)],
                                                 center: UnitPoint(x: 0.35, y: 0.25), startRadius: 0, endRadius: side * 0.6))
                    Canvas { context, size in
                        context.blendMode = .plusLighter
                        for (index, strand) in Self.strands.enumerated() {
                            let (color, amplitude, speed, phase) = strand
                            let swing = on ? (0.55 + 0.45 * sin(t * 1.3 + Double(index))) : 0.15
                            var path = Path()
                            for step in 0...40 {
                                let x = size.width * Double(step) / 40
                                let u = Double(step) / 40
                                let y = size.height / 2 + sin(.pi * u) * amplitude * swing * size.height * 0.2
                                    * sin(u * .pi * 2.4 + t * speed + phase)
                                step == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                            }
                            var glow = context
                            let k = side / 44
                            glow.addFilter(.blur(radius: 2.5 * k))
                            glow.stroke(path, with: .color(color.opacity(0.9)), lineWidth: 4 * k)
                            context.stroke(path, with: .color(.white.opacity(0.85)), lineWidth: 0.9 * k)
                        }
                    }
                    .mask(Circle())
                    Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.06), .white.opacity(0.25)],
                                                         startPoint: .top, endPoint: .bottom), lineWidth: 0.8 * side / 44)
                    Capsule().fill(.white.opacity(0.4)).frame(width: side * 0.27, height: side * 0.07)
                        .blur(radius: side / 44).offset(y: -side * 0.27)
                }
                .padding(side * 0.16)
            }
            .saturation(on ? 1 : 0)
        }
        .frame(width: side, height: side)
        .shadow(color: .black.opacity(0.25), radius: side * 0.14, y: side * 0.07)
        .animation(.smooth(duration: 0.4), value: on)
    }
}

// MARK: - Siri (yeni kurulum)

/// Yeni yükleyenlere izinlerden önce: büyük Siri simgesi ve anahtar. Anahtar açıkken damla gerçek çentikte görünür.
struct SiriStep: View {
    @Environment(NotchIsland.self) private var island

    var body: some View {
        @Bindable var island = island
        VStack(spacing: 22) {
            ZStack {
                // Simgenin arkasında yavaşça nefes alan renkli ışık.
                Circle()
                    .fill(AngularGradient(colors: [.cyan, .blue, .purple, .pink, .orange, .cyan], center: .center))
                    .frame(width: 170, height: 170)
                    .blur(radius: 50)
                    .opacity(island.showsSiri ? 0.55 : 0.12)
                    .floating(4, speed: 0.6)
                SiriIcon(on: island.showsSiri, side: 128)
                    .floating(5, speed: 0.8, phase: 1)
            }
            .frame(height: 220)
            .padding(.top, 40)
            .appearIn(0.05)
            .animation(.smooth(duration: 0.5), value: island.showsSiri)

            OnboardingTitle(title: L("Siri artık çentikten açılıyor"),
                            subtitle: L("Siri'yi çağırınca çentikten sıvı cam bir damla akar. Işığı sesle oynar, cevabı içinde yazar."))
                .appearIn(0.2)

            SiriCard(on: $island.showsSiri, title: L("Çentikte göster"))
                .frame(width: 520)
                .appearIn(0.35)
        }
    }
}

// MARK: - Ada vitrini

/// Mac ekranının üst kısmı (kullanıcının kendi duvar kâğıdıyla): ada her seferinde normal çentikten başlar,
/// önce yana açılır; müzikte ve aramada ardından aşağı doğru büyür, sonra çentiğe döner.
/// Altındaki sekmeler o anki özelliği işaretler; tıklanınca oraya atlar.
private struct IslandShowcase: View {
    enum Scene { case notch, music, player, call, callCard, timer, download }

    /// Döngü: her özellik çentikten çıkar ve çentiğe döner.
    private static let sequence: [Scene] = [.notch, .music, .player, .notch, .call, .callCard, .notch, .timer, .notch, .download]

    @State private var scene: Scene = .notch
    @State private var tab = 0
    @State private var start = Date()
    @State private var cycle: Task<Void, Never>?
    @State private var wallpaper = DesktopPicture.load()
    @Namespace private var tabSpace

    private let notch = CGSize(width: 104, height: 22)

    var body: some View {
        VStack(spacing: 14) {
            screen
            tabs
        }
        .onAppear { run(from: 0) }
        .onDisappear { cycle?.cancel() }
    }

    // MARK: Ekran

    private var screen: some View {
        ZStack(alignment: .top) {
            if let wallpaper {
                Image(nsImage: wallpaper)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 600, height: 196, alignment: .top)
                    .clipped()
            } else {
                LinearGradient(colors: [Color(red: 0.1, green: 0.1, blue: 0.3), Color(red: 0.75, green: 0.4, blue: 0.5)],
                               startPoint: .top, endPoint: .bottom)
            }
            Rectangle().fill(.ultraThinMaterial).frame(height: notch.height)
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: scene == .notch)) { context in
                island(t: context.date.timeIntervalSince(start))
            }
        }
        .frame(width: 600, height: 196)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
        .environment(\.colorScheme, .dark)
    }

    private var size: (width: CGFloat, height: CGFloat, corner: CGFloat) {
        switch scene {
        case .notch: (notch.width, notch.height, 8)
        case .music, .call, .timer, .download: (notch.width + 116, notch.height, 11)
        case .player: (330, 146, 30)
        case .callCard: (300, 76, 28)
        }
    }

    private func island(t: Double) -> some View {
        let size = size
        return ZStack(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: size.corner, bottomTrailingRadius: size.corner, style: .continuous)
                .fill(.black)
            content(t: t)
                .id(scene)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.9, anchor: .top)).animation(.easeOut(duration: 0.3).delay(0.15)),
                    removal: .opacity.animation(.easeOut(duration: 0.12))))
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    @ViewBuilder private func content(t: Double) -> some View {
        switch scene {
        case .notch:
            Color.clear
        case .music:
            compact {
                Artwork(size: 16, corner: 4)
            } trailing: {
                Bars(t: t)
            }
        case .player:
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Artwork(size: 42, corner: 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Midnight City").font(.system(size: 13, weight: .semibold))
                        Text("M83").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    Bars(t: t).padding(.top, 2).frame(maxHeight: .infinity, alignment: .top)
                }
                .frame(height: 42)
                HStack(spacing: 8) {
                    let progress = min(0.32 + t.truncatingRemainder(dividingBy: 60) / 200, 1)
                    Text("1:24")
                    GeometryReader { proxy in
                        Capsule().fill(.white.opacity(0.2))
                            .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: proxy.size.width * progress) }
                    }
                    .frame(height: 5)
                    Text("-2:39")
                }
                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
                HStack(spacing: 38) {
                    Image(systemName: "backward.fill")
                    Image(systemName: "pause.fill").font(.system(size: 22))
                    Image(systemName: "forward.fill")
                }
                .font(.system(size: 16))
            }
            .padding(.horizontal, 22)
            .padding(.top, notch.height + 6)
        case .call:
            compact {
                Image(systemName: "phone.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.green)
            } trailing: {
                Text(clock(42 + Int(t) % 600)).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.green)
            }
        case .callCard:
            HStack(spacing: 10) {
                Circle()
                    .fill(LinearGradient(colors: [Color(red: 0.55, green: 0.6, blue: 0.7), Color(red: 0.35, green: 0.4, blue: 0.5)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 34, height: 34)
                    .overlay(Text("EC").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Emma Clarke").font(.system(size: 13, weight: .semibold))
                    Text(clock(42 + Int(t) % 600)).font(.system(size: 11.5, weight: .medium).monospacedDigit()).foregroundStyle(.green)
                }
                Spacer()
                Circle().fill(.white.opacity(0.18)).frame(width: 32, height: 32)
                    .overlay(Image(systemName: "mic.slash.fill").font(.system(size: 13)))
                Circle().fill(.red).frame(width: 32, height: 32)
                    .overlay(Image(systemName: "phone.down.fill").font(.system(size: 13)))
            }
            .padding(.horizontal, 18)
            .padding(.top, notch.height + 2)
        case .timer:
            compact {
                Image(systemName: "timer").font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
            } trailing: {
                Text(clock(max(0, 299 - Int(t) % 300))).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.orange)
            }
        case .download:
            compact {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 14)).foregroundStyle(.white, .blue)
            } trailing: {
                let progress = min((t.truncatingRemainder(dividingBy: 3.6)) / 3, 1)
                ZStack {
                    Circle().stroke(.white.opacity(0.2), lineWidth: 2.2)
                    Circle().trim(from: 0, to: progress)
                        .stroke(.blue, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    if progress >= 1 { Image(systemName: "checkmark").font(.system(size: 6.5, weight: .heavy)).foregroundStyle(.blue) }
                }
                .frame(width: 13, height: 13)
            }
        }
    }

    private func compact<L: View, T: View>(@ViewBuilder leading: () -> L, @ViewBuilder trailing: () -> T) -> some View {
        HStack {
            leading()
            Spacer()
            trailing()
        }
        .padding(.horizontal, 9)
        .frame(height: notch.height)
    }

    private func clock(_ seconds: Int) -> String { String(format: "%d:%02d", seconds / 60, seconds % 60) }

    // MARK: Sekmeler

    private var tabList: [(symbol: String, title: String, scene: Scene)] {
        [("music.note", L("Müzik"), .music),
         ("phone.fill", L("Aramalar"), .call),
         ("timer", L("Zamanlayıcılar"), .timer),
         ("arrow.down.circle.fill", L("İndirmeler"), .download)]
    }

    private static func tab(of scene: Scene) -> Int? {
        switch scene {
        case .notch: nil
        case .music, .player: 0
        case .call, .callCard: 1
        case .timer: 2
        case .download: 3
        }
    }

    private var tabs: some View {
        HStack(spacing: 6) {
            ForEach(Array(tabList.enumerated()), id: \.offset) { index, item in
                let active = index == tab
                Button {
                    // Tıklanan özellik çentikten başlar.
                    if let at = Self.sequence.firstIndex(of: item.scene) { run(from: at - 1) }
                } label: {
                    Label(item.title, systemImage: item.symbol)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(active ? Color.primary : Color.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background {
                            if active { Capsule().fill(Color.primary.opacity(0.08)).matchedGeometryEffect(id: "tab", in: tabSpace) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.snappy(duration: 0.35), value: tab)
    }

    // MARK: Döngü

    private func run(from index: Int) {
        cycle?.cancel()
        cycle = Task { @MainActor in
            var index = max(index, 0)
            while !Task.isCancelled {
                let next = Self.sequence[index]
                // Küçülürken sakin, büyürken yaylı (Tuno'daki ada gibi).
                let growing = next != .notch
                withAnimation(growing ? .spring(duration: 0.55, bounce: 0.3) : .smooth(duration: 0.4)) { scene = next }
                if let value = Self.tab(of: next) ?? Self.tab(of: Self.sequence[(index + 1) % Self.sequence.count]) {
                    tab = value
                }
                let hold: Double = switch next {
                case .notch: 0.9
                case .player, .callCard: 3.2
                case .music, .call: 1.4
                case .timer, .download: 2.6
                }
                try? await Task.sleep(for: .seconds(hold))
                index = (index + 1) % Self.sequence.count
            }
        }
    }
}

/// Kullanıcının masaüstü resmi (vitrinin arka planı); okunamazsa renk geçişi kullanılır.
private enum DesktopPicture {
    @MainActor static func load() -> NSImage? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              !url.hasDirectoryPath
        else { return nil }
        return NSImage(contentsOf: url)
    }
}

/// Albüm kapağı yerine renkli kare.
private struct Artwork: View {
    let size: CGFloat
    let corner: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.98, green: 0.35, blue: 0.5), Color(red: 0.45, green: 0.3, blue: 0.95)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(Image(systemName: "music.note").font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(.white.opacity(0.9)))
    }
}

/// Ses dalgası çubukları (Tuno'daki gibi pembe).
private struct Bars: View {
    let t: Double

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                let level = 0.3 + 0.7 * abs(sin(t * (2.4 + Double(index) * 0.55) + Double(index) * 1.3))
                Capsule()
                    .fill(index.isMultiple(of: 2) ? Color(red: 1, green: 0.22, blue: 0.37) : Color(red: 1, green: 0.39, blue: 0.51))
                    .frame(width: 2.5, height: 12 * level)
            }
        }
        .frame(height: 12)
    }
}
