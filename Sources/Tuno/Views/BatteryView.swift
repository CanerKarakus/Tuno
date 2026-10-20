import SwiftUI

/// Mac'in pili: yüzde, kalan süre, şarj döngüsü ve pil sağlığı.
struct BatteryView: View {
    @State private var battery = MacBattery()

    var body: some View {
        Form {
            Section { PageHeader(page: .battery) }
            if let info = battery.info {
                Section {
                    HStack(spacing: 16) {
                        BatteryGauge(percent: info.percent, isCharging: info.isCharging)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(String(format: L("%%%d"), info.percent))
                                .font(.system(size: 30, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            Text(status(info)).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }

                Section(L("Pil Sağlığı")) {
                    if let health = info.health {
                        MeterRow(title: L("Azami kapasite"), value: health,
                                 text: health.formatted(.percent.precision(.fractionLength(0))),
                                 color: health >= 0.8 ? .green : .orange)
                    }
                    if let cycles = info.cycleCount {
                        let limit = info.designCycleCount ?? 1000
                        MeterRow(title: L("Şarj döngüsü"), value: Double(cycles) / Double(max(limit, 1)),
                                 text: "\(cycles) / \(limit)", color: cycles < limit * 8 / 10 ? .blue : .orange)
                    }
                    if let full = info.fullCapacity, let design = info.designCapacity {
                        LabeledContent(L("Tam kapasite"), value: "\(full) mAh")
                        LabeledContent(L("Tasarım kapasitesi"), value: "\(design) mAh")
                    }
                }

                Section(L("Güç")) {
                    LabeledContent(L("Güç kaynağı"), value: info.isPluggedIn ? L("Güç adaptörü") : L("Pil"))
                    if info.isPluggedIn, let watts = info.adapterWatts {
                        LabeledContent(L("Adaptör gücü"), value: "\(watts) W")
                    }
                }
            } else {
                Section {
                    Text(L("Bu Mac'te pil yok.")).foregroundStyle(.secondary)
                }
            }
            PageFooter()
        }
        .formStyle(.grouped)
        .animation(.snappy, value: battery.info)
        .onAppear { battery.startUpdating() }
        .onDisappear { battery.stopUpdating() }
    }

    private func status(_ info: MacBattery.Info) -> String {
        if info.isPluggedIn && (info.isFullyCharged || info.percent >= 100) { return L("Tam dolu") }
        if info.isCharging {
            return info.minutesRemaining.map { String(format: L("Şarj oluyor · tam dolmasına %@"), Self.duration($0)) } ?? L("Şarj oluyor")
        }
        if info.isPluggedIn { return L("Adaptöre bağlı, şarj olmuyor") }
        return info.minutesRemaining.map { String(format: L("Pilde · yaklaşık %@ kaldı"), Self.duration($0)) } ?? L("Pilde · süre hesaplanıyor")
    }

    private static func duration(_ minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return String(format: L("%d dk"), rest) }
        return rest == 0 ? String(format: L("%d sa"), hours) : String(format: L("%d sa %d dk"), hours, rest)
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
