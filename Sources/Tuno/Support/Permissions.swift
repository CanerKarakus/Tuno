import AVFoundation
import AppKit
import ApplicationServices
import Observation
import ScreenCaptureKit

enum PermissionKind: String, CaseIterable, Identifiable {
    case audioCapture, microphone, accessibility, screenRecording

    var id: Self { self }

    var title: String {
        switch self {
        case .audioCapture: L("Sistem Sesi Kaydı")
        case .microphone: L("Mikrofon")
        case .accessibility: L("Erişilebilirlik")
        case .screenRecording: L("Ekran Kaydı")
        }
    }

    var detail: String {
        switch self {
        case .audioCapture: L("Uygulama başına ses, ses yükseltme, ekolayzer ve HDMI ses denetimi. Ses kaydedilmez.")
        case .microphone: L("Giriş sayfasındaki mikrofon seviye testi.")
        case .accessibility: L("Kısayollar, fare tuşları ve kaydırma, orta tık, parlaklık tuşları, pencereleri öne getirme.")
        case .screenRecording: L("Alt-Tab ve Dock pencere önizlemeleri. İzin verildikten sonra Tuno yeniden başlatılmalıdır.")
        }
    }

    var symbol: String {
        switch self {
        case .audioCapture: "waveform"
        case .microphone: "mic.fill"
        case .accessibility: "accessibility"
        case .screenRecording: "rectangle.dashed.badge.record"
        }
    }

    var settingsAnchor: String {
        switch self {
        case .audioCapture: "Privacy_AudioCapture"
        case .microphone: "Privacy_Microphone"
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        }
    }
}

enum PermissionStatus { case granted, denied, notDetermined }

/// Tuno'nun ihtiyaç duyduğu tüm macOS izinleri: durum, isteme ve gerektiğinde yeniden başlatma.
@Observable
@MainActor
final class Permissions {
    private(set) var statuses: [PermissionKind: PermissionStatus] = [:]
    private(set) var isRequestingAll = false
    /// Ekran Kaydı istendi ama izin ancak yeniden başlatınca etkinleşir.
    private(set) var screenRecordingNeedsRestart = false

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var pollTimer: Timer?

    private static let screenRequestedKey = "screenRecordingRequested"

    init() { refresh() }

    func status(_ kind: PermissionKind) -> PermissionStatus { statuses[kind] ?? .notDetermined }
    var missing: [PermissionKind] { PermissionKind.allCases.filter { status($0) != .granted } }
    var allGranted: Bool { missing.isEmpty }

    func refresh() {
        let previous = statuses
        let microphone: PermissionStatus = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
        statuses = [
            .audioCapture: AudioCaptureTCC.status(),
            .microphone: microphone,
            .accessibility: AXIsProcessTrusted() ? .granted : .notDetermined,
            .screenRecording: CGPreflightScreenCaptureAccess() ? .granted : .notDetermined,
        ]
        let requested = UserDefaults.standard.bool(forKey: Self.screenRequestedKey)
        screenRecordingNeedsRestart = requested && status(.screenRecording) != .granted
        if status(.screenRecording) == .granted { UserDefaults.standard.removeObject(forKey: Self.screenRequestedKey) }
        if previous != statuses { onChange?() }
    }

    /// İzin penceresi açıkken kullanıcı Sistem Ayarları'ndan döndüğünde durumu güncel tut.
    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - İsteme

    func request(_ kind: PermissionKind) async {
        switch kind {
        case .audioCapture:
            if status(.audioCapture) == .denied { openSettings(kind) } else { _ = await AudioCaptureTCC.request() }
        case .microphone:
            if status(.microphone) == .denied { openSettings(kind) } else {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) { openSettings(kind) }
        case .screenRecording:
            // İlk seferde yalnızca sistem iletişim kutusu: Tuno'yu listeye o ekler ve ayarları kendisi açar.
            // Ayarları burada da açmak, Tuno listede yokken sayfayı öne getiriyordu.
            let askedBefore = UserDefaults.standard.bool(forKey: Self.screenRequestedKey)
            UserDefaults.standard.set(true, forKey: Self.screenRequestedKey)
            // Her seferinde macOS'a gerçekten sorulur: Tuno'yu "Ekran ve Sistem Sesi Kaydı" listesine yalnızca gerçek
            // bir ScreenCaptureKit isteği ekliyor. İzinler sıfırlanmışsa (tccutil, yeniden kurulum) liste boştur ve
            // yalnızca Ayarlar'ı açmak Tuno'yu oraya getirmez; kullanıcı elle eklemek zorunda kalırdı.
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
            // Daha önce sorulduysa macOS iletişim kutusunu yeniden göstermez; ayarlar açılır (Tuno artık listede).
            if askedBefore && !CGPreflightScreenCaptureAccess() { openSettings(kind) }
        }
        refresh()
    }

    /// Eksik izinleri sırayla ister: önce uygulama içi iletişim kutuları (ses kaydı, mikrofon),
    /// sonra Sistem Ayarları gerektirenler (Erişilebilirlik verilince Ekran Kaydı).
    func requestAll() async {
        guard !isRequestingAll else { return }
        isRequestingAll = true
        defer { isRequestingAll = false }

        for kind in [PermissionKind.audioCapture, .microphone] where status(kind) == .notDetermined {
            await request(kind)
        }
        if status(.accessibility) != .granted {
            await request(.accessibility)
            // Kullanıcı Sistem Ayarları'nda izni verene kadar (en fazla 2 dk) bekle.
            for _ in 0..<120 where !AXIsProcessTrusted() {
                try? await Task.sleep(for: .seconds(1))
            }
            refresh()
        }
        if status(.screenRecording) != .granted {
            await request(.screenRecording)
        }
    }

    func openSettings(_ kind: PermissionKind) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(kind.settingsAnchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Ekran Kaydı gibi yeniden başlatma gerektiren izinler için Tuno'yu kapatıp yeniden açar.
    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.8; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// L("Sistem Sesi Kaydı") (process tap) izni için public bir sorgu API'si yok; TCC çerçevesinin
/// kendi işlevleri kullanılır (Apple'ın AudioCap örneğindeki yöntem).
enum AudioCaptureTCC {
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private static let service = "kTCCServiceAudioCapture" as CFString

    static func status() -> PermissionStatus {
        guard let symbol = handle.flatMap({ dlsym($0, "TCCAccessPreflight") }) else { return .notDetermined }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .notDetermined
        }
    }

    static func request() async -> Bool {
        guard let symbol = handle.flatMap({ dlsym($0, "TCCAccessRequest") }) else { return false }
        let request = unsafeBitCast(symbol, to: Request.self)
        return await withCheckedContinuation { continuation in
            request(service, nil) { granted in continuation.resume(returning: granted) }
        }
    }
}
