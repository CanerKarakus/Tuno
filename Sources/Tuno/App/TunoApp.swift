import SwiftUI

@main
struct TunoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Tuno", id: "main") {
            ContentView()
                .environment(appDelegate.devices)
                .environment(appDelegate.mixer)
                .environment(appDelegate.mixer.equalizer)
                .environment(appDelegate.shortcuts)
                .environment(appDelegate.inputMeter)
                .environment(appDelegate.scroll)
                .environment(appDelegate.displays)
                .environment(appDelegate.clipboard)
                .environment(appDelegate.dockPreviews)
                .environment(appDelegate.permissions)
                .environment(appDelegate.onboarding)
                .environment(appDelegate.updater)
                .environment(appDelegate.snapper)
                .environment(appDelegate.keepAwake)
                .environment(appDelegate.finderCut)
                .environment(appDelegate.closeQuitter)
                .environment(appDelegate.keyboardIndicator)
                .environment(appDelegate.support)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 880, height: 600)
        .windowToolbarStyle(.unified)
        // İzinler eksikse ya da tanıtım görülmediyse açılışta yalnızca karşılama penceresi görünür.
        .defaultLaunchBehavior(OnboardingModel.launchPhase == nil ? .presented : .suppressed)
        .restorationBehavior(.disabled)

        Window("Tuno'ya Hoş Geldiniz", id: "onboarding") {
            OnboardingRoot()
                .environment(appDelegate.onboarding)
                .environment(appDelegate.permissions)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(OnboardingModel.launchPhase == nil ? .suppressed : .presented)
        .restorationBehavior(.disabled)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let devices = DeviceStore()
    let inputMeter = InputMeter()
    let scroll = PointerController()
    lazy var mixer = Mixer(devices: devices, equalizer: Equalizer())
    let displays = DisplayController()
    lazy var shortcuts = ShortcutCenter(mixer: mixer, devices: devices, displays: displays)
    let permissions = Permissions()
    let updater = Updater()
    lazy var support = SupportSession(updater: updater)
    private let crashReporter = CrashReporter()
    let onboarding = OnboardingModel()
    let clipboard = ClipboardHistory()
    let dockPreviews = DockPreviews()
    let snapper = WindowSnapper()
    let keepAwake = KeepAwake()
    let battery = HeadphoneBattery()
    let finderCut = FinderCutPaste()
    let closeQuitter = CloseButtonQuitter()
    let keyboardIndicator = KeyboardIndicator()
    private let keyboardTap = KeyboardTap()
    private var statusBar: StatusBarController?
    private var windowSwitcher: WindowSwitcher?
    private var microphoneIndicator: NSStatusItem?
    private var supportIndicator: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        crashReporter.checkAfterLaunch(enabled: updater.isConfigured)
        DockAutoHide.resume()
        SystemHotKeys.restore()
        observeWindowClosing()
        _ = shortcuts
        statusBar = StatusBarController {
            PanelRoot()
                .environment(self.devices)
                .environment(self.mixer)
                .environment(self.mixer.equalizer)
                .environment(self.clipboard)
                .environment(self.displays)
                .environment(self.keepAwake)
                .environment(self.battery)
        }
        shortcuts.onClipboard = { [weak self] in
            guard let self, self.clipboard.isEnabled else { return }
            self.statusBar?.toggle(mode: .clipboard)
        }
        permissions.onChange = { [weak self] in
            guard let self else { return }
            self.shortcuts.refreshAvailability()
            self.dockPreviews.refreshAvailability()
            self.scroll.refreshSystem()
            self.snapper.refresh()
            self.keyboardTap.refresh()
            self.closeQuitter.refresh()
        }
        let switcher = WindowSwitcher(shortcuts: shortcuts)
        windowSwitcher = switcher
        keyboardTap.handlers = [
            { [weak switcher] type, event in switcher?.handle(type, event) ?? false },
            { [weak self] type, event in self?.finderCut.handle(type, event) ?? false },
            { [weak self] type, event in self?.keyboardIndicator.handle(type, event) ?? false },
        ]
        keyboardTap.refresh()
        shortcuts.onSnap = { [weak self] shortcut in self?.snapper.snapFocusedWindow(shortcut) }
        shortcuts.onMicrophoneMute = { [weak self] in
            guard let self else { return }
            self.devices.setMicrophoneMuted(!self.devices.microphoneMuted)
        }
        shortcuts.onKeepAwake = { [weak self] in
            guard let self else { return }
            self.keepAwake.toggle()
            VolumeHUD.shared.show(symbol: self.keepAwake.isActive ? "cup.and.heat.waves.fill" : "cup.and.saucer",
                                  title: self.keepAwake.isActive ? "Uyanık tutuluyor" : "Uyku engelleme kapalı")
        }
        support.onActiveChange = { [weak self] active in self?.updateSupportIndicator(active) }
        devices.onMicrophoneMuteChange = { [weak self] muted in
            self?.updateMicrophoneIndicator(muted)
            VolumeHUD.shared.show(symbol: muted ? "mic.slash.fill" : "mic.fill",
                                  title: muted ? "Mikrofon kapalı" : "Mikrofon açık")
        }
    }

    /// Tuno kırmızı düğmeyle kapanmaz: pencere kapanınca Dock'tan kalkar, arka planda çalışmaya devam
    /// eder. Çıkmak için menü çubuğundaki kapatma düğmesi ya da ⌘Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Tuno çalışırken yeniden açılınca (Finder, Launchpad, Spotlight) ayarlar penceresi gelir.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowOpener.openMain() }
        return true
    }

    /// Son pencere kapanınca Dock simgesini kaldırır.
    private func observeWindowClosing() {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let closing = note.object as? NSWindow, closing.styleMask.contains(.titled) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let others = NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) }
                    if !others { NSApp.setActivationPolicy(.accessory) }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        support.endForQuit()
        inputMeter.stop()
        scroll.shutdown()
        displays.restore()
        mixer.shutdown()
        DockAutoHide.resume()
        SystemHotKeys.setCommandTabTakenOver(false)
        snapper.shutdown()
        keepAwake.stop()
        devices.setMicrophoneMuted(false)
    }

    /// Mikrofon kapalıyken menü çubuğunda kırmızı bir simge; tıklayınca mikrofon açılır.
    private func updateMicrophoneIndicator(_ muted: Bool) {
        guard muted else {
            microphoneIndicator.map(NSStatusBar.system.removeStatusItem)
            microphoneIndicator = nil
            return
        }
        guard microphoneIndicator == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: "Mikrofon kapalı")?
            .withSymbolConfiguration(.init(paletteColors: [.systemRed]))
        item.button?.image = image
        item.button?.toolTip = "Mikrofon kapalı. Açmak için tıklayın."
        item.button?.target = self
        item.button?.action = #selector(unmuteMicrophone)
        microphoneIndicator = item
    }

    @objc private func unmuteMicrophone() {
        devices.setMicrophoneMuted(false)
    }

    /// Destek modu açıkken menü çubuğunda bir simge: kullanıcı bağlantının açık olduğunu görür, oradan da sonlandırabilir.
    private func updateSupportIndicator(_ active: Bool) {
        guard active else {
            supportIndicator.map(NSStatusBar.system.removeStatusItem)
            supportIndicator = nil
            return
        }
        guard supportIndicator == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "lifepreserver.fill", accessibilityDescription: "Destek modu açık")?
            .withSymbolConfiguration(.init(paletteColors: [.systemRed]))
        item.button?.toolTip = "Destek modu açık"
        let menu = NSMenu()
        let title = NSMenuItem(title: "Destek modu açık", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        let end = NSMenuItem(title: "Oturumu Sonlandır", action: #selector(endSupportSession), keyEquivalent: "")
        end.target = self
        menu.addItem(end)
        item.menu = menu
        supportIndicator = item
    }

    @objc private func endSupportSession() {
        support.end()
    }
}

extension UserDefaults {
    func bool(forKey key: String, default value: Bool) -> Bool {
        object(forKey: key) == nil ? value : bool(forKey: key)
    }
}
