import AVFoundation
import AppKit
import Observation

enum OnboardingPhase: Hashable { case language, theme, permissions, tour, whatsNew, siri }

/// İlk açılış akışı (en fazla 4 adım, sayfa noktalarıyla):
/// 1. Dil — seçilmeden ilerlenmez (ilk kurulum ve 1.4.7'den yükseltenler).
/// 2. Görünüm — açık, koyu ya da otomatik.
/// 3. Hazır — tanıtım, bir kez.
/// 4. İzinler — yalnızca eksik izin varsa; "Daha Sonra Hatırlat" izin ekranını 1 gün erteler. Sonra uygulama açılır.
/// Gerekmeyen adımlar atlanır; hiçbiri gerekmiyorsa doğrudan ana pencere açılır.
@Observable
@MainActor
final class OnboardingModel {
    var phase: OnboardingPhase
    /// Bu açılışta gösterilecek adımlar (sayfa noktaları); açılışta bir kez belirlenir.
    private(set) var steps: [OnboardingPhase]
    @ObservationIgnored var onFinish: (() -> Void)?
    private(set) var isFinished = false

    private static let snoozeKey = "permissionsSnoozedUntil"
    private static let tourKey = "introTourSeen"
    private static let whatsNewKey = "whatsNewSeen"
    /// Bu sürümün yenilikleri; güncelleyenlere bir kez, geçilmeden uygulama açılmaz.
    private static let whatsNewVersion = "1.6"

    /// Açılışta bir kez hesaplanır: `nil` → doğrudan ana pencere.
    static let launchPhase: OnboardingPhase? = plannedSteps().first

    private static func plannedSteps() -> [OnboardingPhase] {
        var steps: [OnboardingPhase] = []
        if !AppLanguage.isChosen { steps.append(.language) }
        if AppTheme.chosen == nil { steps.append(.theme) }
        if !UserDefaults.standard.bool(forKey: tourKey) {
            steps.append(.tour)
            if NotchIsland.notchedScreen != nil { steps.append(.siri) }   // yeni kurulum: izinlerden önce Siri
        } else if UserDefaults.standard.string(forKey: whatsNewKey) != whatsNewVersion, NotchIsland.notchedScreen != nil {
            steps.append(.whatsNew)   // güncelleyenler: tanıtımı görmüş, yenilikleri görmemiş
        }
        // İzinler en son: verilince ya da "Daha Sonra Hatırlat"a basılınca uygulama açılır.
        // TUNO_SHOW_PERMISSIONS=1: izinler verili olsa da adım gösterilir (yalnızca deneme için).
        let forced = ProcessInfo.processInfo.environment["TUNO_SHOW_PERMISSIONS"] == "1"
        if forced || (!allPermissionsGranted() && !snoozed) { steps.append(.permissions) }
        return steps
    }

    private static var snoozed: Bool {
        (UserDefaults.standard.object(forKey: snoozeKey) as? Date ?? .distantPast) > Date()
    }

    init() {
        let planned = Self.plannedSteps()
        let initial: [OnboardingPhase] = planned.isEmpty ? [.permissions] : planned
        steps = initial
        phase = initial[0]
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

    var stepIndex: Int { steps.firstIndex(of: phase) ?? 0 }
    var canGoBack: Bool { stepIndex > 0 && phase != .language }

    func back() {
        guard canGoBack else { return }
        phase = steps[stepIndex - 1]
    }

    /// Bir sonraki adım; adım kalmadıysa ana pencere.
    func next() {
        let index = stepIndex
        if index + 1 < steps.count { phase = steps[index + 1] } else { finish() }
    }

    /// Ayarlardan izin ekranını yeniden açmak için.
    func showPermissions() {
        isFinished = false
        steps = [.permissions]
        phase = .permissions
    }

    /// Tüm izinler verildi.
    func permissionsCompleted() {
        UserDefaults.standard.removeObject(forKey: Self.snoozeKey)
        next()
    }

    /// "Daha Sonra": izin ekranını 1 gün ertele.
    func later() {
        UserDefaults.standard.set(Date().addingTimeInterval(24 * 60 * 60), forKey: Self.snoozeKey)
        next()
    }

    /// Yeni kurulumda Siri sayfası: 1.6'nın yenilikleri sonradan ayrıca gösterilmez.
    func finishSiri() { finishWhatsNew() }

    func finishWhatsNew() {
        UserDefaults.standard.set(Self.whatsNewVersion, forKey: Self.whatsNewKey)
        next()
    }

    func finishTour() {
        tourSeen = true
        next()
    }

    /// Pencere başka bir yolla kapatıldıysa (kırmızı düğme) izin ekranını ertele.
    func windowClosed() {
        guard !isFinished else { return }
        switch phase {
        case .language, .theme, .whatsNew, .siri:
            return   // seçim yapılmadan ya da yenilikler geçilmeden kapandı: OnboardingRoot pencereyi yeniden açar
        case .tour:
            tourSeen = true
        case .permissions:
            UserDefaults.standard.set(Date().addingTimeInterval(24 * 60 * 60), forKey: Self.snoozeKey)
        }
        isFinished = true
    }

    private func finish() {
        if steps.contains(.tour) { tourSeen = true }
        isFinished = true
        onFinish?()
    }
}
