import AppKit
import Foundation

/// Tuno çöktükten sonraki ilk açılışta macOS'un yazdığı çökme raporunu (DiagnosticReports/Tuno-*.ips)
/// bulur ve kullanıcı izin verirse geliştiriciye gönderir.
///
/// Raporda Tuno ve macOS sürümü, Mac modeli ve hata ayrıntıları bulunur. Gönderilmeden önce kullanıcı adı
/// ve klasör yolları temizlenir, cihaza özgü kimlikler silinir. Yalnızca yayın sürümünde çalışır.
@MainActor
final class CrashReporter {
    enum Policy: String, CaseIterable, Identifiable {
        case ask, always, never
        var id: Self { self }
        var title: String {
            switch self {
            case .ask: L("Göndermeden önce sor")
            case .always: L("Otomatik gönder")
            case .never: L("Gönderme")
            }
        }
    }

    static let policyKey = "crashReportPolicy"
    private static let lastScanKey = "crashReportsLastScan"
    private static let endpoint = URL(string: "https://gettuno.info/crash.php")!
    private static let maxPerLaunch = 5

    static var policy: Policy {
        Policy(rawValue: UserDefaults.standard.string(forKey: policyKey) ?? "") ?? .ask
    }

    /// Açılıştan birkaç saniye sonra yeni çökme raporu var mı bakar.
    func checkAfterLaunch(enabled: Bool) {
        guard enabled else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            await self.scan()
        }
    }

    private func scan() async {
        let defaults = UserDefaults.standard
        // İlk açılışta son bir haftanın raporları da sorulur; sonrasında yalnızca yeniler.
        let since = defaults.object(forKey: Self.lastScanKey) as? Date ?? Date(timeIntervalSinceNow: -7 * 86400)
        let reports = Self.findReports(since: since)
        let newest = reports.map(\.date).max() ?? Date()
        defer { defaults.set(max(newest, since), forKey: Self.lastScanKey) }
        guard !reports.isEmpty, Self.policy != .never else { return }

        if Self.policy == .ask {
            guard ask(count: reports.count) else { return }
        }
        SupportLog.log("çökme", "\(reports.count) çökme raporu bulundu")
        for report in reports.suffix(Self.maxPerLaunch) {
            await send(report.url)
        }
    }

    private func ask(count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = L("Tuno beklenmedik şekilde kapandı")
        alert.informativeText = (count > 1 ? String(format: L("%d çökme raporu bulundu. "), count) : "")
            + L("Raporu göndererek sorunun düzeltilmesine yardımcı olabilirsin. Rapor yalnızca Tuno ve macOS sürümünü, Mac modelini ve hatanın teknik ayrıntılarını içerir; kişisel dosyaların ya da adın gönderilmez.")
        alert.addButton(withTitle: L("Gönder"))
        alert.addButton(withTitle: L("Gönderme"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L("Bu seçimi hatırla")
        NSApp.activate()
        let send = alert.runModal() == .alertFirstButtonReturn
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set((send ? Policy.always : Policy.never).rawValue, forKey: Self.policyKey)
        }
        return send
    }

    // MARK: - Raporlar

    private struct Report { let url: URL; let date: Date }

    private static func findReports(since: Date) -> [Report] {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports")
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let bundle = Bundle.main.bundleIdentifier ?? ""
        return urls.compactMap { url -> Report? in
            let name = url.lastPathComponent
            guard url.pathExtension == "ips", name.hasPrefix("Tuno-") || name.hasPrefix("Tuno_") else { return nil }
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  date > since, date > Date(timeIntervalSinceNow: -14 * 86400) else { return nil }
            // İlk satır raporun başlığıdır (JSON); başka bir uygulamanın "Tuno" adlı raporu karışmasın.
            guard let head = try? String(contentsOf: url, encoding: .utf8).split(separator: "\n", maxSplits: 1).first,
                  let json = try? JSONSerialization.jsonObject(with: Data(head.utf8)) as? [String: Any],
                  (json["bundleID"] as? String) == bundle else { return nil }
            return Report(url: url, date: date)
        }.sorted { $0.date < $1.date }
    }

    /// Kullanıcı adını, ev klasörünü ve cihaza özgü kimlikleri temizler.
    private static func scrub(_ text: String) -> String {
        var text = text
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        text = text.replacingOccurrences(of: home, with: "~")
        text = text.replacingOccurrences(of: "/Users/\(NSUserName())", with: "/Users/~")
        for key in ["crashReporterKey", "sleepWakeUUID", "deviceIdentifierForVendor", "userID"] {
            text = text.replacingOccurrences(of: #""\#(key)"\s*:\s*"[^"]*""#, with: "\"\(key)\":\"\"", options: .regularExpression)
        }
        return text
    }

    private func send(_ url: URL) async {
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return }
        text = Self.scrub(text)
        if text.utf8.count > 1_500_000 { text = String(text.prefix(1_500_000)) }
        let info = Bundle.main.infoDictionary
        let body: [String: String] = [
            "version": info?["CFBundleShortVersionString"] as? String ?? "?",
            "build": info?["CFBundleVersion"] as? String ?? "?",
            "os": SystemInfo.osVersion,
            "model": SystemInfo.model,
            "arch": SystemInfo.architecture,
            // Destek ekibi çökmeyi o Mac'in zaman çizelgesinde görebilsin (Tuno Kullanıcı ID'si; kişisel bilgi değil).
            "sid": SupportID.value,
            "report": text,
        ]
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }
}
