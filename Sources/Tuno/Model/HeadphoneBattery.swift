import Foundation
import Observation

/// Bağlı Bluetooth kulaklık ve hoparlörlerin pil düzeyleri (AirPods'ta sol, sağ ve kutu ayrı).
/// macOS bunları yalnızca sistem bilgisinde verir; okuması yaklaşık bir saniye sürdüğü için
/// arka planda ve yalnızca gerektiğinde (panel açılınca, aygıtlar değişince) okunur.
@Observable
@MainActor
final class HeadphoneBattery {
    struct Device: Identifiable, Equatable {
        struct Level: Equatable { let label: String; let percent: Int }
        let name: String
        let isHeadphones: Bool
        let levels: [Level]
        var id: String { name }
    }

    private(set) var devices: [Device] = []
    @ObservationIgnored private var isReading = false
    @ObservationIgnored private var lastRead: Date?

    func refresh(force: Bool = false) {
        guard !isReading, force || lastRead.map({ Date().timeIntervalSince($0) > 20 }) ?? true else { return }
        isReading = true
        Task.detached(priority: .utility) {
            let result = Self.read()
            await MainActor.run {
                self.isReading = false
                self.lastRead = Date()
                if result != self.devices { self.devices = result }
            }
        }
    }

    nonisolated private static func read() -> [Device] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controller = (root["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let connected = controller["device_connected"] as? [[String: Any]]
        else { return [] }
        let labels = [("Left", L("Sol")), ("Right", L("Sağ")), ("Case", L("Kutu")), ("Main", "")]
        return connected.flatMap { $0.map { name, value -> Device? in
            guard let info = value as? [String: Any] else { return nil }
            let levels = labels.compactMap { key, label -> Device.Level? in
                guard let text = info["device_batteryLevel\(key)"] as? String,
                      let percent = Int(text.filter(\.isNumber)) else { return nil }
                return Device.Level(label: label, percent: percent)
            }
            let type = info["device_minorType"] as? String ?? ""
            // Yalnızca ses aygıtları (fare ve klavye değil).
            guard !levels.isEmpty, ["Head", "Speaker", "Audio"].contains(where: type.contains) else { return nil }
            return Device(name: name, isHeadphones: type.contains("Head"), levels: levels)
        }.compactMap { $0 } }
        .sorted { ($0.isHeadphones ? 0 : 1, $0.name) < ($1.isHeadphones ? 0 : 1, $1.name) }
    }
}
