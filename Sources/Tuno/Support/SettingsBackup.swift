import AppKit
import Foundation

/// Ayar yedekleri ve sıfırlama. Tuno günde bir kez ayarlarının kopyasını alır (son 10 kopya), destekle
/// sıfırlamadan ya da yedeğe dönmeden önce de bir kopya alınır; böylece her işlem geri alınabilir.
///
/// Ayarlar Tuno çalışırken yazılırsa kapanırken modeller eski değerleri geri yazabilir. Bu yüzden yeni
/// ayarlar Tuno kapandıktan sonra küçük bir betikle yüklenir ve Tuno yeniden açılır.
/// Kurulum numarası, güncelleme kayıtları, tanıtım ve izin durumu gibi uygulama kayıtları yedeğe girmez,
/// sıfırlamada da korunur. Pano geçmişi ayrı dosyada durur; dokunulmaz.
enum SettingsBackup {
    struct Item {
        let id: String
        let date: Date
        let reason: String
    }

    private static let keptPrefixes = ["SU", "tuno", "support", "NS", "Apple", "com.apple"]
    private static let keptKeys: Set<String> = ["introTourSeen", "permissionsSnoozedUntil", "crashReportsLastScan",
                                                "systemCommandTabDisabled"]
    private static let limit = 10
    private static let lastKey = "supportLastBackup"

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Tuno/Ayar Yedekleri")
    }

    private static var domain: String { Bundle.main.bundleIdentifier ?? "app.tuno.mac" }

    private static func isSetting(_ key: String) -> Bool {
        !keptKeys.contains(key) && !keptPrefixes.contains { key.hasPrefix($0) }
    }

    /// Ayar anahtarları (uygulama kayıtları hariç).
    static func currentSettings() -> [String: Any] {
        (UserDefaults.standard.persistentDomain(forName: domain) ?? [:]).filter { isSetting($0.key) }
    }

    static func list() -> [Item] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "plist" }.compactMap { url -> Item? in
            let id = url.deletingPathExtension().lastPathComponent
            guard id.range(of: #"^\d{8}-\d{6}$"#, options: .regularExpression) != nil,
                  let date = idFormatter.date(from: id) else { return nil }
            let reason = L((NSDictionary(contentsOf: url)?["_reason"] as? String) ?? "Günlük yedek")
            return Item(id: id, date: date, reason: reason)
        }.sorted { $0.date > $1.date }
    }

    @discardableResult
    static func make(reason: String) -> String? {
        var settings = currentSettings()
        settings["_reason"] = reason
        let id = idFormatter.string(from: Date())
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard (settings as NSDictionary).write(to: folder.appending(path: "\(id).plist"), atomically: true) else { return nil }
        UserDefaults.standard.set(Date(), forKey: lastKey)
        for old in list().dropFirst(limit) { try? FileManager.default.removeItem(at: folder.appending(path: "\(old.id).plist")) }
        return id
    }

    /// Açılışta: son yedek 20 saatten eskiyse yeni bir yedek.
    static func daily() {
        let last = UserDefaults.standard.object(forKey: lastKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 20 * 3600, !currentSettings().isEmpty else { return }
        make(reason: "Günlük yedek")
    }

    /// Tüm ayarları varsayılana döndürüp Tuno'yu yeniden açar.
    @MainActor
    static func resetAndRelaunch() throws {
        make(reason: "Sıfırlamadan önce")
        try relaunch(with: [:])
    }

    /// Seçilen yedeğe döner ve Tuno'yu yeniden açar.
    @MainActor
    static func restoreAndRelaunch(_ id: String) throws {
        guard id.range(of: #"^\d{8}-\d{6}$"#, options: .regularExpression) != nil,
              var settings = NSDictionary(contentsOf: folder.appending(path: "\(id).plist")) as? [String: Any]
        else { throw CocoaError(.fileNoSuchFile) }
        settings.removeValue(forKey: "_reason")
        make(reason: "Yedeğe dönmeden önce")
        try relaunch(with: settings.filter { isSetting($0.key) })
    }

    /// Tuno kapanınca: ayar anahtarları silinir, verilenler yazılır (uygulama kayıtları korunur), Tuno yeniden açılır.
    @MainActor
    private static func relaunch(with settings: [String: Any]) throws {
        var domainValues = (UserDefaults.standard.persistentDomain(forName: domain) ?? [:]).filter { !isSetting($0.key) }
        domainValues.merge(settings) { _, new in new }
        let work = FileManager.default.temporaryDirectory.appending(path: "tuno-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let plist = work.appending(path: "settings.plist")
        guard (domainValues as NSDictionary).write(to: plist, atomically: true) else { throw CocoaError(.fileWriteUnknown) }
        // $1 işlem numarası, $2 alan adı, $3 ayar dosyası, $4 uygulama, $5 geçici klasör
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
        /usr/bin/defaults delete "$2" >/dev/null 2>&1
        /usr/bin/defaults import "$2" "$3"
        /usr/bin/open "$4"
        /bin/rm -rf "$5"
        """
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script, "tuno-settings", String(getpid()), domain, plist.path, Bundle.main.bundleURL.path, work.path]
        try process.run()
        NSApp.terminate(nil)
    }

    private static let idFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
