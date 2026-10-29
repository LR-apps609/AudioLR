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
    /// Tutte le tracce che IsoLR può creare, nell'ordine della libreria.
    static let allKeys = ["vocals", "lead", "backing", "male", "female", "drums", "bass", "guitar", "piano", "other"] + DrumSplitter.parts + ["instrumental"]

    static func info(_ key: String) -> (name: String, symbol: String, order: Int) {
        switch key {
        case "vocals": return ("Voce", "music.mic", 0)
        case "lead": return ("Voce solista", "music.mic.circle", 1)
        case "backing": return ("Cori", "person.3.fill", 2)
        case "male": return ("Voce maschile", "person.fill", 1)
        case "female": return ("Voce femminile", "person.fill", 2)
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
    /// Le canzoni trascinate o scelte ma non ancora avviate: prima si sceglie la qualità, poi «Separa».
    @Published private(set) var pending: [URL] = []
    /// Le canzoni che aspettano il loro turno (trascinate insieme, per esempio un album).
    @Published private(set) var queue: [URL] = []
    /// Le ultime separazioni, per riaprirle.
    @Published private(set) var history: [HistoryItem] = History.all()
    /// Dove ha lavorato l'ultima separazione (Neural Engine o grafica), con la verifica.
    @Published private(set) var engineText: String?
    /// Se questa separazione ha dovuto usare un modello di riserva (memoria, download…): la qualità non è quella piena
    /// e lo si dice, invece di tacerlo.
    @Published private(set) var qualityNote: String?
    /// Durante lo scaricamento: il file è arrivato e il modello si sta verificando e installando.
    @Published private(set) var installing = false
    /// Il passo preciso in corso («Apro il modello sul Neural Engine…») e da quando: la finestra lo mostra col tempo.
    @Published private(set) var stepDetail: String?
    @Published private(set) var stepStarted = Date()
    /// Quanto ci ha messo l'ultima separazione, in secondi.
    @Published private(set) var elapsed: Double?
    /// La traccia di cui si stanno cercando le note (MIDI), e i file MIDI già creati per questa canzone.
    @Published private(set) var midiWorking: String?
    @Published private(set) var midiFiles: [String: URL] = [:]
    @Published private(set) var midiError: String?

    /// Le tracce che hanno note da trascrivere (la batteria no: non ha altezze).
    var midiStems: [Stem] {
        stems.filter { ["vocals", "lead", "backing", "male", "female", "bass", "guitar", "piano", "other"].contains($0.key) }
    }

    /// Le note di una traccia in un file MIDI accanto alle tracce, al tempo della canzone.
    /// Con `shift` (Transpose) note, tonalità e accordi dei file sono spostati di tanti semitoni.
    func makeMidi(_ stem: Stem, shift: Int = 0) {
        guard midiWorking == nil, let dir = folder else { return }
        let cacheKey = shift == 0 ? stem.key : "\(stem.key)\(shift)"
        if let done = midiFiles[cacheKey] { NSWorkspace.shared.activateFileViewerSelecting([done]); return }
        midiWorking = stem.key
        midiError = nil
        let title = self.title, bpm = analysis?.bpm ?? 120, a = analysis
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let audio = try AudioIO.read(stem.url)
                let notes = try MidiTranscriber.bundled().transcribe(audio).map {
                    Note(start: $0.start, end: $0.end, pitch: max(0, min(127, $0.pitch + shift)), velocity: $0.velocity)
                }
                let name = "\(title) – \(stem.name)\(Downloads.suffix(shift))"
                let url = dir.appendingPathComponent("\(name).mid")
                try MidiFile.data(notes, bpm: bpm, program: MidiFile.program(for: stem.key), name: name)
                    .write(to: url, options: .atomic)
                // Spartito (MusicXML) sulle battute vere della canzone; per chitarra e basso anche la tablatura
                let kind = MusicXML.kind(for: stem.key, notes: notes)
                let score = Score.build(notes, structure: a?.structure, bpm: bpm, keyRoot: ((a?.keyRoot ?? 0) + shift + 12) % 12, minor: a?.minor ?? false,
                                        monophonic: ["bass", "vocals", "lead", "male", "female"].contains(stem.key))
                var files = [url]
                if !score.bars.isEmpty {
                    let xml = dir.appendingPathComponent("\(name).musicxml")
                    try MusicXML.data(score, kind: kind, title: name, instrument: stem.name, program: MidiFile.program(for: stem.key))
                        .write(to: xml, options: .atomic)
                    files.append(xml)
                    if let tuning = kind.tuning {
                        let tab = dir.appendingPathComponent("\(name) (tab).txt")
                        try Tab.text(score, tuning: tuning, title: name).write(to: tab, atomically: true, encoding: .utf8)
                        files.append(tab)
                    }
                }
                await self?.midiDone(cacheKey, url, folder: dir, files: files)
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await self?.midiFailed(msg, folder: dir)
            }
        }
    }

    private func midiDone(_ key: String, _ url: URL, folder dir: URL, files: [URL]) {
        midiWorking = nil
        guard folder == dir else { return }
        midiFiles[key] = url
        NSWorkspace.shared.activateFileViewerSelecting(files)
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
        let songs = Self.songs(in: urls)
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

    /// Canzoni appena trascinate o scelte: non partono da sole. La finestra le mostra con la qualità da scegliere
    /// e il tasto «Separa», così non si avvia per sbaglio un lavoro lungo con la qualità sbagliata.
    /// Durante una separazione si aggiungono alla coda, con la qualità scelta in quel momento.
    func prepare(_ urls: [URL], quality: Quality = .current) {
        let songs = Self.songs(in: urls)
        guard !songs.isEmpty else { return }
        // Anche nella breve pausa tra una canzone della coda e la successiva si va in coda
        if isBusy || !queue.isEmpty { enqueue(songs, quality: quality); return }
        if phase != .idle { reset() }
        pending = songs
    }

    /// «Separa»: parte la prima canzone pronta, le altre vanno in coda.
    func startPending(quality: Quality) {
        let songs = pending
        pending = []
        enqueue(songs, quality: quality)
    }

    func clearPending() { pending = [] }

    /// Le estensioni delle canzoni che macOS sa aprire.
    nonisolated static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "wave", "aif", "aiff", "aifc", "flac", "caf", "alac"]

    /// Le canzoni da separare: i file così come sono, le cartelle aperte con le sottocartelle (in ordine di nome).
    /// Dentro le cartelle si saltano i file nascosti, quelli non audio e i file creati da IsoLR: «X – Voce»,
    /// «X – Karaoke», «X – Mix 2», «X – Senza batteria»… ma solo se accanto ci sono davvero le tracce di «X»,
    /// così una canzone che si chiama «Artista – Senza di te» non si salta.
    nonisolated static func songs(in urls: [URL], limit: Int = 5000) -> [URL] {
        let fm = FileManager.default
        let stemNames = Set(Stem.allKeys.map { Stem.info($0).name })
        let mixNames = ["Karaoke", "Karaoke con cori", "Solo voce", "Mix"] + MixState.Instrument.allCases.map(\.without)
        /// «X» se il nome è «X – qualcosa» con «qualcosa» tra quelli creati da IsoLR.
        func made(_ name: String, extra: Bool) -> String? {
            guard let r = name.range(of: " – ", options: .backwards) else { return nil }
            var tail = String(name[r.upperBound...])
            // «Mix 2», «Karaoke 3»…
            if let sp = tail.lastIndex(of: " "), Int(tail[tail.index(after: sp)...]) != nil { tail = String(tail[..<sp]) }
            let hit = stemNames.contains(tail) || (extra && mixNames.contains(tail))
            return hit ? String(name[..<r.lowerBound]) : nil
        }
        var out: [URL] = []
        for u in urls where u.isFileURL {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            guard isDir.boolValue else { out.append(u); continue }
            guard let e = fm.enumerator(at: u, includingPropertiesForKeys: [.isRegularFileKey],
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            var found: [URL] = []
            for case let f as URL in e {
                guard audioExtensions.contains(f.pathExtension.lowercased()),
                      (try? f.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                found.append(f)
                if found.count >= limit { break }
            }
            // Per ogni cartella, le canzoni di cui ci sono già le tracce di IsoLR (almeno due tracce)
            var count: [String: Int] = [:]
            for f in found {
                if let x = made(f.deletingPathExtension().lastPathComponent, extra: false) {
                    count[f.deletingLastPathComponent().path + "/" + x, default: 0] += 1
                }
            }
            found.removeAll { f in
                guard let x = made(f.deletingPathExtension().lastPathComponent, extra: true) else { return false }
                return (count[f.deletingLastPathComponent().path + "/" + x] ?? 0) >= 2
            }
            out += found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        return out
    }

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
        qualityNote = nil
        installing = false
        stepDetail = nil
        analysis = nil
        timings = []
        sourceInfo = AudioIO.describe(url)
        self.quality = quality
        let models = quality.models
        let wantedVoice = quality.voiceModel
        let wantedInstruments = quality.instrumentModel
        let split = Prefs.splitGuitarPiano
        let downloads = quality.allModels
        // Modalità leggera (computer lenti): meno passaggi e un modello in memoria alla volta
        let light = Prefs.oneModelAtATime
        let swOnBase = quality.swOnBase
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
            /// Il passo preciso in corso: nella finestra (con il tempo che passa) e nel registro.
            func say(_ text: String) async {
                AppLog.write(text)
                await self?.note(cancel, text)
            }
            /// Con poca memoria, un modello che ha finito il suo passaggio si libera subito.
            func done(_ names: String?...) {
                guard Prefs.lowMemory || light else { return }
                for n in names.compactMap({ $0 }) { ModelStore.shared.release(n) }
            }
            do {
                // 1. I modelli (la prima volta si scaricano: un'unica barra per tutti)
                var voiceName = wantedVoice
                var swName = wantedInstruments
                var bassName = quality.bassModel
                var helperName = quality.helperModel
                var secondName = quality.secondVoice
                // Cosa è stato fatto davvero, per dire se la qualità è quella piena
                var voiceUsed: String? = nil
                var bassApplied = false
                var secondApplied = false
                var helperApplied = false
                var swMixApplied = false
                for (k, name) in downloads.enumerated() {
                    if !ModelStore.shared.isReady(name) {
                        await say("Scarico il modello \(k + 1) di \(downloads.count) (\(name))…")
                    }
                    do {
                        try await ModelStore.shared.prepare(name) { p in
                            let total = (Double(k) + p) / Double(downloads.count)
                            Task { @MainActor in
                                guard case .downloading = self?.phase else { return }
                                self?.phase = .downloading(total)
                                self?.installing = p >= 0.8 && p < 1
                            }
                        }
                        if name == wantedVoice || name == wantedInstruments || name == quality.secondVoice { _ = try await ModelStore.shared.config(name) }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch _ where cancel.isSet {
                        throw CancellationError()
                    } catch _ where name == wantedVoice {
                        // Il modello voce non è disponibile: si prova quello più leggero, altrimenti si separa senza
                        voiceName = nil
                        var next = Quality.fallbackVoice(for: name)
                        while let n = next, voiceName == nil {
                            if (try? await ModelStore.shared.prepare(n) { _ in }) != nil,
                               (try? await ModelStore.shared.config(n)) != nil { voiceName = n }
                            next = Quality.fallbackVoice(for: n)
                        }
                    } catch _ where name == quality.secondVoice {
                        // La seconda voce è un di più: senza, la squadra ha un membro in meno
                        secondName = nil
                    } catch _ where name == quality.helperModel {
                        // Demucs per le medie degli strumenti è un di più: senza, restano quelli di SW
                        helperName = nil
                    } catch _ where name == quality.bassModel {
                        // Il basso di Demucs è un di più: senza, resta quello di SW
                        bassName = nil
                    } catch _ where name == wantedInstruments {
                        // Il modello strumenti non è disponibile: si usano i modelli Demucs di riserva,
                        // scaricati qui con la loro barra (non in silenzio durante la prova del motore)
                        swName = nil
                        let reserve = voiceName == nil ? models : models.filter { $0 != Quality.voiceSpecialist }
                        for (j, m) in reserve.enumerated() {
                            try await ModelStore.shared.prepare(m) { p in
                                let total = (Double(j) + p) / Double(reserve.count)
                                Task { @MainActor in if case .downloading = self?.phase { self?.phase = .downloading(total) } }
                            }
                            if cancel.isSet { throw CancellationError() }
                        }
                    }
                    if cancel.isSet { throw CancellationError() }
                }
                lap("Preparazione dei modelli")
                await self?.set(cancel, .reading)
                await say("Leggo la canzone…")
                var mix = try AudioIO.read(url)
                guard mix[0].count >= Int(AudioIO.sampleRate) else { throw SeparationError("la canzone è troppo corta (almeno 1 secondo)") }
                let seconds = Double(mix[0].count) / AudioIO.sampleRate
                await self?.loaded(cancel, peaks: Peaks.of(mix), duration: seconds)
                lap("Lettura della canzone")

                // Con il modello voce a parte, il Demucs specializzato nella voce non serve: un passaggio in meno
                // Con il modello strumenti SW i modelli Demucs non servono affatto
                let instrumentModels = swName != nil ? [] : voiceName == nil ? models : models.filter { $0 != Quality.voiceSpecialist }

                // 2. Il motore: deciso una volta per modello su questo Mac
                var decisions: [String: EngineChoice.Decision] = [:]
                for name in instrumentModels {
                    if let d = EngineChoice.current(name) { decisions[name] = d; continue }
                    await self?.set(cancel, .tuning)
                    await say("Prova del motore: modello \(name)…")
                    let d = try await SeparationJob.tune(name, mix: mix)
                    EngineChoice.store(d, for: name)
                    decisions[name] = d
                    if cancel.isSet { throw CancellationError() }
                }
                // Il basso e gli aiutanti Demucs di Studio sono un di più: se la prova del motore non riesce, restano quelli di SW
                for extra in [bassName, helperName].compactMap({ $0 }) where swName != nil {
                    if let d = EngineChoice.current(extra) {
                        decisions[extra] = d
                    } else {
                        await self?.set(cancel, .tuning)
                        do {
                            let d = try await SeparationJob.tune(extra, mix: mix)
                            EngineChoice.store(d, for: extra)
                            decisions[extra] = d
                            // Con poca memoria non restano aperte due copie fino al loro turno: si riaprono dopo
                            done(extra)
                        } catch {
                            done(extra)
                            if cancel.isSet { throw CancellationError() }
                            if extra == bassName { bassName = nil } else { helperName = nil }
                        }
                    }
                    if cancel.isSet { throw CancellationError() }
                }
                for v in [voiceName, swName].compactMap({ $0 }) where EngineChoice.current(v) == nil {
                    await self?.set(cancel, .tuning)
                    EngineChoice.store(try await SeparationJob.tuneRoFormer(v, mix: mix, label: v == swName ? "degli strumenti" : "della voce", say: say), for: v)
                    if cancel.isSet { throw CancellationError() }
                }
                // La seconda voce: se è già quella di riserva in uso, o la prova del motore non riesce, si fa senza
                if secondName == voiceName { secondName = nil }
                if let s = secondName, EngineChoice.current(s) == nil {
                    await self?.set(cancel, .tuning)
                    do { EngineChoice.store(try await SeparationJob.tuneRoFormer(s, mix: mix, label: "della seconda voce", say: say), for: s) } catch {
                        if cancel.isSet { throw CancellationError() }
                        secondName = nil
                    }
                }
                lap("Prova del motore")

                // 3. La voce, con il suo modello (se questa qualità ne ha uno)
                await self?.set(cancel, .separating(0))
                let began = Date()
                // Quanta parte della barra spetta alla voce
                // Studio: SW passa anche sulla canzone intera, per la squadra della voce e degli strumenti
                let swMix = quality.swOnMix && swName != nil && voiceName != nil
                let voiceShare = voiceName == nil ? 0.0 : swName == nil ? 0.35 : swMix ? 0.65 : secondName == nil ? 0.45 : 0.6
                // Come si divide la parte della voce: primo modello, secondo, SW sulla canzone intera
                let (firstShare, secondShare): (Double, Double) = swMix ? (secondName == nil ? (0.7, 0) : (0.55, 0.15))
                    : (secondName == nil ? (1.0, 0) : (0.5, 0.5))
                // Il tempo che manca si misura dal primo pezzo calcolato, non dal clic: l'apertura dei modelli
                // (a volte minuti la prima volta) non deve gonfiare la stima di tutta la canzone
                let pace = Pace()
                func report(_ total: Double) {
                    let left = pace.remaining(at: total)
                    Task { @MainActor in
                        // Un aggiornamento in ritardo non deve riaprire una separazione già finita o annullata
                        guard case .separating = self?.phase, self?.cancelled === cancel else { return }
                        self?.phase = .separating(total)
                        self?.remaining = left
                    }
                }
                var voiceOut: [[Float]]?
                var instrumentsInput = mix
                // Studio: batteria, basso e altro (tutto il resto) di SW sulla canzone intera, per le medie
                var mixParts: [String: [[Float]]] = [:]
                // Studio leggera B: gli strumenti sono quelli di SW sulla canzone, senza ripassare sulla base
                var mixAll: (names: [String], audio: [[[Float]]])? = nil
                if let v = voiceName {
                    var d = EngineChoice.current(v) ?? EngineChoice.decide(agreement: 99)
                    // Il modello voce davvero usato: se quello scelto non riesce si passa al più leggero
                    var used = v
                    func runVoice(_ units: MLComputeUnits) async throws -> [[Float]] {
                        do {
                            let (voice, helpers) = try await SeparationJob.workers(used, units: units, label: "della voce", say: say)
                            await say("Separo la voce: primo pezzo della canzone…")
                            voice.overlap = Prefs.voiceOverlapValue
                            return try voice.separate(mix, helpers: helpers, progress: { report($0 * voiceShare * firstShare) }, isCancelled: { cancel.isSet })
                        } catch let e where !(e is ImplausibleResult) && !(e is CancellationError) && !cancel.isSet
                                    && Quality.fallbackVoice(for: used) != nil {
                            // Il modello voce non riesce (memoria, Mac più vecchio): si usa quello più leggero,
                            // dopo aver liberato quello che non è riuscito
                            done(used)
                            used = Quality.fallbackVoice(for: used)!
                            if let stored = EngineChoice.current(used) { d = stored }
                            return try await runVoice(d.units)
                        }
                    }
                    let vo: [[Float]]
                    do { vo = try await runVoice(d.units) } catch is ImplausibleResult {
                        // Il Neural Engine sbaglia o non riesce: la grafica; se nemmeno lei, solo il processore (lento ma sicuro)
                        do {
                            vo = try await runVoice(.cpuAndGPU)
                            d = EngineChoice.Decision(units: .cpuAndGPU, agreement: 0)
                        } catch is ImplausibleResult {
                            do { vo = try await runVoice(.cpuOnly) } catch is ImplausibleResult {
                                throw SeparationError("il calcolo su questo Mac non riesce, nemmeno con il solo processore")
                            }
                            d = EngineChoice.Decision(units: .cpuOnly, agreement: 0)
                        }
                        EngineChoice.store(d, for: used)
                    }
                    decisions[used] = d
                    voiceUsed = used
                    done(used)
                    lap("Voce (RoFormer)")
                    var vo2 = vo
                    // Quanti modelli sono nella squadra della voce (si sommano, poi si divide)
                    var members: Float = 1
                    // La seconda voce (Studio): la media dei modelli è più pulita di ognuno
                    if let s = secondName, s != used, let sd = EngineChoice.current(s) {
                        do {
                            let (second, helpers) = try await SeparationJob.workers(s, units: sd.units, label: "della seconda voce", say: say)
                            await say("Seconda voce: primo pezzo della canzone…")
                            second.overlap = Prefs.voiceOverlapValue
                            let other = try second.separate(mix, helpers: helpers, progress: { report(voiceShare * (firstShare + secondShare * $0)) },
                                                            isCancelled: { cancel.isSet })
                            for c in 0..<2 {
                                let n = min(vo2[c].count, other[c].count)
                                for k in 0..<n { vo2[c][k] += other[c][k] }
                            }
                            members += 1
                            decisions[s] = sd
                            secondApplied = true
                            done(s)
                            lap("Seconda voce (Mel-RoFormer)")
                        } catch {
                            // Se non riesce resta la voce del primo modello
                            done(s)
                            if cancel.isSet { throw CancellationError() }
                        }
                    }
                    // Studio: SW sulla canzone intera. La sua voce è il terzo membro della squadra; i suoi strumenti
                    // entrano dopo nelle medie di batteria, basso e altro
                    if swMix, let w = swName, let wd = EngineChoice.current(w) {
                        do {
                            func runMix(_ units: MLComputeUnits) async throws -> (names: [String], audio: [[[Float]]]) {
                                let (model, helpers) = try await SeparationJob.workers(w, units: units, label: "degli strumenti", say: say)
                                await say("Voce, terzo modello (SW sulla canzone intera): primo pezzo…")
                                model.overlap = Prefs.instrumentOverlap
                                let audio = try model.separateAll(mix, helpers: helpers,
                                                                  progress: { report(voiceShare * (firstShare + secondShare + (1 - firstShare - secondShare) * $0)) },
                                                                  isCancelled: { cancel.isSet })
                                return (model.config.sources, audio)
                            }
                            // Se il Neural Engine dà un risultato sbagliato si rifà sulla grafica, e lo si ricorda
                            let got: (names: [String], audio: [[[Float]]])
                            do { got = try await runMix(wd.units) } catch is ImplausibleResult {
                                var g = EngineChoice.Decision(units: .cpuAndGPU, agreement: 0)
                                do { got = try await runMix(.cpuAndGPU) } catch is ImplausibleResult {
                                    got = try await runMix(.cpuOnly)
                                    g = EngineChoice.Decision(units: .cpuOnly, agreement: 0)
                                }
                                EngineChoice.store(g, for: w)
                                decisions[w] = g
                            }
                            let (names, all) = got
                            if let v = names.firstIndex(of: "vocals") {
                                for c in 0..<2 {
                                    let n = min(vo2[c].count, all[v][c].count)
                                    for k in 0..<n { vo2[c][k] += all[v][c][k] }
                                }
                                members += 1
                            }
                            if swOnBase { mixParts = SeparationJob.instrumentTotals(names, all) } else { mixAll = got }
                            swMixApplied = true
                            lap("Terza voce e strumenti (SW sulla canzone)")
                        } catch {
                            if cancel.isSet { throw CancellationError() }
                        }
                    }
                    if members > 1 {
                        let inv = 1 / members
                        for c in 0..<2 { for k in vo2[c].indices { vo2[c][k] *= inv } }
                    }
                    voiceOut = vo2
                    // Gli strumenti si cercano nella base senza voce: ogni modello fa quello in cui è migliore
                    instrumentsInput = (0..<2).map { c in zip(mix[c], vo2[c]).map { $0 - $1 } }
                    // La canzone intera non serve più: con le canzoni lunghe sono centinaia di MB in meno
                    mix = []
                }

                // 4. Gli strumenti: con SW un modello solo per tutti; con htdemucs_ft ogni modello dà il suo strumento
                var out: [[[Float]]] = []
                var sources: [String] = []
                // Quanta parte della barra degli strumenti spetta a SW (il resto ai Demucs di Studio, se ci sono)
                let extras = [bassName, helperName].compactMap { $0 }
                let swShare = 1.0 - 0.15 * Double(extras.count)
                if let w = swName {
                    var d = EngineChoice.current(w) ?? EngineChoice.decide(agreement: 99)
                    let input = instrumentsInput
                    func runSW(_ units: MLComputeUnits) async throws -> (names: [String], audio: [[[Float]]]) {
                        let (model, helpers) = try await SeparationJob.workers(w, units: units, label: "degli strumenti", say: say)
                        await say("Separo gli strumenti: primo pezzo della canzone…")
                        model.overlap = Prefs.instrumentOverlap
                        let audio = try model.separateAll(input, helpers: helpers, progress: { report(voiceShare + (1 - voiceShare) * swShare * $0) },
                                                          isCancelled: { cancel.isSet })
                        return (model.config.sources, audio)
                    }
                    var res: (names: [String], audio: [[[Float]]])
                    if let m = mixAll {
                        res = m
                        mixAll = nil
                    } else { do { res = try await runSW(d.units) } catch is ImplausibleResult {
                        do {
                            res = try await runSW(.cpuAndGPU)
                            d = EngineChoice.Decision(units: .cpuAndGPU, agreement: 0)
                        } catch is ImplausibleResult {
                            do { res = try await runSW(.cpuOnly) } catch is ImplausibleResult {
                                throw SeparationError("il calcolo su questo Mac non riesce, nemmeno con il solo processore")
                            }
                            d = EngineChoice.Decision(units: .cpuOnly, agreement: 0)
                        }
                        EngineChoice.store(d, for: w)
                    } }
                    decisions[w] = d
                    (sources, out) = SeparationJob.arrange(res.names, res.audio, voice: voiceOut, split: split)
                    // Le tracce grezze di SW non servono più (centinaia di MB con le canzoni lunghe)
                    res = ([], [])
                    done(w)
                    lap("Strumenti (BS-RoFormer SW)")

                    // Studio: i Demucs sulla stessa base (il basso specializzato, e quello di Rapida per tutti gli strumenti).
                    // Un di più: se un modello non si carica o il calcolo non riesce, restano le tracce di SW
                    // Di ogni Demucs si tiene solo quello che entra nelle medie (memoria)
                    var demucs: [String: [String: [[Float]]]] = [:]
                    for (j, name) in extras.enumerated() {
                        guard let d = decisions[name] else { continue }
                        await say(name == bassName ? "Basso: secondo modello (Demucs) sulla base…" : "Strumenti: modello Demucs sulla base, per la squadra…")
                        let from = swShare + 0.15 * Double(j)
                        func run(_ core: CoreMLSeparationCore) throws -> [[[Float]]] {
                            try Separator(core: core).separate(input, progress: { p in
                                report(voiceShare + (1 - voiceShare) * (from + 0.15 * p))
                            }, isCancelled: { cancel.isSet })
                        }
                        var result: [[[Float]]]?
                        var found: [String] = []
                        var implausible = false
                        for units in (d.units == .cpuAndGPU ? [MLComputeUnits.cpuAndGPU] : [d.units, .cpuAndGPU]) + [.cpuOnly] where result == nil {
                            guard let core = try? await ModelStore.shared.load(name, units: units, progress: { _ in }) else { continue }
                            do {
                                result = try run(core)
                                found = core.sources
                                // Solo se il Neural Engine ha dato un risultato sbagliato si ricorda la grafica
                                if units != d.units && implausible {
                                    let g = EngineChoice.Decision(units: units, agreement: 0)
                                    EngineChoice.store(g, for: name)
                                    decisions[name] = g
                                }
                            } catch is CancellationError { throw CancellationError() } catch is ImplausibleResult {
                                implausible = true
                            } catch {}
                        }
                        done(name)
                        if cancel.isSet { throw CancellationError() }
                        if let r = result {
                            var keep = SeparationJob.instrumentTotals(found, r)
                            if name == bassName { keep = keep.filter { $0.key == "bass" } }
                            demucs[name] = keep
                            lap(name == bassName ? "Basso (Demucs)" : "Strumenti (Demucs)")
                        }
                    }
                    // Le medie (banco «al massimo», mediana sulle 50 canzoni di MUSDB):
                    // batteria SW base + Demucs + SW canzone 11,19 dB (SW da solo 11,09);
                    // basso SW base + Demucs FT + Demucs + SW canzone 9,84 (SW + FT 9,80, SW da solo 8,67);
                    // altro (con chitarra e piano) SW base + Demucs + SW canzone 7,97 (SW da solo 7,77)
                    // Massima (nessuna squadra): niente da fare, e nessuna copia in più in memoria
                    let own: [String: [[Float]]] = demucs.isEmpty && mixParts.isEmpty ? [:] : SeparationJob.instrumentTotals(sources, out)
                    func part(_ name: String?, _ key: String) -> [[Float]]? {
                        guard let n = name else { return nil }
                        return demucs[n]?[key]
                    }
                    for key in ["drums", "bass", "rest"] {
                        guard let mine = own[key] else { continue }
                        var team = [mine]
                        if key == "bass", let b = part(bassName, "bass") { team.append(b); bassApplied = true }
                        if let h = part(helperName, key) { team.append(h); helperApplied = true }
                        if let m = mixParts[key] { team.append(m) }
                        guard team.count > 1 else { continue }
                        let avg = SeparationJob.average(team)
                        if key == "rest" {
                            // Chitarra e piano restano quelli di SW: la differenza va in «altro»
                            guard let o = sources.firstIndex(of: "other") else { continue }
                            for c in 0..<2 { for k in out[o][c].indices where k < avg[c].count { out[o][c][k] += avg[c][k] - mine[c][k] } }
                        } else if let i = sources.firstIndex(of: key) {
                            out[i] = avg
                        }
                    }
                    mixParts = [:]
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
                        var d = EngineChoice.Decision(units: .cpuAndGPU, agreement: 0)
                        do { result = try run(core) } catch is ImplausibleResult {
                            core = try await ModelStore.shared.load(name, units: .cpuOnly) { _ in }
                            do { result = try run(core) } catch is ImplausibleResult {
                                throw SeparationError("il calcolo su questo Mac non riesce, nemmeno con il solo processore")
                            }
                            d = EngineChoice.Decision(units: .cpuOnly, agreement: 0)
                        }
                        EngineChoice.store(d, for: name)
                        decisions[name] = d
                    }
                    if sources.isEmpty { sources = core.sources }
                    Separator.merge(&out, result, sources: core.sources, specialty: core.specialty)
                    done(name)
                }
                if !instrumentModels.isEmpty {
                    if let vo = voiceOut, let i = sources.firstIndex(of: "vocals") { out[i] = vo }
                    lap(instrumentModels.count > 1 ? "Strumenti (\(instrumentModels.count) modelli Demucs)" : "Separazione (Demucs)")
                }
                let took = Date().timeIntervalSince(began)

                await self?.set(cancel, .saving)
                await say("Salvo le tracce…")
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
                let analysis = Analysis.analyze(out, sources: sources)
                lap("Tempo e tonalità")
                // Il file per DJ, se scelto nelle Impostazioni: se non riesce, le tracce restano comunque
                if Prefs.makeStemFile {
                    // Le tracce in memoria non servono più: il file si fa da quelle salvate
                    out = []
                    _ = try? await StemFile.make(stems: stems, song: url, folder: dir, title: url.deletingPathExtension().lastPathComponent)
                    lap("File per DJ (.stem.mp4)")
                    if cancel.isSet { throw CancellationError() }
                }
                let all = times
                var reduced: [String] = []
                if let v = wantedVoice, voiceUsed != v { reduced.append(voiceUsed == nil ? "voce senza il suo modello" : "voce dal modello di riserva") }
                if wantedInstruments != nil && swName == nil { reduced.append("strumenti dai modelli di riserva") }
                if quality.bassModel != nil && swName != nil && !bassApplied { reduced.append(quality.helperModel != nil ? "basso senza il Demucs specializzato" : "basso da un solo modello") }
                if quality.secondVoice != nil && voiceUsed == wantedVoice && !secondApplied { reduced.append("voce senza il secondo modello") }
                if quality.swOnMix && swName != nil && voiceUsed != nil && !swMixApplied { reduced.append("voce e strumenti senza SW sulla canzone intera") }
                if quality.helperModel != nil && swName != nil && !helperApplied { reduced.append("strumenti senza Demucs in squadra") }
                let note = reduced.isEmpty ? nil : "Qualità ridotta su questo Mac: " + reduced.joined(separator: ", ")
                await self?.finish(cancel, dir: dir, stems: stems, engine: engine, took: took, timings: all, analysis: analysis, note: note)
            } catch is CancellationError {
                await self?.stopped(cancel, clearing: true)
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await self?.set(cancel, .failed(msg))
                await self?.afterFailure(cancel)
            }
        }
    }

    /// La stima del tempo che manca: dalla velocità misurata a partire dal primo avanzamento.
    final class Pace: @unchecked Sendable {
        private let lock = NSLock()
        private var first: (time: Date, total: Double)?
        /// I secondi che mancano a `total` (0…1), oppure nil finché non c'è abbastanza da misurare.
        func remaining(at total: Double, now: Date = Date()) -> Double? {
            lock.lock(); defer { lock.unlock() }
            guard let f = first else { first = (now, total); return nil }
            let done = total - f.total, elapsed = now.timeIntervalSince(f.time)
            guard done > 0.01, elapsed > 1 else { return nil }
            return elapsed / done * (1 - total)
        }
    }

    /// Questo Mac ha il Neural Engine (i Mac con chip Apple sì, quelli Intel no).
    nonisolated static let hasNeuralEngine: Bool = MLComputeDevice.allComputeDevices.contains {
        if case .neuralEngine = $0 { return true } else { return false }
    }

    /// Le copie di un modello RoFormer che lavorano insieme sui pezzi della canzone: una sul Neural Engine
    /// e una sulla grafica, se il Neural Engine è affidabile su questo Mac; altrimenti una sola, dove deciso.
    /// Quanto si aspetta che il Neural Engine apra un modello (la prima volta lo adatta a questo Mac)
    /// prima di continuare con la sola grafica.
    nonisolated static let aneLimit: Double = 240

    /// Neural Engine e grafica insieme (due copie di ogni modello): solo con abbastanza memoria.
    /// Con 8 GB due copie da centinaia di MB fanno usare il disco come memoria e tutto rallenta.
    nonisolated static var useDual: Bool { hasNeuralEngine && Prefs.dualEngine && !Prefs.lowMemory }

    nonisolated static func workers(_ name: String, units: MLComputeUnits, label: String = "",
                                    say: @escaping (String) async -> Void = { _ in }) async throws -> (RoFormer, [RoFormer]) {
        let what = label.isEmpty ? "il modello" : "il modello \(label)"
        // Senza Neural Engine (Mac Intel) o se è stata scelta la grafica: una copia sola, sulla grafica
        if units == .cpuOnly { return (try await ModelStore.shared.roformer(name, units: .cpuOnly) { _ in }, []) }
        if !hasNeuralEngine || Prefs.gpuOnly || units == .cpuAndGPU {
            let u: MLComputeUnits = hasNeuralEngine ? .cpuAndGPU : units
            await say("Apro \(what) sulla grafica…")
            return (try await ModelStore.shared.roformer(name, units: u) { _ in }, [])
        }
        let aneUnits: MLComputeUnits = useDual ? .cpuAndNeuralEngine : .all
        await say("Apro \(what) sul Neural Engine (la prima volta il Mac lo adatta: fino a \(Int(aneLimit / 60)) minuti)…")
        guard let ane = try await withTimeout(aneLimit, { try await ModelStore.shared.roformer(name, units: aneUnits) { _ in } }) else {
            // Troppo lento: si continua con la grafica e lo si ricorda (si riprova solo rifacendo la prova del motore)
            ModelStore.shared.abandon(name, units: aneUnits)
            EngineChoice.store(EngineChoice.Decision(units: .cpuAndGPU, agreement: EngineChoice.slowANE), for: name)
            await say("Il Neural Engine non ha aperto \(what) in \(Int(aneLimit / 60)) minuti: continuo con la grafica…")
            return (try await ModelStore.shared.roformer(name, units: .cpuAndGPU) { _ in }, [])
        }
        guard useDual else { return (ane, []) }
        await say("Apro \(what) anche sulla grafica, per lavorare con tutti e due…")
        return (ane, [try await ModelStore.shared.roformer(name, units: .cpuAndGPU) { _ in }])
    }

    /// Come `tune`, per i modelli RoFormer: un pezzo dal centro della canzone su Neural Engine e su grafica.
    nonisolated static func tuneRoFormer(_ name: String, mix: [[Float]], label: String = "",
                                         say: @escaping (String) async -> Void = { _ in }) async throws -> EngineChoice.Decision {
        if !hasNeuralEngine { return EngineChoice.Decision(units: .all, agreement: EngineChoice.noANE) }
        let what = label.isEmpty ? "il modello" : "il modello \(label)"
        // La stessa copia che poi lavorerà sul Neural Engine (con i due motori insieme): una copia in meno in memoria
        let aneUnits: MLComputeUnits = useDual ? .cpuAndNeuralEngine : .all
        await say(hasNeuralEngine
                  ? "Prova del motore: apro \(what) sul Neural Engine (la prima volta il Mac lo adatta: fino a \(Int(aneLimit / 60)) minuti)…"
                  : "Prova del motore: apro \(what)…")
        guard let ane = try await withTimeout(aneLimit, { try await ModelStore.shared.roformer(name, units: aneUnits) { _ in } }) else {
            ModelStore.shared.abandon(name, units: aneUnits)
            await say("Il Neural Engine non ha aperto \(what) in \(Int(aneLimit / 60)) minuti: userò la grafica…")
            return EngineChoice.Decision(units: .cpuAndGPU, agreement: EngineChoice.slowANE)
        }
        await say("Prova del motore: apro \(what) sulla grafica…")
        let gpu = try await ModelStore.shared.roformer(name, units: .cpuAndGPU) { _ in }
        await say("Prova del motore: confronto Neural Engine e grafica su un pezzo della canzone…")
        let chunk = ane.config.chunk
        let start = max(0, (mix[0].count - chunk) / 2)
        let piece = (0..<2).map { c in (0..<chunk).map { i in start + i < mix[c].count ? mix[c][start + i] : 0 } }
        let a = try ane.runChunkAll(piece), b = try gpu.runChunkAll(piece)
        guard RoFormer.plausible(piece: piece, stems: b) else { return EngineChoice.Decision(units: .all, agreement: 0) }
        let d = EngineChoice.decide(agreement: Separator.agreement(b, a))
        AppLog.write("Prova del motore \(name): \(d.text)")
        return d
    }

    /// Le tracce finali dagli strumenti di SW: la voce dal suo modello (se c'è), chitarra e pianoforte
    /// in tracce proprie oppure dentro «Altri strumenti». La voce che SW trova nella base (residui) si scarta.
    /// Batteria, basso e «tutto il resto» (altro con chitarra e piano) di un modello, per le medie di Studio.
    nonisolated static func instrumentTotals(_ names: [String], _ audio: [[[Float]]]) -> [String: [[Float]]] {
        var out: [String: [[Float]]] = [:]
        for k in ["drums", "bass"] { if let i = names.firstIndex(of: k) { out[k] = audio[i] } }
        let rest = ["other", "guitar", "piano"].compactMap { names.firstIndex(of: $0) }
        if let first = rest.first {
            var sum = audio[first]
            for i in rest.dropFirst() { for c in 0..<2 { for k in sum[c].indices where k < audio[i][c].count { sum[c][k] += audio[i][c][k] } } }
            out["rest"] = sum
        }
        return out
    }

    /// La media campione per campione (lunghezza della prima traccia).
    nonisolated static func average(_ team: [[[Float]]]) -> [[Float]] {
        var out = team[0]
        for t in team.dropFirst() { for c in 0..<2 { for k in out[c].indices where k < t[c].count { out[c][k] += t[c][k] } } }
        let inv = 1 / Float(team.count)
        for c in 0..<2 { for k in out[c].indices { out[c][k] *= inv } }
        return out
    }

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
        // Senza Neural Engine il confronto metterebbe a confronto la grafica con sé stessa (sui Mac Intel, decine di minuti)
        if !hasNeuralEngine { return EngineChoice.Decision(units: .all, agreement: EngineChoice.noANE) }
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
        qualityNote = nil
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
        // La voce si divide in un modo solo alla volta (solista e cori, oppure uomo e donna): nel mix non si sommano due volte
        let taken = ExtraSplit.allCases.filter { $0.source == kind.source }.flatMap(\.parts)
        return phase == .done && splitting == nil && stems.contains { $0.key == kind.source } && !stems.contains { taken.contains($0.key) }
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
                do { res = try await run(EngineChoice.current(kind.modelName)?.units ?? .all) } catch is ImplausibleResult {
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

    /// Annulla subito: la finestra torna libera all'istante, anche se in sottofondo un modello si sta ancora aprendo
    /// (il sistema non permette di interromperlo: quando finisce, il lavoro vede l'annullamento e si ferma da solo).
    func cancel() {
        cancelled.set()
        task?.cancel()
        AppLog.write("Annullato dall'utente (fase: \(phase))")
        guard isBusy else { return }
        queue = []
        queuedQuality = [:]
        phase = .idle
        remaining = nil
        stepDetail = nil
        history = History.all()
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

    /// Un lavoro in sottofondo cambia la finestra solo se è ancora quello in corso e non è stato annullato:
    /// dopo «Annulla» la finestra è già libera, e un lavoro rimasto indietro (es. un modello che si apre) non la tocca più.
    private func current(_ token: Cancel) -> Bool { token === cancelled && !token.isSet }

    private func note(_ token: Cancel, _ text: String) {
        guard current(token) else { return }
        stepDetail = text
        stepStarted = Date()
    }

    private func set(_ token: Cancel, _ p: Phase) {
        guard current(token) else { return }
        phase = p
        stepStarted = Date()
    }

    /// Warp: la griglia corretta a mano diventa quella della canzone (metronomo, parti, passaggio A–B).
    func saveGrid(_ structure: SongStructure) {
        guard var a = analysis else { return }
        a.structure = structure
        analysis = a
        if let dir = folder { History.setAnalysis(a, folder: dir) }
        history = History.all()
    }

    /// Una versione nuova della canzone aperta (messa a tempo o rimontata), già scritta in `dir`:
    /// entra nella libreria con la sua analisi e si apre.
    func addVersion(folder dir: URL, duration: Double, analysis a: SongAnalysis?) {
        History.add(song: nil, folder: dir, quality: quality, duration: duration, seconds: elapsed, engine: engineText, analysis: a)
        history = History.all()
        if let item = history.first(where: { $0.folder == dir.path }) { open(item) }
    }

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

    /// Per le schermate di prova: una separazione a metà strada (niente calcolo vero).
    func showcaseWorking(title: String, peaks: [Float], quality: Quality, progress: Double) {
        self.title = title
        self.quality = quality
        self.mixPeaks = peaks
        phase = .separating(progress)
    }

    /// Annullare ferma anche la coda.
    private func stopped(_ token: Cancel, clearing: Bool) {
        // Dopo «Annulla» la finestra è già stata liberata da cancel()
        guard token === cancelled, phase != .idle else { return }
        if clearing { queue = [] }
        phase = .idle
        history = History.all()
    }

    /// Una canzone non riuscita non blocca le altre.
    private func afterFailure(_ token: Cancel) {
        guard token === cancelled else { return }
        startNextInQueue()
    }

    private func loaded(_ token: Cancel, peaks: [Float], duration: Double) {
        guard current(token) else { return }
        mixPeaks = peaks
        self.duration = duration
    }

    private func finish(_ token: Cancel, dir: URL, stems: [Stem], engine: String, took: Double, timings: [Timing], analysis: SongAnalysis?, note: String? = nil) {
        guard current(token) else { return }
        self.analysis = analysis
        engineText = engine
        qualityNote = note
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

    /// Un WAV per strumento, più la base senza voce, in Musica/IsoLR/<canzone>/.
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
