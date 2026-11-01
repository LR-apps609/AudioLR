import Foundation

// ════════════════════════════════════════════════════════════════════
//  Il testo sincronizzato: dalla voce separata, parola per parola con i
//  tempi, tutto sul Mac. Modello: Whisper small (OpenAI, licenza MIT) nella
//  versione Core ML di WhisperKit (argmax, licenza MIT), scaricato la prima
//  volta dalla release «modelli-1» come gli altri modelli.
//  Qui: le regole (righe, .lrc, .srt, parola sotto la testina, modifiche) e
//  il motore. Le stesse regole sono in windows/ui/core/lyrics.js.
// ════════════════════════════════════════════════════════════════════

/// Una parola cantata, con inizio e fine in secondi dall'inizio della canzone.
struct LyricWord: Codable, Equatable {
    var text: String
    var start: Double
    var end: Double
}

/// Una riga del testo: le sue parole (indici nell'elenco delle parole) e i tempi.
struct LyricLine: Equatable {
    var words: Range<Int>
    var text: String
    var start: Double
    var end: Double
}

/// Il testo di una canzone, salvato accanto alle tracce («isolr-testo.json»).
struct Lyrics: Codable, Equatable {
    var version = 1
    var language: String?
    var words: [LyricWord]
    /// Corretto a mano: non si riscrive con una nuova trascrizione senza chiedere.
    var edited = false

    static let fileName = "isolr-testo.json"

    // MARK: Righe

    /// Le parole raggruppate in righe da cantare: si va a capo alla fine di una frase (. ? !), dopo una pausa
    /// lunga, o quando la riga diventa troppo lunga per lo schermo.
    static func lines(_ words: [LyricWord], maxGap: Double = 1.2, maxWords: Int = 8, maxChars: Int = 42) -> [LyricLine] {
        var out: [LyricLine] = []
        var first = 0
        var chars = 0
        func close(_ end: Int) {
            guard end > first else { return }
            let text = words[first..<end].map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            out.append(LyricLine(words: first..<end, text: text, start: words[first].start, end: words[end - 1].end))
            first = end
            chars = 0
        }
        for i in words.indices {
            let w = words[i].text.trimmingCharacters(in: .whitespaces)
            if i > first {
                let gap = words[i].start - words[i - 1].end
                let tooLong = (i - first) >= maxWords || chars + w.count + 1 > maxChars
                if gap > maxGap || tooLong { close(i) }
            }
            chars += w.count + 1
            if let last = w.last, ".?!…".contains(last) { close(i + 1) }
        }
        close(words.count)
        return out
    }

    /// La riga e la parola sotto la testina (nil prima del primo canto o tra due righe lontane).
    static func current(_ lines: [LyricLine], words: [LyricWord], at t: Double) -> (line: Int, word: Int?)? {
        // L'ultima riga cominciata; dopo la sua fine resta accesa ancora un attimo
        var lo = 0, hi = lines.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].start <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard found >= 0, t <= lines[found].end + 1.5 else { return nil }
        let word = lines[found].words.last { words[$0].start <= t }
        return (found, word)
    }

    // MARK: Esportazione

    /// «[01:02.35]» come nei file .lrc.
    static func lrcTime(_ s: Double) -> String {
        let cs = Int((max(0, s) * 100).rounded())
        return String(format: "[%02d:%02d.%02d]", cs / 6000, (cs / 100) % 60, cs % 100)
    }

    /// «00:01:02,350» come nei sottotitoli .srt.
    static func srtTime(_ s: Double) -> String {
        let ms = Int((max(0, s) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60000) % 60, (ms / 1000) % 60, ms % 1000)
    }

    /// Il testo in formato .lrc (una riga con il suo tempo; i lettori musicali e molti karaoke lo leggono).
    static func lrc(_ lines: [LyricLine], title: String) -> String {
        var s = "[ti:\(title)]\n[re:IsoLR]\n"
        for l in lines { s += lrcTime(l.start) + l.text + "\n" }
        return s
    }

    /// Il testo come sottotitoli .srt (per i programmi video).
    static func srt(_ lines: [LyricLine]) -> String {
        var s = ""
        for (i, l) in lines.enumerated() {
            s += "\(i + 1)\n\(srtTime(l.start)) --> \(srtTime(l.end))\n\(l.text)\n\n"
        }
        return s
    }

    // MARK: Modifiche a mano

    /// Riscrive il testo di una riga: se il numero di parole resta uguale ogni parola tiene il suo tempo,
    /// altrimenti le parole nuove si dividono il tempo della riga in proporzione alla loro lunghezza.
    static func rewrite(_ words: [LyricWord], line: LyricLine, to text: String) -> [LyricWord] {
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        var out = words
        if parts.count == line.words.count {
            for (k, i) in line.words.enumerated() { out[i].text = parts[k] }
            return out
        }
        let total = max(1, parts.reduce(0) { $0 + $1.count + 1 })
        var t = line.start
        let span = line.end - line.start
        var fresh: [LyricWord] = []
        for p in parts {
            let d = span * Double(p.count + 1) / Double(total)
            fresh.append(LyricWord(text: p, start: t, end: t + d))
            t += d
        }
        out.replaceSubrange(line.words, with: fresh)
        return out
    }

    /// Sposta nel tempo le parole di una riga (anticipo o ritardo, in secondi).
    static func shift(_ words: [LyricWord], line: LyricLine, by dt: Double) -> [LyricWord] {
        var out = words
        for i in line.words {
            out[i].start = max(0, out[i].start + dt)
            out[i].end = max(out[i].start, out[i].end + dt)
        }
        return out
    }

    /// Pulisce quello che dà Whisper: spazi, parole vuote, tempi al contrario, righe ripetute all'infinito
    /// (succede nei tratti senza voce).
    static func clean(_ raw: [LyricWord]) -> [LyricWord] {
        var out: [LyricWord] = []
        for var w in raw {
            w.text = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !w.text.isEmpty else { continue }
            if w.end < w.start { w.end = w.start }
            out.append(w)
        }
        // Più di 4 volte la stessa parola di fila: si tiene la prima
        var kept: [LyricWord] = []
        var run = 0
        for w in out {
            if let last = kept.last, last.text.lowercased() == w.text.lowercased() { run += 1 } else { run = 0 }
            if run < 4 { kept.append(w) }
        }
        return kept
    }

    // MARK: Salvataggio

    static func load(in folder: URL) -> Lyrics? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(Lyrics.self, from: data)
    }

    func save(in folder: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }
}
