import Foundation

/// macOS Saat uygulamasının zamanlayıcıları ve alarmları. Saat bunları "com.apple.mobiletimerd" tercihlerine
/// yazar (izin gerekmez); dosya değişince yeniden okunur. Zamanlayıcının sesini ve bildirimini Saat kendisi çalar.
@MainActor
final class ClockWatcher {
    struct Timer: Equatable {
        let id: String
        let end: Date
        let total: TimeInterval
    }

    /// Çalışan zamanlayıcılar değişince (en yakın biten önce).
    var onTimers: (([Timer]) -> Void)?
    /// Bir zamanlayıcı bittiğinde ya da kurulu bir alarmın saati geldiğinde (başlık).
    var onRing: ((String, _ isAlarm: Bool) -> Void)?

    private static let domain = "com.apple.mobiletimerd" as CFString
    private static let file = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Preferences/com.apple.mobiletimerd.plist")

    private var poll: Foundation.Timer?
    private var modified: Date?
    private var timers: [Timer] = []
    private var alarms: [(id: String, hour: Int, minute: Int)] = []
    private var rangAlarms: Set<String> = []

    init() {
        poll = Foundation.Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        poll?.tolerance = 0.5
        check()
    }

    private func check() {
        let date = (try? FileManager.default.attributesOfItem(atPath: Self.file.path))?[.modificationDate] as? Date
        if date != modified {
            modified = date
            CFPreferencesAppSynchronize(Self.domain)
            let running = Self.readTimers()
            if running != timers {
                timers = running
                onTimers?(running)
            }
            alarms = Self.readAlarms()
        }
        let now = Date()
        for timer in timers where timer.end <= now {
            timers.removeAll { $0.id == timer.id }
            onTimers?(timers)
            onRing?(L("Zamanlayıcı bitti"), false)
        }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: now)
        for alarm in alarms {
            let key = "\(alarm.id)-\(Calendar.current.startOfDay(for: now).timeIntervalSince1970)"
            guard alarm.hour == parts.hour, alarm.minute == parts.minute, !rangAlarms.contains(key) else { continue }
            rangAlarms.insert(key)
            onRing?(String(format: L("Alarm · %@"), now.formatted(date: .omitted, time: .shortened)), true)
        }
    }

    /// MTTimerState: 3 = çalışıyor (2 = duraklatıldı, 1 = durdu).
    private static func readTimers() -> [Timer] {
        guard let root = CFPreferencesCopyAppValue("MTTimers" as CFString, domain) as? [String: Any],
              let list = root["MTTimers"] as? [[String: Any]]
        else { return [] }
        return list.compactMap { item -> Timer? in
            guard let timer = item["$MTTimer"] as? [String: Any],
                  (timer["MTTimerState"] as? Int) == 3,
                  let fire = timer["MTTimerFireTime"] as? [String: Any],
                  let end = (fire["$MTTimerDate"] as? [String: Any])?["MTTimerTimeDate"] as? Date,
                  end > Date()
            else { return nil }
            return Timer(id: timer["MTTimerID"] as? String ?? UUID().uuidString, end: end,
                         total: timer["MTTimerDuration"] as? Double ?? end.timeIntervalSinceNow)
        }
        .sorted { $0.end < $1.end }
    }

    private static func readAlarms() -> [(id: String, hour: Int, minute: Int)] {
        guard let root = CFPreferencesCopyAppValue("MTAlarms" as CFString, domain) as? [String: Any],
              let list = root["MTAlarms"] as? [[String: Any]]
        else { return [] }
        return list.compactMap { item in
            guard let alarm = item["$MTAlarm"] as? [String: Any], (alarm["MTAlarmEnabled"] as? Int) == 1,
                  let hour = alarm["MTAlarmHour"] as? Int, let minute = alarm["MTAlarmMinute"] as? Int
            else { return nil }
            return (alarm["MTAlarmID"] as? String ?? "\(hour):\(minute)", hour, minute)
        }
    }
}
