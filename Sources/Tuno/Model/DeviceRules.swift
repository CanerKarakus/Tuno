import CoreAudio
import Foundation
import Observation

/// Daha önce görülmüş bir ses aygıtı (bağlı olmasa da listede kalır).
struct KnownDevice: Codable, Identifiable, Hashable {
    var uid: String
    var name: String
    var symbol: String
    var transport: String
    var id: String { uid }
}

/// Bir yön (çıkış/giriş) için otomatik geçiş kuralları.
struct DeviceRuleSet: Codable, Equatable {
    var isEnabled = false
    /// Öncelik sırası (ilk = en çok tercih edilen).
    var order: [KnownDevice] = []
    /// macOS'un otomatik geçmesine izin verilmeyen aygıtlar.
    var blocked: Set<String> = []
}

/// Ses aygıtı öncelik kuralları: aygıt takılıp çıkarıldığında listedeki ilk uygun aygıta
/// geçer; engellenen bir aygıta macOS kendiliğinden geçerse geri alır.
/// Kullanıcının Tuno'dan elle seçtiği aygıta (engelli olsa bile) dokunulmaz.
@Observable
@MainActor
final class DeviceRules {
    private(set) var output: DeviceRuleSet
    private(set) var input: DeviceRuleSet

    @ObservationIgnored private var manualSelection: [AudioScope: String] = [:]
    @ObservationIgnored private var lastPresent: [AudioScope: Set<String>] = [:]

    private static let key = "deviceRules"

    private struct Stored: Codable {
        var output: DeviceRuleSet
        var input: DeviceRuleSet
    }

    init() {
        let stored = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        output = stored?.output ?? DeviceRuleSet()
        input = stored?.input ?? DeviceRuleSet()
    }

    func rules(_ scope: AudioScope) -> DeviceRuleSet { scope == .output ? output : input }

    // MARK: - Düzenleme

    func setEnabled(_ enabled: Bool, scope: AudioScope) { update(scope) { $0.isEnabled = enabled } }

    func move(_ uid: String, by offset: Int, scope: AudioScope) {
        update(scope) { rules in
            guard let index = rules.order.firstIndex(where: { $0.uid == uid }) else { return }
            let target = min(max(index + offset, 0), rules.order.count - 1)
            let item = rules.order.remove(at: index)
            rules.order.insert(item, at: target)
        }
    }

    func setBlocked(_ blocked: Bool, uid: String, scope: AudioScope) {
        update(scope) { if blocked { $0.blocked.insert(uid) } else { $0.blocked.remove(uid) } }
    }

    func forget(_ uid: String, scope: AudioScope) {
        update(scope) { rules in
            rules.order.removeAll { $0.uid == uid }
            rules.blocked.remove(uid)
        }
    }

    /// Kullanıcı Tuno'dan bir aygıt seçti: bir sonraki takma/çıkarmaya kadar ona dokunma.
    func noteManualSelection(_ uid: String, scope: AudioScope) {
        manualSelection[scope] = uid
    }

    private func update(_ scope: AudioScope, _ change: (inout DeviceRuleSet) -> Void) {
        if scope == .output { change(&output) } else { change(&input) }
        let stored = Stored(output: output, input: input)
        if let data = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    // MARK: - Değerlendirme

    /// Aygıt listesi ya da varsayılan aygıt değiştiğinde çağrılır; geçilmesi gereken aygıtı döner.
    func evaluate(scope: AudioScope, devices: [AudioDevice], current: AudioDevice?) -> AudioDevice? {
        let present = Set(devices.map(\.uid))
        let previous = lastPresent[scope]
        lastPresent[scope] = present

        // Yeni görülen aygıtları listenin sonuna ekle, adlarını güncelle.
        update(scope) { rules in
            for device in devices {
                let known = KnownDevice(uid: device.uid, name: device.name,
                                        symbol: device.symbolName(for: scope), transport: device.transportLabel)
                if let index = rules.order.firstIndex(where: { $0.uid == device.uid }) {
                    if rules.order[index] != known { rules.order[index] = known }
                } else {
                    rules.order.append(known)
                }
            }
        }

        let rules = self.rules(scope)
        guard rules.isEnabled, let previous else { return nil }   // ilk açılışta geçiş yapma
        let listChanged = previous != present
        if listChanged { manualSelection[scope] = nil }

        let best = rules.order.lazy
            .filter { !rules.blocked.contains($0.uid) }
            .compactMap { known in devices.first { $0.uid == known.uid } }
            .first

        if listChanged {
            // Aygıt takıldı/çıkarıldı: en öncelikli uygun aygıta geç.
            if let best, best.uid != current?.uid { return best }
        } else if let current, rules.blocked.contains(current.uid), manualSelection[scope] != current.uid {
            // macOS kendiliğinden engelli bir aygıta geçti: geri al.
            if let best, best.uid != current.uid { return best }
        }
        return nil
    }
}
