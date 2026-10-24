import Foundation

// ════════════════════════════════════════════════════════════════════
//  Il registro di AudioLR: ogni passo di una separazione con l'ora, in
//  ~/Library/Logs/AudioLR/AudioLR.log. Resta sul Mac; finisce in una
//  segnalazione solo se l'utente la manda (Aiuto › Segnala un problema).
// ════════════════════════════════════════════════════════════════════

enum AppLog {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/AudioLR", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("AudioLR.log")
    }()
    private static let lock = NSLock()
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Aggiunge una riga. Oltre 1 MB il registro ricomincia (si tiene la seconda metà).
    static func write(_ line: String) {
        lock.withLock {
            let text = "\(stamp.string(from: Date()))  \(line)\n"
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: Data(text.utf8))
            } else {
                try? Data(text.utf8).write(to: url)
            }
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 1_000_000,
               let data = try? Data(contentsOf: url) {
                try? data.suffix(500_000).write(to: url)
            }
        }
    }

    /// Le ultime righe, per una segnalazione.
    static func tail(_ lines: Int = 120) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}

/// Un'azione che si fa una volta sola, anche se chiamata da più parti.
final class RunOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ f: () -> Void) { lock.withLock { if !done { done = true; f() } } }
}

/// Esegue `op`, ma smette di aspettarlo dopo `seconds`: restituisce nil se non ha finito in tempo.
/// (Il lavoro continua in sottofondo: serve per le aperture dei modelli che il sistema non sa interrompere.)
func withTimeout<T>(_ seconds: Double, _ op: @escaping () async throws -> T) async throws -> T? {
    let once = RunOnce()
    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T?, Error>) in
        Task {
            do { let v = try await op(); once.run { cont.resume(returning: v) } } catch { once.run { cont.resume(throwing: error) } }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            once.run { cont.resume(returning: nil) }
        }
    }
}
