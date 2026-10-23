import Foundation
import AppKit

// ════════════════════════════════════════════════════════════════════
//  Il lavoro su una canzone: modello → lettura → separazione → file WAV.
//  La finestra osserva questo oggetto e mostra a che punto è.
// ════════════════════════════════════════════════════════════════════

/// Uno strumento separato, pronto da ascoltare.
struct Stem: Identifiable, Equatable {
    let key: String
    let name: String
    let symbol: String
    let url: URL
    var id: String { key }

    /// Nomi italiani e simboli dei quattro strumenti di Demucs (più la base senza voce).
    static func info(_ key: String) -> (name: String, symbol: String, order: Int) {
        switch key {
        case "vocals": return ("Voce", "music.mic", 0)
        case "drums": return ("Batteria", "circle.circle", 1)
        case "bass": return ("Basso", "guitars", 2)
        case "guitar": return ("Chitarra", "guitars.fill", 3)
        case "piano": return ("Pianoforte", "pianokeys", 4)
        case "other": return ("Altri strumenti", "music.note", 5)
        case "instrumental": return ("Base (senza voce)", "music.quarternote.3", 6)
        default: return (key.capitalized, "waveform", 7)
        }
    }
}

@MainActor
final class SeparationJob: ObservableObject {
    static let shared = SeparationJob()

    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case reading
        case separating(Double)
        case saving
        case done
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var song: URL?
    @Published private(set) var stems: [Stem] = []
    @Published private(set) var folder: URL?
    /// Secondi che mancano alla fine della separazione (nil finché non si può stimare).
    @Published private(set) var remaining: Double?

    private var task: Task<Void, Never>?
    private var cancelled = Cancel()

    var isBusy: Bool {
        switch phase {
        case .downloading, .reading, .separating, .saving: return true
        default: return false
        }
    }

    /// Bandierina condivisa con il lavoro in corso, per fermarlo.
    final class Cancel: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    func start(_ url: URL) {
        guard !isBusy else { return }
        song = url
        stems = []
        folder = nil
        remaining = nil
        phase = ModelStore.shared.isReady ? .reading : .downloading(0)
        let cancel = Cancel()
        cancelled = cancel
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let core = try await ModelStore.shared.load { p in
                    Task { @MainActor in self?.phase = .downloading(p) }
                }
                await self?.set(.reading)
                let mix = try AudioIO.read(url)
                guard mix[0].count >= Int(AudioIO.sampleRate) else { throw SeparationError("la canzone è troppo corta (almeno 1 secondo)") }

                await self?.set(.separating(0))
                let began = Date()
                let separator = Separator(core: core)
                let out = try separator.separate(mix, progress: { p in
                    let elapsed = Date().timeIntervalSince(began)
                    let left: Double? = p > 0.02 ? elapsed / p * (1 - p) : nil
                    Task { @MainActor in
                        self?.phase = .separating(p)
                        self?.remaining = left
                    }
                }, isCancelled: { cancel.isSet })

                await self?.set(.saving)
                let (dir, stems) = try SeparationJob.save(out, sources: core.sources, song: url)
                await self?.finish(dir: dir, stems: stems)
            } catch is CancellationError {
                await self?.set(.idle)
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await self?.set(.failed(msg))
            }
        }
    }

    func cancel() {
        cancelled.set()
        task?.cancel()
    }

    func reset() {
        guard !isBusy else { return }
        phase = .idle
        song = nil
        stems = []
        folder = nil
    }

    private func set(_ p: Phase) { phase = p }

    private func finish(dir: URL, stems: [Stem]) {
        folder = dir
        self.stems = stems
        phase = .done
        remaining = nil
        NSSound(named: "Glass")?.play()
    }

    /// Un WAV per strumento, più la base senza voce, in Musica/AudioLR/<canzone>/.
    nonisolated static func save(_ out: [[[Float]]], sources: [String], song: URL) throws -> (URL, [Stem]) {
        let fm = FileManager.default
        let title = song.deletingPathExtension().lastPathComponent
        var dir = Paths.output.appendingPathComponent(title, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: dir.path) {
            dir = Paths.output.appendingPathComponent("\(title) \(n)", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var stems: [Stem] = []
        for (i, key) in sources.enumerated() {
            let info = Stem.info(key)
            let url = dir.appendingPathComponent("\(title) – \(info.name).wav")
            try AudioIO.writeWAV(out[i], to: url)
            stems.append(Stem(key: key, name: info.name, symbol: info.symbol, url: url))
        }
        // La base per il karaoke: tutto tranne la voce
        if let v = sources.firstIndex(of: "vocals"), sources.count > 1 {
            let length = out[0][0].count
            var base = [[Float]](repeating: [Float](repeating: 0, count: length), count: 2)
            for (i, _) in sources.enumerated() where i != v {
                for c in 0..<2 { for j in 0..<length { base[c][j] += out[i][c][j] } }
            }
            let info = Stem.info("instrumental")
            let url = dir.appendingPathComponent("\(title) – \(info.name).wav")
            try AudioIO.writeWAV(base, to: url)
            stems.append(Stem(key: "instrumental", name: info.name, symbol: info.symbol, url: url))
        }
        stems.sort { Stem.info($0.key).order < Stem.info($1.key).order }
        return (dir, stems)
    }
}
