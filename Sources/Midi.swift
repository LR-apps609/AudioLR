import Foundation
import CoreML
import Accelerate

// ════════════════════════════════════════════════════════════════════
//  Dall'audio alle note: Basic Pitch di Spotify (licenza Apache 2.0,
//  modello Core ML incluso nell'app, circa 270 KB) trova le note di una
//  traccia, e qui diventano un file MIDI da trascinare in GarageBand o
//  Logic. La ricerca delle note è la copia di basic_pitch/note_creation.py.
// ════════════════════════════════════════════════════════════════════

struct Note: Equatable {
    /// Inizio e fine in secondi.
    let start: Double
    let end: Double
    /// Nota MIDI (60 = Do centrale).
    let pitch: Int
    /// Forza della nota, 1…127.
    let velocity: Int
}

final class MidiTranscriber {
    // Le misure di Basic Pitch (basic_pitch/constants.py)
    static let rate = 22_050
    static let hop = 256
    static let windowSamples = rate * 2 - hop              // 43 844 campioni per finestra
    static let framesPerWindow = 172
    static let overlapFrames = 30
    static let fps = Double(rate / hop)                     // 86 colonne al secondo
    static let midiOffset = 21                              // la prima nota del pianoforte (La0)
    static let keys = 88

    let model: MLModel?
    /// Per i test: una rete finta (riceve una finestra, restituisce note e attacchi 172×88).
    var fakeNetwork: (([Float]) -> (frames: [Float], onsets: [Float]))?

    init(model: MLModel?) { self.model = model }

    /// Il modello incluso nell'app. Solo processore, come lo usa Spotify: è piccolo, e su grafica
    /// e Neural Engine alcune sue operazioni non sono affidabili.
    static func bundled(units: MLComputeUnits = .cpuOnly) throws -> MidiTranscriber {
        guard let url = Bundle.main.url(forResource: "BasicPitch", withExtension: "mlmodelc")
                ?? Bundle(for: MidiTranscriber.self).url(forResource: "BasicPitch", withExtension: "mlmodelc") else {
            throw SeparationError("il modello delle note non è nell'app")
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = units
        return MidiTranscriber(model: try MLModel(contentsOf: url, configuration: cfg))
    }

    // MARK: Audio

    /// Stereo a 44,1 kHz → mono a 22 050 Hz (con filtro, perché le frequenze alte non tornino giù come rumore).
    static func prepare(_ audio: [[Float]]) -> [Float] {
        guard let n = audio.first?.count, n > 0 else { return [] }
        var mono = audio[0]
        if audio.count > 1 { vDSP.add(mono, audio[1], result: &mono); vDSP.multiply(0.5, mono, result: &mono) }
        // Filtro passa-basso a 31 coefficienti (sinc con finestra di Hann), taglio a 10 kHz, poi un campione su due
        let taps = 31, cutoff = 10_000.0 / 44_100
        let h: [Float] = (0..<taps).map { i in
            let x = Double(i - taps / 2)
            let sinc = x == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
            return Float(sinc * (0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(taps - 1))))
        }
        let padded = [Float](repeating: 0, count: taps / 2) + mono + [Float](repeating: 0, count: taps)
        let outCount = (n + 1) / 2
        var out = [Float](repeating: 0, count: outCount)
        vDSP_desamp(padded, 2, h, &out, vDSP_Length(outCount), vDSP_Length(taps))
        return out
    }

    // MARK: Rete

    /// Note e attacchi per ogni colonna (colonne × 88), su tutta la traccia (già a 22 050 Hz).
    func activations(_ x: [Float], isCancelled: () -> Bool = { false }) throws -> (frames: [[Float]], onsets: [[Float]]) {
        let W = Self.windowSamples, T = Self.framesPerWindow, K = Self.keys
        let overlap = Self.overlapFrames * Self.hop
        let step = W - overlap
        let half = Self.overlapFrames / 2
        let audio = [Float](repeating: 0, count: overlap / 2) + x
        var frames: [[Float]] = [], onsets: [[Float]] = []
        var start = 0
        while start < audio.count {
            if isCancelled() { throw CancellationError() }
            var win = [Float](repeating: 0, count: W)
            let len = min(W, audio.count - start)
            for i in 0..<len { win[i] = audio[start + i] }
            let (f, o) = try run(win)
            // Si tolgono le colonne sovrapposte, metà all'inizio e metà alla fine (unwrap_output)
            for t in half..<(T - half) {
                frames.append(Array(f[(t * K)..<((t + 1) * K)]))
                onsets.append(Array(o[(t * K)..<((t + 1) * K)]))
            }
            start += step
        }
        let total = Int(floor(Double(x.count) * Self.fps / Double(Self.rate)))
        return (Array(frames.prefix(total)), Array(onsets.prefix(total)))
    }

    private func run(_ window: [Float]) throws -> (frames: [Float], onsets: [Float]) {
        if let fake = fakeNetwork { return fake(window) }
        guard let model else { throw SeparationError("modello delle note non disponibile") }
        let input = try MLDictionaryFeatureProvider(dictionary: ["input_2": try CoreMLSeparationCore.array(window, shape: [1, Self.windowSamples, 1])])
        let out = try model.prediction(from: input)
        guard let f = out.featureValue(for: "Identity_1")?.multiArrayValue,
              let o = out.featureValue(for: "Identity_2")?.multiArrayValue else {
            throw SeparationError("il modello delle note non ha dato risultati")
        }
        return (CoreMLSeparationCore.floats(f), CoreMLSeparationCore.floats(o))
    }

    // MARK: Note

    /// Le note dalle attivazioni (output_to_notes_polyphonic, con il «trucco Melodia»).
    static func notes(frames: [[Float]], onsets rawOnsets: [[Float]], onsetThreshold: Float = 0.5, frameThreshold: Float = 0.3,
                      minNoteLength: Int = 11, energyTolerance: Int = 11, melodia: Bool = true) -> [Note] {
        let n = frames.count, K = keys
        guard n > 2 else { return [] }
        // Attacchi in più dove le note crescono di colpo (get_infered_onsets, 2 differenze)
        var diff = [[Float]](repeating: [Float](repeating: 0, count: K), count: n)
        var maxDiff: Float = 0, maxOnset: Float = 0
        for t in 0..<n {
            for k in 0..<K {
                maxOnset = max(maxOnset, rawOnsets[t][k])
                guard t >= 2 else { continue }
                let d1 = frames[t][k] - frames[t - 1][k], d2 = frames[t][k] - frames[t - 2][k]
                let d = max(0, min(d1, d2))
                diff[t][k] = d
                maxDiff = max(maxDiff, d)
            }
        }
        var onsets = rawOnsets
        if maxDiff > 0 {
            for t in 0..<n { for k in 0..<K { onsets[t][k] = max(onsets[t][k], maxOnset * diff[t][k] / maxDiff) } }
        }
        // Massimi locali nel tempo sopra la soglia, dal più recente al più vecchio (come np.where al contrario)
        var peaks: [(t: Int, k: Int)] = []
        for t in 1..<(n - 1) {
            for k in 0..<K where onsets[t][k] > onsets[t - 1][k] && onsets[t][k] > onsets[t + 1][k] && onsets[t][k] >= onsetThreshold {
                peaks.append((t, k))
            }
        }
        peaks.reverse()

        var energy = frames
        var notes: [(start: Int, end: Int, pitch: Int, amp: Float)] = []
        func clear(_ t: Int, _ k: Int) {
            energy[t][k] = 0
            if k < K - 1 { energy[t][k + 1] = 0 }
            if k > 0 { energy[t][k - 1] = 0 }
        }
        func mean(_ a: Int, _ b: Int, _ k: Int) -> Float {
            guard b > a else { return 0 }
            var s: Float = 0
            for t in a..<b { s += frames[t][k] }
            return s / Float(b - a)
        }
        for (start, k) in peaks {
            if start >= n - 1 { continue }
            var i = start + 1, below = 0
            while i < n - 1 && below < energyTolerance {
                below = energy[i][k] < frameThreshold ? below + 1 : 0
                i += 1
            }
            i -= below
            if i - start <= minNoteLength { continue }
            for t in start..<i { clear(t, k) }
            notes.append((start, i, k + midiOffset, mean(start, i, k)))
        }
        if melodia {
            // Le celle con energia, dalla più forte: l'energia si può solo azzerare, mai crescere,
            // quindi la più forte rimasta è sempre la prima della lista non ancora azzerata
            var cells: [(e: Float, t: Int, k: Int)] = []
            for t in 0..<n { for k in 0..<K where energy[t][k] > frameThreshold { cells.append((energy[t][k], t, k)) } }
            cells.sort { $0.e != $1.e ? $0.e > $1.e : ($0.t, $0.k) < ($1.t, $1.k) }
            for c in cells {
                let bt = c.t, bk = c.k
                guard energy[bt][bk] > frameThreshold else { continue }
                energy[bt][bk] = 0
                var i = bt + 1, below = 0
                while i < n - 1 && below < energyTolerance {
                    below = energy[i][bk] < frameThreshold ? below + 1 : 0
                    clear(i, bk)
                    i += 1
                }
                let end = i - 1 - below
                i = bt - 1
                below = 0
                while i > 0 && below < energyTolerance {
                    below = energy[i][bk] < frameThreshold ? below + 1 : 0
                    clear(i, bk)
                    i -= 1
                }
                let start = i + 1 + below
                if end - start <= minNoteLength { continue }
                notes.append((start, end, bk + midiOffset, mean(start, end, bk)))
            }
        }
        return notes.map { Note(start: time(ofFrame: $0.start), end: time(ofFrame: $0.end), pitch: $0.pitch,
                                velocity: max(1, min(127, Int((127 * $0.amp).rounded())))) }
            .sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) }
    }

    /// Secondi di una colonna, con la correzione di Basic Pitch per le finestre (model_frames_to_time).
    static func time(ofFrame f: Int) -> Double {
        let original = Double(f * hop) / Double(rate)
        let offset = Double(hop) / Double(rate) * (Double(framesPerWindow) - Double(windowSamples) / Double(hop)) + 0.0018
        return original - offset * floor(Double(f) / Double(framesPerWindow))
    }

    /// Tutta la traccia: dall'audio separato alle note.
    func transcribe(_ audio: [[Float]], isCancelled: () -> Bool = { false }) throws -> [Note] {
        let a = try activations(Self.prepare(audio), isCancelled: isCancelled)
        return Self.notes(frames: a.frames, onsets: a.onsets)
    }
}

// MARK: - File MIDI

enum MidiFile {
    /// Il suono General MIDI più vicino a ogni traccia.
    static func program(for stem: String) -> UInt8 {
        switch stem {
        case "vocals", "lead": return 53          // voce «oohs»
        case "backing": return 52                 // coro «aahs»
        case "bass": return 33                    // basso elettrico
        case "guitar": return 25                  // chitarra acustica
        case "piano": return 0                    // pianoforte
        default: return 48                        // archi
        }
    }

    /// Un file MIDI (formato 0, una traccia) con le note, al tempo della canzone se si conosce.
    static func data(_ notes: [Note], bpm: Double = 120, program: UInt8 = 0, name: String = "") -> Data {
        let ppq = 480
        let tempo = max(30, min(300, bpm))
        func ticks(_ s: Double) -> Int { Int((s * tempo / 60 * Double(ppq)).rounded()) }
        func vlq(_ v: Int) -> [UInt8] {
            var v = max(0, v), bytes = [UInt8(v & 0x7F)]
            v >>= 7
            while v > 0 { bytes.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
            return bytes
        }
        // Eventi assoluti: (tick, ordine, byte); a parità di tick prima gli spegnimenti
        var events: [(tick: Int, order: Int, bytes: [UInt8])] = []
        for n in notes {
            let p = UInt8(max(0, min(127, n.pitch)))
            events.append((ticks(n.start), 1, [0x90, p, UInt8(n.velocity)]))
            events.append((max(ticks(n.end), ticks(n.start) + 1), 0, [0x80, p, 0]))
        }
        events.sort { ($0.tick, $0.order) < ($1.tick, $1.order) }
        var track: [UInt8] = []
        let title = Array(name.utf8.prefix(120))
        if !title.isEmpty { track += [0x00, 0xFF, 0x03] + vlq(title.count) + title }
        let us = Int(60_000_000 / tempo)
        track += [0x00, 0xFF, 0x51, 0x03, UInt8((us >> 16) & 0xFF), UInt8((us >> 8) & 0xFF), UInt8(us & 0xFF)]
        track += [0x00, 0xC0, program]
        var last = 0
        for e in events {
            track += vlq(e.tick - last) + e.bytes
            last = e.tick
        }
        track += [0x00, 0xFF, 0x2F, 0x00]
        func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        var out: [UInt8] = Array("MThd".utf8) + be32(6) + [0, 0, 0, 1, UInt8(ppq >> 8), UInt8(ppq & 0xFF)]
        out += Array("MTrk".utf8) + be32(track.count) + track
        return Data(out)
    }
}
