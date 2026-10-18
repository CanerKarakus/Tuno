import AppKit
import CryptoKit
import Foundation
import Security

/// Destekle sürüm değiştirme (eski bir sürüme dönmek dahil). Sparkle güvenlik gereği sürüm düşürmez; bu yüzden
/// kurulum burada yapılır ama aynı güvencelerle:
///  1. Adres yalnızca https://gettuno.info/updates/Tuno-<sürüm>.dmg olabilir, sürüm en az `minimum`.
///  2. İndirilen dosya Sparkle'ın EdDSA imzasıyla, uygulamadaki `SUPublicEDKey` ile doğrulanır.
///  3. DMG'deki Tuno.app, çalışan Tuno'nun Apple kod imzası gereksinimini (aynı geliştirici, aynı uygulama) karşılamalı.
///  4. Kullanıcı onaylamadan hiçbir şey indirilmez.
/// Tuno kapanınca küçük bir kabuk betiği eski uygulamayı yenisiyle değiştirip yeniden açar; bir adım
/// başarısız olursa eski uygulama yerine konur.
enum VersionSwitcher {
    /// Destek modu bu sürümle geldi; daha eskiye dönen Mac'e bir daha bağlanılamazdı.
    static let minimum = "1.4.4"

    struct Target {
        let version: String
        let url: URL
        let length: Int
        let signature: Data
        /// Eski bir sürüme geçiliyorsa o sürümde tutulur.
        let pin: Bool

        init(_ payload: [String: Any]) throws {
            guard let version = payload["version"] as? String,
                  version.range(of: #"^\d+\.\d+(\.\d+)?$"#, options: .regularExpression) != nil
            else { throw SwitchError.invalid }
            guard version.compare(VersionSwitcher.minimum, options: .numeric) != .orderedAscending else { throw SwitchError.tooOld }
            guard version != UpdateDelegate.currentVersion else { throw SwitchError.same }
            guard let address = payload["url"] as? String, let url = URL(string: address),
                  url.scheme == "https", url.host == "gettuno.info", url.port == nil, url.query == nil,
                  url.path == "/updates/Tuno-\(version).dmg",
                  let length = payload["length"] as? Int, length > 0, length < 300_000_000,
                  let signature = (payload["signature"] as? String).flatMap({ Data(base64Encoded: $0) }), signature.count == 64
            else { throw SwitchError.invalid }
            self.version = version
            self.url = url
            self.length = length
            self.signature = signature
            self.pin = payload["pin"] as? Bool ?? true
        }
    }

    enum SwitchError: LocalizedError {
        case invalid, tooOld, same, notConfigured, location, download, size, signature, mount, missingApp, wrongApp, codeSignature

        var errorDescription: String? {
            switch self {
            case .invalid: "Sürüm bilgisi geçersiz."
            case .tooOld: "\(VersionSwitcher.minimum) sürümünden eskiye geçilemez."
            case .same: "Bu sürüm zaten kurulu."
            case .notConfigured: "Bu Tuno kopyası sürüm değiştirmeyi desteklemiyor (geliştirme sürümü)."
            case .location: "Tuno'nun bulunduğu klasöre yazılamıyor. Tuno'yu Uygulamalar klasörüne taşıyıp yeniden dene."
            case .download: "Sürüm indirilemedi."
            case .size, .signature: "İndirilen dosya doğrulanamadı; kurulmadı."
            case .mount: "Disk görüntüsü açılamadı."
            case .missingApp, .wrongApp: "Disk görüntüsünde beklenen Tuno sürümü yok."
            case .codeSignature: "Uygulamanın Apple imzası doğrulanamadı; kurulmadı."
            }
        }
    }

    @MainActor
    static func confirm(_ target: Target) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Tuno Destek, Tuno'yu \(target.version) sürümüne geçirmek istiyor"
        alert.informativeText = "Şu an \(UpdateDelegate.currentVersion) kullanıyorsun. Onaylarsan Tuno \(target.version) indirilip doğrulanır, "
            + "ardından Tuno kapanıp yeni sürümle yeniden açılır. Ayarların korunur."
            + (target.pin ? "\n\nBu sürümde kalırsın; Destek sayfasından istediğin zaman normal güncellemelere dönebilirsin." : "")
        alert.addButton(withTitle: "Onayla")
        alert.addButton(withTitle: "Vazgeç")
        alert.icon = NSApp.applicationIconImage
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// İndirir, doğrular ve yeni uygulamayı Tuno'nun bulunduğu diskte geçici bir klasöre hazırlar.
    static func prepare(_ target: Target) async throws -> URL {
        guard let encodedKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              let keyData = Data(base64Encoded: encodedKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { throw SwitchError.notConfigured }
        let destination = Bundle.main.bundleURL
        let manager = FileManager.default
        guard !destination.path.contains("/AppTranslocation/"),
              manager.isWritableFile(atPath: destination.deletingLastPathComponent().path),
              manager.isWritableFile(atPath: destination.path)
        else { throw SwitchError.location }

        let download: URL
        do {
            let (file, response) = try await URLSession(configuration: .ephemeral).download(from: target.url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SwitchError.download }
            download = file
        } catch let error as SwitchError { throw error } catch { throw SwitchError.download }

        let work = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        do {
            let dmg = work.appending(path: "Tuno.dmg")
            try manager.moveItem(at: download, to: dmg)
            let data = try Data(contentsOf: dmg)
            guard data.count == target.length else { throw SwitchError.size }
            guard key.isValidSignature(target.signature, for: data) else { throw SwitchError.signature }

            let mount = work.appending(path: "mount")
            try manager.createDirectory(at: mount, withIntermediateDirectories: true)
            guard run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path]) else {
                throw SwitchError.mount
            }
            defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
            let source = mount.appending(path: "Tuno.app")
            guard manager.fileExists(atPath: source.path) else { throw SwitchError.missingApp }
            let staged = work.appending(path: "Tuno.app")
            guard run("/usr/bin/ditto", [source.path, staged.path]) else { throw SwitchError.missingApp }
            try verify(staged, version: target.version)
            try? manager.removeItem(at: dmg)
            return staged
        } catch {
            try? manager.removeItem(at: work)
            throw error
        }
    }

    /// Aynı uygulama (paket kimliği), beklenen sürüm ve çalışan Tuno ile aynı Apple imza gereksinimi.
    private static func verify(_ app: URL, version: String) throws {
        guard let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == version
        else { throw SwitchError.wrongApp }
        var running: SecCode?
        var runningStatic: SecStaticCode?
        var requirement: SecRequirement?
        var candidate: SecStaticCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &runningStatic) == errSecSuccess, let runningStatic,
              SecCodeCopyDesignatedRequirement(runningStatic, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate
        else { throw SwitchError.codeSignature }
        // Sparkle'ın da kullandığı denetim. Katı mod (kSecCSStrictValidate) kullanılmaz: macOS disk görüntüsündeki
        // dosyalara silinemeyen com.apple.provenance özniteliğini ekliyor, katı mod bunu reddediyor.
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(candidate, flags, requirement) == errSecSuccess else { throw SwitchError.codeSignature }
    }

    /// Tuno kapanınca uygulamayı değiştirip yeniden açan betiği başlatır ve Tuno'yu kapatır.
    @MainActor
    static func relaunch(with staged: URL) throws {
        let destination = Bundle.main.bundleURL
        let work = staged.deletingLastPathComponent()
        let old = work.appending(path: "Tuno-eski.app")
        // $1 Tuno'nun işlem numarası, $2 kurulu uygulama, $3 yeni uygulama, $4 eskinin geçici yeri, $5 geçici klasör
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
        if /bin/mv "$2" "$4"; then
          if /bin/mv "$3" "$2"; then /bin/rm -rf "$4"; else /bin/mv "$4" "$2"; fi
        fi
        /usr/bin/open "$2"
        /bin/rm -rf "$5"
        """
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script, "tuno-switch", String(getpid()), destination.path, staged.path, old.path, work.path]
        try process.run()
        NSApp.terminate(nil)
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
