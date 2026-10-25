import AppKit
import SwiftUI

// MARK: - Pencere kökü

/// İlk açılış penceresi: dil → görünüm → izinler → hazır (gerekmeyen adımlar atlanır). Her adım Apple'ın
/// karşılama ekranları gibi: büyük başlık, canlı kartlar, altta sayfa noktaları ve tek ana düğme.
struct OnboardingRoot: View {
    @Environment(OnboardingModel.self) private var model
    @Environment(Permissions.self) private var permissions
    @Environment(LanguageStore.self) private var language
    @Environment(ThemeStore.self) private var theme
    @Environment(NotchIsland.self) private var island
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var languageChoice = AppLanguage.chosen ?? AppLanguage.detected
    @State private var themeChoice = AppTheme.chosen ?? .system
    @State private var forward = true
    /// İlk ekran: Mac'in dilinde "merhaba" yazılır, bitince dil seçimine geçilir.
    @State private var showHello = OnboardingModel.launchPhase == .language

    var body: some View {
        ZStack {
            if showHello {
                HelloView { withAnimation(.easeInOut(duration: 0.7)) { showHello = false } }
                    .transition(.opacity)
            } else {
                content.transition(.opacity)
            }
        }
        .frame(width: 780, height: 590)
        .background(OnboardingBackground(dark: scheme == .dark))
        // Görünüm her zaman açıkça verilir: nil'e dönmek macOS'ta pencereyi önceki (koyu) görünümde bırakıyordu.
        .preferredColorScheme(scheme)
        .onAppear {
            WindowOpener.action = openWindow
            permissions.startPolling()
            // Onboarding açıkken ilk yüz taraması beklesin (indirme bitse bile).
            FaceID.shared.holdAutoEnroll = true
            model.onFinish = {
                openWindow(id: "main")
                dismissWindow(id: "onboarding")
                NSApp.activate()
            }
        }
        .onDisappear {
            permissions.stopPolling()
            island.siriPreview = false
            model.windowClosed()
            // Dil ya da görünüm seçilmeden ya da yenilikler geçilmeden pencere kapatıldıysa yeniden açılır.
            FaceID.shared.holdAutoEnroll = false
            if !AppLanguage.isChosen || AppTheme.chosen == nil || ([.whatsNew, .siri, .faceID].contains(model.phase) && !model.isFinished) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { WindowOpener.action?(id: "onboarding") }
            }
        }
        // Siri önizlemesi: yalnızca Yenilikler ekranında ve anahtar açıkken çentikte görünür.
        .onChange(of: previewOn, initial: true) { _, on in island.siriPreview = on }
        .onChange(of: permissions.allGranted) { _, granted in
            // Tüm izinler verilince kısa bir an "tamam" görünsün, sonra devam.
            guard granted, model.phase == .permissions else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                if model.phase == .permissions { go { model.permissionsCompleted() } }
            }
        }
    }

    private var previewOn: Bool { !showHello && [.whatsNew, .siri].contains(model.phase) && island.showsSiri && !model.isFinished }

    /// Seçilen görünüm (dil adımından sonra): Otomatik'te macOS'un o anki görünümü.
    private var themeScheme: ColorScheme {
        switch theme.current {
        case .light: return .light
        case .dark: return .dark
        case .system:
            let system = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
            return system ? .dark : .light
        }
    }

    /// Pencerenin görünümü: merhaba ve dil adımı koyu; görünüm seçildikten sonra (geri dönülse de) seçilen görünüm.
    private var scheme: ColorScheme {
        if showHello { return .dark }
        if model.phase == .language && !theme.isChosen { return .dark }
        return themeScheme
    }

    private var content: some View {
        let _ = language.current
        return VStack(spacing: 0) {
            ZStack {
                step
                    .id(model.phase)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: forward ? 36 : -36)),
                        removal: .opacity.animation(.easeOut(duration: 0.18))))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            bottomBar
        }
        .animation(.smooth(duration: 0.4), value: model.phase)
    }

    @ViewBuilder private var step: some View {
        switch model.phase {
        case .language:
            LanguageStep(selection: $languageChoice)
        case .theme:
            ThemeStep(selection: $themeChoice)
        case .permissions:
            PermissionsStep()
        case .tour:
            ReadyStep()
        case .whatsNew:
            WhatsNewStep()
        case .siri:
            SiriStep()
        case .faceID:
            FaceIDStep()
        }
    }

    private var bottomBar: some View {
        HStack {
            Button(L("Geri")) { go(forward: false) { model.back() } }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .opacity(model.canGoBack ? 1 : 0)
                .disabled(!model.canGoBack)
                .frame(width: 160, alignment: .leading)
            Spacer()
            PageDots(count: model.steps.count, current: model.stepIndex)
            Spacer()
            HStack(spacing: 10) {
                if model.phase == .permissions && !permissions.allGranted {
                    Button(L("Daha Sonra Hatırlat")) { go { model.later() } }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
                primaryButton
            }
            .frame(width: 260, alignment: .trailing)
        }
        .padding(.horizontal, 30)
        .padding(.top, 14)
        .padding(.bottom, 24)
    }

    @ViewBuilder private var primaryButton: some View {
        switch model.phase {
        case .language:
            OnboardingButton(title: L("Devam")) {
                LanguageStore.shared.set(languageChoice)
                go { model.next() }
            }
        case .theme:
            OnboardingButton(title: L("Devam")) {
                ThemeStore.shared.set(themeChoice)
                go { model.next() }
            }
        case .permissions:
            if permissions.allGranted {
                OnboardingButton(title: L("Devam")) { go { model.permissionsCompleted() } }
            } else {
                OnboardingButton(title: permissions.isRequestingAll ? L("İzinler isteniyor…") : L("Tüm İzinleri İste"),
                                 busy: permissions.isRequestingAll) {
                    Task { await permissions.requestAll() }
                }
            }
        case .siri:
            OnboardingButton(title: model.steps.last == .siri ? L("Tuno'yu Kullanmaya Başla") : L("Devam")) {
                go { model.finishSiri() }
            }
        case .faceID:
            OnboardingButton(title: model.steps.last == .faceID ? L("Tuno'yu Kullanmaya Başla") : L("Devam")) {
                go { model.finishFaceID() }
            }
        case .whatsNew:
            OnboardingButton(title: model.steps.last == .whatsNew ? L("Tuno'yu Kullanmaya Başla") : L("Devam")) {
                go { model.finishWhatsNew() }
            }
        case .tour:
            OnboardingButton(title: model.steps.last == .tour ? L("Tuno'yu Kullanmaya Başla") : L("Devam")) {
                go { model.finishTour() }
            }
        }
    }

    private func go(forward: Bool = true, _ action: () -> Void) {
        self.forward = forward
        action()
    }
}

// MARK: - Merhaba

/// Apple cihazlarının ilk açılışındaki "hello": tek kalem çizgisiyle, bitişik el yazısı soldan sağa çizilir;
/// arkada bulanık, yavaşça kayan mavi-turuncu-kırmızı renk geçişi. Çizim bitince kısa bir duraklama ve dil seçimi.
struct HelloView: View {
    let onFinish: () -> Void
    @State private var drawn: CGFloat = 0
    var body: some View {
        ZStack {
            HelloBackground()
            HelloScript()
                .trim(from: 0, to: drawn)
                .stroke(.white, style: StrokeStyle(lineWidth: 8.5, lineCap: .round, lineJoin: .round))
                .frame(width: 380, height: 190)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(.timingCurve(0.45, 0.05, 0.35, 1, duration: 2.8)) { drawn = 1 }
            try? await Task.sleep(for: .milliseconds(2800))
            try? await Task.sleep(for: .milliseconds(900))
            onFinish()
        }
    }
}

/// Apple'ın açılış ekranındaki gibi bulanık renk geçişi: üstte mavi ve turuncu, ortada kırmızı, altta koyu lacivert.
struct HelloBackground: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate * 0.25
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    Color(red: 0.09, green: 0.1, blue: 0.14)
                    Group {
                        Ellipse().fill(Color(red: 0.55, green: 0.66, blue: 0.86))
                            .frame(width: w * 0.9, height: h * 0.55).position(x: w * (0.25 + 0.05 * sin(t)), y: h * 0.12)
                        Ellipse().fill(Color(red: 0.93, green: 0.62, blue: 0.38))
                            .frame(width: w * 0.8, height: h * 0.5).position(x: w * (0.78 + 0.05 * cos(t * 0.8)), y: h * 0.18)
                        Ellipse().fill(Color(red: 0.78, green: 0.18, blue: 0.32))
                            .frame(width: w * 1.2, height: h * 0.42).position(x: w * (0.5 + 0.06 * sin(t * 0.7 + 1)), y: h * 0.48)
                    }
                    .blur(radius: 90)
                    LinearGradient(colors: [.clear, Color(red: 0.09, green: 0.1, blue: 0.14)], startPoint: .center, endPoint: .bottom)
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// "hello" tek kalem çizgisi (yaklaşık 320×170'lik çizim alanında), Apple'ın el yazısı biçiminde.
struct HelloScript: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // h: yükselen giriş, üstte ilmik, aşağı gövde, sonra kambur ve çıkış
        p.move(to: CGPoint(x: 14, y: 140))
        p.addCurve(to: CGPoint(x: 66, y: 46), control1: CGPoint(x: 36, y: 122), control2: CGPoint(x: 64, y: 76))
        p.addCurve(to: CGPoint(x: 48, y: 40), control1: CGPoint(x: 68, y: 22), control2: CGPoint(x: 52, y: 20))
        p.addCurve(to: CGPoint(x: 36, y: 150), control1: CGPoint(x: 42, y: 64), control2: CGPoint(x: 38, y: 112))
        p.addCurve(to: CGPoint(x: 70, y: 106), control1: CGPoint(x: 42, y: 124), control2: CGPoint(x: 54, y: 106))
        p.addCurve(to: CGPoint(x: 82, y: 138), control1: CGPoint(x: 86, y: 106), control2: CGPoint(x: 84, y: 124))
        p.addCurve(to: CGPoint(x: 100, y: 150), control1: CGPoint(x: 80, y: 150), control2: CGPoint(x: 90, y: 154))
        // e
        p.addCurve(to: CGPoint(x: 128, y: 116), control1: CGPoint(x: 112, y: 146), control2: CGPoint(x: 128, y: 132))
        p.addCurve(to: CGPoint(x: 110, y: 114), control1: CGPoint(x: 128, y: 104), control2: CGPoint(x: 114, y: 102))
        p.addCurve(to: CGPoint(x: 124, y: 152), control1: CGPoint(x: 104, y: 128), control2: CGPoint(x: 108, y: 150))
        p.addCurve(to: CGPoint(x: 152, y: 140), control1: CGPoint(x: 136, y: 154), control2: CGPoint(x: 146, y: 148))
        // l
        p.addCurve(to: CGPoint(x: 186, y: 44), control1: CGPoint(x: 166, y: 120), control2: CGPoint(x: 186, y: 72))
        p.addCurve(to: CGPoint(x: 168, y: 46), control1: CGPoint(x: 186, y: 24), control2: CGPoint(x: 172, y: 24))
        p.addCurve(to: CGPoint(x: 170, y: 146), control1: CGPoint(x: 164, y: 72), control2: CGPoint(x: 162, y: 128))
        p.addCurve(to: CGPoint(x: 194, y: 142), control1: CGPoint(x: 174, y: 156), control2: CGPoint(x: 186, y: 154))
        // l
        p.addCurve(to: CGPoint(x: 226, y: 44), control1: CGPoint(x: 208, y: 120), control2: CGPoint(x: 226, y: 72))
        p.addCurve(to: CGPoint(x: 208, y: 46), control1: CGPoint(x: 226, y: 24), control2: CGPoint(x: 212, y: 24))
        p.addCurve(to: CGPoint(x: 210, y: 146), control1: CGPoint(x: 204, y: 72), control2: CGPoint(x: 202, y: 128))
        p.addCurve(to: CGPoint(x: 236, y: 140), control1: CGPoint(x: 214, y: 156), control2: CGPoint(x: 228, y: 152))
        // o ve kuyruk
        p.addCurve(to: CGPoint(x: 262, y: 108), control1: CGPoint(x: 242, y: 126), control2: CGPoint(x: 250, y: 108))
        p.addCurve(to: CGPoint(x: 280, y: 136), control1: CGPoint(x: 276, y: 108), control2: CGPoint(x: 282, y: 122))
        p.addCurve(to: CGPoint(x: 248, y: 142), control1: CGPoint(x: 278, y: 152), control2: CGPoint(x: 254, y: 158))
        p.addCurve(to: CGPoint(x: 266, y: 112), control1: CGPoint(x: 244, y: 130), control2: CGPoint(x: 252, y: 114))
        p.addCurve(to: CGPoint(x: 306, y: 106), control1: CGPoint(x: 280, y: 112), control2: CGPoint(x: 296, y: 112))
        // Çizim alanına sığdır.
        let box = CGRect(x: 6, y: 16, width: 308, height: 146)
        let scale = min(rect.width / (box.width * 1.18), rect.height / box.height)
        return p.applying(CGAffineTransform.identity
            .translatedBy(x: rect.midX, y: rect.midY)
            .scaledBy(x: scale * 1.18, y: scale)
            .translatedBy(x: -box.midX, y: -box.midY))
    }
}

// MARK: - Ortak parçalar

/// Apple'ın karşılama ekranlarındaki büyük, yuvarlak ana düğme.
struct OnboardingButton: View {
    let title: String
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small) }
                Text(title).font(.body.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 120)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .disabled(busy)
    }
}

struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.primary.opacity(0.85) : Color.primary.opacity(0.2))
                    .frame(width: index == current ? 20 : 7, height: 7)
            }
        }
        .animation(.snappy(duration: 0.3), value: current)
        .opacity(count > 1 ? 1 : 0)
    }
}

/// Başlık ve açıklama (her adımda aynı yerde).
struct OnboardingTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520)
        }
    }
}

/// Düz zemin (koyuda uygulamanın koyu rengi, açıkta beyaz) ve alttan yükselen, yavaşça yer değiştiren yumuşak
/// bir renk ışıltısı (Apple'ın karşılama ekranlarındaki gibi). Dil adımı her zaman koyu.
struct OnboardingBackground: View {
    let dark: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let isDark = dark || scheme == .dark
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate * 0.28
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    glow(Color(red: 0.35, green: 0.55, blue: 1), x: w * (0.22 + 0.10 * sin(t)), y: h * (1.02 + 0.03 * cos(t * 1.4)), size: w * 0.62)
                    glow(Color(red: 0.62, green: 0.42, blue: 1), x: w * (0.52 + 0.12 * sin(t * 0.8 + 2)), y: h * (1.06 + 0.03 * sin(t * 1.1)), size: w * 0.58)
                    glow(Color(red: 1, green: 0.45, blue: 0.68), x: w * (0.80 + 0.10 * cos(t * 0.9 + 1)), y: h * (1.02 + 0.04 * cos(t * 1.2 + 1)), size: w * 0.55)
                }
                .compositingGroup()
                .mask(LinearGradient(colors: [.clear, .black.opacity(0.6), .black], startPoint: .top, endPoint: .bottom))
                .environment(\.glowOpacity, isDark ? 0.30 : 0.20)
                .background(isDark ? Color(red: 0.09, green: 0.09, blue: 0.1) : Color.white)
            }
        }
        .ignoresSafeArea()
    }

    private func glow(_ color: Color, x: CGFloat, y: CGFloat, size: CGFloat) -> some View {
        GlowBlob(color: color, size: size).position(x: x, y: y)
    }
}

private struct GlowBlob: View {
    let color: Color
    let size: CGFloat
    @Environment(\.glowOpacity) private var opacity

    var body: some View {
        Ellipse()
            .fill(color.opacity(opacity))
            .frame(width: size, height: size * 0.62)
            .blur(radius: size * 0.22)
    }
}

private struct GlowOpacityKey: EnvironmentKey { static let defaultValue: Double = 0.2 }
extension EnvironmentValues {
    var glowOpacity: Double {
        get { self[GlowOpacityKey.self] }
        set { self[GlowOpacityKey.self] = newValue }
    }
}

/// Süzülme: kartlar hafifçe aşağı yukarı hareket eder.
struct Floating: ViewModifier {
    var amplitude: CGFloat = 3
    var speed: Double = 0.7
    var phase: Double = 0

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            content.offset(y: sin(t * speed + phase) * amplitude * 0.6)
        }
    }
}

/// Kartların sırayla, yaylanarak belirmesi.
struct AppearIn: ViewModifier {
    var delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown ? 1 : 0.85)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 18)
            .onAppear {
                withAnimation(.spring(duration: 0.7, bounce: 0.35).delay(delay)) { shown = true }
            }
    }
}

extension View {
    func floating(_ amplitude: CGFloat = 6, speed: Double = 1, phase: Double = 0) -> some View {
        modifier(Floating(amplitude: amplitude, speed: speed, phase: phase))
    }

    func appearIn(_ delay: Double) -> some View { modifier(AppearIn(delay: delay)) }
}

/// Buzlu cam kart (sitedeki yumuşak gölgeli kartlar gibi).
struct GlassCard<Content: View>: View {
    var tint: Color = .clear
    var corner: CGFloat = 20
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).fill(tint.opacity(0.14)))
            }
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
    }
}

// MARK: - 1. Dil

private let greetings: [AppLanguage: String] = [.tr: "Merhaba", .en: "Hello", .es: "Hola"]

struct LanguageStep: View {
    @Binding var selection: AppLanguage

    var body: some View {
        VStack(spacing: 26) {
            hero
            OnboardingTitle(title: L("Dil seçin"),
                            subtitle: L("Tuno'nun arayüz dilini seçin. Dilediğiniz zaman Ayarlar'dan değiştirebilirsiniz."))
            HStack(spacing: 14) {
                ForEach(Array(AppLanguage.allCases.enumerated()), id: \.element) { index, language in
                    LanguageCard(language: language, selected: selection == language,
                                 suggested: language == AppLanguage.detected) {
                        withAnimation(.spring(duration: 0.35, bounce: 0.3)) { selection = language }
                        // Seçim hemen uygulanır: metinler seçilen dile döner.
                        LanguageStore.shared.set(language)
                    }
                    .appearIn(0.15 + Double(index) * 0.08)
                }
            }
        }
        .padding(.top, 34)
    }

    private var hero: some View {
        ZStack {
            Image(systemName: "globe")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.primary)
            bubble("Merhaba", color: .pink).offset(x: -150, y: -18).floating(7, speed: 1.1, phase: 0.5)
            bubble("Hello", color: .blue).offset(x: 150, y: -30).floating(6, speed: 0.8, phase: 1.7)
            bubble("Hola", color: .orange).offset(x: 112, y: 42).floating(5, speed: 1.3, phase: 2.6)
            bubble("Hallo", color: .green).offset(x: -118, y: 46).floating(5, speed: 0.95, phase: 3.4)
        }
        .frame(height: 120)
    }

    private func bubble(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(color.gradient, in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }
}

private struct LanguageCard: View {
    let language: AppLanguage
    let selected: Bool
    let suggested: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if suggested {
                        Text(L("Önerilen"))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.22), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: selected)
                }
                Spacer(minLength: 0)
                Text(greetings[language] ?? "").font(.system(size: 24, weight: .bold))
                Text(language.name).font(.callout).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(width: 200, height: 128, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.accentColor.opacity(selected ? 0.16 : 0)))
            }
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.1), lineWidth: selected ? 2.5 : 1))
            .scaleEffect(selected ? 1.03 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 2. Görünüm

struct ThemeStep: View {
    @Binding var selection: AppTheme

    var body: some View {
        VStack(spacing: 30) {
            OnboardingTitle(title: L("Görünümünüzü seçin"),
                            subtitle: L("Tuno'yu açık ya da koyu kullanın, ya da macOS'a uysun. Genel ayarlarından değiştirebilirsiniz."))
                .padding(.top, 46)
            ThemePicker(selection: $selection, cardWidth: 206)
        }
    }
}

/// Üç önizleme kartı (Sistem Ayarları › Görünüm gibi); seçim hemen uygulanır ve kaydedilir.
struct ThemePicker: View {
    @Binding var selection: AppTheme
    var cardWidth: CGFloat = 206

    var body: some View {
        HStack(spacing: cardWidth > 150 ? 20 : 14) {
            ForEach(Array(AppTheme.allCases.enumerated()), id: \.element) { index, theme in
                Button {
                    withAnimation(.spring(duration: 0.35, bounce: 0.3)) { selection = theme }
                    withAnimation(.easeInOut(duration: 0.35)) { ThemeStore.shared.set(theme) }
                } label: {
                    VStack(spacing: 10) {
                        ThemePreview(theme: theme)
                            .frame(width: cardWidth, height: cardWidth * 0.68)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(selection == theme ? Color.accentColor : Color.primary.opacity(0.12),
                                              lineWidth: selection == theme ? 3 : 1))
                            .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
                            .scaleEffect(selection == theme ? 1.03 : 1)
                        HStack(spacing: 6) {
                            Image(systemName: selection == theme ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selection == theme ? Color.accentColor : Color.secondary)
                            Text(theme.title).font(cardWidth > 150 ? .body.weight(.medium) : .callout)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .appearIn(cardWidth > 150 ? 0.1 + Double(index) * 0.08 : 0)
            }
        }
    }
}

/// Küçük bir Tuno penceresi çizimi: kenar çubuğu, renkli simgeler, ses kaydırıcısı.
struct ThemePreview: View {
    let theme: AppTheme

    var body: some View {
        switch theme {
        case .light: MiniWindow(dark: false)
        case .dark: MiniWindow(dark: true)
        case .system:
            ZStack {
                MiniWindow(dark: false)
                MiniWindow(dark: true).mask(DiagonalHalf())
            }
        }
    }
}

private struct DiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

private struct MiniWindow: View {
    let dark: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let back = dark ? Color(white: 0.13) : Color(white: 0.96)
            let side = dark ? Color(white: 0.19) : Color(white: 0.9)
            let card = dark ? Color(white: 0.22) : .white
            let line = dark ? Color.white.opacity(0.22) : Color.black.opacity(0.12)
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: dark ? [Color(red: 0.2, green: 0.18, blue: 0.35), Color(red: 0.1, green: 0.12, blue: 0.22)]
                                            : [Color(red: 0.72, green: 0.82, blue: 1), Color(red: 0.95, green: 0.8, blue: 0.9)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: h * 0.045) {
                        HStack(spacing: 3) {
                            ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0).frame(width: w * 0.03) }
                        }
                        .padding(.bottom, h * 0.03)
                        ForEach(Array([Color.pink, .blue, .orange, .purple, .teal].enumerated()), id: \.offset) { index, color in
                            HStack(spacing: w * 0.02) {
                                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: w * 0.045, height: w * 0.045)
                                Capsule().fill(line).frame(width: w * (index == 0 ? 0.13 : 0.1), height: h * 0.03)
                            }
                            .padding(3)
                            .background(index == 0 ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 3))
                        }
                        Spacer()
                    }
                    .padding(w * 0.035)
                    .frame(width: w * 0.32, height: h * 0.86, alignment: .topLeading)
                    .background(side)
                    VStack(alignment: .leading, spacing: h * 0.05) {
                        Capsule().fill(line).frame(width: w * 0.2, height: h * 0.04)
                        VStack(alignment: .leading, spacing: h * 0.05) {
                            ForEach(0..<3, id: \.self) { index in
                                HStack(spacing: w * 0.02) {
                                    Circle().fill([Color.pink, .green, .orange][index]).frame(width: w * 0.04)
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(line)
                                        Capsule().fill(Color.accentColor).frame(width: w * [0.26, 0.18, 0.3][index])
                                    }
                                    .frame(height: h * 0.03)
                                }
                            }
                        }
                        .padding(w * 0.03)
                        .background(card, in: RoundedRectangle(cornerRadius: 5))
                        Spacer()
                    }
                    .padding(w * 0.04)
                    .frame(width: w * 0.58, height: h * 0.86, alignment: .topLeading)
                    .background(back)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .offset(x: w * 0.05, y: h * 0.09)
            }
        }
    }
}

// MARK: - 3. İzinler

struct PermissionsStep: View {
    @Environment(Permissions.self) private var permissions

    var body: some View {
        VStack(spacing: 20) {
            PermissionOrbit()
                .padding(.top, 12)
            OnboardingTitle(title: L("Tuno'yu hazırlayalım"),
                            subtitle: L("Tüm özelliklerin çalışması için macOS'un birkaç izne ihtiyacı var. İzinler yalnızca bu Mac'te kullanılır; hiçbir veri gönderilmez."))
            LazyVGrid(columns: [GridItem(.fixed(350), spacing: 12), GridItem(.fixed(350))], spacing: 12) {
                ForEach(Array(PermissionKind.allCases.enumerated()), id: \.element) { index, kind in
                    PermissionRow(kind: kind).appearIn(0.1 + Double(index) * 0.06)
                }
            }
            if permissions.screenRecordingNeedsRestart {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.clockwise.circle.fill").font(.title2).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Ekran Kaydı iznini verdiyseniz Tuno'yu yeniden başlatın")).font(.callout.weight(.medium))
                        Text(L("Yeniden açıldığında eksik kalan diğer izinler de burada gösterilir."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("Yeniden Başlat")) { permissions.relaunch() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(12)
                .frame(width: 712)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.snappy(duration: 0.25), value: permissions.screenRecordingNeedsRestart)
    }
}

/// Tuno simgesinin çevresinde dönen izin simgeleri; verilen izin yeşile döner.
private struct PermissionOrbit: View {
    @Environment(Permissions.self) private var permissions

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate * 0.35
            ZStack {
                Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1).frame(width: 132, height: 132)
                TunoIcon(size: 62).shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                ForEach(Array(PermissionKind.allCases.enumerated()), id: \.element) { index, kind in
                    let angle = t + Double(index) * .pi / 2
                    SettingsIcon(symbol: kind.symbol,
                                 color: permissions.status(kind) == .granted ? .green : .accentColor, size: 30)
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                        .offset(x: cos(angle) * 66, y: sin(angle) * 66)
                }
            }
            .frame(height: 132)
        }
    }
}

struct PermissionRow: View {
    let kind: PermissionKind
    @Environment(Permissions.self) private var permissions

    var body: some View {
        let status = permissions.status(kind)
        HStack(spacing: 12) {
            SettingsIcon(symbol: kind.symbol, color: status == .granted ? .green : .accentColor, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(.body.weight(.semibold))
                Text(kind.detail).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            switch status {
            case .granted:
                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            case .denied:
                Button(L("Ayarları Aç")) { permissions.openSettings(kind) }
                    .controlSize(.small)
            case .notDetermined:
                Button(L("İzin Ver")) { Task { await permissions.request(kind) } }
                    .controlSize(.small)
                    .disabled(permissions.isRequestingAll)
            }
        }
        .padding(12)
        .frame(height: 74)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(status == .granted ? Color.green.opacity(0.5) : Color.primary.opacity(0.08)))
        .animation(.spring(duration: 0.35, bounce: 0.3), value: status)
    }
}

// MARK: - 4. Hazır

/// Tuno'nun neler yaptığını canlı kartlarla gösterir (sitedeki ana sayfa kartları gibi).
struct ReadyStep: View {
    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                VolumeCard().rotationEffect(.degrees(-4)).offset(x: -250, y: 10).floating(6, speed: 0.9).appearIn(0.05)
                EqualizerCard().rotationEffect(.degrees(3)).offset(x: -70, y: -14).floating(5, speed: 1.1, phase: 1).appearIn(0.15)
                ScrollCard().rotationEffect(.degrees(-2)).offset(x: 95, y: 18).floating(7, speed: 0.8, phase: 2).appearIn(0.25)
                WindowsCard().rotationEffect(.degrees(4)).offset(x: 258, y: -22).floating(5, speed: 1.2, phase: 3).appearIn(0.35)
            }
            .frame(height: 250)
            .padding(.top, 24)
            OnboardingTitle(title: L("Her şey hazır"),
                            subtitle: L("Tuno menü çubuğunda sizi bekliyor. Ses, ekolayzer, fare, pencereler ve daha fazlası tek tıkla."))
        }
    }
}

private struct VolumeCard: View {
    var body: some View {
        GlassCard(tint: .pink) {
            VStack(alignment: .leading, spacing: 10) {
                Label(L("Uygulama Sesleri"), systemImage: "slider.horizontal.3")
                    .font(.callout.weight(.semibold))
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    VStack(spacing: 9) {
                        ForEach(Array([Color.pink, .green, .orange].enumerated()), id: \.offset) { index, color in
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 5).fill(color.gradient).frame(width: 20, height: 20)
                                GeometryReader { geo in
                                    let value = 0.45 + 0.35 * sin(t * 0.9 + Double(index) * 1.9)
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.primary.opacity(0.12))
                                        Capsule().fill(Color.accentColor).frame(width: geo.size.width * value)
                                    }
                                }
                                .frame(height: 6)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .frame(width: 190)
        }
    }
}

private struct EqualizerCard: View {
    var body: some View {
        GlassCard(tint: .yellow) {
            VStack(alignment: .leading, spacing: 10) {
                Label(L("Ekolayzer"), systemImage: "slider.vertical.3").font(.callout.weight(.semibold))
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(0..<8, id: \.self) { index in
                            Capsule()
                                .fill(LinearGradient(colors: [.orange, .yellow], startPoint: .bottom, endPoint: .top))
                                .frame(width: 10, height: 22 + 38 * (0.5 + 0.5 * sin(t * 2.2 + Double(index) * 0.8)))
                        }
                    }
                    .frame(height: 64, alignment: .bottom)
                }
                Text("+6 dB").font(.system(size: 22, weight: .bold))
            }
            .padding(16)
            .frame(width: 150)
        }
    }
}

private struct ScrollCard: View {
    var body: some View {
        GlassCard(tint: .blue) {
            VStack(alignment: .leading, spacing: 10) {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let y = sin(t * 1.6) * 14
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.4), lineWidth: 2)
                        .frame(width: 96, height: 64)
                        .overlay {
                            HStack(spacing: 6) {
                                Circle().fill(Color.accentColor).frame(width: 12)
                                Circle().fill(Color.accentColor).frame(width: 12)
                            }
                            .offset(y: y)
                        }
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: y < 0 ? "arrow.up" : "arrow.down").font(.caption.weight(.bold)).padding(6)
                        }
                }
                Text(L("Kaydırma yönü")).font(.callout.weight(.semibold))
                Text(L("Trackpad ve fare ayrı ayrı")).font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(width: 160, alignment: .leading)
        }
    }
}

private struct WindowsCard: View {
    var body: some View {
        GlassCard(tint: .purple) {
            VStack(alignment: .leading, spacing: 10) {
                TimelineView(.animation(minimumInterval: 1 / 20)) { context in
                    let front = Int(context.date.timeIntervalSinceReferenceDate / 1.4) % 3
                    ZStack {
                        ForEach(0..<3, id: \.self) { index in
                            let order = (index - front + 3) % 3
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill([Color.blue, .purple, .pink][index].gradient)
                                .frame(width: 92, height: 58)
                                .overlay(alignment: .topLeading) {
                                    HStack(spacing: 3) {
                                        ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0).frame(width: 5) }
                                    }
                                    .padding(5)
                                }
                                .offset(x: CGFloat(order) * 10, y: CGFloat(order) * -8)
                                .zIndex(Double(3 - order))
                                .opacity(order == 0 ? 1 : 0.75)
                        }
                    }
                    .animation(.spring(duration: 0.5, bounce: 0.3), value: front)
                    .frame(width: 120, height: 80)
                }
                Text(L("Pencereler")).font(.callout.weight(.semibold))
                Text("⌘⇥").font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(width: 150, alignment: .leading)
        }
    }
}

// MARK: - Ana pencere: dil ve görünüm seçilmeden kullanılamaz

/// Ana pencere dil ve görünüm seçilmeden açılırsa (menü çubuğundan) üstünde bu kart durur.
struct SetupOverlay: View {
    @Environment(LanguageStore.self) private var language
    @Environment(ThemeStore.self) private var theme
    @State private var languageChoice = AppLanguage.chosen ?? AppLanguage.detected
    @State private var themeChoice = AppTheme.chosen ?? .system
    @State private var showTheme = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 0) {
                ZStack {
                    if showTheme || language.isChosen && !theme.isChosen {
                        ThemeStep(selection: $themeChoice).transition(.move(edge: .trailing).combined(with: .opacity))
                    } else {
                        LanguageStep(selection: $languageChoice)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                .frame(maxHeight: .infinity)
                HStack {
                    Spacer()
                    if showTheme || language.isChosen && !theme.isChosen {
                        OnboardingButton(title: L("Devam")) { withAnimation { ThemeStore.shared.set(themeChoice) } }
                    } else {
                        OnboardingButton(title: L("Devam")) {
                            LanguageStore.shared.set(languageChoice)
                            withAnimation(.smooth(duration: 0.4)) { showTheme = true }
                        }
                    }
                }
                .padding(24)
            }
            .frame(width: 760, height: 560)
            .background(OnboardingBackground(dark: !(showTheme || language.isChosen && !theme.isChosen))
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous)))
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(radius: 40)
        }
    }
}
