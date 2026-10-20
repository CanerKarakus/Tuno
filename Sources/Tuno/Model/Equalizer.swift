import Foundation
import Observation

struct EQPreset: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var gains: [Double]
    var isBuiltIn = false
}

extension EQPreset {
    static let flatID = "flat"

    private static func builtIn(_ id: String, _ name: String, _ gains: [Double]) -> EQPreset {
        EQPreset(id: id, name: name, gains: gains, isBuiltIn: true)
    }

    static var builtIn: [EQPreset] { [
        builtIn(flatID, L("Düz"), [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        builtIn("bass", L("Bas Güçlendirici"), [6, 5, 4, 2.5, 1, 0, 0, 0, 0, 0]),
        builtIn("bassCut", L("Bas Azaltıcı"), [-6, -5, -4, -2.5, -1, 0, 0, 0, 0, 0]),
        builtIn("treble", L("Tiz Güçlendirici"), [0, 0, 0, 0, 0, 1, 2.5, 4, 5, 6]),
        builtIn("vocal", L("Vokal"), [-2, -2, -1, 0, 2, 4, 4, 3, 1, 0]),
        builtIn("speech", L("Konuşma ve Podcast"), [-6, -4, -2, 0, 2, 4, 4, 3, 1, -1]),
        builtIn("acoustic", L("Akustik"), [4, 4, 3, 1, 1.5, 1.5, 3, 3.5, 3, 2]),
        builtIn("electronic", L("Elektronik"), [4.5, 4, 1, 0, -2, 2, 1, 1.5, 4, 5]),
        builtIn("rock", L("Rock"), [5, 4, 3, 1.5, -0.5, -1, 0.5, 2.5, 3.5, 4.5]),
        builtIn("classical", Lc("Klasik", "eq"), [4.5, 3.5, 3, 2.5, -1.5, -1.5, 0, 2, 3, 4]),
        builtIn("loudness", L("Yüksek Ses (Loudness)"), [5, 4, 1, 0, -1, 0, 0, 1, 4, 5]),
        builtIn("night", L("Gece Modu"), [-4, -3, -2, -1, 0, 1, 1, 0, -1, -2]),
        builtIn("laptop", L("Dizüstü Hoparlörü"), [-3, -1, 2, 3, 2, 1, 0, 1, 2, 2]),
    ] }
}

/// Bir aygıta hangi EQ ayarının uygulanacağı.
enum DeviceEQProfile: Codable, Hashable {
    case global          // genel EQ ayarını izle
    case off             // bu aygıtta EQ kapalı
    case preset(String)  // bu aygıta özel hazır ayar
}

@Observable
@MainActor
final class Equalizer {
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let gainRange: ClosedRange<Double> = -12...12

    var isEnabled: Bool { didSet { changed() } }
    private(set) var gains: [Double]
    var preamp: Double { didSet { changed() } }
    /// Seçili hazır ayar; kullanıcı bantları değiştirirse `nil` (Özel) olur.
    private(set) var presetID: String?
    private(set) var userPresets: [EQPreset]
    private(set) var deviceProfiles: [String: DeviceEQProfile]

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var loading = true

    private struct Stored: Codable {
        var isEnabled: Bool
        var gains: [Double]
        var preamp: Double
        var presetID: String?
        var userPresets: [EQPreset]
        var deviceProfiles: [String: DeviceEQProfile]
    }

    private static let key = "equalizer"

    init() {
        let stored = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        isEnabled = stored?.isEnabled ?? false
        gains = stored?.gains ?? Array(repeating: 0, count: Self.frequencies.count)
        preamp = stored?.preamp ?? 0
        presetID = stored.map(\.presetID) ?? EQPreset.flatID
        userPresets = stored?.userPresets ?? []
        deviceProfiles = stored?.deviceProfiles ?? [:]
        loading = false
    }

    var allPresets: [EQPreset] { EQPreset.builtIn + userPresets }

    func preset(id: String?) -> EQPreset? { allPresets.first { $0.id == id } }

    var presetName: String { preset(id: presetID)?.name ?? L("Özel") }

    // MARK: - Düzenleme

    func setGain(_ value: Double, band: Int) {
        guard gains.indices.contains(band) else { return }
        gains[band] = min(max(value, Self.gainRange.lowerBound), Self.gainRange.upperBound)
        presetID = matchingPresetID()
        changed()
    }

    func apply(_ preset: EQPreset) {
        gains = preset.gains
        presetID = preset.id
        if !isEnabled { isEnabled = true } else { changed() }
    }

    func reset() {
        gains = Array(repeating: 0, count: Self.frequencies.count)
        preamp = 0
        presetID = EQPreset.flatID
        changed()
    }

    func saveCurrent(as name: String) {
        let preset = EQPreset(id: "user.\(UUID().uuidString)", name: name, gains: gains)
        userPresets.append(preset)
        presetID = preset.id
        changed()
    }

    func delete(_ preset: EQPreset) {
        guard !preset.isBuiltIn else { return }
        userPresets.removeAll { $0.id == preset.id }
        for (uid, profile) in deviceProfiles where profile == .preset(preset.id) { deviceProfiles[uid] = nil }
        if presetID == preset.id { presetID = nil }
        changed()
    }

    func profile(for uid: String) -> DeviceEQProfile { deviceProfiles[uid] ?? .global }

    func setProfile(_ profile: DeviceEQProfile, for uid: String) {
        deviceProfiles[uid] = profile == .global ? nil : profile
        changed()
    }

    private func matchingPresetID() -> String? {
        allPresets.first { $0.gains == gains }?.id
    }

    // MARK: - İşleme için çıktı

    /// Aygıta uygulanacak bant kazançları; EQ etkin değilse `nil`.
    func gains(for uid: String) -> [Double]? {
        switch profile(for: uid) {
        case .off: return nil
        case .preset(let id): return preset(id: id)?.gains
        case .global: return isEnabled ? gains : nil
        }
    }

    func isActive(for uid: String) -> Bool {
        guard let gains = gains(for: uid) else { return false }
        return gains.contains { abs($0) > 0.05 } || abs(preampDB(for: uid)) > 0.05
    }

    func preampDB(for uid: String) -> Double {
        gains(for: uid) == nil ? 0 : preamp
    }

    func filters(for uid: String, sampleRate: Double) -> [Biquad] {
        guard isActive(for: uid), let gains = gains(for: uid) else { return [] }
        return Self.filters(gains: gains, sampleRate: sampleRate)
    }

    static func filters(gains: [Double], sampleRate: Double) -> [Biquad] {
        zip(frequencies, gains).enumerated().map { index, pair in
            let kind: Biquad.Kind = index == 0 ? .lowShelf : index == frequencies.count - 1 ? .highShelf : .peak
            let q = kind == .peak ? 1.41 : 0.71
            return Biquad(kind: kind, frequency: pair.0, gainDB: pair.1, q: q, sampleRate: sampleRate)
        }
    }

    private func changed() {
        guard !loading else { return }
        let stored = Stored(isEnabled: isEnabled, gains: gains, preamp: preamp, presetID: presetID,
                            userPresets: userPresets, deviceProfiles: deviceProfiles)
        if let data = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(data, forKey: Self.key) }
        onChange?()
    }
}
