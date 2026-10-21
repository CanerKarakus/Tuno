import AppKit
import ApplicationServices

/// Bir uygulamanın ekranda önde olup olmadığını anında bildirir. Pencere Dock'a küçültülünce uygulama hâlâ
/// öndeki uygulama sayılır; bu yüzden etkinleşme bildirimine ek olarak pencere olayları Erişilebilirlik ile izlenir.
@MainActor
final class AppWindowWatcher {
    let bundleID: String
    var onChange: ((Bool) -> Void)?
    private(set) var inFront = false

    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var workspaceObservers: [NSObjectProtocol] = []

    private static let notifications = [
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
        kAXApplicationHiddenNotification, kAXApplicationShownNotification,
        kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
        kAXWindowCreatedNotification, kAXUIElementDestroyedNotification,
    ]

    init(bundleID: String) {
        self.bundleID = bundleID
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
        update()
    }

    private var app: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    fileprivate func update() {
        let app = self.app
        attach(to: app?.processIdentifier ?? 0)
        let value: Bool
        if let app, app.isActive, !app.isHidden {
            value = Self.hasVisibleWindow(pid: app.processIdentifier)
        } else {
            value = false
        }
        guard value != inFront else { return }
        inFront = value
        onChange?(value)
    }

    /// Küçültülmemiş en az bir penceresi var mı.
    private static func hasVisibleWindow(pid: pid_t) -> Bool {
        let element = AXUIElementCreateApplication(pid)
        var windows: CFTypeRef?
        // Erişilebilirlik yoksa pencereler okunamaz: uygulama önde sayılır (eski davranış).
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success,
              let list = windows as? [AXUIElement]
        else { return true }
        return list.contains { window in
            var minimized: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
            return (minimized as? Bool) != true
        }
    }

    private func attach(to pid: pid_t) {
        guard pid != observedPID else { return }
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedPID = pid
        guard pid > 0 else { return }

        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<AppWindowWatcher>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.update() }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        let element = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.notifications {
            AXObserverAddNotification(created, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
    }
}
