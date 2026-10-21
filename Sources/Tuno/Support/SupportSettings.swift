import AppKit
import ServiceManagement

/// Destek modunda yönetim panelinin gördüğü ve değiştirebildiği ayarlar.
///
/// Panel bu tarifi uygulamadaki sayfalarla aynı düzende (kenar çubuğu, gruplu bölümler, anahtarlar, açılır
/// menüler, kaydırıcılar) çizer. Panelden gelen her değişiklik burada anahtarına göre bulunur, türü ve aralığı
/// denetlenir; listede olmayan hiçbir şey değiştirilemez. Pano içeriği ya da kişisel dosya gösterilmez.
@MainActor
struct SupportSettings {
    let app: AppDelegate

    enum Control {
        case toggle(Bool)
        case choice(String, [(value: String, label: String)], style: String)
        case slider(Double, ClosedRange<Double>, format: String)
        case info(String)
        case bands([Double], labels: [String])
    }

    struct Row {
        var key: String?
        var title: String
        var subtitle: String?
        var control: Control
        var disabled = false
        var apply: ((Any) -> Void)?
    }

    struct Section {
        var title: String?
        var footer: String?
        var rows: [Row]
    }

    struct Screen {
        var page: Page
        var sections: [Section]
    }

    enum ApplyError: LocalizedError {
        case unknown, invalid, disabled
        var errorDescription: String? {
            switch self {
            case .unknown: L("Bu ayar bu Tuno sürümünde yok.")
            case .invalid: L("Geçersiz değer.")
            case .disabled: L("Bu ayar şu an değiştirilemiyor (izin eksik ya da kapalı).")
            }
        }
    }

    // MARK: - Panel için tarif

    func json() -> [[String: Any]] {
        screens().map { screen in
            [
                "id": screen.page.rawValue, "title": screen.page.title, "symbol": screen.page.symbol,
                "color": Self.colorName(screen.page),
                "sections": screen.sections.map { section -> [String: Any] in
                    var item: [String: Any] = ["rows": section.rows.map(Self.rowJSON)]
                    if let title = section.title { item["title"] = title }
                    if let footer = section.footer { item["footer"] = footer }
                    return item
                },
            ]
        }
    }

    private static func rowJSON(_ row: Row) -> [String: Any] {
        var item: [String: Any] = ["title": row.title]
        if let key = row.key, row.apply != nil { item["key"] = key }
        if let subtitle = row.subtitle { item["subtitle"] = subtitle }
        if row.disabled { item["disabled"] = true }
        switch row.control {
        case .toggle(let value):
            item["type"] = "toggle"; item["value"] = value
        case .choice(let value, let options, let style):
            item["type"] = "choice"; item["value"] = value; item["style"] = style
            item["options"] = options.map { [$0.value, $0.label] }
        case .slider(let value, let range, let format):
            item["type"] = "slider"; item["value"] = value; item["min"] = range.lowerBound; item["max"] = range.upperBound
            item["format"] = format
        case .info(let value):
            item["type"] = "info"; item["value"] = value
        case .bands(let values, let labels):
            item["type"] = "bands"; item["value"] = values; item["labels"] = labels
        }
        return item
    }

    // MARK: - Değişiklik

    /// Panelden gelen değeri uygular; kullanıcıya gösterilecek "Başlık → değer" metnini döndürür.
    func apply(key: String, value: Any) throws -> String {
        guard let row = screens().lazy.flatMap({ $0.sections }).flatMap({ $0.rows }).first(where: { $0.key == key }),
              let apply = row.apply
        else { throw ApplyError.unknown }
        guard !row.disabled else { throw ApplyError.disabled }
        switch row.control {
        case .toggle:
            guard let flag = value as? Bool else { throw ApplyError.invalid }
            apply(flag)
            return "\(row.title): \(flag ? L("Açık") : L("Kapalı"))"
        case .choice(_, let options, _):
            let text = (value as? String) ?? (value as? NSNumber)?.stringValue ?? ""
            guard let option = options.first(where: { $0.value == text }) else { throw ApplyError.invalid }
            apply(option.value)
            return "\(row.title): \(option.label)"
        case .slider(_, let range, let format):
            guard let number = (value as? NSNumber)?.doubleValue, number.isFinite else { throw ApplyError.invalid }
            let clamped = min(max(number, range.lowerBound), range.upperBound)
            apply(clamped)
            return "\(row.title): \(format == "percent" ? "%\(Int((clamped * 100).rounded()))" : String(format: "%.1f", clamped))"
        case .info, .bands:
            throw ApplyError.unknown
        }
    }

    // MARK: - Sayfalar (uygulamadaki sırayla)

    private func screens() -> [Screen] {
        [mixer(), device(.output), device(.input), equalizer(), pointer(), shortcuts(), displays(), windows(), finder(),
         clipboard(), general()]
    }

    private func mixer() -> Screen {
        let mixer = app.mixer
        let maxBoost = UserDefaults.standard.object(forKey: PreferenceKey.maxBoost) as? Double ?? 1.5
        var rows: [Row] = []
        for audioApp in mixer.apps where audioApp.id.range(of: #"^[A-Za-z0-9_.:-]{1,100}$"#, options: .regularExpression) != nil {
            let settings = mixer.settings(for: audioApp)
            rows.append(Row(key: "mixer.\(audioApp.id).volume", title: audioApp.name,
                            control: .slider(Double(settings.volume), 0...maxBoost, format: "percent")) { value in
                mixer.setVolume(Float(value as! Double), for: audioApp)
            })
            rows.append(Row(key: "mixer.\(audioApp.id).muted", title: String(format: L("%@ · Sessiz"), audioApp.name), control: .toggle(settings.muted)) { value in
                if mixer.settings(for: audioApp).muted != (value as! Bool) { mixer.toggleMute(audioApp) }
            })
        }
        if rows.isEmpty { rows = [Row(title: L("Şu anda ses çalan bir uygulama yok"), control: .info(""))] }
        return Screen(page: .mixer, sections: [
            Section(title: L("Uygulamalar"),
                    footer: L("%100 üzerindeki değerler sesi yükseltir."),
                    rows: rows),
        ])
    }

    private func device(_ scope: AudioScope) -> Screen {
        let devices = app.devices
        let list = scope == .output ? devices.outputDevices : devices.inputDevices
        let current = scope == .output ? devices.defaultOutput : devices.defaultInput
        let prefix = scope == .output ? "output" : "input"
        var sections = [Section(title: scope == .output ? L("Çıkış Aygıtı") : L("Giriş Aygıtı"), rows: [
            Row(key: "\(prefix).device", title: L("Aygıt"),
                control: .choice(current?.uid ?? "", list.map { ($0.uid, $0.name) }, style: "list")) { value in
                if let target = list.first(where: { $0.uid == value as? String }) { devices.setDefault(target, scope: scope) }
            },
        ])]
        if let current {
            let controls = scope == .output ? devices.output : devices.input
            var rows: [Row] = []
            if scope == .input {
                rows.append(Row(key: "input.micMuted", title: L("Mikrofonu kapat"),
                                subtitle: L("Tüm giriş aygıtları susturulur; kapalıyken menü çubuğunda kırmızı mikrofon görünür."),
                                control: .toggle(devices.microphoneMuted)) { devices.setMicrophoneMuted($0 as! Bool) })
            }
            if controls.canSetVolume, let volume = controls.volume {
                rows.append(Row(key: "\(prefix).volume", title: scope == .output ? L("Çıkış Düzeyi") : L("Giriş Düzeyi"),
                                control: .slider(Double(volume), 0...1, format: "percent")) { value in
                    devices.setVolume(Float(value as! Double), scope: scope)
                })
            }
            if scope == .output {
                rows.append(Row(key: "output.muted", title: L("Sessiz"), control: .toggle(controls.muted), disabled: !controls.canMute) {
                    devices.setMuted($0 as! Bool, scope: scope)
                })
            }
            rows.append(Row(title: L("Bağlantı"), control: .info(current.transportLabel)))
            if controls.sampleRate > 0 {
                rows.append(Row(title: L("Örnekleme Hızı"), control: .info((controls.sampleRate / 1000).formatted() + " kHz")))
            }
            sections.append(Section(title: current.name, rows: rows))
            if scope == .output {
                let uid = current.uid
                let limit = devices.volumeLimit(for: uid)
                var limitRows = [Row(key: "output.limit", title: L("Ses sınırı"),
                                     subtitle: L("Ses tuşlarıyla ya da uygulamalardan bu düzeyin üstüne çıkılamaz."),
                                     control: .toggle(limit != nil)) { value in
                    devices.setVolumeLimit((value as! Bool) ? 0.7 : nil, for: uid)
                }]
                if let limit {
                    limitRows.append(Row(key: "output.limitValue", title: L("En yüksek düzey"),
                                         control: .slider(Double(limit), 0.05...1, format: "percent")) { value in
                        devices.setVolumeLimit(Float(value as! Double), for: uid)
                    })
                }
                sections.append(Section(rows: limitRows))
            }
        }
        let rules = devices.rules.rules(scope)
        sections.append(Section(title: L("Otomatik Geçiş"), rows: [
            Row(key: "\(prefix).rules", title: L("Öncelik sırasına göre otomatik geç"), control: .toggle(rules.isEnabled)) {
                devices.rules.setEnabled($0 as! Bool, scope: scope)
            },
        ]))
        return Screen(page: scope == .output ? .output : .input, sections: sections)
    }

    private func equalizer() -> Screen {
        let equalizer = app.mixer.equalizer
        var options = equalizer.allPresets.map { ($0.id, $0.name) }
        if equalizer.presetID == nil { options.append(("custom", L("Özel"))) }
        return Screen(page: .equalizer, sections: [
            Section(rows: [
                Row(key: "eq.enabled", title: L("Ekolayzer"), subtitle: L("Tüm uygulamaların sesine uygulanır"),
                    control: .toggle(equalizer.isEnabled)) { equalizer.isEnabled = $0 as! Bool },
                Row(key: "eq.preset", title: L("Hazır Ayar"), control: .choice(equalizer.presetID ?? "custom", options, style: "menu")) { value in
                    if let preset = equalizer.preset(id: value as? String) { equalizer.apply(preset) }
                },
                Row(title: L("Bantlar"), control: .bands(equalizer.gains, labels: Equalizer.frequencies.map {
                    $0 >= 1000 ? "\(Int($0 / 1000))k" : "\(Int($0))"
                })),
            ]),
        ])
    }

    private func pointer() -> Screen {
        let pointer = app.scroll
        let prefs = pointer.pointer
        func direction(_ device: PointingDevice) -> [Row] {
            let name = device.rawValue
            return [
                Row(key: "pointer.\(name).vertical", title: L("Kaydırma yönü"),
                    control: .choice(pointer.verticalNatural(device) ? "natural" : "classic", [("natural", L("Doğal")), ("classic", L("Klasik"))], style: "segmented")) {
                    pointer.setVerticalNatural($0 as? String == "natural", for: device)
                },
                Row(key: "pointer.\(name).horizontal", title: L("Sayfalar arasında geçiş (geri / ileri)"),
                    control: .choice(pointer.horizontalNatural(device) ? "natural" : "classic", [("natural", L("Doğal")), ("classic", L("Ters"))], style: "segmented")) {
                    pointer.setHorizontalNatural($0 as? String == "natural", for: device)
                },
            ]
        }
        var mouse = [
            Row(key: "pointer.smoothScrolling", title: L("Yumuşak kaydırma"),
                subtitle: L("Tekerlekli farelerde kesik kesik kaydırma yerine trackpad gibi akıcı kaydırma."),
                control: .toggle(prefs.smoothScrolling)) { value in pointer.updatePointer { $0.smoothScrolling = value as! Bool } },
        ]
        if prefs.smoothScrolling {
            mouse.append(Row(key: "pointer.scrollSpeed", title: L("Kaydırma hızı"), control: .slider(prefs.scrollSpeed, 0.5...3, format: "number")) { value in
                pointer.updatePointer { $0.scrollSpeed = value as! Double }
            })
            mouse.append(Row(key: "pointer.scrollSmoothness", title: L("Akıcılık"), control: .slider(prefs.scrollSmoothness, 0...1, format: "number")) { value in
                pointer.updatePointer { $0.scrollSmoothness = value as! Double }
            })
        }
        mouse.append(Row(key: "pointer.disableAcceleration", title: L("İşaretçi hızlandırmasını kapat"),
                         subtitle: L("İmleç, fareyi ne kadar hızlı hareket ettirdiğinizden bağımsız olarak hep aynı oranda gider. Trackpad etkilenmez."),
                         control: .toggle(prefs.disableAcceleration)) { value in pointer.updatePointer { $0.disableAcceleration = value as! Bool } })
        if prefs.disableAcceleration {
            mouse.append(Row(key: "pointer.pointerSpeed", title: L("İşaretçi hızı"), control: .slider(prefs.pointerSpeed, 0.3...3, format: "number")) { value in
                pointer.updatePointer { $0.pointerSpeed = value as! Double }
            })
        }
        let actions = ButtonAction.allCases.map { ($0.rawValue, $0.title) }
        let buttons = MouseButton.allCases.map { button in
            Row(key: "pointer.button.\(button.rawValue)", title: button.title,
                control: .choice(prefs.action(for: button).rawValue, actions, style: "menu")) { value in
                if let action = ButtonAction(rawValue: value as? String ?? "") { pointer.setAction(action, for: button) }
            }
        }
        return Screen(page: .pointer, sections: [
            Section(title: L("Trackpad"), rows: direction(.trackpad) + [
                Row(key: "pointer.middleClick", title: L("Üç parmakla dokunma: orta tık"), control: .toggle(prefs.trackpadMiddleClick)) { value in
                    pointer.updatePointer { $0.trackpadMiddleClick = value as! Bool }
                },
            ]),
            Section(title: L("Fare"), rows: direction(.mouse)),
            Section(title: L("Fare: Kaydırma ve İşaretçi"), rows: mouse),
            Section(title: L("Fare Tuşları"), rows: buttons),
            Section(rows: [Row(title: L("macOS \"Doğal kaydırma\" ayarı"), control: .info(pointer.systemNatural ? L("Açık") : L("Kapalı")))]),
        ])
    }

    private func shortcuts() -> Screen {
        let center = app.shortcuts
        let indicator = app.keyboardIndicator
        let list = Shortcut.listed.map { shortcut in
            Row(key: "shortcut.\(shortcut.rawValue)", title: shortcut.title, subtitle: shortcut.keys.joined(separator: " "),
                control: .toggle(center.isEnabled(shortcut))) { center.setEnabled($0 as! Bool, for: shortcut) }
        }
        return Screen(page: .shortcuts, sections: [
            Section(title: L("Genel Kısayollar"), rows: [
                Row(key: "keyboard.indicator", title: L("Caps Lock ve klavye dili göstergesi"),
                    subtitle: L("Caps Lock ve klavye dili değişince kısa bir gösterge çıkar."),
                    control: .toggle(indicator.isEnabled)) { indicator.isEnabled = $0 as! Bool },
            ] + list),
            Section(title: L("Klavye Ses Tuşları"), rows: [
                Row(key: "keyboard.mediaKeys", title: L("Ses tuşlarını yazılımsal ses için kullan"),
                    subtitle: L("HDMI ve DisplayPort ekranlarda klavyenin ses tuşları Tuno'nun yazılımsal sesini ayarlar."),
                    control: .toggle(center.mediaKeysEnabled)) { center.mediaKeysEnabled = $0 as! Bool },
            ]),
        ])
    }

    private func displays() -> Screen {
        let displays = app.displays
        var brightness = displays.displays.map { display in
            Row(key: "display.\(display.id).brightness", title: display.name,
                subtitle: display.supportsDDC ? L("Donanımsal") : L("Yazılımsal karartma"),
                control: .slider(display.brightness, 0...1, format: "percent")) { value in
                displays.setBrightness(value as! Double, for: display.id)
            }
        }
        if brightness.isEmpty { brightness = [Row(title: L("Harici ekran bağlı değil"), control: .info(""))] }
        return Screen(page: .displays, sections: [
            Section(title: L("Parlaklık"), rows: brightness),
            Section(rows: [
                Row(key: "displays.keys", title: L("Parlaklık tuşları harici ekranı ayarlasın"),
                    subtitle: L("İmleç hangi ekrandaysa parlaklık tuşları onu ayarlar; dahili ekranda her zamanki gibi çalışır."),
                    control: .toggle(displays.brightnessKeysEnabled)) { displays.brightnessKeysEnabled = $0 as! Bool },
            ]),
        ])
    }

    private func windows() -> Screen {
        let center = app.shortcuts
        let available = app.permissions.status(.screenRecording) == .granted && app.permissions.status(.accessibility) == .granted
        let dock = app.dockPreviews
        let snapper = app.snapper
        let closer = app.closeQuitter
        let thumbnails = UserDefaults.standard.bool(forKey: WindowSwitcher.showThumbnailsKey, default: true)
        return Screen(page: .windows, sections: [
            Section(title: L("Alt-Tab"), footer: available ? nil : L("Alt-Tab ve Dock önizlemesi, Ekran Kaydı ve Erişilebilirlik izni verilmeden çalışmaz."), rows: [
                Row(key: "windows.switcher", title: L("Pencereler arasında geçiş (Alt-Tab)"), control: .toggle(center.isEnabled(.switchWindows)),
                    disabled: !available) { center.setEnabled($0 as! Bool, for: .switchWindows) },
                Row(key: "windows.thumbnails", title: L("Pencere önizlemelerini göster"), control: .toggle(thumbnails), disabled: !available) {
                    UserDefaults.standard.set($0 as! Bool, forKey: WindowSwitcher.showThumbnailsKey)
                },
            ]),
            Section(title: L("Dock"), rows: [
                Row(key: "windows.dock", title: L("Dock'ta pencere önizlemesi"), control: .toggle(dock.isEnabled), disabled: !available) {
                    dock.isEnabled = $0 as! Bool
                },
            ]),
            Section(title: L("Yerleştirme"), rows: [
                Row(key: "windows.snap", title: L("Kenara sürükleyerek yerleştir"), control: .toggle(snapper.isEnabled)) { snapper.isEnabled = $0 as! Bool },
                Row(key: "windows.doubleClick", title: L("Başlığa çift tıklayınca ekranı kapla"), control: .toggle(snapper.doubleClickMaximize)) {
                    snapper.doubleClickMaximize = $0 as! Bool
                },
            ]),
            Section(title: L("Kapatma"), rows: [
                Row(key: "windows.closeQuits", title: L("Son pencere kapanınca uygulamayı kapat"), control: .toggle(closer.isEnabled)) {
                    closer.isEnabled = $0 as! Bool
                },
            ]),
        ])
    }

    private func finder() -> Screen {
        let finder = app.finderCut
        return Screen(page: .finder, sections: [
            Section(rows: [
                Row(key: "finder.cut", title: L("⌘X ile kes, ⌘V ile taşı"), control: .toggle(finder.isEnabled)) { finder.isEnabled = $0 as! Bool },
                Row(key: "finder.trash", title: L("Delete ile çöpe at"), control: .toggle(finder.deleteToTrash)) { finder.deleteToTrash = $0 as! Bool },
                Row(key: "finder.enter", title: L("Enter ile aç, F2 ile yeniden adlandır"), control: .toggle(finder.enterOpens)) {
                    finder.enterOpens = $0 as! Bool
                },
            ]),
        ])
    }

    private func clipboard() -> Screen {
        let clipboard = app.clipboard
        let center = app.shortcuts
        return Screen(page: .clipboard, sections: [
            Section(rows: [
                Row(key: "clipboard.enabled", title: L("Pano geçmişini kaydet"), control: .toggle(clipboard.isEnabled)) { clipboard.isEnabled = $0 as! Bool },
                Row(key: "clipboard.shortcut", title: L("⌘⇧V ile göster"), control: .toggle(center.isEnabled(.clipboardHistory)),
                    disabled: !clipboard.isEnabled) { center.setEnabled($0 as! Bool, for: .clipboardHistory) },
                Row(key: "clipboard.limit", title: L("Saklanacak öğe sayısı"),
                    control: .choice(String(clipboard.limit), [25, 50, 100, 200].map { (String($0), String($0)) }, style: "menu"),
                    disabled: !clipboard.isEnabled) { clipboard.limit = Int($0 as! String) ?? clipboard.limit },
            ]),
            // Yalnızca sayı; pano içeriği hiçbir zaman gönderilmez.
            Section(rows: [Row(title: L("Kayıtlı öğe"), control: .info("\(clipboard.items.count)"))]),
        ])
    }

    private func general() -> Screen {
        let defaults = UserDefaults.standard
        let updater = app.updater
        let permissions = app.permissions
        var update = [Row(title: L("Sürüm"), control: .info(updater.version))]
        if updater.isConfigured {
            update.append(Row(key: "general.autoUpdate", title: L("Güncellemeleri otomatik denetle"), control: .toggle(updater.automaticallyChecks)) {
                updater.automaticallyChecks = $0 as! Bool
            })
        }
        return Screen(page: .general, sections: [
            Section(rows: [
                Row(key: "general.launchAtLogin", title: L("Girişte başlat"), control: .toggle(SMAppService.mainApp.status == .enabled)) { value in
                    if value as! Bool { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                },
                Row(key: "general.menuBar", title: L("Menü çubuğunda göster"), control: .toggle(defaults.bool(forKey: PreferenceKey.showMenuBar, default: true))) {
                    defaults.set($0 as! Bool, forKey: PreferenceKey.showMenuBar)
                },
            ]),
            Section(title: L("İzinler"), rows: PermissionKind.allCases.map { kind in
                let status = permissions.status(kind)
                return Row(title: kind.title, control: .info(status == .granted ? L("Verildi") : status == .denied ? L("Verilmedi") : L("Sorulmadı")))
            }),
            Section(title: L("Güncellemeler"), rows: update),
            Section(title: L("Gizlilik"), rows: [
                Row(key: "general.crashPolicy", title: L("Çökme raporları"),
                    control: .choice(CrashReporter.policy.rawValue, CrashReporter.Policy.allCases.map { ($0.rawValue, $0.title) }, style: "menu")) {
                    defaults.set($0 as! String, forKey: CrashReporter.policyKey)
                },
            ]),
            Section(title: L("Uygulama Sesleri"), rows: [
                Row(key: "general.maxBoost", title: L("En yüksek ses düzeyi"),
                    control: .choice(String(defaults.object(forKey: PreferenceKey.maxBoost) as? Double ?? 1.5),
                                     [("1.0", L("%100 (yükseltme yok)")), ("1.5", "%150"), ("2.0", "%200")], style: "menu")) {
                    defaults.set(Double($0 as! String) ?? 1.5, forKey: PreferenceKey.maxBoost)
                },
            ]),
        ])
    }

    private static func colorName(_ page: Page) -> String {
        switch page {
        case .mixer: "pink"
        case .output, .finder, .privacy: "blue"
        case .input: "orange"
        case .equalizer: "purple"
        case .pointer: "teal"
        case .shortcuts: "indigo"
        case .displays: "yellow"
        case .windows: "cyan"
        case .clipboard: "brown"
        case .battery: "green"
        case .support: "red"
        case .general, .about: "gray"
        case .island: "black"
        }
    }
}
