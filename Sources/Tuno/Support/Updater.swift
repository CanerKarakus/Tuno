import Foundation
import Observation
import Sparkle

/// Siteden dağıtılan sürümün otomatik güncellemesi (Sparkle).
///
/// Güncelleme adresi (`SUFeedURL`) ve imza anahtarı (`SUPublicEDKey`) Info.plist'te yoksa
/// (geliştirme sürümü) güncelleyici hiç başlatılmaz.
@Observable
@MainActor
final class Updater {
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private let delegate = UpdateDelegate()
    private(set) var canCheck = false
    @ObservationIgnored private var observation: NSKeyValueObservation?

    var isConfigured: Bool { controller != nil }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "geliştirme"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    init() {
        let info = Bundle.main.infoDictionary
        let feed = info?["SUFeedURL"] as? String ?? ""
        let key = info?["SUPublicEDKey"] as? String ?? ""
        guard feed.hasPrefix("https://"), !key.isEmpty else {
            controller = nil
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
        canCheck = controller?.updater.canCheckForUpdates ?? false
        observation = controller?.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.canCheck = value } }
        }
        if let updater = controller?.updater {
            delegate.resumePendingCritical(updater)
            // Sparkle ilk açılışta denetim yapmaz; ilk denetim bir gün sonra gelirdi. Kısa bir süre sonra
            // sessizce bir kez denetlenir: yeni sürüm varsa önerilir, yeni kurulum panelde aynı gün görünür.
            if updater.automaticallyChecksForUpdates, updater.lastUpdateCheckDate == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak updater] in
                    MainActor.assumeIsolated {
                        guard let updater, updater.lastUpdateCheckDate == nil else { return }
                        updater.checkForUpdatesInBackground()
                    }
                }
            }
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

/// Güncelleme denetimine anonim sistem bilgisi ekler ve kritik güncellemelerin ertelenmesine izin vermez.
///
/// Kritik güncelleme Sparkle'da atlanamaz ama "Sonra Hatırlat" ile kapatılabilir. Kapatılırsa bir saat
/// sonra yeniden sorulur; Tuno yeniden açıldığında da hemen sorulur. Güncelleme kurulunca kayıt silinir.
@MainActor
final class UpdateDelegate: NSObject, SPUUpdaterDelegate {
    private let pendingKey = "pendingCriticalUpdate"
    private var retry: Timer?

    /// Güncelleme denetimiyle giden anonim bilgiler: macOS sürümü, Mac modeli, işlemci mimarisi.
    /// Yönetim panelindeki macOS ve Mac dağılımı bunlardan çıkar; kişi ya da cihaz kimliği gönderilmez.
    func feedParameters(for updater: SPUUpdater, sendingSystemProfile sendingProfile: Bool) -> [[String: String]] {
        var parameters = [
            ["key": "os", "value": SystemInfo.osVersion, "displayKey": "macOS", "displayValue": SystemInfo.osVersion],
            ["key": "model", "value": SystemInfo.model, "displayKey": "Mac", "displayValue": SystemInfo.model],
            ["key": "arch", "value": SystemInfo.architecture, "displayKey": "İşlemci", "displayValue": SystemInfo.architecture],
        ]
        // Dönüşüm hunisi için iki tek seferlik işaret: ilk denetim ve kurulumdan bir hafta sonraki ilk denetim.
        if let milestone = Milestones.next() {
            parameters.append(["key": milestone, "value": "1", "displayKey": milestone, "displayValue": "1"])
        }
        return parameters
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        if item.isCriticalUpdate {
            UserDefaults.standard.set(item.displayVersionString, forKey: pendingKey)
        }
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        guard updateItem.isCriticalUpdate, choice != .install else { return }
        retry?.invalidate()
        retry = Timer.scheduledTimer(withTimeInterval: 3600, repeats: false) { [weak updater] _ in
            MainActor.assumeIsolated { updater?.checkForUpdatesInBackground() }
        }
    }

    /// Önceki açılışta ertelenmiş bir kritik güncelleme varsa birkaç saniye sonra yeniden sorar.
    func resumePendingCritical(_ updater: SPUUpdater) {
        guard let pending = UserDefaults.standard.string(forKey: pendingKey) else { return }
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        if current.compare(pending, options: .numeric) != .orderedAscending {
            UserDefaults.standard.removeObject(forKey: pendingKey)   // kurulmuş
            return
        }
        retry = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak updater] _ in
            MainActor.assumeIsolated { updater?.checkForUpdatesInBackground() }
        }
    }
}

/// Kurulum işaretleri (yönetim panelindeki dönüşüm hunisi). Her biri bir Mac'ten yalnızca bir kez gider;
/// kimlik ya da tarih gönderilmez. Önceki bir sürümden güncelleyenler yeni kurulum sayılmaz.
enum Milestones {
    private static let installKey = "tunoInstallDate"
    private static let firstKey = "tunoReportedFirst"
    private static let weekKey = "tunoReportedWeek"

    /// Bu denetimde gönderilecek işaret: "first", "week" ya da yok.
    static func next() -> String? {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: installKey) == nil {
            // Sparkle daha önce denetim yaptıysa bu Mac'te Tuno zaten kuruluydu: yeni kurulum sayılmaz.
            let existing = defaults.object(forKey: "SULastCheckTime") != nil
            defaults.set(existing ? Date.distantPast : Date(), forKey: installKey)
            if existing { defaults.set(true, forKey: firstKey); defaults.set(true, forKey: weekKey) }
        }
        if !defaults.bool(forKey: firstKey) {
            defaults.set(true, forKey: firstKey)
            return "first"
        }
        if !defaults.bool(forKey: weekKey), let installed = defaults.object(forKey: installKey) as? Date,
           Date().timeIntervalSince(installed) >= 7 * 86400 {
            defaults.set(true, forKey: weekKey)
            return "week"
        }
        return nil
    }
}

/// Anonim sistem bilgisi (güncelleme denetimi ve çökme raporları için).
enum SystemInfo {
    static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.patchVersion > 0
            ? "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            : "\(version.majorVersion).\(version.minorVersion)"
    }

    /// "Mac14,2" gibi model tanımlayıcısı.
    static var model: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }
}
