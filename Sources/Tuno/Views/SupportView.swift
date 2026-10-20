import AppKit
import SwiftUI

struct SupportView: View {
    @Environment(SupportSession.self) private var support
    @State private var showCode = false
    @State private var copied = false
    private let supportID = SupportID.value

    var body: some View {
        Form {
            Section { PageHeader(page: .support) }
            Section {
                LabeledContent {
                    HStack(spacing: 10) {
                        Text(supportID)
                            .font(.system(.body, design: .monospaced).weight(.medium))
                            .textSelection(.enabled)
                        Button(copied ? L("Kopyalandı") : L("Kopyala"), action: copy)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Tuno Kullanıcı ID'si"))
                        Text(L("Destek ekibi sorduğunda bu numarayı ilet."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text(L("Bu numara yalnızca bu kurulumu tanımlar; kişisel bilgi içermez."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if support.isActive {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        LabeledContent {
                            Button(L("Oturumu Sonlandır"), role: .destructive) { support.end() }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Circle().fill(.green).frame(width: 7, height: 7)
                                    Text(L("Destek modu açık"))
                                }
                                Text(String(format: L("Kalan süre %@"), Self.clock(support.remaining)))
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                    if let busy = support.busy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(busy).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    LabeledContent {
                        Button(L("Destek Modunu Aç…")) { showCode = true }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Destek modu"))
                            Text(L("Kapalı")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let notice = support.notice {
                    NoticeRow(symbol: "info.circle.fill", color: .secondary, text: notice)
                }
            } header: {
                Text(L("Destek Modu"))
            } footer: {
                Text(L("Destek modu yalnızca Tuno Destek'in verdiği kodla açılır ve 30 dakika sürer. Önemli işlemler önce sana sorulur; sonlandırınca bağlantı kesilir."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !support.activity.isEmpty {
                Section(L("Bu Oturumda Yapılanlar")) {
                    ForEach(Array(support.activity.prefix(30).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }

            if let until = support.verboseUntil, until > Date() {
                Section(L("Günlük")) {
                    NoticeRow(symbol: "doc.text.magnifyingglass", color: .blue,
                              text: String(format: L("Tuno Destek ayrıntılı günlüğü açtı; %@ saatinde kendiliğinden kapanır. Günlük bu Mac'te kalır, yalnızca onayladığın tanılama paketiyle gönderilir."), until.formatted(date: .omitted, time: .shortened)))
                    LabeledContent(L("Ayrıntılı günlük")) {
                        Button(L("Şimdi Kapat")) { support.stopVerbose() }
                    }
                }
            }

            if let pinned = support.pinnedVersion {
                Section(L("Sürüm")) {
                    NoticeRow(symbol: "pin.fill", color: .orange,
                              text: String(format: L("Tuno Destek bu Mac'i %@ sürümünde tutuyor; otomatik güncellemeler bekletiliyor."), pinned))
                    LabeledContent(L("Güncellemeler")) {
                        Button(L("Normal Güncellemelere Dön")) { support.unpin() }
                    }
                }
            }
            PageFooter()
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showCode) { SupportCodeSheet() }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(supportID, forType: .string)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { copied = false } }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Destek ekibinin verdiği 6 haneli kod. Onaylanınca oturum açılır.
private struct SupportCodeSheet: View {
    @Environment(SupportSession.self) private var support
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var error: String?
    @State private var working = false
    @FocusState private var focused: Bool
    @State private var shakes: CGFloat = 0

    var body: some View {
        VStack(spacing: 18) {
            SettingsIcon(symbol: Page.support.symbol, color: Page.support.tint, size: 52)
            VStack(spacing: 6) {
                Text(L("Destek Modunu Aç")).font(.title3.weight(.semibold))
                Text(L("Tuno Destek'in sana verdiği 6 haneli kodu yaz."))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            CodeBoxes(code: code, focused: focused, invalid: error != nil)
                .modifier(Shake(amount: shakes))
                // Tuşlar doğrudan yakalanır (metin alanı yok): hızlı yazınca da harf kaybolmaz.
                .focusable(!working)
                .focusEffectDisabled()
                .focused($focused)
                .onKeyPress(phases: [.down, .repeat]) { press in
                    // Mac'teki silme tuşu U+007F gönderir; SwiftUI'nin .delete'i U+0008.
                    if press.key == .delete || press.key == .deleteForward || press.characters == "\u{7F}" || press.characters == "\u{8}" {
                        if !code.isEmpty { code.removeLast() }
                        return .handled
                    }
                    if press.key == .return { confirm(); return .handled }
                    if press.modifiers.contains(.command) {
                        guard press.characters.lowercased() == "v" else { return .ignored }
                        type(NSPasteboard.general.string(forType: .string) ?? "")
                        return .handled
                    }
                    guard !press.characters.isEmpty, press.key != .escape, press.key != .tab else { return .ignored }
                    type(press.characters)
                    return .handled
                }
                .contentShape(Rectangle())
                .onTapGesture { focused = true }
                .opacity(working ? 0.5 : 1)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 8) {
                Label(L("Destek ekibi 30 dakika boyunca Tuno'nun ayarlarını görüp değiştirebilir."), systemImage: "slider.horizontal.3")
                Label(L("Sürüm değiştirme, tanılama ve sıfırlama önce sana sorulur."), systemImage: "hand.raised")
                Label(L("Destek sayfasından ya da menü çubuğundan istediğin an sonlandırabilirsin."), systemImage: "xmark.circle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button(L("Vazgeç")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(L("Onayla"), action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(code.count != 6 || working)
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear { focused = true }
    }

    /// Yazılan ya da yapıştırılan karakterler: küçük harf, boşluk, tire ve koddaki olmayan harfler atlanır.
    private func type(_ text: String) {
        guard !working else { return }
        let added = text.uppercased().filter { SupportID.codeCharacters.contains($0) }
        guard !added.isEmpty else { return }
        code = String((code + added).prefix(6))
        error = nil
    }

    private func confirm() {
        guard code.count == 6, !working else { return }
        working = true
        Task {
            do {
                try await support.join(code: code)
                dismiss()
            } catch {
                working = false
                withAnimation(.linear(duration: 0.4)) { shakes += 1 }
                code = ""
                self.error = error.localizedDescription
                focused = true
            }
        }
    }
}

/// Kodun altı kutusu: dolanlar harfi gösterir, sıradaki kutuda imleç yanıp söner.
private struct CodeBoxes: View {
    let code: String
    let focused: Bool
    let invalid: Bool

    var body: some View {
        let characters = Array(code)
        HStack(spacing: 8) {
            ForEach(0..<6, id: \.self) { index in
                if index == 3 {
                    RoundedRectangle(cornerRadius: 1).fill(.tertiary).frame(width: 10, height: 2)
                }
                box(index, character: index < characters.count ? String(characters[index]) : nil,
                    active: focused && index == min(characters.count, 5))
            }
        }
        .animation(.spring(duration: 0.25, bounce: 0.3), value: code)
    }

    private func box(_ index: Int, character: String?, active: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return ZStack {
            shape.fill(Color.primary.opacity(0.06))
            shape.strokeBorder(invalid ? Color.red.opacity(0.8) : active ? Color.accentColor : Color.primary.opacity(0.12),
                               lineWidth: active || invalid ? 2 : 1)
            if let character {
                Text(character)
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            } else if active {
                Caret()
            }
        }
        .frame(width: 42, height: 52)
        .scaleEffect(active ? 1.04 : 1)
        .animation(.easeOut(duration: 0.15), value: active)
    }
}

private struct Caret: View {
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.accentColor)
            .frame(width: 2, height: 24)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever()) { visible = false }
            }
    }
}

/// Hatalı kodda yana sallanma.
private struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(amount * .pi * 4), y: 0))
    }
}
