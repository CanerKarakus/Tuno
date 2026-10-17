import SwiftUI

struct EqualizerView: View {
    @Environment(Equalizer.self) private var equalizer
    @Environment(DeviceStore.self) private var devices
    @State private var savingName = ""
    @State private var isSaving = false

    var body: some View {
        @Bindable var equalizer = equalizer
        Form {
            Section {
                HStack(spacing: 12) {
                    SettingsIcon(symbol: "slider.vertical.3", color: .purple, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Ekolayzer")
                        Text("Tüm uygulamaların sesine uygulanır")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Ekolayzer", isOn: $equalizer.isEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .padding(.vertical, 2)

                LabeledContent("Hazır Ayar") {
                    HStack(spacing: 8) {
                        PresetMenu()
                        Button("Farklı Kaydet…") {
                            savingName = ""
                            isSaving = true
                        }
                        Button("Sıfırla") { equalizer.reset() }
                        if let preset = equalizer.preset(id: equalizer.presetID), !preset.isBuiltIn {
                            Button(role: .destructive) { equalizer.delete(preset) } label: {
                                Image(systemName: "trash")
                            }
                            .help("Hazır ayarı sil")
                        }
                    }
                }
            }

            Section {
                EQPanel()
                    .opacity(equalizer.isEnabled ? 1 : 0.45)
                    .padding(.vertical, 6)
            } footer: {
                Text("Bantları sürükleyin; sıfırlamak için çift tıklayın. Yüksek kazançlarda kırpılmayı önlemek için ön kazancı düşürebilirsiniz.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(devices.outputDevices) { device in
                    DeviceProfileRow(device: device)
                }
            } header: {
                Text("Aygıt Profilleri")
            } footer: {
                Text("Bir aygıta özel ayar seçerseniz o aygıta geçtiğinizde otomatik uygulanır. Ör. kulaklıkta Bas Güçlendirici, hoparlörde Düz.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert("Hazır ayarı kaydet", isPresented: $isSaving) {
            TextField("Ad", text: $savingName)
            Button("Kaydet") {
                let name = savingName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { equalizer.saveCurrent(as: name) }
            }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Geçerli bant ayarları yeni bir hazır ayar olarak kaydedilir.")
        }
    }
}

private struct PresetMenu: View {
    @Environment(Equalizer.self) private var equalizer

    var body: some View {
        Menu(equalizer.presetName) {
            ForEach(EQPreset.builtIn) { preset in
                presetButton(preset)
            }
            if !equalizer.userPresets.isEmpty {
                Section("Benim Ayarlarım") {
                    ForEach(equalizer.userPresets) { preset in
                        presetButton(preset)
                    }
                }
            }
        }
        .fixedSize()
    }

    private func presetButton(_ preset: EQPreset) -> some View {
        Button {
            equalizer.apply(preset)
        } label: {
            if preset.id == equalizer.presetID {
                Label(preset.name, systemImage: "checkmark")
            } else {
                Text(preset.name)
            }
        }
    }
}

private struct DeviceProfileRow: View {
    let device: AudioDevice
    @Environment(Equalizer.self) private var equalizer

    var body: some View {
        Picker(selection: Binding(
            get: { equalizer.profile(for: device.uid) },
            set: { equalizer.setProfile($0, for: device.uid) }
        )) {
            Text("Genel ayarı kullan").tag(DeviceEQProfile.global)
            Text("Kapalı").tag(DeviceEQProfile.off)
            Divider()
            ForEach(equalizer.allPresets) { preset in
                Text(preset.name).tag(DeviceEQProfile.preset(preset.id))
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: device.symbolName(for: .output))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(device.name)
            }
        }
    }
}

// MARK: - Grafik ve bant kaydırıcıları

private struct EQPanel: View {
    @Environment(Equalizer.self) private var equalizer

    private static let labels = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 6) {
                VerticalGainSlider(
                    value: Binding(get: { equalizer.preamp }, set: { equalizer.preamp = $0.rounded(toPlaces: 1) }),
                    tint: .secondary)
                    .frame(width: 26)
                Text("Ön").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(height: 230)

            VStack(spacing: 6) {
                ZStack {
                    ResponseGrid()
                    ResponseCurve(gains: equalizer.gains, isEnabled: equalizer.isEnabled)
                    HStack(spacing: 0) {
                        ForEach(0..<Equalizer.frequencies.count, id: \.self) { band in
                            VerticalGainSlider(
                                value: Binding(
                                    get: { equalizer.gains[band] },
                                    set: { equalizer.setGain($0.rounded(toPlaces: 1), band: band) }),
                                tint: .purple)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(height: 210)

                HStack(spacing: 0) {
                    ForEach(Self.labels, id: \.self) { label in
                        Text(label)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

private struct ResponseGrid: View {
    var body: some View {
        Canvas { context, size in
            for db in stride(from: -12.0, through: 12.0, by: 6) {
                let y = size.height * (1 - (db + 12) / 24)
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(.primary.opacity(db == 0 ? 0.18 : 0.07)),
                               style: StrokeStyle(lineWidth: 1, dash: db == 0 ? [] : [3, 4]))
                if db != 0 {
                    context.draw(Text(db > 0 ? "+\(Int(db))" : "\(Int(db))")
                        .font(.system(size: 9)).foregroundStyle(.tertiary),
                                 at: CGPoint(x: 10, y: y - 7))
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035)))
    }
}

private struct ResponseCurve: View {
    let gains: [Double]
    let isEnabled: Bool

    var body: some View {
        Canvas { context, size in
            let sampleRate = 48_000.0
            let filters = Equalizer.filters(gains: gains, sampleRate: sampleRate)
            // Bantlar oktav aralıklı olduğundan log eksende eşit dağılır: 22.6 Hz … 22.6 kHz.
            let minLog = log2(32 / 2.0.squareRoot()), span = 10.0
            let steps = 160
            var line = Path()
            for step in 0...steps {
                let x = Double(step) / Double(steps)
                let frequency = pow(2, minLog + x * span)
                let db = filters.reduce(0) { $0 + $1.magnitudeDB(at: min(frequency, sampleRate / 2.1), sampleRate: sampleRate) }
                let y = size.height * (1 - (min(max(db, -12), 12) + 12) / 24)
                let point = CGPoint(x: x * size.width, y: y)
                step == 0 ? line.move(to: point) : line.addLine(to: point)
            }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            fill.addLine(to: CGPoint(x: 0, y: size.height / 2))
            fill.closeSubpath()
            let color = isEnabled ? Color.purple : .secondary
            context.fill(fill, with: .color(color.opacity(0.14)))
            context.stroke(line, with: .color(color.opacity(0.9)), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }
        .allowsHitTesting(false)
    }
}

/// −12…+12 dB dikey kaydırıcı.
private struct VerticalGainSlider: View {
    @Binding var value: Double
    var tint: Color
    @State private var isDragging = false
    @State private var isHovering = false

    private let range = Equalizer.gainRange

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let knob: CGFloat = 14
            let travel = height - knob
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let y = knob / 2 + travel * (1 - fraction)

            ZStack(alignment: .top) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)
                    .padding(.vertical, knob / 2)

                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(tint.opacity(0.9), lineWidth: 2))
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .scaleEffect(isDragging ? 1.2 : 1)
                    .offset(y: y - knob / 2)

                if isDragging || isHovering {
                    Text(value == 0 ? "0" : String(format: "%+.1f", value))
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.regularMaterial, in: Capsule())
                        .offset(y: max(y - knob / 2 - 18, -2))
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        let f = 1 - min(max((gesture.location.y - knob / 2) / travel, 0), 1)
                        let raw = range.lowerBound + f * (range.upperBound - range.lowerBound)
                        value = abs(raw) < 0.4 ? 0 : raw
                    }
                    .onEnded { _ in isDragging = false }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { value = 0 })
            .onHover { isHovering = $0 }
            .animation(.snappy(duration: 0.15), value: isDragging)
        }
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
