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
        case "lead": return ("Voce solista", "music.mic.circle", 1)
        case "backing": return ("Cori", "person.3.fill", 2)
        case "drums": return ("Batteria", "metronome.fill", 3)
        case "bass": return ("Basso", "guitars", 10)
        case "guitar": return ("Chitarra", "guitars.fill", 11)
        case "piano": return ("Pianoforte", "pianokeys", 12)
        case "other": return ("Altri strumenti", "music.quarternote.3", 13)
        // Le parti della batteria (DrumSep), subito dopo la batteria
        case "kick": return ("Cassa", "circle.fill", 4)
        case "snare": return ("Rullante", "circle.dashed", 5)
        case "toms": return ("Tom", "circle.circle", 6)
        case "hh": return ("Charleston", "sparkle", 7)
        case "ride": return ("Ride", "circle.and.line.horizontal", 8)
        case "crash": return ("Crash", "burst.fill", 9)
        case "instrumental": return ("Base (senza voce)", "headphones", 20)
        default: return (key.capitalized, "waveform", 21)
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
    /// La traccia di cui si stanno cercando le note (MIDI), e i file MIDI già creati per questa canzone.
    @Published private(set) var midiWorking: String?
    @Published private(set) var midiFiles: [String: URL] = [:]
    @Published private(set) var midiError: String?

    /// Le tracce che hanno note da trascrivere (la batteria no: non ha altezze).
    var midiStems: [Stem] {
        stems.filter { ["vocals", "lead", "backing", "bass", "guitar", "piano", "other"].contains($0.key) }
    }

    /// Le note di una traccia in un file MIDI accanto alle tracce, al tempo della canzone.
    func makeMidi(_ stem: Stem) {
        guard midiWorking == nil, let dir = folder else { return }
        if let done = midiFiles[stem.key] { NSWorkspace.shared.activateFileViewerSelecting([done]); return }
        midiWorking = stem.key
        midiError = nil
        let title = self.title, bpm = analysis?.bpm ?? 120
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let audio = try AudioIO.read(stem.url)
                let notes = try MidiTranscriber.bundled().transcribe(audio)
                let url = dir.appendingPathComponent("\(title) – \(stem.name).mid")
                try MidiFile.data(notes, bpm: bpm, program: MidiFile.program(for: stem.key), name: "\(title) – \(stem.name)")
                    .write(to: url, options: .atomic)
                await self?.midiDone(stem.key, url, folder: dir)
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await self?.midiFailed(msg, folder: dir)
            }
        }
    }

    private func midiDone(_ key: String, _ url: URL, folder dir: URL) {
        midiWorking = nil
        guard folder == dir else { return }
        midiFiles[key] = url
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func midiFailed(_ msg: String, folder dir: URL) {
        midiWorking = nil
        if folder == dir { midiError = msg }
    }

    /// Tempo e tonalità della canzone separata.
    @Published private(set) var analysis: SongAnalysis?
    /// La divisione in più in corso (batteria o voce), e a che punto è (0…1).
    @Published private(set) var splitting: ExtraSplit?
    @Published private(set) var splitProgress: Double = 0
    /// L'ultimo errore di ogni divisione in più.
    @Published private(set) var splitErrors: [ExtraSplit: String] = [:]
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

    /// Al lavoro: una separazione, oppure una divisione in più (batteria, voce e cori).
    /// Aggiornare l'app o eliminare i modelli aspetta che abbia finito.
    var isWorking: Bool { isBusy || splitting != nil }

    /// La divisione in più in corso: il suo Annulla, e un segno per riconoscerla quando finisce.
    private var splitCancel = Cancel()
    private var splitToken = UUID()

    /// Ferma la divisione in più in corso (se c'è): cambiando canzone non ha più senso.
    func cancelSplit() {
        guard splitting != nil else { return }
        splitCancel.set()
        splitToken = UUID()
        splitting = nil
    }

    /// Bandierina condivisa con il lavoro in corso, per fermarlo.
    final class Cancel: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    /// La qualità scelta per ogni canzone in coda (quella del momento in cui è stata aggiunta).
    private var queuedQuality: [URL: Quality] = [:]

    /// Più canzoni insieme: la prima parte subito, le altre aspettano in coda.
    func enqueue(_ urls: [URL], quality: Quality = .current) {
        let songs = urls.filter { $0.isFileURL }
        guard let first = songs.first else { return }
        for s in songs { queuedQuality[s] = quality }
        if isBusy {
            queue += songs
        } else {
            queue += songs.dropFirst()
            start(first, quality: quality)
        }
    }

    func clearQueue() { queue = []; queuedQuality = [:] }

    func start(_ url: URL, quality: Quality = .current) {
        guard !isBusy else { queue.append(url); queuedQuality[url] = quality; return }
        cancelSplit()
        splitErrors = [:]
        queuedQuality[url] = nil
        midiFiles = [:]
        midiError = nil
        song = url
        title = url.deletingPathExtension().lastPathComponent
        stems = []
        folder = nil
        remaining = nil
        mixPeaks = []
        duration = 0
        elapsed = nil
        engineText = nil
        analysis = nil
        timings = []
        sourceInfo = AudioIO.describe(url)
        self.quality = quality
        let models = quality.models
        let wantedVoice = quality.voiceModel
        let wantedInstruments = quality.instrumentModel
        let split = Prefs.splitGuitarPiano
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
                var swName = wantedInstruments
                var bassName = quality.bassModel
                for (k, name) in downloads.enumerated() {
                    do {
                        _ = try await ModelStore.shared.mlModel(name) { p in
                            let total = (Double(k) + p) / Double(downloads.count)
                            Task { @MainActor in if case .downloading = self?.phase { self?.phase = .downloading(total) } }
                        }
                        if name == wantedVoice || name == wantedInstruments { _ = try await ModelStore.shared.config(name) }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch _ where cancel.isSet {
                        throw CancellationError()
                    } catch _ where name == wantedVoice {
                        // Il modello voce non è disponibile: si prova quello più leggero, altrimenti si separa senza
                        voiceName = nil
                        var next = Quality.fallbackVoice(for: name)
                        while let n = next, voiceName == nil {
                            if (try? await ModelStore.shared.mlModel(n) { _ in }) != nil,
                               (try? await ModelStore.shared.config(n)) != nil { voiceName = n }
                            next = Quality.fallbackVoice(for: n)
                        }
                    } catch _ where name == quality.bassModel {
                        // Il basso di Demucs è un di più: senza, resta quello di SW
                        bassName = nil
                    } catch _ where name == wantedInstruments {
                        // Il modello strumenti non è disponibile: si usano i modelli Demucs di riserva,
                        // scaricati qui con la loro barra (non in silenzio durante la prova del motore)
                        swName = nil
                        let reserve = voiceName == nil ? models : models.filter { $0 != Quality.voiceSpecialist }
                        for (j, m) in reserve.enumerated() {
                            _ = try await ModelStore.shared.mlModel(m) { p in
                                let total = (Double(j) + p) / Double(reserve.count)
                                Task { @MainActor in if case .downloading = self?.phase { self?.phase = .downloading(total) } }
                            }
                            if cancel.isSet { throw CancellationError() }
                        }
                    }
                    if cancel.isSet { throw CancellationError() }
                }
                lap("Preparazione dei modelli")
                await self?.set(.reading)
                var mix = try AudioIO.read(url)
                guard mix[0].count >= Int(AudioIO.sampleRate) else { throw SeparationError("la canzone è troppo corta (almeno 1 secondo)") }
                let seconds = Double(mix[0].count) / AudioIO.sampleRate
                await self?.loaded(peaks: Peaks.of(mix), duration: seconds)
                lap("Lettura della canzone")

                // Con il modello voce a parte, il Demucs specializzato nella voce non serve: un passaggio in meno
                // Con il modello strumenti SW i modelli Demucs non servono affatto
                let instrumentModels = swName != nil ? [] : voiceName == nil ? models : models.filter { $0 != Quality.voiceSpecialist }

                // 2. Il motore: deciso una volta per modello su questo Mac
                var decisions: [String: EngineChoice.Decision] = [:]
                for name in instrumentModels + (swName == nil ? [] : [bassName].compactMap { $0 }) {
                    if let d = EngineChoice.stored(name) { decisions[name] = d; continue }
                    await self?.set(.tuning)
                    let d = try await SeparationJob.tune(name, mix: mix)
                    EngineChoice.store(d, for: name)
                    decisions[name] = d
                    if cancel.isSet { throw CancellationError() }
                }
                for v in [voiceName, swName].compactMap({ $0 }) where EngineChoice.stored(v) == nil {
                    await self?.set(.tuning)
                    EngineChoice.store(try await SeparationJob.tuneRoFormer(v, mix: mix), for: v)
                    if cancel.isSet { throw CancellationError() }
                }
                lap("Prova del motore")

                // 3. La voce, con il suo modello (se questa qualità ne ha uno)
                await self?.set(.separating(0))
                let began = Date()
                // Quanta parte della barra spetta alla voce
                let voiceShare = voiceName == nil ? 0.0 : swName == nil ? 0.35 : 0.45
                func report(_ total: Double) {
                    let elapsed = Date().timeIntervalSince(began)
                    let left: Double? = total > 0.02 ? elapsed / total * (1 - total) : nil
                    Task { @MainActor in
                        // Un aggiornamento in ritardo non deve riaprire una separazione già finita o annullata
                        guard case .separating = self?.phase else { return }
                        self?.phase = .separating(total)
                        self?.remaining = left
                    }
                }
                var voiceOut: [[Float]]?
                var instrumentsInput = mix
                if let v = voiceName {
                    var d = EngineChoice.stored(v) ?? EngineChoice.decide(agreement: 99)
                    // Il modello voce davvero usato: se quello scelto non riesce si passa al più leggero
                    var used = v
                    func runVoice(_ units: MLComputeUnits) async throws -> [[Float]] {
                        do {
                            let (voice, helpers) = try await SeparationJob.workers(used, units: units)
                            voice.overlap = Prefs.voiceOverlapValue
                            return try voice.separate(mix, helpers: helpers, progress: { report($0 * voiceShare) }, isCancelled: { cancel.isSet })
                        } catch let e where !(e is ImplausibleResult) && !(e is CancellationError) && !cancel.isSet
                                    && Quality.fallbackVoice(for: used) != nil {
                            // Il modello voce non riesce (memoria, Mac più vecchio): si usa quello più leggero
                            used = Quality.fallbackVoice(for: used)!
                            if let stored = EngineChoice.stored(used) { d = stored }
                            return try await runVoice(d.units)
                        }
                    }
                    let vo: [[Float]]
                    do { vo = try await runVoice(d.units) } catch is ImplausibleResult {
                        do { vo = try await runVoice(.cpuAndGPU) } catch is ImplausibleResult {
                            throw SeparationError("il calcolo su questo Mac dà risultati sbagliati")
                        }
                        // 0: il Neural Engine qui ha dato un risultato sbagliato, si resta sulla grafica
                        d = EngineChoice.Decision(units: .cpuAndGPU, agreement: 0)
                        EngineChoice.store(d, for: used)
                    }
                    decisions[used] = d
                    voiceOut = vo
                    // Gli strumenti si cercano nella base senza voce: ogni modello fa quello in cui è migliore
                    instrumentsInput = (0..<2).map { c in zip(mix[c], vo[c]).map { $0 - $1 } }
                    // La canzone intera non serve più: con le canzoni lunghe sono centinaia di MB in meno
                    mix = []
                    lap("Voce (RoFormer)")
                }

                // 4. Gli strumenti: con SW un modello solo per tutti; con htdemucs_ft ogni modello dà il suo strumento
                var out: [[[Float]]] = []
                var sources: [String] = []
                // Quanta parte della barra degli strumenti spetta a SW (il resto al basso di Demucs, se c'è)
                let swShare = bassName == nil ? 1.0 : 0.85
                if let w = swName {
                    var d = EngineChoice.stored(w) ?? EngineChoice.decide(agreement: 99)
                    let input = instrumentsInput
                    func runSW(_ units: MLComputeUnits) async throws -> (names: [String], audio: [[[Float]]]) {
                        let (model, helpers) = try await SeparationJob.workers(w, units: units)
                        model.overlap = Prefs.instrumentOverlap
                        let audio = try model.separateAll(input, helpers: helpers, progress: { report(voiceShare + (1 - voiceShare) * swShare * $0) },
                                                          isCancelled: { cancel.isSet })
                        return (model.config.sources, audio)
                    }
                    var res: (names: [String], audio: [[[Float]]])
                    do { res = try await runSW(d.units) } catch is ImplausibleResult {
                        do { res = try await runSW(.cpuAndGPU) } catch is ImplausibleResult {
                            throw SeparationError("il calcolo su questo Mac dà risultati sbagliati")
                        }
                        d = EngineChoice.Decision(units: .cpuAndGPU, agreement: 0)
                        EngineChoice.store(d, for: w)
                    }
                    decisions[w] = d
                    (sources, out) = SeparationJob.arrange(res.names, res.audio, voice: voiceOut, split: split)
                    lap("Strumenti (BS-RoFormer SW)")

                    // In Studio il basso dal Demucs specializzato, sulla stessa base: più pieno e più pulito di quello di SW
                    if let b = bassName, let i = sources.firstIndex(of: "bass"), let d = decisions[b] {
                        func run(_ core: CoreMLSeparationCore) throws -> [[[Float]]] {
                            try Separator(core: core).separate(input, progress: { p in
                                report(voiceShare + (1 - voiceShare) * (swShare + (1 - swShare) * p))
                            }, isCancelled: { cancel.isSet })
                        }
                        // Un di più: se il modello non si carica o il calcolo non riesce, resta il basso di SW
                        var result: [[[Float]]]?
                        var bassSources: [String] = []
                        for units in d.units == .cpuAndGPU ? [MLComputeUnits.cpuAndGPU] : [d.units, .cpuAndGPU] where result == nil {
                            guard let core = try? await ModelStore.shared.load(b, units: units, progress: { _ in }) else { continue }
                            do {
                                result = try run(core)
                                bassSources = core.sources
                                if units != d.units { EngineChoice.store(EngineChoice.Decision(units: .cpuAndGPU, agreement: 0), for: b) }
                            } catch is CancellationError { throw CancellationError() } catch {}
                        }
                        if cancel.isSet { throw CancellationError() }
                        // Se il calcolo non riesce resta il basso di SW
                        if let r = result, let j = bassSources.firstIndex(of: "bass") { out[i] = r[j] }
                        lap("Basso (Demucs)")
                    }
                }
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
                        let d = EngineChoice.Decision(units: .cpuAndGPU, agreement: 0)
                        EngineChoice.store(d, for: name)
                        decisions[name] = d
                    }
                    if sources.isEmpty { sources = core.sources }
                    Separator.merge(&out, result, sources: core.sources, specialty: core.specialty)
                }
                if !instrumentModels.isEmpty {
                    if let vo = voiceOut, let i = sources.firstIndex(of: "vocals") { out[i] = vo }
                    lap(instrumentModels.count > 1 ? "Strumenti (\(instrumentModels.count) modelli Demucs)" : "Separazione (Demucs)")
                }
                let took = Date().timeIntervalSince(began)

                await self?.set(.saving)
                // La base è esattamente la canzone meno la voce: con la voce a parte è già pronta;
                // con SW da solo (Massima) si toglie dalla canzone la voce di SW
                var base: [[Float]]? = voiceOut == nil ? nil : instrumentsInput
                if base == nil, swName != nil, !mix.isEmpty, let v = sources.firstIndex(of: "vocals") {
                    base = (0..<2).map { c in zip(mix[c], out[v][c]).map { $0 - $1 } }
                }
                let (dir, stems) = try SeparationJob.save(out, sources: sources, song: url, base: base)
                // Se anche un solo modello ha dovuto usare la grafica, si dice quello
                let engine = (decisions.values.first(where: { $0.units != .all }) ?? decisions.values.first!).text
                lap("Salvataggio")
                // Il file per DJ, se scelto nelle Impostazioni: se non riesce, le tracce restano comunque
                if Prefs.makeStemFile {
                    _ = try? await StemFile.make(stems: stems, song: url, folder: dir, title: url.deletingPathExtension().lastPathComponent)
                    lap("File per DJ (.stem.mp4)")
                }
                let analysis = Analysis.analyze(out, sources: sources)
                lap("Tempo e tonalità")
                let all = times
                await self?.finish(dir: dir, stems: stems, engine: engine, took: took, timings: all, analysis: analysis)
            } catch is CancellationError {
                await self?.stopped(clearing: true)
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await self?.set(.failed(msg))
                await self?.afterFailure()
            }
        }
    }

    /// Questo Mac ha il Neural Engine (i Mac con chip Apple sì, quelli Intel no).
    nonisolated static let hasNeuralEngine: Bool = MLComputeDevice.allComputeDevices.contains {
        if case .neuralEngine = $0 { return true } else { return false }
    }

    /// Le copie di un modello RoFormer che lavorano insieme sui pezzi della canzone: una sul Neural Engine
    /// e una sulla grafica, se il Neural Engine è affidabile su questo Mac; altrimenti una sola, dove deciso.
    nonisolated static func workers(_ name: String, units: MLComputeUnits) async throws -> (RoFormer, [RoFormer]) {
        if units == .all && hasNeuralEngine && Prefs.dualEngine {
            let ane = try await ModelStore.shared.roformer(name, units: .cpuAndNeuralEngine) { _ in }
            let gpu = try await ModelStore.shared.roformer(name, units: .cpuAndGPU) { _ in }
            return (ane, [gpu])
        }
        return (try await ModelStore.shared.roformer(name, units: units) { _ in }, [])
    }

    /// Come `tune`, per i modelli RoFormer: un pezzo dal centro della canzone su Neural Engine e su grafica.
    nonisolated static func tuneRoFormer(_ name: String, mix: [[Float]]) async throws -> EngineChoice.Decision {
        let ane = try await ModelStore.shared.roformer(name, units: .all) { _ in }
        let gpu = try await ModelStore.shared.roformer(name, units: .cpuAndGPU) { _ in }
        let chunk = ane.config.chunk
        let start = max(0, (mix[0].count - chunk) / 2)
        let piece = (0..<2).map { c in (0..<chunk).map { i in start + i < mix[c].count ? mix[c][start + i] : 0 } }
        let a = try ane.runChunkAll(piece), b = try gpu.runChunkAll(piece)
        guard RoFormer.plausible(piece: piece, stems: b) else { return EngineChoice.Decision(units: .all, agreement: 0) }
        return EngineChoice.decide(agreement: Separator.agreement(b, a))
    }

    /// Le tracce finali dagli strumenti di SW: la voce dal suo modello (se c'è), chitarra e pianoforte
    /// in tracce proprie oppure dentro «Altri strumenti». La voce che SW trova nella base (residui) si scarta.
    nonisolated static func arrange(_ names: [String], _ audio: [[[Float]]], voice: [[Float]]?, split: Bool) -> ([String], [[[Float]]]) {
        func get(_ k: String) -> [[Float]]? { names.firstIndex(of: k).map { audio[$0] } }
        func sum(_ parts: [[[Float]]]) -> [[Float]] {
            var o = parts[0]
            for p in parts.dropFirst() { for c in 0..<2 { for i in o[c].indices { o[c][i] += p[c][i] } } }
            return o
        }
        var keys: [String] = [], out: [[[Float]]] = []
        if let v = voice ?? get("vocals") { keys.append("vocals"); out.append(v) }
        for k in ["drums", "bass"] { if let a = get(k) { keys.append(k); out.append(a) } }
        let extras = ["guitar", "piano"].filter { get($0) != nil }
        if split {
            for k in extras { keys.append(k); out.append(get(k)!) }
            if let o = get("other") { keys.append("other"); out.append(o) }
        } else {
            let parts = (["other"] + extras).compactMap(get)
            if !parts.isEmpty { keys.append("other"); out.append(sum(parts)) }
        }
        return (keys, out)
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
        cancelSplit()
        splitErrors = [:]
        analysis = nil
        midiFiles = [:]
        midiError = nil
        song = nil
        timings = []
        sourceInfo = nil
        title = item.title
        folder = item.folderURL
        quality = Quality(rawValue: item.quality) ?? .best
        engineText = item.engine
        analysis = item.analysis
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

    /// Si può dividere ancora una traccia: c'è, non è già divisa e nessun'altra divisione è in corso.
    func canSplit(_ kind: ExtraSplit) -> Bool {
        phase == .done && splitting == nil && stems.contains { $0.key == kind.source } && !stems.contains { kind.parts.contains($0.key) }
    }

    /// Divide una traccia nelle sue parti (la batteria in cassa, rullante…; la voce in solista e cori), accanto alle altre.
    func split(_ kind: ExtraSplit) {
        guard canSplit(kind), let source = stems.first(where: { $0.key == kind.source }), let dir = folder else { return }
        splitting = kind
        splitProgress = 0
        splitErrors[kind] = nil
        let title = self.title, format = Prefs.format, cancel = Cancel(), token = UUID()
        splitCancel = cancel
        splitToken = token
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let audio = try AudioIO.read(source.url)
                func run(_ units: MLComputeUnits) async throws -> (names: [String], parts: [[[Float]]]) {
                    try await kind.run(audio, units: units, progress: { p in
                        Task { @MainActor in if self?.splitToken == token { self?.splitProgress = p } }
                    },
                                       isCancelled: { cancel.isSet })
                }
                var res: (names: [String], parts: [[[Float]]])
                do { res = try await run(EngineChoice.stored(kind.modelName)?.units ?? .all) } catch is ImplausibleResult {
                    res = try await run(.cpuAndGPU)
                    EngineChoice.store(EngineChoice.Decision(units: .cpuAndGPU, agreement: 0), for: kind.modelName)
                }
                let measures = res.parts.map(Stem.measure)
                let gain = Stem.safeGain(peaks: measures.map(\.peak))
                var made: [Stem] = []
                for (k, key) in res.names.enumerated() where kind.parts.contains(key) {
                    let info = Stem.info(key)
                    let url = dir.appendingPathComponent("\(title) – \(info.name).\(format.fileExtension)")
                    try AudioIO.write(res.parts[k], to: url, format: format, gain: gain)
                    made.append(Stem(key: key, name: info.name, symbol: info.symbol, url: url, peaks: Peaks.of(res.parts[k]),
                                     share: nil, peakDB: measures[k].peakDB + (gain < 1 ? 20 * log10(Double(gain)) : 0),
                                     balance: measures[k].balance,
                                     gainDB: gain < 1 ? 20 * log10(Double(gain)) : 0))
                }
                await self?.splitDone(made, folder: dir, token: token)
            } catch is CancellationError {
                await self?.splitDone([], folder: dir, token: token)
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await self?.splitFailed(kind, msg, token: token)
            }
        }
    }

    private func splitDone(_ parts: [Stem], folder dir: URL, token: UUID) {
        // Una divisione annullata (o di un'altra canzone) che arriva tardi non tocca niente
        guard token == splitToken else { return }
        splitting = nil
        guard folder == dir, !parts.isEmpty else { return }
        stems = (stems + parts).sorted { Stem.info($0.key).order < Stem.info($1.key).order }
        if Prefs.soundWhenDone { NSSound(named: "Glass")?.play() }
    }

    private func splitFailed(_ kind: ExtraSplit, _ msg: String, token: UUID) {
        guard token == splitToken else { return }
        splitting = nil
        splitErrors[kind] = msg
    }

    /// Svuota la cronologia (i file restano nella cartella delle tracce).
    func clearHistory() {
        History.clear()
        history = []
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
        let q = queuedQuality.removeValue(forKey: next) ?? quality
        // Un attimo per vedere il risultato della canzone appena finita
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.start(next, quality: q) }
    }

    func reset() {
        guard !isBusy else { return }
        cancelSplit()
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

    /// Per le schermate di prova (ScreenshotTests): mostra una separazione finita senza farla davvero.
    func showcase(title: String, stems: [Stem], folder: URL, quality: Quality, duration: Double,
                  analysis: SongAnalysis?, elapsed: Double, engine: String, timings: [Timing]) {
        self.title = title
        self.stems = stems
        self.folder = folder
        self.quality = quality
        self.duration = duration
        self.analysis = analysis
        self.elapsed = elapsed
        self.engineText = engine
        self.timings = timings
        phase = .done
    }

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

    private func finish(dir: URL, stems: [Stem], engine: String, took: Double, timings: [Timing], analysis: SongAnalysis?) {
        self.analysis = analysis
        engineText = engine
        elapsed = took
        self.timings = timings
        folder = dir
        self.stems = stems
        phase = .done
        remaining = nil
        if Prefs.soundWhenDone { NSSound(named: "Glass")?.play() }
        if Prefs.revealWhenDone { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
        History.add(song: song, folder: dir, quality: quality, duration: duration, seconds: took, engine: engine, analysis: analysis)
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
