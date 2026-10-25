import SwiftUI

/// Menü çubuğu panelinin kökü: mikser ya da pano geçmişi.
struct PanelRoot: View {
    @Environment(PanelState.self) private var state

    var body: some View {
        ZStack(alignment: .top) {
            switch state.mode {
            case .mixer:
                MenuBarView().transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            case .clipboard:
                ClipboardPanelView().transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
    }
}

/// ⌘⇧V ile açılan pano geçmişi.
struct ClipboardPanelView: View {
    @Environment(ClipboardHistory.self) private var clipboard
    @Environment(PanelState.self) private var state
    @Environment(\.menuActions) private var actions
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var searchFocused: Bool

    private var faceID: FaceID { FaceID.shared }

    private var results: [ClipItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return clipboard.items }
        // Gizli öğelerin içeriği, yüz tanınmadan aramayla da ortaya çıkmasın.
        return clipboard.items.filter { item in
            (!item.hidden || faceID.isRevealed) && item.searchText.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            searchField
            if faceID.verifying {
                Label(L("Gizli öğeler için kameraya bak…"), systemImage: "faceid")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .symbolEffect(.pulse, options: .repeating)
                    .transition(.opacity)
            }
            list
            hint
        }
        .animation(.easeInOut(duration: 0.2), value: faceID.verifying)
        .padding(12)
        .frame(width: 340)
        .onAppear(perform: reset)
        .onReceive(NotificationCenter.default.publisher(for: .tunoPanelWillOpen)) { _ in reset() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { state.mode = .mixer }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .help(L("Miksere dön"))

            VStack(alignment: .leading, spacing: 0) {
                Text(L("Pano Geçmişi")).font(.headline)
                Text(String(format: L("%d öğe"), clipboard.items.count)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !clipboard.items.isEmpty {
                Button(L("Temizle")) { clipboard.clear() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L("Ara"), text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { pasteSelected() }
                .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                .onChange(of: query) { selection = 0 }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private var list: some View {
        let items = results
        if items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard").font(.title2).foregroundStyle(.tertiary)
                Text(clipboard.items.isEmpty ? L("Henüz bir şey kopyalanmadı") : L("Sonuç yok"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(items.prefix(100).enumerated()), id: \.element.id) { index, item in
                            ClipRow(item: item, index: index, isSelected: index == selection,
                                    locked: item.hidden && !faceID.isRevealed, canHide: faceID.isUsable,
                                    onPaste: { paste(item) }, onDelete: { clipboard.remove(item) },
                                    onToggleHidden: { clipboard.setHidden(item, !item.hidden) })
                                .id(item.id)
                                .onHover { if $0 { selection = index } }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 380)
                .fixedSize(horizontal: false, vertical: items.count <= 6)
                .onChange(of: selection) {
                    guard items.indices.contains(selection) else { return }
                    withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(items[selection].id) }
                }
            }
        }
    }

    private var hint: some View {
        HStack(spacing: 12) {
            Label(L("Seç"), systemImage: "arrow.up.arrow.down")
            Label(L("Yapıştır"), systemImage: "return")
            Label(L("Kapat"), systemImage: "escape")
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .labelStyle(.titleAndIcon)
    }

    private func reset() {
        query = ""
        selection = 0
        DispatchQueue.main.async { searchFocused = true }
        if clipboard.hasHidden { Task { _ = await faceID.verify() } }
    }

    private func moveSelection(_ offset: Int) {
        let count = min(results.count, 100)
        guard count > 0 else { return }
        selection = min(max(selection + offset, 0), count - 1)
    }

    private func pasteSelected() {
        let items = results
        guard items.indices.contains(selection) else { return }
        paste(items[selection])
    }

    private func paste(_ item: ClipItem) {
        guard item.hidden, !faceID.isRevealed else {
            actions.close()
            clipboard.paste(item)
            return
        }
        Task {
            guard await faceID.verify() else { NSSound.beep(); return }
            actions.close()
            clipboard.paste(item)
        }
    }
}

private struct ClipRow: View {
    let item: ClipItem
    let index: Int
    let isSelected: Bool
    var locked = false
    var canHide = false
    let onPaste: () -> Void
    let onDelete: () -> Void
    var onToggleHidden: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            preview
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("Geçmişten sil"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onPaste)
        .onHover { hovering = $0 }
        .contextMenu {
            if canHide || item.hidden {
                Button(item.hidden ? L("Gizlemeyi Kaldır") : L("Gizle"), systemImage: item.hidden ? "eye" : "eye.slash") {
                    onToggleHidden()
                }
                .disabled(locked)
            }
            Button(L("Geçmişten sil"), systemImage: "trash", role: .destructive, action: onDelete)
        }
    }

    @ViewBuilder private var preview: some View {
        if locked {
            Image(systemName: "lock.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            content
        }
    }

    @ViewBuilder private var content: some View {
        switch item.content {
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .files(let urls):
            Image(nsImage: NSWorkspace.shared.icon(forFile: urls.first?.path ?? "/"))
                .resizable()
                .frame(width: 32, height: 32)
        case .text:
            Image(systemName: "text.alignleft")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private var title: String {
        if locked { return L("Gizli öğe") }
        return switch item.content {
        case .text(let text): text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .image(let image): String(format: L("Görsel · %d×%d"), Int(image.size.width), Int(image.size.height))
        case .files(let urls):
            urls.count == 1 ? urls[0].lastPathComponent : String(format: L("%@ ve %d dosya daha"), urls[0].lastPathComponent, urls.count - 1)
        }
    }

    private var subtitle: String {
        let time = item.date.formatted(.relative(presentation: .named))
        return [item.sourceApp, time].compactMap { $0 }.joined(separator: " · ")
    }
}
