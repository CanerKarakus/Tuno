import AppKit
import IOKit
import IOKit.ps
import Intents
import Network
import Observation

/// Adanın ince bildirimleri için sistem olayları: pil azaldı, Düşük Güç Modu, Odak modu, Bluetooth cihazı
/// (klavye, fare, hoparlör…) ve Wi-Fi / VPN. Her biri yalnızca `onNotice` ile bir bildirim ister; ada gösterir.
@MainActor
final class IslandSignals {
    struct Notice {
        enum Tone { case green, yellow, red, blue, orange, purple }
        let symbol: String
        let tone: Tone
        let title: String
        let detail: String
    }

    var onNotice: ((Notice) -> Void)?
    /// Kapalıyken izleyiciler bildirim istemez (deneme düğmeleri etkilenmez).
    var alertsOn = true

    // MARK: Pil azaldı

    private var lowLevel: Int?   // en son bildirilen eşik (20 ya da 10); şarja takılınca sıfırlanır

    /// Pil değişince çağrılır (IOPS bildirimi).
    func batteryChanged() {
        guard alertsOn, let info = MacBattery().info else { return }
        if info.isPluggedIn { lowLevel = nil; return }
        for threshold in [10, 20] where info.percent <= threshold {
            guard lowLevel == nil || threshold < lowLevel! else { return }
            lowLevel = threshold
            lowBattery(percent: info.percent)
            return
        }
    }

    func lowBattery(percent: Int) {
        let critical = percent <= 10
        onNotice?(Notice(symbol: critical ? "battery.0percent" : "battery.25percent", tone: critical ? .red : .yellow,
                         title: critical ? L("Pil çok az") : L("Pil azaldı"), detail: "%\(percent)"))
    }

    // MARK: Düşük Güç Modu

    private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var observers: [NSObjectProtocol] = []

    func startLowPower() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.isLowPowerModeEnabled
                guard now != self.lowPower else { return }
                self.lowPower = now
                if self.alertsOn { self.lowPowerMode(on: now) }
            }
        })
    }

    func lowPowerMode(on: Bool) {
        onNotice?(Notice(symbol: "leaf.fill", tone: .yellow, title: L("Düşük Güç Modu"), detail: on ? L("Açık") : L("Kapalı")))
    }

    // MARK: Odak modu (Odak durumu izniyle)

    private var focusTimer: Timer?
    private var focused: Bool?

    static var focusAuthorized: Bool { INFocusStatusCenter.default.authorizationStatus == .authorized }

    /// İzin ister (ilk seferde sistem sorusu çıkar); verilirse izleme başlar.
    func enableFocus(_ completion: @escaping (Bool) -> Void) {
        INFocusStatusCenter.default.requestAuthorization { status in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let granted = status == .authorized
                    if granted { self.startFocus() }
                    completion(granted)
                }
            }
        }
    }

    func startFocus() {
        guard Self.focusAuthorized, focusTimer == nil else { return }
        focused = INFocusStatusCenter.default.focusStatus.isFocused
        // Odak durumu için değişiklik bildirimi yok: üç saniyede bir bakılır (çok hafif).
        focusTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let now = INFocusStatusCenter.default.focusStatus.isFocused, now != self.focused else { return }
                self.focused = now
                self.focusMode(on: now)
            }
        }
        focusTimer?.tolerance = 1
    }

    func stopFocus() {
        focusTimer?.invalidate()
        focusTimer = nil
        focused = nil
    }

    func focusMode(on: Bool) {
        onNotice?(Notice(symbol: on ? "moon.fill" : "moon", tone: .purple, title: L("Odak"), detail: on ? L("Açık") : L("Kapalı")))
    }

    // MARK: Bluetooth cihazları (klavye, fare, hoparlör…)

    private var hidNotification: io_iterator_t = 0
    private var hidPort: IONotificationPortRef?

    func startBluetooth() {
        guard hidPort == nil else { return }
        let port = IONotificationPortCreate(kIOMainPortDefault)
        hidPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { context, iterator in
            guard let context else { return }
            let signals = Unmanaged<IslandSignals>.fromOpaque(context).takeUnretainedValue()
            var devices: [(name: String, battery: Int?)] = []
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                func value(_ key: String) -> Any? { IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
                let transport = value("Transport") as? String ?? ""
                guard transport.contains("Bluetooth"), let name = value("Product") as? String else { continue }
                devices.append((name, value("BatteryPercent") as? Int))
            }
            MainActor.assumeIsolated { signals.bluetoothDevices(devices) }
        }
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("AppleDeviceManagementHIDEventService"),
                                         callback, context, &hidNotification)
        // Bağlıların ilk listesi bildirilmez (yalnızca yeni bağlananlar).
        while case let service = IOIteratorNext(hidNotification), service != 0 { IOObjectRelease(service) }
    }

    private var lastBluetooth: [String: Date] = [:]

    private func bluetoothDevices(_ devices: [(name: String, battery: Int?)]) {
        guard alertsOn else { return }
        for device in devices {
            // Aynı cihaz kısa sürede birkaç kez eşleşebilir.
            if let last = lastBluetooth[device.name], Date().timeIntervalSince(last) < 20 { continue }
            lastBluetooth[device.name] = Date()
            bluetoothConnected(name: device.name, battery: device.battery)
        }
    }

    func bluetoothConnected(name: String, battery: Int?) {
        let lower = name.lowercased()
        let (symbol, kind): (String, String) =
            lower.contains("keyboard") || lower.contains("klavye") ? ("keyboard.fill", L("Klavye"))
            : lower.contains("trackpad") ? ("rectangle.and.hand.point.up.left.fill", L("Trackpad"))
            : lower.contains("mouse") || lower.contains("fare") ? ("computermouse.fill", L("Fare"))
            : lower.contains("speaker") || lower.contains("hoparlör") ? ("hifispeaker.fill", L("Hoparlör"))
            : ("dot.radiowaves.left.and.right", L("Cihaz"))
        // Cihazın adı yerine türü yazılır (adlar uzun olur).
        onNotice?(Notice(symbol: symbol, tone: .blue, title: kind, detail: battery.map { "%\($0)" } ?? L("Bağlandı")))
    }

    // MARK: Wi-Fi ve VPN

    private var monitor: NWPathMonitor?
    private var online: Bool?
    private var vpn = false

    func startNetwork() {
        guard monitor == nil else { return }
        vpn = Self.vpnActive()
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.pathChanged(online: path.status == .satisfied) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.tuno.island.network"))
    }

    private func pathChanged(online now: Bool) {
        let previous = online
        online = now
        let vpnNow = Self.vpnActive()
        defer { vpn = vpnNow }
        guard alertsOn else { return }
        if vpnNow != vpn {
            networkNotice(vpn: true, connected: vpnNow)
        } else if let previous, previous != now {
            networkNotice(vpn: false, connected: now)
        }
    }

    func networkNotice(vpn: Bool, connected: Bool) {
        if vpn {
            onNotice?(Notice(symbol: "lock.shield.fill", tone: connected ? .green : .orange, title: "VPN",
                             detail: connected ? L("Bağlandı") : L("Koptu")))
        } else {
            onNotice?(Notice(symbol: connected ? "wifi" : "wifi.slash", tone: connected ? .green : .orange, title: "Wi-Fi",
                             detail: connected ? L("Bağlandı") : L("Koptu")))
        }
    }

    /// Bir VPN tüneli (IPv4 adresli utun arayüzü) var mı.
    private static func vpnActive() -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard entry.ifa_addr?.pointee.sa_family == UInt8(AF_INET), (entry.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            if String(cString: entry.ifa_name).hasPrefix("utun") { return true }
        }
        return false
    }
}
