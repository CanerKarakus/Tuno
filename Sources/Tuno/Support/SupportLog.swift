import Foundation

/// Tuno'nun kendi günlüğü (~/Library/Logs/Tuno/Tuno.log). Yalnızca bu Mac'te durur; destek ekibine ancak
/// kullanıcının onayladığı tanılama paketiyle gider. Önemli olaylar her zaman yazılır; destek ekibi
/// ayrıntılı günlüğü açınca (en fazla 24 saat) daha fazla ayrıntı da yazılır.
enum SupportLog {
    private static let verboseKey = "supportVerboseUntil"
    private static let queue = DispatchQueue(label: "app.tuno.log")
    private static let maxSize = 1_000_000

    static let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Tuno")
    static var file: URL { folder.appending(path: "Tuno.log") }

    /// Ayrıntılı günlüğün kapanacağı an (kapalıysa nil).
    static var verboseUntil: Date? {
        guard let date = UserDefaults.standard.object(forKey: verboseKey) as? Date, date > Date() else { return nil }
        return date
    }

    static var isVerbose: Bool { verboseUntil != nil }

    static func setVerbose(_ on: Bool) {
        UserDefaults.standard.set(on ? Date().addingTimeInterval(24 * 3600) : nil, forKey: verboseKey)
        log("destek", on ? "Ayrıntılı günlük açıldı (24 saat)" : "Ayrıntılı günlük kapatıldı")
    }

    /// `verbose` olaylar yalnızca ayrıntılı günlük açıkken yazılır.
    static func log(_ category: String, _ message: String, verbose: Bool = false) {
        guard !verbose || isVerbose else { return }
        let line = "\(Date().formatted(.iso8601)) [\(category)] \(message)\n"
        queue.async {
            let manager = FileManager.default
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
            if let size = (try? manager.attributesOfItem(atPath: file.path))?[.size] as? Int, size > maxSize {
                let old = folder.appending(path: "Tuno.1.log")
                try? manager.removeItem(at: old)
                try? manager.moveItem(at: file, to: old)
            }
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: file)
            }
        }
    }

    /// Son satırlar (tanılama paketi için); ev klasörü yolu ~ ile kısaltılır.
    static func tail(lines count: Int = 1500) -> String {
        queue.sync {
            let previous = (try? String(contentsOf: folder.appending(path: "Tuno.1.log"), encoding: .utf8)) ?? ""
            let current = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let lines = (previous + current).split(separator: "\n", omittingEmptySubsequences: true).suffix(count)
            return lines.joined(separator: "\n")
                .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        }
    }
}
