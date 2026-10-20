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
        let short = info?["CFBundleShortVersionString"] as? String ?? L("geliştirme")
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
        Milestones.prepare()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
        canCheck = controller?.updater.canCheckForUpdates ?? false
        observation = controller?.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.canCheck = value } }
        }
        if let updater = controller?.updater {
            delegate.resumePendingCritical(updater)
            // Bu sürümle henüz başarılı bir denetim yoksa (yeni kurulum, güncelleme, yeniden kurulum) kısa süre
            // sonra sessizce denetle: yönetim paneli Mac'i aynı dakika yeni sürümde görür. Sparkle bunu ilk açılışta
            // hiç, sonrasında da ancak bir sonraki zamanlanmış denetimde yapardı. Başarısız olursa sonraki açılışta yeniden.
            // Son denetimin üzerinden bir saatten fazla geçtiyse de açılışta denetlenir: kritik bir düzeltme,
            // Tuno yeniden açılan Mac'e Sparkle'ın 6 saatlik aralığını beklemeden ulaşsın.
            let stale = (updater.lastUpdateCheckDate ?? .distantPast).timeIntervalSinceNow < -3600
            if updater.automaticallyChecksForUpdates, UpdateDelegate.reportedVersion != UpdateDelegate.currentVersion || stale {
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak updater] in
                    MainActor.assumeIsolated {
                        guard let updater, !updater.sessionInProgress else { return }
                        updater.checkForUpdatesInBackground()
                    }
                }
            }
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Sessiz denetim (ör. destek sabitlemesi kalkınca son sürüm hemen önerilsin).
    func checkInBackground() {
        guard let updater = controller?.updater, !updater.sessionInProgress else { return }
        updater.checkForUpdatesInBackground()
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
    /// Bu denetimle giden kurulum işareti; ancak denetim başarılı olunca gönderilmiş sayılır.
    private var sentMilestone: String?

    private static let reportedKey = "tunoReportedVersion"
    nonisolated static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    /// En son hangi sürümle başarılı bir güncelleme denetimi yapıldı.
    static var reportedVersion: String? { UserDefaults.standard.string(forKey: reportedKey) }

    /// Güncelleme denetimiyle giden anonim bilgiler: macOS sürümü, Mac modeli, işlemci mimarisi ve rastgele kurulum numarası.
    /// Yönetim panelindeki macOS ve Mac dağılımı bunlardan çıkar; kişi ya da cihaz kimliği gönderilmez.
    func feedParameters(for updater: SPUUpdater, sendingSystemProfile sendingProfile: Bool) -> [[String: String]] {
        var parameters = [
            ["key": "os", "value": SystemInfo.osVersion, "displayKey": "macOS", "displayValue": SystemInfo.osVersion],
            ["key": "model", "value": SystemInfo.model, "displayKey": "Mac", "displayValue": SystemInfo.model],
            ["key": "arch", "value": SystemInfo.architecture, "displayKey": "İşlemci", "displayValue": SystemInfo.architecture],
            ["key": "id", "value": InstallID.value, "displayKey": "Kurulum", "displayValue": InstallID.value],
            // Seçilen arayüz dili ve görünüm (yönetim panelinde dağılım; seçilmediyse gönderilmez).
            ["key": "lang", "value": AppLanguage.chosen?.rawValue ?? "", "displayKey": "Dil", "displayValue": AppLanguage.chosen?.rawValue ?? ""],
            ["key": "theme", "value": AppTheme.chosen?.rawValue ?? "", "displayKey": "Görünüm", "displayValue": AppTheme.chosen?.rawValue ?? ""],
        ].filter { !($0["value"] ?? "").isEmpty }
        // Dönüşüm hunisi için iki tek seferlik işaret: ilk denetim ve kurulumdan bir hafta sonraki ilk denetim.
        sentMilestone = Milestones.pending()
        if let milestone = sentMilestone {
            parameters.append(["key": milestone, "value": "1", "displayKey": milestone, "displayValue": "1"])
        }
        return parameters
    }

    /// Denetim sunucuya ulaştı: işaret gönderilmiş, bu sürüm bildirilmiş sayılır.
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        if let milestone = sentMilestone { Milestones.markSent(milestone) }
        sentMilestone = nil
        UserDefaults.standard.set(Self.currentVersion, forKey: Self.reportedKey)
    }

    /// Destekle eski bir sürüme geçen Mac o sürümde tutulur: güncelleme yokmuş gibi davranılır (SupportPin).
    func bestValidUpdate(in appcast: SUAppcast, for updater: SPUUpdater) -> SUAppcastItem? {
        guard let pinned = SupportPin.version else { return nil }
        guard pinned == Self.currentVersion else {
            SupportPin.set(nil)
            return nil
        }
        return SUAppcastItem.empty()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        SupportLog.log("güncelleme", "Yeni sürüm bulundu: \(item.displayVersionString)\(item.isCriticalUpdate ? " (kritik)" : "")")
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
        guard let pending = UserDefaults.standard.string(forKey: pendingKey), SupportPin.version == nil else { return }
        let current = Self.currentVersion
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

    /// Bu denetimle gönderilecek işaret: "first", "week" ya da yok. Gönderilmiş sayılması için denetimin
    /// başarılı olması gerekir (markSent); ağ hatasında bir sonraki denetimde yeniden gider.
    /// Açılışta, Sparkle başlamadan önce çağrılır. Sparkle ilk açılışta hiç denetim yapmadan SULastCheckTime yazar;
    /// kurulum tarihi denetim sırasında belirlenseydi her yeni kurulum eski kurulum sayılır, "first" hiç gitmezdi.
    static func prepare() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: installKey) == nil else { return }
        // Sparkle daha önce çalıştıysa bu Mac'te Tuno zaten kuruluydu: yeni kurulum sayılmaz.
        let existing = defaults.object(forKey: "SULastCheckTime") != nil || defaults.object(forKey: "SUHasLaunchedBefore") != nil
        defaults.set(existing ? Date.distantPast : Date(), forKey: installKey)
        if existing { defaults.set(true, forKey: firstKey); defaults.set(true, forKey: weekKey) }
    }

    static func pending() -> String? {
        let defaults = UserDefaults.standard
        prepare()
        if !defaults.bool(forKey: firstKey) { return "first" }
        if !defaults.bool(forKey: weekKey), let installed = defaults.object(forKey: installKey) as? Date,
           Date().timeIntervalSince(installed) >= 7 * 86400 {
            return "week"
        }
        return nil
    }

    static func markSent(_ milestone: String) {
        UserDefaults.standard.set(true, forKey: milestone == "first" ? firstKey : weekKey)
    }
}

/// Rastgele kurulum numarası: yalnızca kaç Mac'te kurulu olduğunu ve hangi sürümde olduğunu saymak için
/// güncelleme denetimiyle gider. Cihazdan, donanımdan ya da kişiden türetilmez; ilk açılışta üretilir ve
/// Tuno'nun ayarlarında durur (ayarlar silinirse yenisi üretilir).
enum InstallID {
    private static let key = "tunoInstallID"

    static var value: String {
        if let id = UserDefaults.standard.string(forKey: key), id.count == 32 { return id }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
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
