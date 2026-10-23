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
    /// Forma d'onda (0…1) per il disegno.
    var peaks: [Float] = []
    var id: String { key }

    /// Nomi italiani e simboli dei quattro strumenti di Demucs (più la base senza voce).
    static func info(_ key: String) -> (name: String, symbol: String, order: Int) {
        switch key {
        case "vocals": return ("Voce", "music.mic", 0)
        case "drums": return ("Batteria", "metronome.fill", 1)
        case "bass": return ("Basso", "guitars", 2)
        case "guitar": return ("Chitarra", "guitars.fill", 3)
        case "piano": return ("Pianoforte", "pianokeys", 4)
        case "other": return ("Altri strumenti", "music.quarternote.3", 5)
        case "instrumental": return ("Base (senza voce)", "headphones", 6)
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
        /// Prima volta con un modello: provo Neural Engine e grafica su un pezzo
        case tuning
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
    /// Forma d'onda della canzone, appena letta.
    @Published private(set) var mixPeaks: [Float] = []
    /// Durata della canzone in secondi.
    @Published private(set) var duration: Double = 0
    /// La qualità della separazione in corso (o dell'ultima).
    @Published private(set) var quality: Quality = .best
    /// Dove ha lavorato l'ultima separazione (Neural Engine o grafica), con la verifica.
    @Published private(set) var engineText: String?
    /// Quanto ci ha messo l'ultima separazione, in secondi.
    @Published private(set) var elapsed: Double?

    private var task: Task<Void, Never>?
    private var cancelled = Cancel()

    var isBusy: Bool {
        switch phase {
        case .downloading, .reading, .tuning, .separating, .saving: return true
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

    func start(_ url: URL, quality: Quality = .current) {
        guard !isBusy else { return }
        song = url
        stems = []
        folder = nil
        remaining = nil
        mixPeaks = []
        duration = 0
        elapsed = nil
        engineText = nil
        self.quality = quality
        let models = quality.models
        phase = models.allSatisfy { ModelStore.shared.isReady($0) } ? .reading : .downloading(0)
        let cancel = Cancel()
        cancelled = cancel
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                // 1. I modelli (la prima volta si scaricano: un'unica barra per tutti)
                for (k, name) in models.enumerated() {
                    _ = try await ModelStore.shared.load(name) { p in
                        let total = (Double(k) + p) / Double(models.count)
                        Task { @MainActor in self?.phase = .downloading(total) }
                    }
                }
                await self?.set(.reading)
                let mix = try AudioIO.read(url)
                guard mix[0].count >= Int(AudioIO.sampleRate) else { throw SeparationError("la canzone è troppo corta (almeno 1 secondo)") }
                let seconds = Double(mix[0].count) / AudioIO.sampleRate
                await self?.loaded(peaks: Peaks.of(mix), duration: seconds)

                // 2. Il motore: deciso una volta per modello su questo Mac
                var decisions: [String: EngineChoice.Decision] = [:]
                for name in models {
                    if let d = EngineChoice.stored(name) { decisions[name] = d; continue }
                    await self?.set(.tuning)
                    let d = try await SeparationJob.tune(name, mix: mix)
                    EngineChoice.store(d, for: name)
                    decisions[name] = d
                    if cancel.isSet { throw CancellationError() }
                }

                // 3. La separazione: con htdemucs_ft ogni modello dà il suo strumento
                await self?.set(.separating(0))
                let began = Date()
                var out: [[[Float]]] = []
                var sources: [String] = []
                for (k, name) in models.enumerated() {
                    let span = (Double(k), Double(k + 1))
                    func run(_ core: CoreMLSeparationCore) throws -> [[[Float]]] {
                        try Separator(core: core).separate(mix, progress: { p in
                            let total = (span.0 + p) / Double(models.count)
                            let elapsed = Date().timeIntervalSince(began)
                            let left: Double? = total > 0.02 ? elapsed / total * (1 - total) : nil
                            Task { @MainActor in
                                self?.phase = .separating(total)
                                self?.remaining = left
                            }
                        }, isCancelled: { cancel.isSet })
                    }
                    var core = try await ModelStore.shared.load(name, units: decisions[name]!.units) { _ in }
                    let result: [[[Float]]]
                    do {
                        result = try run(core)
                    } catch is ImplausibleResult {
                        // Il calcolo ha sbagliato: si riprova solo con grafica e processore, e lo si ricorda
                        core = try await ModelStore.shared.load(name, units: .cpuAndGPU) { _ in }
                        do { result = try run(core) } catch is ImplausibleResult {
                            throw SeparationError("il calcolo su questo Mac dà risultati sbagliati")
                        }
                        let d = EngineChoice.Decision(units: .cpuAndGPU, agreement: decisions[name]!.agreement)
                        EngineChoice.store(d, for: name)
                        decisions[name] = d
                    }
                    if sources.isEmpty { sources = core.sources }
                    Separator.merge(&out, result, sources: core.sources, specialty: core.specialty)
                }
                let took = Date().timeIntervalSince(began)

                await self?.set(.saving)
                let (dir, stems) = try SeparationJob.save(out, sources: sources, song: url)
                // Se anche un solo modello ha dovuto usare la grafica, si dice quello
                let engine = (decisions.values.first(where: { $0.units != .all }) ?? decisions.values.first!).text
                await self?.finish(dir: dir, stems: stems, engine: engine, took: took)
            } catch is CancellationError {
                await self?.set(.idle)
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await self?.set(.failed(msg))
            }
        }
    }

    /// Prova Neural Engine e grafica sul pezzo centrale della canzone e decide dove lavorare.
    nonisolated static func tune(_ name: String, mix: [[Float]]) async throws -> EngineChoice.Decision {
        let ane = try await ModelStore.shared.load(name, units: .all) { _ in }
        let gpu = try await ModelStore.shared.load(name, units: .cpuAndGPU) { _ in }
        let norm = Separator.normalized(mix).norm
        let offset = max(0, (mix[0].count - ane.segment) / 2)
        let piece = Separator.piece(norm, offset: offset, segment: ane.segment)
        let a = try Separator(core: ane).runSegment(piece)
        let b = try Separator(core: gpu).runSegment(piece)
        // Conta solo lo strumento in cui il modello è specializzato (con htdemucs_ft le altre tracce sono di scarto)
        let keep = gpu.specialty.compactMap { gpu.sources.firstIndex(of: $0) }
        // Se nemmeno la grafica dà un risultato coerente, si lascia decidere al controllo durante la separazione
        guard Separator.plausible(piece: piece, result: b, keep: keep) else { return EngineChoice.Decision(units: .all, agreement: 0) }
        return EngineChoice.decide(agreement: Separator.agreement(keep.map { b[$0] }, keep.map { a[$0] }))
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
        mixPeaks = []
        duration = 0
    }

    private func set(_ p: Phase) { phase = p }

    private func loaded(peaks: [Float], duration: Double) {
        mixPeaks = peaks
        self.duration = duration
    }

    private func finish(dir: URL, stems: [Stem], engine: String, took: Double) {
        engineText = engine
        elapsed = took
        folder = dir
        self.stems = stems
        phase = .done
        remaining = nil
        NSSound(named: "Glass")?.play()
    }

    /// Un WAV per strumento, più la base senza voce, in Musica/AudioLR/<canzone>/.
    nonisolated static func save(_ out: [[[Float]]], sources: [String], song: URL,
                                 into root: URL = Paths.output) throws -> (URL, [Stem]) {
        let fm = FileManager.default
        let title = song.deletingPathExtension().lastPathComponent
        var dir = root.appendingPathComponent(title, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: dir.path) {
            dir = root.appendingPathComponent("\(title) \(n)", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var stems: [Stem] = []
        for (i, key) in sources.enumerated() {
            let info = Stem.info(key)
            let url = dir.appendingPathComponent("\(title) – \(info.name).wav")
            try AudioIO.writeWAV(out[i], to: url)
            stems.append(Stem(key: key, name: info.name, symbol: info.symbol, url: url, peaks: Peaks.of(out[i])))
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
            stems.append(Stem(key: "instrumental", name: info.name, symbol: info.symbol, url: url, peaks: Peaks.of(base)))
        }
        stems.sort { Stem.info($0.key).order < Stem.info($1.key).order }
        return (dir, stems)
    }
}
