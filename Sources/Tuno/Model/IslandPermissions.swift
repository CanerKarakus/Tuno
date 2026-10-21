import AppKit

/// Dynamic Island'ın isteğe bağlı özelliklerinin izinleri. Anahtar açılınca istenir; macOS reddedilen izni bir daha
/// sormadığından, daha önce reddedildiyse Tuno'nun kendi kaydı sıfırlanıp soru yeniden getirilir.
enum IslandPermissions {
    private static let bundleID = Bundle.main.bundleIdentifier ?? "app.tuno.mac"

    /// İndirilenler klasörü (indirme ve AirDrop). Ana iş parçacığında çağrılmamalı: izin penceresi yanıtlanana kadar bekler.
    static func requestDownloads() -> Bool {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let started = Date()
        if (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil { return true }
        // Anında reddedildiyse soru hiç gösterilmedi (eskiden reddedilmiş): kaydı sıfırla ve yeniden sor.
        guard Date().timeIntervalSince(started) < 0.5 else { return false }
        reset("SystemPolicyDownloadsFolder")
        return (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil
    }

    static var downloadsGranted: Bool {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        return (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil
    }

    /// Bir uygulamaya komut gönderme (Otomasyon). Uygulama kapalıysa arka planda açılır.
    static func requestAutomation(of target: String, scriptName: String) -> Bool {
        if !isRunning(target) {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) else { return false }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            for _ in 0..<20 where !isRunning(target) { Thread.sleep(forTimeInterval: 0.25) }
            Thread.sleep(forTimeInterval: 1)
        }
        switch automationStatus(target) {
        case noErr: return true
        case OSStatus(errAEEventNotPermitted): reset("AppleEvents")
        default: break
        }
        // Joker olay türüyle macOS soru göstermez; zararsız gerçek bir komut gösterir.
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"\(scriptName)\" to get player state")?.executeAndReturnError(&error)
        return automationStatus(target) == noErr
    }

    static func automationGranted(_ target: String) -> Bool { automationStatus(target) == noErr }

    private static func automationStatus(_ target: String) -> OSStatus {
        guard let desc = NSAppleEventDescriptor(bundleIdentifier: target).aeDesc else { return -1 }
        return AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false)
    }

    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Yalnızca Tuno'nun kendi kaydı (`tccutil reset <hizmet> <Tuno>`).
    private static func reset(_ service: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        SupportLog.log("izin", "\(service) kaydı sıfırlandı (yeniden sorulacak)")
    }
}
