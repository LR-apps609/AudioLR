import Foundation
import Accelerate

// ════════════════════════════════════════════════════════════════════
//  Slice to MIDI: gli attacchi di una traccia (flusso spettrale con una
//  soglia che segue la musica), le fette tra un attacco e l'altro, i
//  ritocchi (sposta, unisci, dividi), l'audio di ogni fetta con dissolvenze
//  brevi e il file MIDI che le richiama nel ritmo della canzone (nota 36 =
//  fetta 1, come i pad di un Drum Rack). L'esportazione è una cartella con
//  le fette in WAV, il MIDI e un LEGGIMI per Ableton e Logic.
//  Le stesse regole sono in windows/ui/core/slice.js.
// ════════════════════════════════════════════════════════════════════

struct AudioSlice: Equatable {
    /// Campioni: dall'inizio (compreso) alla fine (esclusa).
    var start: Int
    var end: Int
}

enum Slicer {
    static let frame = 1024, hop = 256                        // finestra di 23 ms, un passo ogni 5,8 ms
    static let firstNote = 36                                  // Do1: il primo pad di un Drum Rack

    static func mono(_ audio: [[Float]]) -> [Float] {
        guard let l = audio.first else { return [] }
        guard audio.count > 1 else { return l }
        var out = l
        vDSP.add(l, audio[1], result: &out)
        vDSP.multiply(0.5, out, result: &out)
        return out
    }

    /// Il flusso spettrale (quanto cresce l'energia, banda per banda), normalizzato a 1.
    static func flux(_ x: [Float]) -> [Float] {
        let frames = x.count >= frame ? (x.count - frame) / hop + 1 : 0
        guard frames > 0, let dft = try? vDSP.DiscreteFourierTransform(count: frame, direction: .forward,
                                                                       transformType: .complexComplex, ofType: Float.self) else { return [] }
        let win = (0..<frame).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(frame))) }
        let zeros = [Float](repeating: 0, count: frame)
        var buf = [Float](repeating: 0, count: frame), re = buf, im = buf
        var prev = [Float](repeating: 0, count: frame / 2 + 1), cur = prev
        var out = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            for i in 0..<frame { buf[i] = x[f * hop + i] * win[i] }
            dft.transform(inputReal: buf, inputImaginary: zeros, outputReal: &re, outputImaginary: &im)
            var s: Float = 0
            for k in 1...(frame / 2) {
                cur[k] = log1p(10 * (re[k] * re[k] + im[k] * im[k]).squareRoot())
                let d = cur[k] - prev[k]
                if d > 0 { s += d }
            }
            out[f] = f == 0 ? 0 : s
            swap(&prev, &cur)
        }
        if let top = out.max(), top > 0 { vDSP.multiply(1 / top, out, result: &out) }
        return out
    }

    /// Gli attacchi, in campioni. `sensitivity` 0…1 (più alta = più colpi), `minGap` secondi tra due colpi.
    static func onsets(_ audio: [[Float]], rate: Double = AudioIO.sampleRate, sensitivity: Double = 0.5, minGap: Double = 0.07) -> [Int] {
        let fl = flux(mono(audio))
        guard !fl.isEmpty else { return [] }
        let half = max(2, Int((0.1 * rate / Double(hop)).rounded()))
        let delta = Float(0.03 + 0.3 * (1 - max(0, min(1, sensitivity))))
        let gap = Int((minGap * rate / Double(hop)).rounded())
        var out: [Int] = []
        var last = -Int.max / 2
        var sum: Float = 0
        // Media mobile su ±0,1 s: la soglia sale dove la musica è piena e scende dove è vuota
        for i in 0..<min(fl.count, half) { sum += fl[i] }
        for i in 0..<fl.count {
            let a = i - half - 1, b = i + half
            if b < fl.count { sum += fl[b] }
            if a >= 0 { sum -= fl[a] }
            let count = min(fl.count, i + half + 1) - max(0, i - half)
            let thr = sum / Float(count) + delta, v = fl[i]
            if v < thr || v < 0.04 { continue }
            if (i > 0 && fl[i - 1] > v) || (i + 1 < fl.count && fl[i + 1] >= v) { continue }
            if i - last < gap { continue }
            // Il flusso cresce quando il colpo entra nella finestra: l'attacco è verso la sua fine
            out.append(max(0, i * hop + frame - hop))
            last = i
        }
        return out
    }

    /// Le fette: da ogni attacco (con un piccolo anticipo) al successivo; l'ultima fino alla fine.
    static func slices(_ starts: [Int], length: Int, rate: Double = AudioIO.sampleRate, preroll: Double = 0.005) -> [AudioSlice] {
        let pre = Int((preroll * rate).rounded())
        let pos = Array(Set(starts.map { max(0, min(length - 1, $0 - pre)) })).sorted()
        guard !pos.isEmpty else { return length > 0 ? [AudioSlice(start: 0, end: length)] : [] }
        return pos.enumerated().map { AudioSlice(start: $0.element, end: $0.offset + 1 < pos.count ? pos[$0.offset + 1] : length) }
    }

    private static func minimum(_ rate: Double) -> Int { Int((0.01 * rate).rounded()) }

    /// Sposta l'inizio della fetta `i` (e la fine della precedente), senza scavalcare le vicine.
    static func move(_ list: [AudioSlice], _ i: Int, to: Int, rate: Double = AudioIO.sampleRate) -> [AudioSlice] {
        guard i > 0, i < list.count else { return list }
        let lo = list[i - 1].start + minimum(rate), hi = list[i].end - minimum(rate)
        let p = max(lo, min(hi, to))
        var out = list
        out[i - 1].end = p
        out[i].start = p
        return out
    }

    /// Unisce la fetta `i` con la successiva.
    static func merge(_ list: [AudioSlice], _ i: Int) -> [AudioSlice] {
        guard i >= 0, i + 1 < list.count else { return list }
        var out = list
        out.replaceSubrange(i...(i + 1), with: [AudioSlice(start: list[i].start, end: list[i + 1].end)])
        return out
    }

    /// Divide in due la fetta che contiene `at`.
    static func split(_ list: [AudioSlice], at: Int, rate: Double = AudioIO.sampleRate) -> [AudioSlice] {
        guard let i = list.firstIndex(where: { at > $0.start + minimum(rate) && at < $0.end - minimum(rate) }) else { return list }
        var out = list
        out.replaceSubrange(i...i, with: [AudioSlice(start: list[i].start, end: at), AudioSlice(start: at, end: list[i].end)])
        return out
    }

    /// L'audio di una fetta, con dissolvenze brevi ai bordi (niente clic).
    static func render(_ audio: [[Float]], _ s: AudioSlice, rate: Double = AudioIO.sampleRate, fade: Double = 0.003) -> [[Float]] {
        let n = max(0, s.end - s.start), f = min(n / 2, Int((fade * rate).rounded()))
        return audio.map { c in
            var out = Array(c[max(0, s.start)..<min(c.count, s.end)])
            guard out.count == n else { return out }
            for i in 0..<f {
                let g = Float(i) / Float(f)
                out[i] *= g
                out[n - 1 - i] *= g
            }
            return out
        }
    }

    /// La nota MIDI di una fetta (36, 37, …; mai oltre 127).
    static func note(of i: Int) -> Int { min(127, firstNote + i) }

    /// Il file MIDI che suona le fette nel loro ritmo originale.
    static func midi(_ list: [AudioSlice], rate: Double = AudioIO.sampleRate, bpm: Double = 120, name: String = "") -> Data {
        let notes = list.enumerated().map {
            Note(start: Double($0.element.start) / rate, end: Double($0.element.end) / rate, pitch: note(of: $0.offset), velocity: 100)
        }
        return MidiFile.data(notes, bpm: bpm, program: 0, name: name)
    }

    /// Il nome di ogni file: «Slice 01.wav»…
    static func fileName(_ i: Int) -> String { String(format: "Slice %02d.wav", i + 1) }

    /// Come caricare le fette nei programmi musicali.
    static func readme(title: String, stem: String, count: Int, bpm: Double?) -> String {
        [
            "\(title) – Slice \(stem)",
            "",
            "\(count) fette (Slice 01.wav … \(fileName(count - 1))) e un file MIDI che le suona nel ritmo originale\(bpm.map { " (\(Int($0.rounded())) BPM)" } ?? "").",
            "La fetta 1 è la nota 36 (Do1), la fetta 2 la nota 37, e così via: come i pad di un Drum Rack.",
            "",
            "Ableton Live",
            "1. Crea una traccia MIDI con un Drum Rack vuoto.",
            "2. Seleziona tutte le fette nel Finder e trascinale sul primo pad (Do1): Live le mette in fila, una per pad.",
            "3. Trascina il file .mid nella traccia: suona le fette nel ritmo della canzone. Sposta le note per cambiare il ritmo.",
            "",
            "Logic Pro",
            "1. Crea una traccia «Drum Machine Designer» (o «Quick Sampler» in modalità Slice).",
            "2. Trascina le fette sui pad a partire da Do1 (in Quick Sampler: trascina la traccia intera e usa i segnaposto).",
            "3. Trascina il file .mid nella traccia.",
            "",
            "Creato con IsoLR.",
        ].joined(separator: "\n")
    }

    /// Esporta in una cartella nuova «`title` – Slice `stem`» accanto alle tracce: fette WAV, MIDI e LEGGIMI.
    /// Restituisce la cartella.
    static func export(_ audio: [[Float]], slices list: [AudioSlice], title: String, stem: String, bpm: Double?, into root: URL) throws -> URL {
        let fm = FileManager.default
        let base = "\(title) – Slice \(stem)"
        var dir = root.appendingPathComponent(base, isDirectory: true)
        var k = 2
        while fm.fileExists(atPath: dir.path) { dir = root.appendingPathComponent("\(base) \(k)", isDirectory: true); k += 1 }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, s) in list.enumerated() {
            try AudioIO.write(render(audio, s), to: dir.appendingPathComponent(fileName(i)), format: .wav24)
        }
        try midi(list, bpm: bpm ?? 120, name: base).write(to: dir.appendingPathComponent("\(base).mid"), options: .atomic)
        try readme(title: title, stem: stem, count: list.count, bpm: bpm).write(to: dir.appendingPathComponent("LEGGIMI.txt"), atomically: true, encoding: .utf8)
        return dir
    }
}
