import CoreML
import CryptoKit
import Foundation
import Observation

/// Yüz tanıma modelleri (AuraFace yüz özeti + iki canlılık modeli). Uygulamaya gömülmez: kullanıcı isteyince
/// sunucudan tek paket olarak iner, SHA-256 ile doğrulanır ve Application Support'a açılır.
/// İndirme yarıda kalırsa (Tuno kapandı) bir sonraki açılışta baştan başlar.
@Observable
@MainActor
final class FaceModels: NSObject {
    enum State: Equatable {
        case absent
        case downloading(Double)
        case installing
        case ready
        case failed(String)
    }

    static let shared = FaceModels()

    static let packageURL = URL(string: "https://gettuno.info/updates/faceid/tuno-faceid-1.zip")!
    nonisolated private static let packageSHA256 = "4518c3574752cf70b391dd61bddfbcc60be818e30397420a98dea1f2ce660a4f"
    nonisolated static let packageBytes: Int64 = 122_059_490
    /// Kullanıcıya gösterilen boyut, ör. "122 MB".
    static var sizeText: String { ByteCountFormatter.string(fromByteCount: packageBytes, countStyle: .file) }

    private(set) var state: State = .absent
    var isReady: Bool { state == .ready }
    var isBusy: Bool {
        switch state {
        case .downloading, .installing: true
        default: false
        }
    }
    var progress: Double {
        switch state {
        case .downloading(let value): value
        case .installing, .ready: 1
        default: 0
        }
    }

    /// Kullanıcı indirmeyi başlattı (yarıda kalırsa açılışta sürdürülür).
    private static let requestedKey = "faceModelsRequested"
    @ObservationIgnored private var task: URLSessionDownloadTask?
    @ObservationIgnored private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    /// Modeller hazır olunca (ilk kez ya da açılışta) çağrılır.
    @ObservationIgnored var onReady: (() -> Void)?

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Tuno/FaceID", directoryHint: .isDirectory)
    }
    nonisolated static var modelFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Tuno/FaceID/FaceID", directoryHint: .isDirectory)
    }

    override private init() {
        super.init()
        if Self.installed { state = .ready }
    }

    nonisolated private static var installed: Bool {
        let fm = FileManager.default
        return ["AuraFace", "FAS27", "FAS40"].allSatisfy {
            fm.fileExists(atPath: modelFolder.appending(path: "\($0).mlmodelc").path)
        }
    }

    /// Açılışta: kullanıcı daha önce indirmeyi başlatmış ama bitmemişse sürdür.
    func resumeIfNeeded() {
        if state == .ready { onReady?(); return }
        if UserDefaults.standard.bool(forKey: Self.requestedKey) { download() }
    }

    func download() {
        guard task == nil, state != .ready else { return }
        UserDefaults.standard.set(true, forKey: Self.requestedKey)
        state = .downloading(0)
        SupportLog.log("faceid", "Model indiriliyor")
        var request = URLRequest(url: Self.packageURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let task = session.downloadTask(with: request)
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
        UserDefaults.standard.set(false, forKey: Self.requestedKey)
        state = .absent
    }

    /// Modelleri ve kayıtlı yüzleri siler (Ayarlar › Yüz Tanıma › Modeli Kaldır).
    func remove() {
        cancel()
        try? FileManager.default.removeItem(at: Self.folder.appending(path: "FaceID"))
        state = .absent
    }

    private func finished(_ result: Result<Void, Error>) {
        task = nil
        switch result {
        case .success:
            UserDefaults.standard.set(false, forKey: Self.requestedKey)
            state = .ready
            SupportLog.log("faceid", "Model kuruldu")
            onReady?()
        case .failure(let error):
            if (error as? URLError)?.code == .cancelled { return }
            SupportLog.log("faceid", "Model indirilemedi: \(error.localizedDescription)")
            state = .failed(error is InstallError ? L("İndirilen dosya doğrulanamadı.") : L("İndirilemedi. İnternet bağlantınızı kontrol edin."))
        }
    }

    private enum InstallError: Error { case checksum, unzip }

    /// İnen paketi doğrular ve açar (arka planda).
    nonisolated private static func install(_ zip: URL) throws {
        let handle = try FileHandle(forReadingFrom: zip)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == packageSHA256 else { throw InstallError.checksum }

        let fm = FileManager.default
        let parent = modelFolder.deletingLastPathComponent()
        let staging = parent.appending(path: "staging", directoryHint: .isDirectory)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, staging.path]
        try ditto.run()
        ditto.waitUntilExit()
        let unpacked = staging.appending(path: "FaceID", directoryHint: .isDirectory)
        guard ditto.terminationStatus == 0, fm.fileExists(atPath: unpacked.appending(path: "AuraFace.mlmodelc").path)
        else { throw InstallError.unzip }
        try? fm.removeItem(at: modelFolder)
        try fm.moveItem(at: unpacked, to: modelFolder)
        try? fm.removeItem(at: staging)
        // Yedeklemeye ve Spotlight'a girmesin.
        var url = parent
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

extension FaceModels: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : Self.packageBytes
        let fraction = min(Double(totalBytesWritten) / Double(total), 1)
        Task { @MainActor in
            if case .downloading(let old) = self.state, fraction - old >= 0.004 || fraction >= 1 {
                self.state = .downloading(fraction)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Geçici dosya bu çağrıdan sonra silinir: önce taşı, sonra arka planda doğrula ve aç.
        let kept = FileManager.default.temporaryDirectory.appending(path: "tuno-faceid-\(UUID().uuidString).zip")
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            guard status == 200 else { throw URLError(.badServerResponse) }
            try FileManager.default.moveItem(at: location, to: kept)
        } catch {
            Task { @MainActor in self.finished(.failure(error)) }
            return
        }
        Task { @MainActor in self.state = .installing }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Self.install(kept) }
            try? FileManager.default.removeItem(at: kept)
            Task { @MainActor in self.finished(result) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in self.finished(.failure(error)) }
    }
}
