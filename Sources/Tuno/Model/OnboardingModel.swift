import AVFoundation
import AppKit
import Observation

enum OnboardingPhase { case permissions, tour }

/// İlk açılış akışı:
/// - İzinlerden biri eksikse yalnızca izin ekranı açılır (ana pencere görünmez).
/// - "Daha Sonra" → izin ekranı 1 gün sonra yeniden gösterilir (tümü verilene kadar).
/// - Tüm izinler verilince ya da "Daha Sonra"ya basılınca kısa tanıtım bir kez gösterilir.
/// - Hiçbiri gerekmiyorsa doğrudan ana pencere açılır.
@Observable
@MainActor
final class OnboardingModel {
    var phase: OnboardingPhase
    @ObservationIgnored var onFinish: (() -> Void)?
    private(set) var isFinished = false

    private static let snoozeKey = "permissionsSnoozedUntil"
    private static let tourKey = "introTourSeen"

    /// Açılışta bir kez hesaplanır: `nil` → doğrudan ana pencere.
    static let launchPhase: OnboardingPhase? = {
        let missing = !allPermissionsGranted()
        let snoozed = (UserDefaults.standard.object(forKey: snoozeKey) as? Date ?? .distantPast) > Date()
        if missing && !snoozed { return .permissions }
        if !UserDefaults.standard.bool(forKey: tourKey) { return .tour }
        return nil
    }()

    init() {
        phase = Self.launchPhase ?? .permissions
    }

    static func allPermissionsGranted() -> Bool {
        AXIsProcessTrusted() && CGPreflightScreenCaptureAccess()
            && AudioCaptureTCC.status() == .granted
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private var tourSeen: Bool {
        get { UserDefaults.standard.bool(forKey: Self.tourKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.tourKey) }
    }

    /// Ayarlardan izin ekranını yeniden açmak için.
    func showPermissions() {
        isFinished = false
        phase = .permissions
    }

    /// Tüm izinler verildi.
    func permissionsCompleted() {
        UserDefaults.standard.removeObject(forKey: Self.snoozeKey)
        advance()
    }

    /// "Daha Sonra": izin ekranını 1 gün ertele.
    func later() {
        UserDefaults.standard.set(Date().addingTimeInterval(24 * 60 * 60), forKey: Self.snoozeKey)
        advance()
    }

    func finishTour() {
        tourSeen = true
        finish()
    }

    /// Pencere başka bir yolla kapatıldıysa (kırmızı düğme) izin ekranını ertele.
    func windowClosed() {
        guard !isFinished else { return }
        if phase == .tour {
            tourSeen = true
        } else {
            UserDefaults.standard.set(Date().addingTimeInterval(24 * 60 * 60), forKey: Self.snoozeKey)
        }
        isFinished = true
    }

    private func advance() {
        if tourSeen { finish() } else { phase = .tour }
    }

    private func finish() {
        isFinished = true
        onFinish?()
    }
}
