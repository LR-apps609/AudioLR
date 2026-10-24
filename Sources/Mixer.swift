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
            if isPlaying, let s = startedAt { startPosition = min(duration, startPosition + Date().timeIntervalSince(s) * oldValue); startedAt = Date() }
            timePitch.rate = Float(rate)
        }
    }
    /// Semitoni in su o in giù.
    @Published var semitones: Int = 0 { didSet { timePitch.pitch = Float(semitones * 100) } }
    /// Il passaggio da ripetere, in secondi (entrambi presenti = ripetizione attiva).
    @Published private(set) var loopA: Double?
    @Published private(set) var loopB: Double?
    var isLooping: Bool { loopA != nil && loopB != nil }

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
        let fmt = engine.outputNode.inputFormat(forBus: 0)
        engine.disconnectNodeOutput(engine.mainMixerNode)
        // mix → velocità e tono → limitatore → uscita
        engine.connect(engine.mainMixerNode, to: timePitch, format: fmt)
        engine.connect(timePitch, to: l, format: fmt)
        engine.connect(l, to: engine.outputNode, format: fmt)
        return l
    }()
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
        return min(duration, startPosition + Date().timeIntervalSince(s) * rate)
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

    func play(from seconds: Double) {
        guard !players.isEmpty else { return }
        stopNodes()
        _ = limiter
        do { if !engine.isRunning { try engine.start() } } catch { return }
        var at = max(0, min(seconds, duration))
        // Con la ripetizione attiva si suona solo il passaggio (e si riparte da A se si è fuori)
        if let a = loopA, let b = loopB, at < a || at >= b - 0.02 { at = a }
        let end = isLooping ? loopB! : duration
        for (k, p) in players {
            guard let f = files[k] else { continue }
            let rate = f.processingFormat.sampleRate
            let first = AVAudioFramePosition(at * rate)
            let last = min(f.length, AVAudioFramePosition(end * rate))
            let count = AVAudioFrameCount(max(0, last - first))
            guard count > 0 else { continue }
            p.scheduleSegment(f, startingFrame: first, frameCount: count, at: nil)
        }
        // Tutti i lettori partono nello stesso istante, un attimo dopo: così restano allineati
        let when = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.08))
        for p in players.values { p.play(at: when) }
        startPosition = at
        startedAt = Date().addingTimeInterval(0.08)
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
        if let a = loopA, let b = loopB, position >= b - 0.03 { play(from: a); return }
        if position >= duration - 0.02 { stop() }
    }

    private func stopNodes() { for p in players.values { p.stop() } }

    private func applyGains() {
        for (k, p) in players { p.volume = Float(state.effectiveGain(k)) }
    }

    /// Salva il mix attuale accanto alle tracce, nel formato scelto nelle Impostazioni.
    func export(stems: [Stem], folder: URL, title: String) async throws -> URL {
        exporting = true
        defer { exporting = false }
        let state = self.state
        let chosen = Self.mixable(stems)
        let name = Self.exportName(state: state, title: title)
        let format = Prefs.format
        // Un mix esportato prima non si sovrascrive: «Canzone – Mix 2», «Canzone – Mix 3»…
        var url = folder.appendingPathComponent("\(name).\(format.fileExtension)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(n).\(format.fileExtension)")
            n += 1
        }
        let target = url
        return try await Task.detached(priority: .userInitiated) {
            let tracks = try chosen.map { (key: $0.key, audio: try AudioIO.read($0.url)) }
            let mixed = MixState.mix(tracks, state: state)
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
