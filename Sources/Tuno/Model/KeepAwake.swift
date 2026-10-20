import Foundation
import IOKit.pwr_mgt
import Observation

/// Mac'in ve ekranın uykuya geçmesini süresiz ya da belirli bir süre engeller.
@Observable
@MainActor
final class KeepAwake {
    private(set) var isActive = false
    private(set) var endsAt: Date?
    /// Seçilen süre (dakika); süresizse nil.
    private(set) var minutes: Int?

    @ObservationIgnored private var assertion = IOPMAssertionID(0)
    @ObservationIgnored private var timer: Timer?

    func toggle() {
        isActive ? stop() : start(minutes: nil)
    }

    static var durations: [(title: String, minutes: Int?)] { [
        (L("Süresiz"), nil), (L("30 dakika"), 30), (L("1 saat"), 60), (L("2 saat"), 120), (L("4 saat"), 240),
    ] }

    func start(minutes: Int?) {
        stop()
        guard IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                          IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                          "Tuno: uyku engelleme" as CFString, &assertion) == kIOReturnSuccess
        else { return }
        isActive = true
        self.minutes = minutes
        if let minutes {
            let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
            endsAt = end
            timer = Timer.scheduledTimer(withTimeInterval: end.timeIntervalSinceNow, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        endsAt = nil
        minutes = nil
        if isActive { IOPMAssertionRelease(assertion) }
        isActive = false
    }
}
