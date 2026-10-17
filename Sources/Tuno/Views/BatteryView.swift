import SwiftUI

/// Mac'in pili: yüzde, kalan süre, şarj döngüsü ve pil sağlığı.
struct BatteryView: View {
    @State private var battery = MacBattery()

    var body: some View {
        Form {
            if let info = battery.info {
                Section {
                    HStack(spacing: 16) {
                        BatteryGauge(percent: info.percent, isCharging: info.isCharging)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("%\(info.percent)")
                                .font(.system(size: 30, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            Text(status(info)).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }

                Section("Pil Sağlığı") {
                    if let health = info.health {
                        MeterRow(title: "Azami kapasite", value: health,
                                 text: health.formatted(.percent.precision(.fractionLength(0))),
                                 color: health >= 0.8 ? .green : .orange)
                    }
                    if let cycles = info.cycleCount {
                        let limit = info.designCycleCount ?? 1000
                        MeterRow(title: "Şarj döngüsü", value: Double(cycles) / Double(max(limit, 1)),
                                 text: "\(cycles) / \(limit)", color: cycles < limit * 8 / 10 ? .blue : .orange)
                    }
                    if let full = info.fullCapacity, let design = info.designCapacity {
                        LabeledContent("Tam kapasite", value: "\(full) mAh")
                        LabeledContent("Tasarım kapasitesi", value: "\(design) mAh")
                    }
                }

                Section("Güç") {
                    LabeledContent("Güç kaynağı", value: info.isPluggedIn ? "Güç adaptörü" : "Pil")
                    if info.isPluggedIn, let watts = info.adapterWatts {
                        LabeledContent("Adaptör gücü", value: "\(watts) W")
                    }
                }
            } else {
                Section {
                    Text("Bu Mac'te pil yok.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .animation(.snappy, value: battery.info)
        .onAppear { battery.startUpdating() }
        .onDisappear { battery.stopUpdating() }
    }

    private func status(_ info: MacBattery.Info) -> String {
        if info.isPluggedIn && (info.isFullyCharged || info.percent >= 100) { return "Tam dolu" }
        if info.isCharging {
            return info.minutesRemaining.map { "Şarj oluyor · tam dolmasına \(Self.duration($0))" } ?? "Şarj oluyor"
        }
        if info.isPluggedIn { return "Adaptöre bağlı, şarj olmuyor" }
        return info.minutesRemaining.map { "Pilde · yaklaşık \(Self.duration($0)) kaldı" } ?? "Pilde · süre hesaplanıyor"
    }

    private static func duration(_ minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest) dk" }
        return rest == 0 ? "\(hours) sa" : "\(hours) sa \(rest) dk"
    }
}

private struct BatteryGauge: View {
    let percent: Int
    let isCharging: Bool

    var body: some View {
        let color: Color = percent <= 20 && !isCharging ? .red : isCharging ? .green : .primary
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.35), lineWidth: 2)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(color.opacity(0.85))
                .frame(width: max(CGFloat(percent) / 100 * 66, 4))
                .padding(5)
            if isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(width: 76, height: 38)
        .overlay(alignment: .trailing) {
            Capsule().fill(Color.primary.opacity(0.35)).frame(width: 4, height: 14).offset(x: 6)
        }
    }
}

private struct MeterRow: View {
    let title: String
    let value: Double
    let text: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(text).monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: min(max(value, 0), 1)).tint(color)
        }
        .padding(.vertical, 2)
    }
}
