import Foundation
import AVFoundation
import AudioToolbox
import SwiftUI

// ════════════════════════════════════════════════════════════════════
//  Il mixer: le tracce separate suonano insieme, sincronizzate, con
//  muto, solo e volume per ognuna; poi si esporta il proprio mix
//  (per esempio karaoke con un filo di voce, o solo basso e batteria).
// ════════════════════════════════════════════════════════════════════

/// Le regole del mixer, separate dal suono così si possono provare.
struct MixState: Equatable {
    var gain: [String: Double] = [:]
    var muted: Set<String> = []
    var solo: Set<String> = []

    /// Il volume che una traccia ha davvero: zero se è muta, o se altre sono in «solo» e lei no.
    func effectiveGain(_ key: String) -> Double {
        if muted.contains(key) { return 0 }
        if !solo.isEmpty && !solo.contains(key) { return 0 }
        return gain[key] ?? 1
    }

    /// Scorciatoie: tutto, karaoke (senza voce), karaoke con i cori (se la voce è divisa), solo voce.
    enum Preset: String, CaseIterable, Identifiable {
        case all, karaoke, backing, voice
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "Tutto"
            case .karaoke: return "Karaoke"
            case .backing: return "Con i cori"
            case .voice: return "Solo voce"
            }
        }
    }

    /// «Senza il mio strumento»: la propria parte via dal mix, per suonarci sopra.
    enum Instrument: String, CaseIterable, Identifiable {
        case drums, bass, guitar, piano
        var id: String { rawValue }
        var title: String {
            switch self {
            case .drums: return "Batteria"
            case .bass: return "Basso"
            case .guitar: return "Chitarra"
            case .piano: return "Pianoforte"
            }
        }
        /// «Senza batteria», «Senza basso»…
        var without: String { "Senza " + title.lowercased() }
        var symbol: String { Stem.info(rawValue).symbol }
        /// Le tracce di questo strumento (la batteria anche divisa nei suoi pezzi).
        var keys: Set<String> { self == .drums ? Set(["drums"] + DrumSplitter.parts) : [rawValue] }

        /// L'ultimo scelto: è «il mio strumento» per ⇧⌘K.
        static let key = "myInstrument"
        static var mine: Instrument? {
            get { Instrument(rawValue: UserDefaults.standard.string(forKey: key) ?? "") }
            set { UserDefaults.standard.set(newValue?.rawValue, forKey: key) }
        }
    }

    mutating func apply(without i: Instrument) {
        muted = i.keys
        solo = []
    }

    /// Lo strumento tolto, se il mix è «senza» uno strumento e basta.
    var without: Instrument? {
        guard solo.isEmpty, !muted.isEmpty else { return nil }
        return Instrument.allCases.first { muted == $0.keys }
    }

    /// Tutte le tracce di voce (intera, oppure solista e cori se è stata divisa).
    static let voices: Set<String> = ["vocals", "lead", "backing"]

    mutating func apply(_ p: Preset) {
        muted = []
        solo = []
        switch p {
        case .all: break
        case .karaoke: muted = Self.voices
        case .backing: muted = ["lead"]
        case .voice: solo = Self.voices
        }
    }

    /// Quale scorciatoia corrisponde allo stato attuale (se una corrisponde).
    var preset: Preset? {
        // «Tutta la voce»: la voce intera, oppure solista e cori insieme
        func allVoice(_ s: Set<String>) -> Bool {
            !s.isEmpty && s.isSubset(of: Self.voices) && (s.contains("vocals") || s.isSuperset(of: ["lead", "backing"]))
        }
        if muted.isEmpty && solo.isEmpty { return .all }
        if muted == ["lead"] && solo.isEmpty { return .backing }
        if allVoice(muted) && solo.isEmpty { return .karaoke }
        if allVoice(solo) && muted.isEmpty { return .voice }
        return nil
    }

    /// Somma delle tracce con i volumi del mixer.
    static func mix(_ tracks: [(key: String, audio: [[Float]])], state: MixState) -> [[Float]] {
        let n = tracks.map { $0.audio.first?.count ?? 0 }.max() ?? 0
        var out = [[Float]](repeating: [Float](repeating: 0, count: n), count: 2)
        for t in tracks {
            let g = Float(state.effectiveGain(t.key))
            guard g > 0 else { continue }
            for c in 0..<2 {
                let ch = t.audio[min(c, t.audio.count - 1)]
                for i in 0..<ch.count { out[c][i] += ch[i] * g }
            }
        }
        return out
    }
}

/// Il suono del mixer: un lettore per traccia, tutti partono nello stesso istante.
@MainActor
final class MixPlayer: ObservableObject {
    @Published var state = MixState() { didSet { applyGains() } }
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double = 0
    @Published private(set) var exporting = false

    // Sala prove: velocità senza cambiare tono, tono senza cambiare velocità, un passaggio da ripetere.
    // Valgono solo per l'ascolto: il mix esportato resta alla velocità e nel tono originali.
    /// 0,5 = metà velocità, 1 = normale.
    @Published var rate: Double = 1 {
        didSet {
            // Il punto in cui si è arrivati, calcolato con la velocità di prima
            if isPlaying, let s = startedAt, s < Date() { startPosition = min(duration, startPosition + Date().timeIntervalSince(s) * oldValue); startedAt = Date() }
            timePitch.rate = Float(rate)
        }
    }
    /// Semitoni in su o in giù.
    @Published var semitones: Int = 0 { didSet { timePitch.pitch = Float(semitones * 100) } }
    /// Il passaggio da ripetere, in secondi (entrambi presenti = ripetizione attiva).
    @Published private(set) var loopA: Double?
    @Published private(set) var loopB: Double?
    var isLooping: Bool { loopA != nil && loopB != nil }
    /// Rampa di velocità: il passaggio riparte ogni volta un po' più veloce (es. 70% → 100%), per imparare un brano.
    @Published var ramp = false {
        didSet { if ramp && !oldValue { rate = Self.rampStart } }
    }
    nonisolated static let rampStart = 0.7
    nonisolated static let rampStep = 0.05
    nonisolated static let rampTarget = 1.0
    /// La velocità del giro successivo: un passo in più, senza superare il traguardo.
    nonisolated static func rampNext(_ r: Double, step: Double = rampStep, target: Double = rampTarget) -> Double {
        min(target, ((r + step) * 100).rounded() / 100)
    }

    // Metronomo: un clic su ogni battito trovato nella canzone (più acuto sul primo della battuta);
    // conteggio: una battuta di clic prima che la musica parta.
    @Published var metronome = false { didSet { clickPlayer.volume = metronome ? 1 : 0 } }
    @Published var countIn = false
    /// Battiti, battute e parti della canzone aperta (nil per le separazioni prima della 0.26).
    @Published private(set) var structure: SongStructure?
    private var bpm: Double = 0
    /// Il metronomo segue i battiti veri; il conteggio basta il tempo.
    var canClick: Bool { !(structure?.beats.isEmpty ?? true) }
    var canCount: Bool { bpm > 0 }

    func setGrid(_ analysis: SongAnalysis?) {
        guard structure != analysis?.structure || bpm != (analysis?.bpm ?? 0) else { return }
        structure = analysis?.structure
        bpm = analysis?.bpm ?? 0
        if !canClick { metronome = false }
        if !canCount { countIn = false }
        if isPlaying { play(from: position, counting: false) }
    }

    /// Ripete una parte della canzone (o un passaggio qualsiasi) e la fa partire.
    func practice(from a: Double, to b: Double) {
        guard b > a + 0.25 else { return }
        loopA = max(0, a)
        loopB = min(duration, b)
        play(from: loopA ?? 0)
    }

    private let clickPlayer = AVAudioPlayerNode()
    private let countPlayer = AVAudioPlayerNode()
    nonisolated static let clickRate = 44_100.0
    private lazy var clickFormat = AVAudioFormat(standardFormatWithSampleRate: Self.clickRate, channels: 2)!
    private lazy var clickHigh = Self.clickBuffer(format: clickFormat, hz: 1_760)
    private lazy var clickLow = Self.clickBuffer(format: clickFormat, hz: 1_175)

    /// Un «tic» di 40 ms: una nota che si spegne subito.
    private static func clickBuffer(format: AVAudioFormat, hz: Double) -> AVAudioPCMBuffer {
        let n = AVAudioFrameCount(0.04 * clickRate)
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
        b.frameLength = n
        for c in 0..<Int(format.channelCount) {
            let d = b.floatChannelData![c]
            for i in 0..<Int(n) {
                let t = Double(i) / clickRate
                d[i] = Float(0.45 * sin(2 * .pi * hz * t) * exp(-t / 0.008) * min(1, t / 0.0005))
            }
        }
        return b
    }

    /// I clic tra `from` e `to` (secondi della canzone): quando e se sono il primo della battuta.
    nonisolated static func clicks(_ s: SongStructure, from: Double, to: Double) -> [(time: Double, strong: Bool)] {
        s.beats.indices.compactMap { i in
            let t = s.beats[i]
            guard t >= from - 0.001, t < to else { return nil }
            let k = ((i - s.firstDownbeat) % s.beatsPerBar + s.beatsPerBar) % s.beatsPerBar
            return (t, k == 0)
        }
    }

    /// La durata di un battito vicino a `at`: dai battiti trovati se ci sono, altrimenti dal tempo medio.
    nonisolated static func beatPeriod(_ s: SongStructure?, bpm: Double, at: Double) -> Double {
        if let b = s?.beats, b.count >= 3 {
            let i = min(b.count - 2, max(0, (b.firstIndex { $0 >= at } ?? b.count - 1) - 1))
            let lo = max(0, i - 4), hi = min(b.count - 1, i + 4)
            let gaps = (lo..<hi).map { b[$0 + 1] - b[$0] }.sorted()
            if let m = gaps.isEmpty ? nil : gaps[gaps.count / 2], m > 0.2, m < 2 { return m }
        }
        return bpm > 0 ? 60 / bpm : 0.5
    }

    /// La parte della canzone in cui si trova `t`.
    func section(at t: Double) -> SongSection? { structure?.sections.first { t >= $0.start && t < $0.end } }

    private let timePitch = AVAudioUnitTimePitch()

    private let engine = AVAudioEngine()
    /// Limitatore in uscita: con i volumi alzati le tracce sommate possono superare il massimo;
    /// invece di tagliare (suono «fritto») il limitatore abbassa solo quei picchi.
    private lazy var limiter: AVAudioUnitEffect = {
        let d = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
                                          componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        let l = AVAudioUnitEffect(audioComponentDescription: d)
        engine.attach(l)
        engine.attach(timePitch)
        for p in [clickPlayer, countPlayer] {
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: clickFormat)
        }
        clickPlayer.volume = metronome ? 1 : 0
        let fmt = engine.outputNode.inputFormat(forBus: 0)
        engine.disconnectNodeOutput(engine.mainMixerNode)
        // mix → velocità e tono → limitatore → uscita
        engine.connect(engine.mainMixerNode, to: timePitch, format: fmt)
        engine.connect(timePitch, to: l, format: fmt)
        engine.connect(l, to: engine.outputNode, format: fmt)
        // Cuffie collegate o tolte, uscita cambiata: macOS ferma il motore audio. Si mette in pausa
        // (il tasto torna a «suona») e si ricollega la catena con il formato della nuova uscita
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                                 queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.outputChanged() }
        }
        return l
    }()
    private var configObserver: NSObjectProtocol?

    private func outputChanged() {
        if isPlaying { pause() }
        let fmt = engine.outputNode.inputFormat(forBus: 0)
        engine.disconnectNodeOutput(engine.mainMixerNode)
        engine.disconnectNodeOutput(timePitch)
        engine.disconnectNodeOutput(limiter)
        engine.connect(engine.mainMixerNode, to: timePitch, format: fmt)
        engine.connect(timePitch, to: limiter, format: fmt)
        engine.connect(limiter, to: engine.outputNode, format: fmt)
    }
    private var players: [String: AVAudioPlayerNode] = [:]
    private var files: [String: AVAudioFile] = [:]
    private var startPosition: Double = 0
    private var startedAt: Date?
    private(set) var keys: [String] = []
    private var loadedFolder: URL?
    private var attempted: Set<String> = []

    /// Secondi dall'inizio della canzone.
    var position: Double {
        guard isPlaying, let s = startedAt else { return startPosition }
        // Durante il conteggio la musica non è ancora partita
        return min(duration, startPosition + max(0, Date().timeIntervalSince(s)) * rate)
    }

    /// Segna l'inizio (A) o la fine (B) del passaggio da ripetere nel punto attuale.
    func markLoopStart() {
        loopA = position
        if let b = loopB, b <= position + 0.25 { loopB = nil }
    }

    func markLoopEnd() {
        let p = position
        guard p > (loopA ?? 0) + 0.25 else { return }
        if loopA == nil { loopA = 0 }
        loopB = p
        if isPlaying { play(from: loopA ?? 0) }
    }

    func clearLoop() {
        loopA = nil
        loopB = nil
        if isPlaying { play(from: position) }
    }

    /// Velocità e tono normali, niente ripetizione.
    func resetPractice() {
        ramp = false
        rate = 1
        semitones = 0
        loopA = nil
        loopB = nil
    }

    /// Le tracce che si mescolano: la base senza voce è già un mix, quindi resta fuori; se la batteria
    /// è stata divisa, al suo posto ci sono le sue parti (cassa, rullante…).
    nonisolated static func mixable(_ stems: [Stem]) -> [Stem] {
        let replaced = ExtraSplit.allCases.filter { k in stems.contains { k.parts.contains($0.key) } }.map(\.source)
        return stems.filter { $0.key != "instrumental" && !replaced.contains($0.key) }
    }

    /// Prepara le tracce da mescolare.
    func load(_ stems: [Stem], folder: URL?) {
        let wanted = Self.mixable(stems).map(\.key)
        // Si confrontano le tracce chieste l'ultima volta (non quelle aperte): un file illeggibile
        // non deve far ricaricare il mixer a ogni aggiornamento
        guard folder != loadedFolder || attempted.isEmpty || Set(wanted) != attempted else { return }
        attempted = Set(wanted)
        let keep = folder == loadedFolder ? state : MixState()
        stop()
        if folder != loadedFolder { resetPractice() }
        for p in players.values { engine.detach(p) }
        players = [:]
        files = [:]
        keys = []
        duration = 0
        state = keep
        loadedFolder = folder
        for s in Self.mixable(stems) {
            guard let f = try? AVAudioFile(forReading: s.url) else { continue }
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: f.processingFormat)
            players[s.key] = p
            files[s.key] = f
            keys.append(s.key)
            duration = max(duration, Double(f.length) / f.processingFormat.sampleRate)
        }
        applyGains()
    }

    func toggle() { isPlaying ? pause() : play(from: position >= duration - 0.05 ? 0 : position) }

    /// Suona da `seconds`; con il conteggio attivo, prima una battuta di clic (non quando il passaggio ricomincia da solo).
    func play(from seconds: Double, counting: Bool = true) {
        guard !players.isEmpty else { return }
        stopNodes()
        _ = limiter
        do { if !engine.isRunning { try engine.start() } } catch { return }
        var at = max(0, min(seconds, duration))
        // Con la ripetizione attiva si suona solo il passaggio (e si riparte da A se si è fuori)
        if let a = loopA, let b = loopB, at < a || at >= b - 0.02 { at = a }
        let end = isLooping ? loopB! : duration
        // Il conteggio: una battuta al tempo del punto di partenza; la musica (e il metronomo) partono dopo
        let period = Self.beatPeriod(structure, bpm: bpm, at: at)
        let bar = structure?.beatsPerBar ?? 4
        let lead = counting && countIn && canCount ? period * Double(bar) : 0
        let sr = Self.clickRate
        if lead > 0 {
            for i in 0..<bar {
                countPlayer.scheduleBuffer(i == 0 ? clickHigh : clickLow,
                                           at: AVAudioTime(sampleTime: AVAudioFramePosition(Double(i) * period * sr), atRate: sr))
            }
        }
        if let s = structure {
            for c in Self.clicks(s, from: at, to: end) {
                clickPlayer.scheduleBuffer(c.strong ? clickHigh : clickLow,
                                           at: AVAudioTime(sampleTime: AVAudioFramePosition((lead + c.time - at) * sr), atRate: sr))
            }
        }
        for (k, p) in players {
            guard let f = files[k] else { continue }
            let rate = f.processingFormat.sampleRate
            let first = AVAudioFramePosition(at * rate)
            let last = min(f.length, AVAudioFramePosition(end * rate))
            let count = AVAudioFrameCount(max(0, last - first))
            guard count > 0 else { continue }
            p.scheduleSegment(f, startingFrame: first, frameCount: count,
                              at: lead > 0 ? AVAudioTime(sampleTime: AVAudioFramePosition(lead * rate), atRate: rate) : nil)
        }
        // Tutti i lettori partono nello stesso istante, un attimo dopo: così restano allineati
        let when = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.08))
        for p in players.values { p.play(at: when) }
        clickPlayer.play(at: when)
        countPlayer.play(at: when)
        startPosition = at
        // Il conteggio passa alla velocità scelta: a metà velocità dura il doppio
        startedAt = Date().addingTimeInterval(0.08 + lead / self.rate)
        isPlaying = true
    }

    func pause() {
        startPosition = position
        stopNodes()
        isPlaying = false
    }

    func stop() {
        stopNodes()
        isPlaying = false
        startPosition = 0
    }

    func seek(to fraction: Double) {
        let t = max(0, min(1, fraction)) * duration
        if isPlaying { play(from: t) } else { startPosition = t }
    }

    /// Chiamato regolarmente dalla finestra: a fine canzone si ferma; a fine passaggio ricomincia da A.
    func tick() {
        guard isPlaying else { return }
        if let a = loopA, let b = loopB, position >= b - 0.03 {
            if ramp { rate = Self.rampNext(rate) }
            play(from: a, counting: false)
            return
        }
        if position >= duration - 0.02 { stop() }
    }

    private func stopNodes() {
        for p in players.values { p.stop() }
        // I clic entrano nel motore solo al primo ascolto
        guard clickPlayer.engine != nil else { return }
        clickPlayer.stop()
        countPlayer.stop()
    }

    private func applyGains() {
        for (k, p) in players { p.volume = Float(state.effectiveGain(k)) }
    }

    /// Salva il mix attuale: accanto alle tracce nel formato delle Impostazioni, oppure in `to` nel formato `format`.
    /// Con `range` (secondi) solo quel passaggio, per esempio la ripetizione A–B.
    func export(stems: [Stem], folder: URL, title: String, to chosenURL: URL? = nil, format chosenFormat: OutputFormat? = nil,
                range: (Double, Double)? = nil) async throws -> URL {
        exporting = true
        defer { exporting = false }
        let state = self.state
        let chosen = Self.mixable(stems)
        let name = Self.exportName(state: state, title: title)
        let format = chosenFormat ?? Prefs.format
        // Un mix esportato prima non si sovrascrive: «Canzone – Mix 2», «Canzone – Mix 3»…
        var url = folder.appendingPathComponent("\(name).\(format.fileExtension)")
        var n = 2
        while chosenURL == nil && FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(n).\(format.fileExtension)")
            n += 1
        }
        let target = chosenURL ?? url
        return try await Task.detached(priority: .userInitiated) {
            let tracks = try chosen.map { (key: $0.key, audio: try AudioIO.read($0.url)) }
            var mixed = MixState.mix(tracks, state: state)
            if let r = range {
                let n = mixed.first?.count ?? 0
                let s0 = max(0, min(n, Int(r.0 * AudioIO.sampleRate))), s1 = max(s0, min(n, Int(r.1 * AudioIO.sampleRate)))
                mixed = mixed.map { Array($0[s0..<s1]) }
            }
            let url = target
            // Con i volumi alzati il mix può superare il massimo: si abbassa tutto quanto basta, senza tagliare
            try AudioIO.write(mixed, to: url, format: format, gain: Stem.safeGain(peaks: [Stem.measure(mixed).peak]))
            return url
        }.value
    }

    /// «Canzone – Karaoke», «Canzone – Solo voce» o «Canzone – Mix».
    nonisolated static func exportName(state: MixState, title: String) -> String {
        switch state.preset {
        case .karaoke?: return "\(title) – Karaoke"
        case .voice?: return "\(title) – Solo voce"
        case .backing?: return "\(title) – Karaoke con cori"
        default:
            if let i = state.without { return "\(title) – \(i.without)" }
            return "\(title) – Mix"
        }
    }
}
