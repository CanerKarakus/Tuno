import AppKit
import SwiftUI

/// İzin ekranı ve tanıtımı barındıran pencere içeriği.
struct OnboardingRoot: View {
    @Environment(OnboardingModel.self) private var model
    @Environment(Permissions.self) private var permissions
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ZStack {
            switch model.phase {
            case .permissions:
                OnboardingView(onLater: { model.later() })
                    .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
            case .tour:
                TourView(onStart: { model.finishTour() })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.4), value: model.phase)
        .onAppear {
            WindowOpener.action = openWindow
            permissions.startPolling()
            model.onFinish = {
                openWindow(id: "main")
                dismissWindow(id: "onboarding")
                NSApp.activate()
            }
        }
        .onDisappear {
            permissions.stopPolling()
            model.windowClosed()
        }
        .onChange(of: permissions.allGranted) { _, granted in
            // Tüm izinler verilince kısa bir an "tamam" görünsün, sonra tanıtıma geç.
            guard granted, model.phase == .permissions else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { model.permissionsCompleted() }
        }
    }
}

struct OnboardingView: View {
    let onLater: () -> Void
    @Environment(Permissions.self) private var permissions

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                TunoIcon(size: 56)
                Text("Tuno'yu hazırlayalım").font(.title2.weight(.semibold))
                Text("Tüm özelliklerin çalışması için macOS'un birkaç izne ihtiyacı var. İzinler yalnızca bu Mac'te kullanılır; hiçbir veri gönderilmez.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }
            .padding(.top, 10)

            VStack(spacing: 8) {
                ForEach(PermissionKind.allCases) { kind in
                    PermissionRow(kind: kind)
                }
            }

            if permissions.screenRecordingNeedsRestart {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.clockwise.circle.fill").font(.title2).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ekran Kaydı iznini verdiyseniz Tuno'yu yeniden başlatın").font(.callout.weight(.medium))
                        Text("Yeniden açıldığında eksik kalan diğer izinler de burada gösterilir.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Yeniden Başlat") { permissions.relaunch() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(12)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack {
                Button("Daha Sonra", action: onLater)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                Spacer()
                if permissions.allGranted {
                    Label("Tüm izinler verildi", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button {
                        Task { await permissions.requestAll() }
                    } label: {
                        if permissions.isRequestingAll {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("İzinler isteniyor…") }
                        } else {
                            Text("Tüm İzinleri İste")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(permissions.isRequestingAll)
                }
            }
        }
        .padding(24)
        .frame(width: 540)
        .animation(.snappy(duration: 0.25), value: permissions.screenRecordingNeedsRestart)
        .animation(.snappy(duration: 0.25), value: permissions.allGranted)
    }
}

private struct PermissionRow: View {
    let kind: PermissionKind
    @Environment(Permissions.self) private var permissions

    var body: some View {
        let status = permissions.status(kind)
        HStack(spacing: 12) {
            SettingsIcon(symbol: kind.symbol, color: status == .granted ? .green : .accentColor, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(.body.weight(.medium))
                Text(kind.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            switch status {
            case .granted:
                Label("Verildi", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
                    .foregroundStyle(.green)
            case .denied:
                Button("Ayarları Aç") { permissions.openSettings(kind) }
            case .notDetermined:
                Button("İzin Ver") { Task { await permissions.request(kind) } }
                    .disabled(permissions.isRequestingAll)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.snappy(duration: 0.2), value: status)
    }
}
