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

    private var results: [ClipItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return clipboard.items }
        return clipboard.items.filter { $0.searchText.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            searchField
            list
            hint
        }
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
            .help("Miksere dön")

            VStack(alignment: .leading, spacing: 0) {
                Text("Pano Geçmişi").font(.headline)
                Text("\(clipboard.items.count) öğe").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !clipboard.items.isEmpty {
                Button("Temizle") { clipboard.clear() }
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
            TextField("Ara", text: $query)
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
                Text(clipboard.items.isEmpty ? "Henüz bir şey kopyalanmadı" : "Sonuç yok")
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
                                    onPaste: { paste(item) }, onDelete: { clipboard.remove(item) })
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
            Label("Seç", systemImage: "arrow.up.arrow.down")
            Label("Yapıştır", systemImage: "return")
            Label("Kapat", systemImage: "escape")
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .labelStyle(.titleAndIcon)
    }

    private func reset() {
        query = ""
        selection = 0
        DispatchQueue.main.async { searchFocused = true }
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
        actions.close()
        clipboard.paste(item)
    }
}

private struct ClipRow: View {
    let item: ClipItem
    let index: Int
    let isSelected: Bool
    let onPaste: () -> Void
    let onDelete: () -> Void
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
                .help("Geçmişten sil")
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
    }

    @ViewBuilder private var preview: some View {
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
        switch item.content {
        case .text(let text): text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .image(let image): "Görsel · \(Int(image.size.width))×\(Int(image.size.height))"
        case .files(let urls):
            urls.count == 1 ? urls[0].lastPathComponent : "\(urls[0].lastPathComponent) ve \(urls.count - 1) dosya daha"
        }
    }

    private var subtitle: String {
        let time = item.date.formatted(.relative(presentation: .named))
        return [item.sourceApp, time].compactMap { $0 }.joined(separator: " · ")
    }
}
