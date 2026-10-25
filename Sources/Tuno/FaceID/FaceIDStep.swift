import AVFoundation
import SwiftUI

/// Onboarding'de Siri'den sonra: yüz tanımayı tanıtır ve isteyen indirir. "İndir"e basınca önce kamera izni,
/// sonra model iner (indirme sürerken sonraki adımlara geçilebilir; bitince ilk tarama çentikte kendiliğinden başlar).
struct FaceIDStep: View {
    @State private var camera = FaceCamera.authorization
    private var models: FaceModels { FaceModels.shared }

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [.green.opacity(0.7), .mint.opacity(0.25), .clear],
                                         center: .center, startRadius: 4, endRadius: 110))
                    .frame(width: 210, height: 210)
                    .blur(radius: 30)
                    .opacity(models.isReady || models.isBusy ? 0.8 : 0.35)
                    .floating(4, speed: 0.6)
                ScanningGlyph(active: models.isBusy)
                    .frame(width: 128, height: 128)
                    .floating(5, speed: 0.8, phase: 1)
            }
            .frame(height: 220)
            .padding(.top, 40)
            .appearIn(0.05)

            OnboardingTitle(title: L("Yüz tanıma artık çentikte"),
                            subtitle: L("Mac'in kilidini yüzünle aç, gizli öğelerini sakla. Yüzün Mac'inden hiçbir zaman çıkmaz."))
                .appearIn(0.2)

            VStack(spacing: 10) {
                card.frame(width: 520)
                Link(destination: Site.url("/privacy/#face")) {
                    Label(L("Gizlilik: yüzün bize ulaşmaz"), systemImage: "hand.raised.fill")
                        .font(.callout)
                }
                .foregroundStyle(.secondary)
            }
            .appearIn(0.35)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            camera = FaceCamera.authorization
        }
    }

    private var card: some View {
        GlassCard(corner: 18) {
            HStack(spacing: 14) {
                ZStack {
                    if models.isBusy {
                        DownloadRing(progress: models.progress, installing: models.state == .installing) { models.cancel() }
                    } else {
                        Image(systemName: models.isReady ? "checkmark.circle.fill" : "faceid")
                            .font(.system(size: 26, weight: .regular))
                            .foregroundStyle(.green)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary).contentTransition(.numericText())
                }
                Spacer(minLength: 8)
                button
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .animation(.smooth(duration: 0.3), value: models.state)
        }
    }

    @ViewBuilder private var button: some View {
        if camera == .denied || camera == .restricted {
            Button(L("Kamera İzni Ver…")) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
            }
            .controlSize(.large)
        } else if !models.isReady && !models.isBusy {
            Button(String(format: L("İndir (%@)"), FaceModels.sizeText)) { start() }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
        }
    }

    private var title: String {
        switch models.state {
        case .downloading: L("İndiriliyor…")
        case .installing: L("Kuruluyor…")
        case .ready: L("Yüz tanıma hazır")
        case .failed: L("İndirilemedi")
        case .absent: L("Yüz tanıma modeli")
        }
    }

    private var detail: String {
        if camera == .denied || camera == .restricted { return L("Yüz tanıma için kamera izni gerekiyor.") }
        switch models.state {
        case .downloading(let value):
            return String(format: L("%%%d · Devam edebilirsin, arka planda iner."), Int(value * 100))
        case .installing: return L("Neredeyse bitti.")
        case .ready: return L("Kurulum bitince yüzün çentikte taranacak.")
        case .failed(let message): return message
        case .absent: return String(format: L("%@ · Yalnızca bu Mac'te çalışır."), FaceModels.sizeText)
        }
    }

    private func start() {
        Task {
            let granted = await FaceCamera.requestAccess()
            camera = FaceCamera.authorization
            guard granted else { return }
            FaceID.shared.autoEnroll = true
            models.download()
        }
    }
}

/// Face ID simgesi; inerken çevresinde dönen ince bir ışık.
private struct ScanningGlyph: View {
    let active: Bool
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.22)
                .stroke(AngularGradient(colors: [.green.opacity(0), .green], center: .center),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(spin ? 360 : 0))
                .opacity(active ? 1 : 0)
                .animation(.linear(duration: 1.4).repeatForever(autoreverses: false), value: spin)
            Image(systemName: "faceid")
                .font(.system(size: 84, weight: .thin))
                .foregroundStyle(.green.gradient)
                .symbolEffect(.pulse, options: .repeating, isActive: active)
        }
        .onAppear { spin = true }
        .animation(.smooth(duration: 0.4), value: active)
    }
}
