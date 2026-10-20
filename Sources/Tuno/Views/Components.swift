import SwiftUI

/// Sistem Ayarları'ndaki renkli, köşeleri yuvarlatılmış simge karosu.
struct SettingsIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

/// Tuno simgesi (uygulama simgesiyle aynı çizim): koyu zeminde altı beyaz çubuk.
struct TunoIcon: View {
    var size: CGFloat = 28

    private static let heights: [CGFloat] = [44, 130, 206, 106, 163, 68]

    var body: some View {
        // Ölçüler uygulama simgesindeki 408'lik kareye göre.
        let unit = size / 408
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.245, green: 0.246, blue: 0.27),
                                          Color(red: 0.04, green: 0.041, blue: 0.06)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                HStack(spacing: 12.8 * unit) {
                    ForEach(Array(Self.heights.enumerated()), id: \.offset) { _, height in
                        Capsule().fill(.white).frame(width: 22 * unit, height: height * unit)
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08)))
            .frame(width: size, height: size)
    }
}

/// Tuno simgesindeki dalga, zeminsiz: koyu modda beyaz, açık modda siyah.
struct TunoWave: View {
    var height: CGFloat = 20

    private static let heights: [CGFloat] = [44, 130, 206, 106, 163, 68]

    var body: some View {
        let unit = height / 206
        HStack(spacing: 12.8 * unit) {
            ForEach(Array(Self.heights.enumerated()), id: \.offset) { _, bar in
                Capsule().frame(width: 22 * unit, height: bar * unit)
            }
        }
        .foregroundStyle(.primary)
        .frame(height: height)
    }
}

/// Sol/sağ simgeli ses düzeyi kaydırıcısı.
struct VolumeSlider: View {
    @Binding var value: Float
    var range: ClosedRange<Float> = 0...1
    var minSymbol = "speaker.fill"
    var maxSymbol = "speaker.wave.3.fill"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: minSymbol).foregroundStyle(.secondary).imageScale(.small)
            Slider(value: $value, in: range)
            Image(systemName: maxSymbol).foregroundStyle(.secondary).imageScale(.small)
        }
    }
}

/// Kayıt listesindeki aygıt satırı (Wi‑Fi ağ listesine benzer).
struct DeviceRow: View {
    let device: AudioDevice
    let scope: AudioScope
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 14)
                Image(systemName: device.symbolName(for: scope))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                    Text(device.transportLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Uyarı/bilgi notu satırı.
struct NoticeRow: View {
    let symbol: String
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension Float {
    var percentText: String { "%\(Int((self * 100).rounded()))" }

    /// %100 çevresinde hafif mıknatıslanma; ses yükseltmeye istemeden geçmeyi önler.
    var snappedToUnity: Float { abs(self - 1) < 0.03 ? 1 : self }
}

/// Denetim Merkezi tarzı kalın kapsül kaydırıcı.
/// `marker` verilirse (ör. 1.0) o noktadan sonrası ses yükseltme olarak turuncu boyanır.
struct CapsuleSlider: View {
    @Binding var value: Float
    var range: ClosedRange<Float> = 0...1
    var symbol: String?
    var marker: Float?
    var isDimmed = false
    var height: CGFloat = 24

    @Environment(\.colorScheme) private var colorScheme
    @State private var isDragging = false

    private var span: Float { range.upperBound - range.lowerBound }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let travel = max(width - height, 1)
            let fraction = CGFloat(min(max((value - range.lowerBound) / span, 0), 1))
            let fillWidth = height + travel * fraction
            let markerX = marker.map { height / 2 + travel * CGFloat(($0 - range.lowerBound) / span) }

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.09))

                if let markerX, value < (marker ?? 0) {
                    Capsule()
                        .fill(Color.primary.opacity(0.25))
                        .frame(width: 2, height: height * 0.4)
                        .offset(x: markerX - 1)
                }

                // Renkler kaydırıcı boyunca sabittir: %100'den sonra beyazdan turuncuya,
                // %150'den sonra kırmızıya yumuşak geçiş; dolgu yalnızca değere kadar görünür.
                Capsule()
                    .fill(LinearGradient(
                        stops: BoostStyle.fillStops(base: .white, maximum: marker == nil ? 1 : range.upperBound,
                                                    fillLength: fillWidth) { v in
                            height / 2 + travel * CGFloat((v - range.lowerBound) / span)
                        },
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: fillWidth)
                    .opacity(isDimmed ? 0.45 : 1)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.12), radius: 1, y: 0.5)

                Circle()
                    .fill(.white)
                    .frame(width: height, height: height)
                    .shadow(color: .black.opacity(0.28), radius: isDragging ? 3 : 1.5, y: 0.5)
                    .scaleEffect(isDragging ? 1.06 : 1)
                    .offset(x: fillWidth - height)

                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: height * 0.46, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.5))
                        .frame(width: height, height: height)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging { withAnimation(.snappy(duration: 0.15)) { isDragging = true } }
                        let f = Float(min(max((gesture.location.x - height / 2) / travel, 0), 1))
                        value = range.lowerBound + span * f
                    }
                    .onEnded { _ in withAnimation(.snappy(duration: 0.2)) { isDragging = false } }
            )
            .animation(isDragging ? nil : .snappy(duration: 0.25), value: value)
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(L("Ses düzeyi"))
        .accessibilityValue(value.percentText)
        .accessibilityAdjustableAction { direction in
            let step = span * 0.05
            value = min(max(value + (direction == .increment ? step : -step), range.lowerBound), range.upperBound)
        }
    }

}

/// Ses düzeyine göre hoparlör simgesi.
func speakerSymbol(volume: Float, muted: Bool) -> String {
    if muted || volume <= 0.001 { return "speaker.slash.fill" }
    if volume < 0.34 { return "speaker.wave.1.fill" }
    if volume < 0.67 { return "speaker.wave.2.fill" }
    return "speaker.wave.3.fill"
}

/// %100 üzeri ses yükseltmenin renkleri: turuncu, %150 üzeri kırmızı.
enum BoostStyle {
    static func color(for volume: Float) -> Color? {
        volume > 1.5 ? .red : volume > 1.001 ? .orange : nil
    }

    private static let colorPoints: [(Float, Color?)] = [(1.0, nil), (1.2, .orange), (1.5, .orange), (1.7, .red)]

    /// Dolgu çubuğu için gradyan: renkler sabit ses değerlerine bağlıdır (%100 → taban renk,
    /// %120 → turuncu, %170 → kırmızı); dolgu `fillLength` noktasında bittiği için oradaki
    /// renk ara tondan hesaplanır. `position` bir ses değerini dolgu eksenindeki noktaya çevirir.
    static func fillStops(base: Color, maximum: Float, fillLength: CGFloat,
                          position: (Float) -> CGFloat) -> [Gradient.Stop] {
        let solid = [Gradient.Stop(color: base, location: 0), .init(color: base, location: 1)]
        guard maximum > 1.001, fillLength > 0 else { return solid }

        var stops: [Gradient.Stop] = [.init(color: base, location: 0)]
        var previous: (x: CGFloat, color: Color) = (0, base)
        for (value, color) in colorPoints {
            let x = position(value)
            let color = color ?? base
            if x >= fillLength {
                let t = previous.x < x ? Double((fillLength - previous.x) / (x - previous.x)) : 1
                stops.append(.init(color: previous.color.mix(with: color, by: min(max(t, 0), 1)), location: 1))
                return stops
            }
            stops.append(.init(color: color, location: max(x, 0) / fillLength))
            previous = (x, color)
        }
        stops.append(.init(color: previous.color, location: 1))
        return stops
    }
}

/// Sayfanın başındaki tanıtım kartı (Sistem Ayarları'ndaki Bluetooth, Pil gibi bölmelerin üstü):
/// büyük renkli simge, başlık ve kısa açıklama. Simge açılışta hafifçe yaylanır.
struct PageHeader: View {
    let page: Page

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: page.symbol, color: page.tint, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(page.title).font(.title3.weight(.semibold))
                Text(page.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
