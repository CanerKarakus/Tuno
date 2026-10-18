import AppKit
import ServiceManagement

/// Destek ekibinin istediği, kullanıcının onayladığı tanılama paketi: sistem bilgisi, izinler, ses aygıtları,
/// ekranlar, Tuno ayarları, son günlük kayıtları ve son çökmelerin listesi. Pano içeriği, kişisel dosyalar,
/// kullanıcı adı ya da ev klasörünün yolu eklenmez.
@MainActor
enum Diagnostics {
    static let summary = "Sistem bilgisi (macOS, Mac modeli), izinlerin durumu, ses aygıtları ve ekranlar, Tuno ayarları, "
        + "Tuno'nun son günlük kayıtları ve son çökmelerin listesi. Pano içeriği, kişisel dosyaların ve adın eklenmez."

    static func confirm() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Tuno Destek bir tanılama paketi istiyor"
        alert.informativeText = "Pakette şunlar yer alır: \(summary)\n\nGöndermek istiyor musun?"
        alert.addButton(withTitle: "Gönder")
        alert.addButton(withTitle: "Gönderme")
        alert.icon = NSApp.applicationIconImage
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func build(app: AppDelegate) -> [String: Any] {
        let info = Bundle.main.infoDictionary
        let devices = app.devices
        func audio(_ list: [AudioDevice], current: AudioDevice?) -> [[String: Any]] {
            list.map { device in
                var item: [String: Any] = ["name": device.name, "transport": device.transportLabel, "default": device.id == current?.id]
                if let limit = devices.volumeLimit(for: device.uid) { item["limit"] = limit }
                return item
            }
        }
        let screens = NSScreen.screens.map { screen -> [String: Any] in
            ["name": screen.localizedName, "width": Int(screen.frame.width), "height": Int(screen.frame.height),
             "scale": screen.backingScaleFactor]
        }
        let pointer = app.scroll
        return [
            "created": Date().formatted(.iso8601),
            "tuno": ["version": info?["CFBundleShortVersionString"] as? String ?? "?", "build": info?["CFBundleVersion"] as? String ?? "?",
                     "id": SupportID.value, "pinned": SupportPin.version ?? "", "loginItem": SMAppService.mainApp.status == .enabled,
                     "path": Bundle.main.bundlePath.hasPrefix("/Applications/") ? "Uygulamalar" : "Başka bir klasör"],
            "system": ["macOS": SystemInfo.osVersion, "model": SystemInfo.model, "arch": SystemInfo.architecture,
                       "uptimeHours": Int(ProcessInfo.processInfo.systemUptime / 3600), "language": Locale.preferredLanguages.first ?? "",
                       "memoryGB": Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)],
            "permissions": Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { kind in
                (kind.title, "\(app.permissions.status(kind))")
            }),
            "audio": ["output": audio(devices.outputDevices, current: devices.defaultOutput),
                      "input": audio(devices.inputDevices, current: devices.defaultInput),
                      "microphoneMuted": devices.microphoneMuted,
                      "apps": app.mixer.apps.map { ["name": $0.name, "volume": app.mixer.settings(for: $0).volume] }],
            "displays": ["screens": screens,
                         "external": app.displays.displays.map { ["name": $0.name, "ddc": $0.supportsDDC, "brightness": $0.brightness] }],
            "pointer": ["accessibility": pointer.isTrusted, "tapActive": pointer.isActive, "tapFailed": pointer.tapFailed,
                        "systemNatural": pointer.systemNatural],
            "settings": SupportSettings(app: app).json(),
            "backups": SettingsBackup.list().prefix(5).map { ["id": $0.id, "reason": $0.reason] },
            "crashes": recentCrashes(),
            "log": SupportLog.tail(),
        ]
    }

    private static func controlsJSON(_ controls: DeviceControls) -> [String: Any] {
        var item: [String: Any] = ["muted": controls.muted, "sampleRate": controls.sampleRate, "canSetVolume": controls.canSetVolume]
        if let volume = controls.volume { item["volume"] = volume }
        return item
    }

    /// Son 14 günün Tuno çökme raporlarının adı ve tarihi (içerikleri değil).
    private static func recentCrashes() -> [String] {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports")
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.compactMap { url -> (String, Date)? in
            guard url.lastPathComponent.hasPrefix("Tuno"),
                  let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  date > Date(timeIntervalSinceNow: -14 * 86400) else { return nil }
            return (url.lastPathComponent, date)
        }.sorted { $0.1 > $1.1 }.prefix(20).map { "\($0.1.formatted(.iso8601)) \($0.0)" }
    }
}
