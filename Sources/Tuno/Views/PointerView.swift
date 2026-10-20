import SwiftUI

struct PointerView: View {
    @Environment(PointerController.self) private var scroll

    var body: some View {
        Form {
            Section { PageHeader(page: .pointer) }
            if !scroll.isTrusted {
                Section {
                    HStack {
                        NoticeRow(symbol: "lock.fill", color: .orange,
                                  text: L("Trackpad ve fareyi ayrı ayarlayabilmek için Tuno'nun kaydırma olaylarına erişmesi gerekiyor (Erişilebilirlik izni)."))
                        Spacer()
                        Button(L("İzin Ver…")) { scroll.requestAccessibility() }
                    }
                }
            }

            if scroll.isTrusted && (scroll.isActive || scroll.tapFailed) {
                Section {
                    StatusRow()
                }
            }

            DeviceScrollSection(
                device: .trackpad, title: L("Trackpad"), symbol: "rectangle.and.hand.point.up.left.fill",
                video: .trackpad, swipeChapter: "SwipeBetweenPages-2F",
                swipeHint: L("İki parmakla sola veya sağa kaydırarak geri / ileri gidin."))

            TrackpadExtrasSection()

            DeviceScrollSection(
                device: .mouse, title: L("Fare"), symbol: "computermouse.fill",
                video: .mouse, swipeChapter: "SwipeBetweenPages",
                swipeHint: L("Magic Mouse'ta tek parmakla yana kaydırarak geri / ileri gidin."))

            MouseExtrasSection()
            MouseButtonsSection()

            Section {
                LabeledContent(L("macOS \"Doğal kaydırma\" ayarı")) {
                    Text(scroll.systemNatural ? L("Açık") : L("Kapalı")).foregroundStyle(.secondary)
                }
            } footer: {
                Text(L("macOS bu ayarı trackpad ve fare için birlikte uygular; Tuno farklı seçtiğiniz aygıtta yönü ters çevirir. Tuno kapanınca sistem ayarı geri gelir."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            PageFooter()
        }
        .formStyle(.grouped)
        .onAppear { scroll.refreshSystem() }
    }
}

private struct DeviceScrollSection: View {
    let device: PointingDevice
    let title: String
    let symbol: String
    let video: GestureVideo
    let swipeChapter: String
    let swipeHint: String
    @Environment(PointerController.self) private var scroll

    var body: some View {
        Section {
            DirectionRow(
                title: L("Kaydırma yönü"),
                hint: L("İçerik parmak hareketinizi izlesin mi."),
                naturalLabel: L("Doğal"), classicLabel: L("Klasik"),
                isNatural: Binding(
                    get: { scroll.verticalNatural(device) },
                    set: { scroll.setVerticalNatural($0, for: device) }),
                isSystem: scroll.verticalNatural(device) == scroll.systemNatural)
            GesturePreview(video: video, chapter: scroll.verticalNatural(device) ? "Scroll-Natural" : "Scroll")
                .padding(.vertical, 4)

            DirectionRow(
                title: L("Sayfalar arasında geçiş (geri / ileri)"),
                hint: swipeHint,
                naturalLabel: L("Doğal"), classicLabel: L("Ters"),
                isNatural: Binding(
                    get: { scroll.horizontalNatural(device) },
                    set: { scroll.setHorizontalNatural($0, for: device) }),
                isSystem: scroll.horizontalNatural(device) == scroll.systemNatural)
            GesturePreview(
                video: video,
                chapter: scroll.horizontalNatural(device) ? "\(swipeChapter)-Natural" : swipeChapter)
                .padding(.vertical, 4)
        } header: {
            HStack(spacing: 8) {
                Label(title, systemImage: symbol)
                Spacer()
                if scroll.isCustomized(device) {
                    Button(L("Sistem Ayarına Dön")) {
                        withAnimation { scroll.resetToSystem(device) }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
    }
}

private struct DirectionRow: View {
    let title: String
    let hint: String
    let naturalLabel: String
    let classicLabel: String
    @Binding var isNatural: Bool
    let isSystem: Bool

    var body: some View {
        LabeledContent {
            Picker(title, selection: $isNatural.animation()) {
                Text(naturalLabel).tag(true)
                Text(classicLabel).tag(false)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    if !isSystem {
                        Text("Tuno")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Yakalamanın çalışıp çalışmadığını ve son kaydırmanın hangi aygıttan geldiğini gösterir.
private struct StatusRow: View {
    @Environment(PointerController.self) private var scroll

    var body: some View {
        if scroll.tapFailed {
            NoticeRow(symbol: "exclamationmark.triangle.fill", color: .orange,
                      text: L("Kaydırma olayları yakalanamıyor. Sistem Ayarları › Gizlilik ve Güvenlik › Erişilebilirlik'te Tuno'yu kapatıp yeniden açmayı deneyin."))
        } else {
            LabeledContent {
                HStack(spacing: 6) {
                    if let device = scroll.lastDetected {
                        Image(systemName: device == .trackpad ? "rectangle.and.hand.point.up.left.fill" : "computermouse.fill")
                        Text(device == .trackpad ? L("Trackpad") : L("Fare"))
                    } else {
                        Text(L("Bir kez kaydırın")).foregroundStyle(.secondary)
                    }
                }
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: scroll.lastDetected)
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text(L("Etkin · son kaydırma"))
                }
            }
        }
    }
}

// MARK: - Trackpad: orta tık

private struct TrackpadExtrasSection: View {
    @Environment(PointerController.self) private var pointer

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { pointer.pointer.trackpadMiddleClick },
                                 set: { value in pointer.updatePointer { $0.trackpadMiddleClick = value } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Üç parmakla dokunma: orta tık"))
                    Text(L("Tarayıcıda bağlantıyı yeni sekmede açar, sekmeyi kapatır. Sistem Ayarları'nda üç parmakla dokunma \"Sözlükte ara\" olarak ayarlıysa ikisi birlikte çalışır."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.searchAnchor("Üç parmakla dokunma: orta tık")
        }
    }
}

// MARK: - Fare: yumuşak kaydırma ve hızlandırma

private struct MouseExtrasSection: View {
    @Environment(PointerController.self) private var pointer

    var body: some View {
        let prefs = pointer.pointer
        Section {
            Toggle(isOn: Binding(get: { prefs.smoothScrolling },
                                 set: { value in pointer.updatePointer { $0.smoothScrolling = value } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Yumuşak kaydırma"))
                    Text(L("Tekerlekli farelerde kesik kesik kaydırma yerine trackpad gibi akıcı kaydırma."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.searchAnchor("Yumuşak kaydırma")
            if prefs.smoothScrolling {
                LabeledContent(L("Kaydırma hızı")) {
                    Slider(value: Binding(get: { prefs.scrollSpeed },
                                          set: { value in pointer.updatePointer { $0.scrollSpeed = value } }),
                           in: 0.5...3) {
                        EmptyView()
                    } minimumValueLabel: {
                        Image(systemName: "tortoise.fill").foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Image(systemName: "hare.fill").foregroundStyle(.secondary)
                    }
                    .frame(width: 240)
                }
                LabeledContent(L("Akıcılık")) {
                    Slider(value: Binding(get: { prefs.scrollSmoothness },
                                          set: { value in pointer.updatePointer { $0.scrollSmoothness = value } }),
                           in: 0...1) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text(L("Kısa")).font(.caption).foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Text(L("Uzun")).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(width: 240)
                }
            }

            Toggle(isOn: Binding(get: { prefs.disableAcceleration },
                                 set: { value in pointer.updatePointer { $0.disableAcceleration = value } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("İşaretçi hızlandırmasını kapat"))
                    Text(L("İmleç hızdan bağımsız hep aynı oranda gider. Trackpad etkilenmez."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.searchAnchor("İşaretçi hızlandırmasını kapat")
            if prefs.disableAcceleration {
                LabeledContent(L("İşaretçi hızı")) {
                    Slider(value: Binding(get: { prefs.pointerSpeed },
                                          set: { value in pointer.updatePointer { $0.pointerSpeed = value } }),
                           in: 0.3...3) {
                        EmptyView()
                    } minimumValueLabel: {
                        Image(systemName: "tortoise.fill").foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Image(systemName: "hare.fill").foregroundStyle(.secondary)
                    }
                    .frame(width: 240)
                }
            }
        } header: {
            Label(L("Fare: Kaydırma ve İşaretçi"), systemImage: "computermouse")
        }
    }
}

// MARK: - Fare tuşları

private struct MouseButtonsSection: View {
    @Environment(PointerController.self) private var pointer

    var body: some View {
        Section {
            ForEach(MouseButton.allCases) { button in
                Picker(button.title, selection: Binding(
                    get: { pointer.pointer.action(for: button) },
                    set: { pointer.setAction($0, for: button) }
                )) {
                    ForEach(ButtonAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
            }
        } header: {
            Label(L("Fare Tuşları"), systemImage: "cursorarrow.click.2")
        } footer: {
            Text(L("\"Geri / İleri\" Safari dahil tüm tarayıcılarda ve Finder'da çalışır. Varsayılan: tuş uygulamaya olduğu gibi iletilir."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
