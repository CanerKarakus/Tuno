import AppKit
import CoreGraphics
import IOKit
import Observation

struct ExternalDisplay: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    /// Monitör DDC/CI ile parlaklık ayarını destekliyor mu (yoksa yazılımsal karartma).
    var supportsDDC: Bool
    var brightness: Double
}

/// Harici monitörlerin parlaklığı. macOS harici ekranlarda parlaklığı ayarlayamaz; Tuno
/// Apple Silicon'da monitöre DDC/CI komutu gönderir, desteklemeyen ekranların üstüne tıklamaları
/// geçiren siyah bir katman koyarak karartır. Parlaklık tuşları imlecin bulunduğu harici ekranı ayarlar.
@Observable
@MainActor
final class DisplayController {
    private(set) var displays: [ExternalDisplay] = []
    var brightnessKeysEnabled: Bool {
        didSet {
            UserDefaults.standard.set(brightnessKeysEnabled, forKey: Self.keysKey)
            onKeysPreferenceChange?()
        }
    }

    @ObservationIgnored var onKeysPreferenceChange: (() -> Void)?
    @ObservationIgnored private var services: [CGDirectDisplayID: DDCService] = [:]
    @ObservationIgnored private var overlays: [CGDirectDisplayID: NSWindow] = [:]

    private static let keysKey = "brightnessKeysForExternalDisplays"
    private static let levelsKey = "externalDisplayBrightness"

    init() {
        brightnessKeysEnabled = UserDefaults.standard.bool(forKey: Self.keysKey)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        let ids = NSScreen.screens.compactMap {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        }.filter { CGDisplayIsBuiltin($0) == 0 }

        // Önceki yoklamada cevap vermeyen monitörlere bir daha DDC denenmez.
        let previous = displays
        services = DDCService.match(displays: ids).filter { id, _ in
            previous.first { $0.id == id }.map(\.supportsDDC) ?? true
        }
        let saved = UserDefaults.standard.dictionary(forKey: Self.levelsKey) as? [String: Double] ?? [:]
        displays = ids.map { id in
            let name = Self.screen(id)?.localizedName ?? "Harici Ekran"
            return ExternalDisplay(id: id, name: name, supportsDDC: services[id] != nil,
                                   brightness: previous.first { $0.id == id }?.brightness ?? saved[Self.key(id)] ?? 1)
        }
        // Bağlantısı kesilen ekranların katmanlarını kaldır, kalanları yeni yerlerine taşı.
        for (id, overlay) in overlays where !ids.contains(id) {
            overlay.orderOut(nil)
            overlays[id] = nil
        }
        for display in displays where !display.supportsDDC { applyOverlay(display.brightness, for: display.id) }

        // Monitörün gerçek değerini arka planda oku. Okunamıyorsa monitör DDC komutlarını
        // dinlemiyor demektir (çoğu HDMI bağlantısı, bazı monitörler): yazılımsal karartmaya geç.
        for (id, service) in services {
            service.readBrightness { [weak self] value in
                // Okuma DDC kuyruğunda biter; sonuç ana iş parçacığında işlenir. Doğrudan assumeIsolated
                // macOS 27.0.1'de (Swift eşzamanlılık denetimi) Tuno'yu kapatıyordu.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let index = self.displays.firstIndex(where: { $0.id == id }) else { return }
                        if let value {
                            self.displays[index].brightness = value
                        } else {
                            self.services[id] = nil
                            self.displays[index].supportsDDC = false
                            self.applyOverlay(self.displays[index].brightness, for: id)
                        }
                    }
                }
            }
        }
    }

    func setBrightness(_ value: Double, for id: CGDirectDisplayID) {
        let value = min(max(value, 0), 1)
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return }
        displays[index].brightness = value
        if let service = services[id] {
            service.writeBrightness(value)
        } else {
            applyOverlay(value, for: id)
        }
        var saved = UserDefaults.standard.dictionary(forKey: Self.levelsKey) as? [String: Double] ?? [:]
        saved[Self.key(id)] = value
        UserDefaults.standard.set(saved, forKey: Self.levelsKey)
    }

    // MARK: - Çözünürlük

    /// Ekranın kullanılabilir çözünürlükleri: her boyut için bir kez (keskin/HiDPI olan ayrı),
    /// en yüksek yenileme hızıyla, büyükten küçüğe.
    func modes(for id: CGDirectDisplayID) -> [DisplayModeOption] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let all = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []).filter { $0.isUsableForDesktopGUI() }
        var best: [String: CGDisplayMode] = [:]
        for mode in all {
            let key = "\(mode.width)x\(mode.height)-\(mode.pixelWidth > mode.width)"
            if let current = best[key], current.refreshRate >= mode.refreshRate { continue }
            best[key] = mode
        }
        return best.values.map(DisplayModeOption.init)
            .sorted { ($0.width, $0.height, $0.isHiDPI ? 1 : 0) > ($1.width, $1.height, $1.isHiDPI ? 1 : 0) }
    }

    func currentMode(for id: CGDirectDisplayID) -> DisplayModeOption? {
        CGDisplayCopyDisplayMode(id).map(DisplayModeOption.init)
    }

    func setMode(_ option: DisplayModeOption, for id: CGDirectDisplayID) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayWithDisplayMode(config, id, option.mode, nil)
        CGCompleteDisplayConfiguration(config, .permanently)
    }

    var isExternalUnderCursor: Bool {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return false }
        return displays.contains { $0.id == id }
    }

    /// Parlaklık tuşları için: imleç harici bir ekrandaysa onu ayarlar.
    func adjustDisplayUnderCursor(by delta: Double) -> ExternalDisplay? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let display = displays.first(where: { $0.id == id })
        else { return nil }
        setBrightness(display.brightness + delta, for: id)
        return displays.first { $0.id == id }
    }

    func restore() {
        overlays.values.forEach { $0.orderOut(nil) }
        overlays = [:]
    }

    // MARK: - Yazılımsal karartma

    /// Ekranın tamamını (menü çubuğu ve Dock dahil) kaplayan, tıklamaları geçiren siyah katman.
    /// En düşük parlaklıkta bile ekran tamamen kararmaz, %10 kadar görünür kalır.
    private func applyOverlay(_ value: Double, for id: CGDirectDisplayID) {
        let opacity = (1 - value) * 0.9
        guard opacity > 0.005, let screen = Self.screen(id) else {
            overlays[id]?.orderOut(nil)
            overlays[id] = nil
            return
        }
        let overlay = overlays[id] ?? Self.makeOverlay()
        overlays[id] = overlay
        if overlay.frame != screen.frame { overlay.setFrame(screen.frame, display: false) }
        overlay.alphaValue = opacity
        if !overlay.isVisible { overlay.orderFrontRegardless() }
    }

    private static func makeOverlay() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .black
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        // Ekran görüntüleri ve kayıtlar karartmadan etkilenmesin.
        window.sharingType = .none
        return window
    }

    private static func screen(_ id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
        }
    }

    private static func key(_ id: CGDirectDisplayID) -> String {
        "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
    }
}

struct DisplayModeOption: Identifiable, Hashable {
    let mode: CGDisplayMode
    var width: Int { mode.width }
    var height: Int { mode.height }
    var isHiDPI: Bool { mode.pixelWidth > mode.width }
    var id: String { "\(width)x\(height)-\(isHiDPI)" }
    var title: String { "\(width) × \(height)" + (isHiDPI ? " (keskin)" : "") }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Apple Silicon'da bir monitörle DDC/CI (I²C) iletişimi (IOAVService, özel API).
final class DDCService: @unchecked Sendable {
    private typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias Write = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private typealias Read = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    private static let create: Create? = symbol("IOAVServiceCreateWithService")
    private static let write: Write? = symbol("IOAVServiceWriteI2C")
    private static let read: Read? = symbol("IOAVServiceReadI2C")

    private static func symbol<T>(_ name: String) -> T? {
        iokit.flatMap { dlsym($0, name) }.map { unsafeBitCast($0, to: T.self) }
    }

    private let service: CFTypeRef
    private let queue = DispatchQueue(label: "app.tuno.ddc", qos: .userInitiated)
    private var pending: UInt16?
    private var writing = false
    private var maximum: UInt16 = 100

    private init(service: CFTypeRef) { self.service = service }

    // MARK: Parlaklık (VCP 0x10)

    func writeBrightness(_ value: Double) {
        queue.async {
            self.pending = UInt16((value * Double(self.maximum)).rounded())
            guard !self.writing else { return }   // sürmekte olan yazma bitince en son değer yazılır
            self.writing = true
            while let next = self.pending {
                self.pending = nil
                self.writeVCP(0x10, next)
            }
            self.writing = false
        }
    }

    func readBrightness(_ completion: @escaping @Sendable (Double?) -> Void) {
        queue.async {
            guard let (current, maximum) = self.readVCP(0x10), maximum > 0 else { return completion(nil) }
            self.maximum = maximum
            completion(Double(current) / Double(maximum))
        }
    }

    private func writeVCP(_ code: UInt8, _ value: UInt16) {
        guard let write = Self.write else { return }
        var packet: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        packet[5] = packet[0..<5].reduce(0x6E ^ 0x51, ^)
        // Bazı monitörler ilk komutu kaçırır; iki kez gönder.
        for _ in 0..<2 {
            usleep(10_000)
            _ = packet.withUnsafeMutableBytes { write(service, 0x37, 0x51, $0.baseAddress!, 6) }
        }
    }

    private func readVCP(_ code: UInt8) -> (UInt16, UInt16)? {
        guard let write = Self.write, let read = Self.read else { return nil }
        var request: [UInt8] = [0x82, 0x01, code, 0]
        request[3] = request[0..<3].reduce(0x6E ^ 0x51, ^)
        for _ in 0..<3 {
            usleep(10_000)
            guard request.withUnsafeMutableBytes({ write(service, 0x37, 0x51, $0.baseAddress!, 4) }) == KERN_SUCCESS
            else { continue }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 12)
            guard reply.withUnsafeMutableBytes({ read(service, 0x37, 0x51, $0.baseAddress!, 12) }) == KERN_SUCCESS,
                  reply[2] == 0x02, reply[3] == 0x00, reply[4] == code
            else { continue }
            let maximum = UInt16(reply[6]) << 8 | UInt16(reply[7])
            let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
            return (current, maximum)
        }
        return nil
    }

    // MARK: Ekran eşleştirme

    /// IORegistry'de harici "DCPAVServiceProxy" servislerini bulur ve her birini, ondan önce gelen
    /// çerçeve arabelleğinin üretici/model bilgisine göre CGDirectDisplayID ile eşleştirir.
    static func match(displays: [CGDirectDisplayID]) -> [CGDirectDisplayID: DDCService] {
        guard let create, !displays.isEmpty else { return [:] }
        var found: [(attributes: [String: Any]?, service: DDCService)] = []
        var iterator = io_iterator_t()
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively),
                                            &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }

        var lastAttributes: [String: Any]?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var nameBuffer = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &nameBuffer)
            let name = String(cString: nameBuffer)
            if name == "AppleCLCD2" || name == "IOMobileFramebufferShim" {
                lastAttributes = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString,
                                                                 kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any]
            } else if name == "DCPAVServiceProxy" {
                let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String
                if location == "External", let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                    found.append((lastAttributes, DDCService(service: service)))
                }
            }
        }

        var result: [CGDirectDisplayID: DDCService] = [:]
        var unmatched = found
        for id in displays {
            if let index = unmatched.firstIndex(where: { matches($0.attributes, id) }) {
                result[id] = unmatched.remove(at: index).service
            }
        }
        // Tek harici ekran varsa ve eşleşme bilgisi okunamadıysa doğrudan eşle.
        if result.isEmpty, displays.count == 1, found.count == 1 {
            result[displays[0]] = found[0].service
        }
        return result
    }

    private static func matches(_ attributes: [String: Any]?, _ id: CGDirectDisplayID) -> Bool {
        guard let product = attributes?["ProductAttributes"] as? [String: Any] else { return false }
        let vendor = product["LegacyManufacturerID"] as? Int
        let model = product["ProductID"] as? Int
        let serial = product["SerialNumber"] as? Int
        guard vendor == Int(CGDisplayVendorNumber(id)), model == Int(CGDisplayModelNumber(id)) else { return false }
        let displaySerial = Int(CGDisplaySerialNumber(id))
        return serial == nil || serial == 0 || displaySerial == 0 || serial == displaySerial
    }
}
