import Foundation
import AppKit
import CoreML

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
    /// Quanta parte dell'energia della canzone è in questa traccia (0…1).
    var share: Double? = nil
    /// Il punto più forte della traccia, in dB (0 = il massimo possibile).
    var peakDB: Double? = nil
    /// Quanta energia sta a destra (0,5 = centrata): serve a scoprire un canale fuori posto.
    var balance: Double? = nil
    /// Di quanto è stato abbassato il volume di tutte le tracce per non distorcere (0 = per niente).
    var gainDB: Double = 0
    var id: String { key }

    /// Energia, picco e bilanciamento di una traccia stereo.
    static func measure(_ audio: [[Float]]) -> (energy: Double, peakDB: Double, peak: Float, balance: Double) {
        var e = [0.0, 0.0], p: Float = 0
        for (c, ch) in audio.prefix(2).enumerated() { for v in ch { e[c] += Double(v) * Double(v); p = max(p, abs(v)) } }
        let total = e[0] + e[1]
        return (total, p > 0 ? 20 * log10(Double(p)) : -120, p, total > 0 ? e[1] / total : 0.5)
    }

    /// Il più forte che una traccia può essere prima di tagliare: un filo sotto il massimo.
    static let ceiling: Float = 0.98

    /// Se anche una sola traccia supera il massimo, tutte si abbassano dello stesso tanto:
    /// niente suono «fritto» e le tracce restano in proporzione (sommate ridanno la canzone).
    static func safeGain(peaks: [Float]) -> Float {
        let top = peaks.max() ?? 0
        return top > ceiling ? ceiling / top : 1
    }

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
    /// Il titolo della canzone (anche quando si riapre una separazione dalla cronologia).
    @Published private(set) var title = ""
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
    /// Le canzoni che aspettano il loro turno (trascinate insieme, per esempio un album).
    @Published private(set) var queue: [URL] = []
    /// Le ultime separazioni, per riaprirle.
    @Published private(set) var history: [HistoryItem] = History.all()
    /// Dove ha lavorato l'ultima separazione (Neural Engine o grafica), con la verifica.
    @Published private(set) var engineText: String?
    /// Quanto ci ha messo l'ultima separazione, in secondi.
    @Published private(set) var elapsed: Double?
    /// Quanto è durata ogni fase dell'ultima separazione (per capire dove va il tempo).
    @Published private(set) var timings: [Timing] = []
    /// Il file di partenza: nome, formato, frequenza.
    @Published private(set) var sourceInfo: String?

    struct Timing: Identifiable, Equatable {
        let name: String
        let seconds: Double
        var id: String { name }
    }

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

    /// Più canzoni insieme: la prima parte subito, le altre aspettano in coda.
    func enqueue(_ urls: [URL], quality: Quality = .current) {
        let songs = urls.filter { $0.isFileURL }
        guard let first = songs.first else { return }
        if isBusy {
            queue += songs
        } else {
            queue += songs.dropFirst()
            start(first, quality: quality)
        }
    }

    func clearQueue() { queue = [] }

    func start(_ url: URL, quality: Quality = .current) {
        guard !isBusy else { queue.append(url); return }
        song = url
        title = url.deletingPathExtension().lastPathComponent
        stems = []
        folder = nil
        remaining = nil
        mixPeaks = []
        duration = 0
        elapsed = nil
        engineText = nil
        timings = []
        sourceInfo = AudioIO.describe(url)
        self.quality = quality
        let models = quality.models
        let wantedVoice = quality.voiceModel
        let downloads = quality.allModels
        phase = downloads.allSatisfy { ModelStore.shared.isReady($0) } ? .reading : .downloading(0)
        let cancel = Cancel()
        cancelled = cancel
        task = Task.detached(priority: .userInitiated) { [weak self] in
            // Cronometro delle fasi
            var times: [Timing] = []
            var clock = Date()
            func lap(_ name: String) {
                let now = Date()
                let d = now.timeIntervalSince(clock)
                if d >= 0.05 { times.append(Timing(name: name, seconds: d)) }
                clock = now
            }
            do {
                // 1. I modelli (la prima volta si scaricano: un'unica barra per tutti)
                var voiceName = wantedVoice
                for (k, name) in downloads.enumerated() {
                    do {
                        _ = try await ModelStore.shared.mlModel(name) { p in
                            let total = (Double(k) + p) / Double(downloads.count)
                            Task { @MainActor in self?.phase = .downloading(total) }
                        }
                        if name == wantedVoice { _ = try await ModelStore.shared.config(name) }
                    } catch _ where name == wantedVoice {
                        // Il modello voce non è ancora disponibile: si separa lo stesso, con i soli modelli Demucs
                        voiceName = nil
                    }
                }
                lap("Preparazione dei modelli")
                await self?.set(.reading)
                let mix = try AudioIO.read(url)
                guard mix[0].count >= Int(AudioIO.sampleRate) else { throw SeparationError("la canzone è troppo corta (almeno 1 secondo)") }
                let seconds = Double(mix[0].count) / AudioIO.sampleRate
                await self?.loaded(peaks: Peaks.of(mix), duration: seconds)
                lap("Lettura della canzone")

                // Con il modello voce a parte, il Demucs specializzato nella voce non serve: un passaggio in meno
                let instrumentModels = voiceName == nil ? models : models.filter { $0 != Quality.voiceSpecialist }

                // 2. Il motore: deciso una volta per modello su questo Mac
                var decisions: [String: EngineChoice.Decision] = [:]
                for name in instrumentModels {
                    if let d = EngineChoice.stored(name) { decisions[name] = d; continue }
                    await self?.set(.tuning)
                    let d = try await SeparationJob.tune(name, mix: mix)
                    EngineChoice.store(d, for: name)
                    decisions[name] = d
                    if cancel.isSet { throw CancellationError() }
                }
                if let v = voiceName, EngineChoice.stored(v) == nil {
                    await self?.set(.tuning)
                    EngineChoice.store(try await SeparationJob.tuneVoice(v, mix: mix), for: v)
                }
                lap("Prova del motore")

                // 3. La voce, con il suo modello (se questa qualità ne ha uno)
                await self?.set(.separating(0))
                let began = Date()
                // Quanta parte della barra spetta alla voce
                let voiceShare = voiceName == nil ? 0.0 : 0.35
                func report(_ total: Double) {
                    let elapsed = Date().timeIntervalSince(began)
                    let left: Double? = total > 0.02 ? elapsed / total * (1 - total) : nil
                    Task { @MainActor in
                        self?.phase = .separating(total)
                        self?.remaining = left
                    }
                }
                var voiceOut: [[Float]]?
                var instrumentsInput = mix
                if let v = voiceName {
                    var d = EngineChoice.stored(v) ?? EngineChoice.decide(agreement: 99)
                    func runVoice(_ units: MLComputeUnits) async throws -> [[Float]] {
                        do {
                            let voice = try await ModelStore.shared.voice(v, units: units) { _ in }
                            voice.overlap = Prefs.voiceOverlap
                            return try voice.separate(mix, progress: { report($0 * voiceShare) }, isCancelled: { cancel.isSet })
                        } catch let e where !(e is ImplausibleResult) && !(e is CancellationError) && v != Quality.lightVoice {
                            // Il modello da 8 s non riesce (memoria, Mac più vecchio): si usa quello leggero da 2 s
                            let voice = try await ModelStore.shared.voice(Quality.lightVoice, units: units) { _ in }
                            voice.overlap = Prefs.voiceOverlap
                            return try voice.separate(mix, progress: { report($0 * voiceShare) }, isCancelled: { cancel.isSet })
                        }
                    }
                    let vo: [[Float]]
                    do { vo = try await runVoice(d.units) } catch is ImplausibleResult {
                        do { vo = try await runVoice(.cpuAndGPU) } catch is ImplausibleResult {
                            throw SeparationError("il calcolo su questo Mac dà risultati sbagliati")
                        }
                        d = EngineChoice.Decision(units: .cpuAndGPU, agreement: d.agreement)
                        EngineChoice.store(d, for: v)
                    }
                    decisions[v] = d
                    voiceOut = vo
                    // Gli strumenti si cercano nella base senza voce: ogni modello fa quello in cui è migliore
                    instrumentsInput = (0..<2).map { c in zip(mix[c], vo[c]).map { $0 - $1 } }
                    lap("Voce (RoFormer)")
                }

                // 4. Gli strumenti: con htdemucs_ft ogni modello dà il suo strumento
                var out: [[[Float]]] = []
                var sources: [String] = []
                for (k, name) in instrumentModels.enumerated() {
                    let span = (Double(k), Double(k + 1))
                    let input = instrumentsInput
                    func run(_ core: CoreMLSeparationCore) throws -> [[[Float]]] {
                        try Separator(core: core).separate(input, progress: { p in
                            report(voiceShare + (1 - voiceShare) * (span.0 + p) / Double(instrumentModels.count))
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
                if let vo = voiceOut, let i = sources.firstIndex(of: "vocals") { out[i] = vo }
                lap(instrumentModels.count > 1 ? "Strumenti (\(instrumentModels.count) modelli Demucs)" : "Separazione (Demucs)")
                let took = Date().timeIntervalSince(began)

                await self?.set(.saving)
                // Con la voce a parte, la base è esattamente la canzone meno la voce
                let (dir, stems) = try SeparationJob.save(out, sources: sources, song: url,
                                                          base: voiceOut == nil ? nil : instrumentsInput)
                // Se anche un solo modello ha dovuto usare la grafica, si dice quello
                let engine = (decisions.values.first(where: { $0.units != .all }) ?? decisions.values.first!).text
                lap("Salvataggio")
                let all = times
                await self?.finish(dir: dir, stems: stems, engine: engine, took: took, timings: all)
            } catch is CancellationError {
                await self?.stopped(clearing: true)
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await self?.set(.failed(msg))
                await self?.afterFailure()
            }
        }
    }

    /// Come `tune`, per il modello voce: un pezzo dal centro della canzone su Neural Engine e su grafica.
    nonisolated static func tuneVoice(_ name: String, mix: [[Float]]) async throws -> EngineChoice.Decision {
        let ane = try await ModelStore.shared.voice(name, units: .all) { _ in }
        let gpu = try await ModelStore.shared.voice(name, units: .cpuAndGPU) { _ in }
        let chunk = ane.config.chunk
        let start = max(0, (mix[0].count - chunk) / 2)
        let piece = (0..<2).map { c in (0..<chunk).map { i in start + i < mix[c].count ? mix[c][start + i] : 0 } }
        let a = try ane.runChunk(piece), b = try gpu.runChunk(piece)
        guard VoiceRoFormer.plausible(piece: piece, voice: b) else { return EngineChoice.Decision(units: .all, agreement: 0) }
        return EngineChoice.decide(agreement: Separator.agreement([b], [a]))
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

    /// Riapre una separazione già fatta: le tracce si riascoltano senza rifare il lavoro.
    func open(_ item: HistoryItem) {
        guard !isBusy else { return }
        let found = History.stems(in: item.folderURL, title: item.title)
        guard !found.isEmpty else {
            History.remove(item)
            history = History.all()
            return
        }
        song = nil
        timings = []
        sourceInfo = nil
        title = item.title
        folder = item.folderURL
        quality = Quality(rawValue: item.quality) ?? .best
        engineText = item.engine
        elapsed = item.seconds
        stems = found.map { f in
            let info = Stem.info(f.key)
            return Stem(key: f.key, name: info.name, symbol: info.symbol, url: f.url)
        }
        duration = 0
        phase = .done
        // Le forme d'onda si calcolano dopo, senza far aspettare
        Task.detached(priority: .utility) { [weak self] in
            var withPeaks: [Stem] = []
            var seconds = 0.0
            for f in found {
                let info = Stem.info(f.key)
                let audio = (try? AudioIO.read(f.url)) ?? []
                if let n = audio.first?.count { seconds = max(seconds, Double(n) / AudioIO.sampleRate) }
                withPeaks.append(Stem(key: f.key, name: info.name, symbol: info.symbol, url: f.url, peaks: audio.isEmpty ? [] : Peaks.of(audio)))
            }
            await self?.reopened(withPeaks, duration: seconds, folder: item.folderURL)
        }
    }

    private func reopened(_ stems: [Stem], duration: Double, folder: URL) {
        guard phase == .done, self.folder == folder else { return }
        self.stems = stems
        self.duration = duration
    }

    func forget(_ item: HistoryItem) {
        History.remove(item)
        history = History.all()
    }

    func cancel() {
        cancelled.set()
        task?.cancel()
    }

    /// Finita una canzone (o andata male), si passa alla prossima in coda.
    private func startNextInQueue() {
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        let q = quality
        // Un attimo per vedere il risultato della canzone appena finita
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.start(next, quality: q) }
    }

    func reset() {
        guard !isBusy else { return }
        phase = .idle
        song = nil
        title = ""
        history = History.all()
        stems = []
        folder = nil
        mixPeaks = []
        duration = 0
    }

    private func set(_ p: Phase) { phase = p }

    /// Annullare ferma anche la coda.
    private func stopped(clearing: Bool) {
        if clearing { queue = [] }
        phase = .idle
        history = History.all()
    }

    /// Una canzone non riuscita non blocca le altre.
    private func afterFailure() { startNextInQueue() }

    private func loaded(peaks: [Float], duration: Double) {
        mixPeaks = peaks
        self.duration = duration
    }

    private func finish(dir: URL, stems: [Stem], engine: String, took: Double, timings: [Timing]) {
        engineText = engine
        elapsed = took
        self.timings = timings
        folder = dir
        self.stems = stems
        phase = .done
        remaining = nil
        if Prefs.soundWhenDone { NSSound(named: "Glass")?.play() }
        if Prefs.revealWhenDone { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
        History.add(song: song, folder: dir, quality: quality, duration: duration, seconds: took, engine: engine)
        history = History.all()
        startNextInQueue()
    }

    /// Un WAV per strumento, più la base senza voce, in Musica/AudioLR/<canzone>/.
    nonisolated static func save(_ out: [[[Float]]], sources: [String], song: URL,
                                 into root: URL = Prefs.folder, format: OutputFormat = Prefs.format,
                                 instrumental: Bool = Prefs.makeInstrumental,
                                 base given: [[Float]]? = nil) throws -> (URL, [Stem]) {
        let fm = FileManager.default
        let title = song.deletingPathExtension().lastPathComponent
        var dir = root.appendingPathComponent(title, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: dir.path) {
            dir = root.appendingPathComponent("\(title) \(n)", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // La base per il karaoke: tutto tranne la voce (o, con la voce a parte, la canzone meno la voce)
        var base: [[Float]]?
        if instrumental, let v = sources.firstIndex(of: "vocals"), sources.count > 1 {
            let length = out[0][0].count
            var b = given ?? [[Float]](repeating: [Float](repeating: 0, count: length), count: 2)
            if given == nil {
                for (i, _) in sources.enumerated() where i != v {
                    for c in 0..<2 { for j in 0..<length { b[c][j] += out[i][c][j] } }
                }
            }
            base = b
        }
        let measures = out.map(Stem.measure)
        let baseMeasure = base.map(Stem.measure)
        let gain = Stem.safeGain(peaks: measures.map(\.peak) + (baseMeasure.map { [$0.peak] } ?? []))
        let gainDB = gain < 1 ? 20 * log10(Double(gain)) : 0
        let total = max(measures.reduce(0) { $0 + $1.energy }, 1e-12)

        var stems: [Stem] = []
        func add(_ key: String, _ audio: [[Float]], _ m: (energy: Double, peakDB: Double, peak: Float, balance: Double)) throws {
            let info = Stem.info(key)
            let url = dir.appendingPathComponent("\(title) – \(info.name).\(format.fileExtension)")
            try AudioIO.write(audio, to: url, format: format, gain: gain)
            stems.append(Stem(key: key, name: info.name, symbol: info.symbol, url: url, peaks: Peaks.of(audio),
                              share: m.energy / total, peakDB: m.peakDB + gainDB, balance: m.balance, gainDB: gainDB))
        }
        for (i, key) in sources.enumerated() { try add(key, out[i], measures[i]) }
        if let b = base, let m = baseMeasure { try add("instrumental", b, m) }
        stems.sort { Stem.info($0.key).order < Stem.info($1.key).order }
        return (dir, stems)
    }
}
