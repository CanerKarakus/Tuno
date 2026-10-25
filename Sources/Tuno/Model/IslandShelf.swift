import AppKit
import Observation

/// Dosya rafı: çentiğe sürüklenen dosyalar burada bekler. Dosyalar kopyalanmaz, özgün yerinde kalır; raftan başka bir
/// uygulamaya sürüklenince Finder gibi kopyalanır. "Link al" dosyayı Tuno sunucusuna yükler (en çok 5 GB, 6 saat; aynı anda en çok iki link)
/// ve gettuno.info/d/xxxxxxxx bağlantısını panoya koyar. Yükleme yalnızca bu düğmeye basılınca olur.
@Observable
@MainActor
final class IslandShelf {
    nonisolated static let maxBytes = 5 * 1024 * 1024 * 1024
    static let maxItems = 4

    struct Item: Identifiable, Equatable {
        enum State: Equatable { case idle, uploading(Double), linked(URL), failed(String) }
        let id = UUID()
        let url: URL
        let name: String
        let size: Int
        let isFolder: Bool
        var state: State = .idle
        /// Gizli: yalnızca kayıtlı bir yüz tanınınca görünür (Yüz Tanıma).
        var hidden = false

        var tooLarge: Bool { size > IslandShelf.maxBytes }
        var uploadable: Bool { !isFolder && !tooLarge }
    }

    private(set) var items: [Item] = []
    /// Bir dosya çentiğe doğru sürükleniyor (ada bırakma alanına dönüşür).
    var dragging = false

    @ObservationIgnored var onLink: ((URL) -> Void)?
    @ObservationIgnored var onChange: (() -> Void)?

    init() {
        NotificationCenter.default.addObserver(forName: .tunoFaceIDRemoved, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.unhideAll() }
        }
    }

    /// Bırakılan dosyalar rafa girer; kaç tanesi alındığı döner.
    @discardableResult
    func add(_ urls: [URL]) -> Int {
        var added = 0
        for url in urls where url.isFileURL && !items.contains(where: { $0.url == url }) {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            let item = Item(url: url, name: FileManager.default.displayName(atPath: url.path),
                            size: values?.fileSize ?? 0, isFolder: values?.isDirectory ?? false)
            items.insert(item, at: 0)
            added += 1
        }
        if items.count > Self.maxItems { items.removeLast(items.count - Self.maxItems) }
        onChange?()
        return added
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        onChange?()
    }

    var hasHidden: Bool { items.contains { $0.hidden } }

    func setHidden(_ id: UUID, _ hidden: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].hidden = hidden
    }

    func unhideAll() {
        for index in items.indices { items[index].hidden = false }
    }

    func clear() {
        items.removeAll()
        onChange?()
    }

    func copyLink(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    /// Dosyayı sunucuya yükler; bitince bağlantı panoya konur.
    func upload(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].uploadable else { return }
        if case .linked(let url) = items[index].state { copyLink(url); onLink?(url); return }
        if case .uploading = items[index].state { return }
        let item = items[index]
        items[index].state = .uploading(0)
        Task { [weak self] in
            do {
                let url = try await Self.send(item) { fraction in
                    Task { @MainActor in self?.setState(id, .uploading(fraction)) }
                }
                self?.setState(id, .linked(url))
                self?.copyLink(url)
                self?.onLink?(url)
            } catch {
                self?.setState(id, .failed(Self.message(error)))
            }
        }
    }

    private func setState(_ id: UUID, _ state: Item.State) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = state
    }

    private static func message(_ error: Error) -> String {
        if let upload = error as? UploadError { return upload.text }
        return L("Yüklenemedi")
    }

    private enum UploadError: Error {
        case rate, full, busy, rejected
        var text: String {
            switch self {
            case .rate: L("Bugünlük sınır doldu")
            case .full: L("Sunucu dolu")
            case .busy: L("Sunucu meşgul")
            case .rejected: L("Yüklenemedi")
            }
        }
    }

    private final class Progress: NSObject, URLSessionTaskDelegate {
        let report: (Double) -> Void
        init(_ report: @escaping (Double) -> Void) { self.report = report }
        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                        totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            if totalBytesExpectedToSend > 0 { report(Double(totalBytesSent) / Double(totalBytesExpectedToSend)) }
        }
    }

    nonisolated private static func send(_ item: Item, progress: @escaping (Double) -> Void) async throws -> URL {
        // Önce yer var mı sorulur: meşgulse dosya hiç gönderilmeden söylenir.
        var check = URLComponents(string: "https://gettuno.info/upload.php")!
        check.queryItems = [URLQueryItem(name: "check", value: "1"), URLQueryItem(name: "size", value: String(item.size))]
        let (_, preflight) = try await URLSession(configuration: .ephemeral).data(from: check.url!)
        switch (preflight as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 503: throw UploadError.busy
        case 429: throw UploadError.rate
        case 507: throw UploadError.full
        default: throw UploadError.rejected
        }
        var components = URLComponents(string: "https://gettuno.info/upload.php")!
        let install = await MainActor.run { InstallID.value }
        components.queryItems = [URLQueryItem(name: "name", value: item.name), URLQueryItem(name: "id", value: install)]
        var request = URLRequest(url: components.url!, timeoutInterval: 3600)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession(configuration: .ephemeral)
            .upload(for: request, fromFile: item.url, delegate: Progress(progress))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 { throw UploadError.rate }
        if status == 507 { throw UploadError.full }
        if status == 503 { throw UploadError.busy }
        guard status == 200, let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = reply["url"] as? String, let url = URL(string: text) else { throw UploadError.rejected }
        return url
    }
}
