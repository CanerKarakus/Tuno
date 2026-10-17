import Foundation
import IOKit
import Observation

/// Mac'in kendi pili: yüzde, kalan süre, şarj döngüsü ve pil sağlığı (AppleSmartBattery).
@Observable
@MainActor
final class MacBattery {
    struct Info: Equatable {
        var percent: Int
        var isCharging: Bool
        var isPluggedIn: Bool
        var isFullyCharged: Bool
        /// Pille kalan ya da tam dolmasına kalan süre (dakika); hesaplanıyorsa nil.
        var minutesRemaining: Int?
        var cycleCount: Int?
        var designCycleCount: Int?
        var designCapacity: Int?
        var fullCapacity: Int?
        var adapterWatts: Int?

        /// Pilin şu anki tam kapasitesinin tasarım kapasitesine oranı.
        var health: Double? {
            guard let designCapacity, let fullCapacity, designCapacity > 0 else { return nil }
            return min(Double(fullCapacity) / Double(designCapacity), 1)
        }
    }

    private(set) var info: Info?
    @ObservationIgnored private var timer: Timer?

    /// Masaüstü Mac'lerde pil yok.
    static var isAvailable: Bool { read() != nil }

    init() { info = Self.read() }

    /// Pil sayfası açıkken birkaç saniyede bir yenile.
    func startUpdating() {
        info = Self.read()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                let info = Self.read()
                if info != self?.info { self?.info = info }
            }
        }
    }

    func stopUpdating() {
        timer?.invalidate()
        timer = nil
    }

    private static func read() -> Info? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let values = properties?.takeRetainedValue() as? [String: Any],
              let current = values["CurrentCapacity"] as? Int
        else { return nil }
        let battery = values["BatteryData"] as? [String: Any] ?? [:]
        let maximum = max(values["MaxCapacity"] as? Int ?? 100, 1)
        let charging = values["IsCharging"] as? Bool ?? false
        // 65535: macOS henüz hesaplamadı.
        let minutes = (charging ? values["AvgTimeToFull"] : values["TimeRemaining"]) as? Int
        return Info(
            percent: min(Int((Double(current) / Double(maximum) * 100).rounded()), 100),
            isCharging: charging,
            isPluggedIn: values["ExternalConnected"] as? Bool ?? false,
            isFullyCharged: values["FullyCharged"] as? Bool ?? false,
            minutesRemaining: minutes.flatMap { $0 > 0 && $0 < 65535 ? $0 : nil },
            cycleCount: values["CycleCount"] as? Int,
            designCycleCount: values["DesignCycleCount9C"] as? Int,
            designCapacity: (values["DesignCapacity"] as? Int) ?? (battery["DesignCapacity"] as? Int),
            fullCapacity: (values["NominalChargeCapacity"] as? Int) ?? (battery["NominalChargeCapacity"] as? Int)
                ?? (values["AppleRawMaxCapacity"] as? Int),
            adapterWatts: (values["AdapterDetails"] as? [String: Any])?["Watts"] as? Int)
    }
}
