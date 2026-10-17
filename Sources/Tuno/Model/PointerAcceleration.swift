import Foundation
import IOKit.hidsystem

/// Farelerde (trackpad hariç) işaretçi hızlandırmasını kapatır ve sabit hız uygular.
///
/// macOS'ta hızlandırma kapatılamaz; bu, `com.apple.mouse.scaling = -1` ile aynı etkiyi
/// HID servislerine anında uygular. Hız, kapalıyken işaretçi çözünürlüğüyle ayarlanır.
/// Kapatıldığında ya da Tuno kapanınca sistem değerleri geri yüklenir.
@MainActor
final class PointerAcceleration {
    private let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private var disabled = false
    private var speed: Double = 1
    private var touched = false

    private static let defaultResolution = 400 * 65536

    func apply(disable: Bool, speed: Double) {
        let changed = disable != disabled || speed != self.speed
        disabled = disable
        self.speed = speed
        if disable {
            if changed || !touched { refresh() }
        } else if touched {
            restore()
        }
    }

    /// Yeni bağlanan farelere de uygulamak için ara ara çağrılır.
    func refresh() {
        guard disabled else { return }
        let resolution = Int(Double(Self.defaultResolution) / max(speed, 0.1))
        for service in mice() {
            set(service, Self.accelerationKey(service), -65536)   // -1 (16.16 sabit nokta): doğrusal
            set(service, kIOHIDPointerResolutionKey, resolution)
        }
        touched = true
    }

    func restore() {
        guard touched else { return }
        let scaling = (UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["com.apple.mouse.scaling"]
            as? Double) ?? 0.6875
        for service in mice() {
            set(service, Self.accelerationKey(service), Int(scaling * 65536))
            set(service, kIOHIDPointerResolutionKey, Self.defaultResolution)
        }
        touched = false
    }

    /// Fare olarak görünen, dahili olmayan ve trackpad olmayan HID servisleri.
    private func mice() -> [IOHIDServiceClient] {
        let services = (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]) ?? []
        return services.filter { service in
            guard IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Mouse)) != 0
            else { return false }
            if (property(service, "Built-In") as? Bool) == true { return false }
            let product = (property(service, kIOHIDProductKey) as? String ?? "").lowercased()
            return !product.contains("trackpad")
        }
    }

    private static func accelerationKey(_ service: IOHIDServiceClient) -> String {
        (IOHIDServiceClientCopyProperty(service, kIOHIDPointerAccelerationTypeKey as CFString) as? String)
            ?? kIOHIDMouseAccelerationTypeKey
    }

    private func property(_ service: IOHIDServiceClient, _ key: String) -> Any? {
        IOHIDServiceClientCopyProperty(service, key as CFString)
    }

    private func set(_ service: IOHIDServiceClient, _ key: String, _ value: Int) {
        IOHIDServiceClientSetProperty(service, key as CFString, value as CFNumber)
    }
}
