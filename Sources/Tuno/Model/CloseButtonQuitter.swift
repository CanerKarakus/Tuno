import AppKit
import ApplicationServices
import Observation

/// Bir uygulamanın son penceresi kırmızı düğmeyle kapatılınca uygulamayı da tamamen kapatır.
/// Yalnızca kırmızı düğmeye tıklanınca devreye girer (⌘W ya da uygulamanın kendi kapattığı
/// pencereler etkilenmez); kaydedilmemiş belge sorusu gelirse pencere açık kaldığı için kapatmaz.
@Observable
@MainActor
final class CloseButtonQuitter {
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            refresh()
        }
    }

    @ObservationIgnored private var monitor: Any?
    private static let enabledKey = "quitOnLastWindowClose"
    /// Kapatılmaması gerekenler: Finder masaüstünü de yönetir.
    private static let excluded: Set<String> = ["com.apple.finder"]

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey, default: true)
        refresh()
    }

    func refresh() {
        let active = isEnabled && AXIsProcessTrusted()
        if active, monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
                MainActor.assumeIsolated { self?.mouseDown(at: NSEvent.mouseLocation) }
            }
        } else if !active, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func mouseDown(at point: NSPoint) {
        guard let primary = NSScreen.screens.first else { return }
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x),
                                               Float(primary.frame.maxY - point.y), &element) == .success,
              let element else { return }
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard (subrole as? String) == (kAXCloseButtonSubrole as String) else { return }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != getpid(), let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular, !Self.excluded.contains(app.bundleIdentifier ?? "")
        else { return }
        // Pencere fare bırakılınca kapanır; birkaç kez bak, hiç pencere kalmadıysa uygulamayı kapat.
        for delay in [0.5, 1.2, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    guard !app.isTerminated, WindowCatalog.windows(for: pid).isEmpty else { return }
                    app.terminate()
                }
            }
        }
    }
}
