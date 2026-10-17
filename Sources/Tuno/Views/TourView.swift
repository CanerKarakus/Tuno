import SwiftUI

/// İzinlerden sonra bir kez gösterilen kısa tanıtım (kaydırılabilir sayfalar).
struct TourView: View {
    let onStart: () -> Void
    @State private var page: Int? = 0

    private static let pages: [TourPage] = [
        TourPage(
            title: "Ses, tam istediğiniz gibi",
            subtitle: "Mac'te olmayan ses kontrolleri artık burada.",
            hero: [("slider.horizontal.3", .pink), ("slider.vertical.3", .purple), ("hifispeaker.fill", .blue)],
            features: [
                ("slider.horizontal.3", "Her uygulamanın sesini ayrı ayarlayın"),
                ("slider.vertical.3", "Sistem geneli ekolayzer"),
                ("list.number", "Ses aygıtlarınız arasında otomatik geçiş"),
            ]),
        TourPage(
            title: "Fare ve trackpad",
            subtitle: "İkisini ayrı ayrı, istediğiniz gibi ayarlayın.",
            hero: [("rectangle.and.hand.point.up.left.fill", .teal), ("computermouse.fill", .cyan),
                   ("cursorarrow.click.2", .indigo)],
            features: [
                ("arrow.up.arrow.down", "Trackpad ve fare için ayrı kaydırma yönü"),
                ("computermouse.fill", "Tekerlekli farelerde akıcı kaydırma"),
                ("cursorarrow.click.2", "Fare tuşlarına yeni görevler"),
            ]),
        TourPage(
            title: "Hepsi tek yerde",
            subtitle: "Tümüne menü çubuğundaki Tuno simgesinden ulaşın.",
            hero: [("rectangle.on.rectangle", .cyan), ("waveform", .pink), ("sun.max.fill", .yellow)],
            features: [
                ("rectangle.on.rectangle", "Pencereler arasında hızlı geçiş"),
                ("sun.max.fill", "Harici ekran parlaklığı"),
                ("doc.on.clipboard.fill", "Pano geçmişi"),
            ]),
    ]

    private var current: Int { page ?? 0 }
    private var isLast: Bool { current == Self.pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(Self.pages.indices, id: \.self) { index in
                        TourPageView(page: Self.pages[index])
                            .containerRelativeFrame(.horizontal)
                            .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $page)
            .scrollIndicators(.never)

            HStack {
                Button("Geri") { go(current - 1) }
                    .buttonStyle(.borderless)
                    .opacity(current == 0 ? 0 : 1)
                    .disabled(current == 0)
                Spacer()
                HStack(spacing: 6) {
                    ForEach(Self.pages.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == current ? Color.accentColor : Color.primary.opacity(0.2))
                            .frame(width: index == current ? 18 : 7, height: 7)
                            .onTapGesture { go(index) }
                    }
                }
                Spacer()
                Button(isLast ? "Başla" : "İleri") { isLast ? onStart() : go(current + 1) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 22)
            .animation(.snappy(duration: 0.25), value: current)
        }
        .frame(width: 560, height: 520)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.rightArrow) { go(current + 1); return .handled }
        .onKeyPress(.leftArrow) { go(current - 1); return .handled }
    }

    private func go(_ index: Int) {
        guard Self.pages.indices.contains(index) else { return }
        withAnimation(.smooth(duration: 0.35)) { page = index }
    }
}

private struct TourPage {
    let title: String
    let subtitle: String
    let hero: [(String, Color)]
    let features: [(String, String)]
}

private struct TourPageView: View {
    let page: TourPage

    var body: some View {
        VStack(spacing: 22) {
            // Hafifçe yelpaze gibi açılmış simge karoları
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [page.hero[0].1.opacity(0.35), .clear],
                                         center: .center, startRadius: 4, endRadius: 120))
                    .frame(width: 240, height: 240)
                ForEach(page.hero.indices, id: \.self) { index in
                    let offset = CGFloat(index - 1)
                    SettingsIcon(symbol: page.hero[index].0, color: page.hero[index].1, size: index == 1 ? 76 : 60)
                        .rotationEffect(.degrees(Double(offset) * 10))
                        .offset(x: offset * 66, y: abs(offset) * 10)
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                        .zIndex(index == 1 ? 1 : 0)
                }
            }
            .frame(height: 150)
            .padding(.top, 34)

            VStack(spacing: 6) {
                Text(page.title).font(.title.weight(.semibold))
                Text(page.subtitle).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(page.features.indices, id: \.self) { index in
                    HStack(spacing: 12) {
                        Image(systemName: page.features[index].0)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 26)
                        Text(page.features[index].1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: 400, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
    }
}
