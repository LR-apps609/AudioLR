import Foundation

// ════════════════════════════════════════════════════════════════════
//  Spartito e tablatura dalle note MIDI di una traccia.
//  • Le note si mettono sulle battute vere della canzone (i battiti trovati
//    nella 0.26) e si arrotondano ai sedicesimi; le note lunghe che passano
//    la stanghetta si legano.
//  • MusicXML: si apre in MuseScore, Guitar Pro, Sibelius, Finale, Dorico.
//    Per chitarra e basso c'è anche il pentagramma della tablatura.
//  • Tablatura di testo (.txt) per chitarra e basso: corde e tasti scelti
//    per muovere la mano il meno possibile, restando in basso sul manico.
// ════════════════════════════════════════════════════════════════════

/// Una nota (o un accordo, o una pausa) dello spartito, in sedicesimi.
struct ScoreEvent: Equatable {
    /// Inizio dentro la battuta e durata, in sedicesimi.
    let start: Int
    let length: Int
    /// Note MIDI suonate insieme; vuoto = pausa.
    let pitches: [Int]
    /// Legata alla successiva (la nota continua nella battuta dopo).
    var tieOut = false
    var tieIn = false
}

struct Score: Equatable {
    static let perBar = 16          // 4/4, in sedicesimi
    var bars: [[ScoreEvent]]
    let bpm: Double
    /// Tonalità (per i diesis o i bemolle in chiave).
    let keyRoot: Int
    let minor: Bool

    /// Mette le note sulle battute: `structure` (battiti veri) se c'è, altrimenti un tempo fisso.
    static func build(_ notes: [Note], structure: SongStructure?, bpm: Double, keyRoot: Int = 0, minor: Bool = false,
                      monophonic: Bool) -> Score {
        let bpm = bpm > 0 ? bpm : 120
        // Da secondi a battiti (con decimali), contati dal primo battito di una battuta
        let beatOf: (Double) -> Double
        if let s = structure, s.beats.count >= 4 {
            let b = s.beats, first = Double(s.firstDownbeat)
            let p0 = b[1] - b[0], p1 = b[b.count - 1] - b[b.count - 2]
            beatOf = { t in
                if t <= b[0] { return (t - b[0]) / p0 - first }
                if t >= b[b.count - 1] { return Double(b.count - 1) + (t - b[b.count - 1]) / p1 - first }
                var lo = 0, hi = b.count - 1
                while hi - lo > 1 { let m = (lo + hi) / 2; if b[m] <= t { lo = m } else { hi = m } }
                return Double(lo) + (t - b[lo]) / (b[hi] - b[lo]) - first
            }
        } else {
            beatOf = { $0 * bpm / 60 }
        }
        // In sedicesimi, arrotondati
        var q: [(start: Int, end: Int, pitch: Int)] = notes.map { n in
            let a = Int((beatOf(n.start) * 4).rounded()), e = Int((beatOf(n.end) * 4).rounded())
            return (a, max(a + 1, e), n.pitch)
        }
        guard !q.isEmpty else { return Score(bars: [], bpm: bpm, keyRoot: keyRoot, minor: minor) }
        // Si parte dalla battuta della prima nota
        let origin = Int((Double(q.map { $0.start }.min()!) / Double(perBar)).rounded(.down)) * perBar
        q = q.map { ($0.start - origin, $0.end - origin, $0.pitch) }
        // Note che partono insieme = un accordo; una voce sola: ogni nota finisce dove parte la successiva
        let starts = Dictionary(grouping: q, by: { $0.start }).sorted { $0.key < $1.key }
        var events: [(start: Int, end: Int, pitches: [Int])] = []
        for k in starts.indices {
            let start = starts[k].key, group = starts[k].value
            var end = group.map { $0.end }.max()!
            if k + 1 < starts.count { end = min(end, starts[k + 1].key) }
            var pitches = Array(Set(group.map { $0.pitch })).sorted()
            if monophonic { pitches = [pitches.last!] }
            events.append((start, max(start + 1, end), pitches))
        }
        // Battute: pause dove non c'è niente, note lunghe spezzate sulla stanghetta e legate
        let total = events.last!.end
        let count = (total + perBar - 1) / perBar
        var bars = [[ScoreEvent]](repeating: [], count: count)
        var cursor = 0
        func put(_ a: Int, _ b: Int, _ p: [Int]) {
            var s = a
            while s < b {
                let bar = s / perBar, barEnd = (bar + 1) * perBar
                let e = min(b, barEnd)
                bars[bar].append(ScoreEvent(start: s - bar * perBar, length: e - s, pitches: p, tieOut: !p.isEmpty && e < b, tieIn: !p.isEmpty && s > a))
                s = e
            }
        }
        for ev in events {
            if ev.start > cursor { put(cursor, ev.start, []) }
            put(ev.start, ev.end, ev.pitches)
            cursor = ev.end
        }
        if cursor < count * perBar { put(cursor, count * perBar, []) }
        return Score(bars: bars, bpm: bpm, keyRoot: keyRoot, minor: minor)
    }

    /// Le durate che si scrivono con una figura sola (in sedicesimi): semibreve, minima puntata… sedicesimo.
    static let figures: [(length: Int, type: String, dot: Bool)] = [
        (16, "whole", false), (12, "half", true), (8, "half", false), (6, "quarter", true),
        (4, "quarter", false), (3, "eighth", true), (2, "eighth", false), (1, "16th", false)]

    /// Una durata qualsiasi in figure legate (5 = 4 + 1).
    static func split(_ n: Int) -> [(length: Int, type: String, dot: Bool)] {
        var left = n, out: [(Int, String, Bool)] = []
        while left > 0 {
            let f = figures.first { $0.length <= left }!
            out.append(f)
            left -= f.length
        }
        return out
    }

    /// Diesis (+) o bemolle (−) in chiave: Sol maggiore +1, Fa maggiore −1…
    var fifths: Int {
        let major = minor ? (keyRoot + 3) % 12 : keyRoot
        return [0, -5, 2, -3, 4, -1, 6, 1, -4, 3, -2, 5][major]
    }
}

// MARK: Tablatura

enum Tab {
    /// Accordature, dalla corda più acuta: chitarra Mi La Re Sol Si Mi, basso Mi La Re Sol.
    static let guitar = [64, 59, 55, 50, 45, 40]
    static let bass = [43, 38, 33, 28]
    static let names = ["E", "B", "G", "D", "A", "E"]
    static let frets = 20

    /// Corda (0 = la più acuta) e tasto per ogni nota di ogni accordo, muovendo la mano il meno possibile.
    static func positions(_ score: Score, tuning: [Int]) -> [[[(string: Int, fret: Int)]]] {
        let low = tuning.min()!, high = tuning.max()! + frets
        func fit(_ p: Int) -> Int {
            var p = p
            while p < low { p += 12 }
            while p > high { p -= 12 }
            return p
        }
        var hand = 3.0                                     // dove sta la mano (tasto)
        return score.bars.map { bar in
            bar.map { ev in
                var used = Set<Int>(), out: [(Int, Int)] = []
                for p in ev.pitches.map(fit).sorted(by: >) {
                    let options = tuning.indices.filter { !used.contains($0) && p - tuning[$0] >= 0 && p - tuning[$0] <= frets }
                    // Vicino alla mano, e meglio in basso sul manico (le corde vuote vanno bene)
                    guard let s = options.min(by: { cost(p - tuning[$0], hand) < cost(p - tuning[$1], hand) }) else { continue }
                    used.insert(s)
                    out.append((s, p - tuning[s]))
                }
                let fretted = out.map { $0.1 }.filter { $0 > 0 }
                if !fretted.isEmpty { hand = Double(fretted.reduce(0, +)) / Double(fretted.count) }
                return out
            }
        }
    }

    private static func cost(_ fret: Int, _ hand: Double) -> Double {
        fret == 0 ? 1 : abs(Double(fret) - hand) + 0.15 * Double(fret)
    }

    /// La tablatura in testo, quattro battute per riga, un trattino per sedicesimo.
    static func text(_ score: Score, tuning: [Int], title: String) -> String {
        let pos = positions(score, tuning: tuning)
        let strings = tuning.count
        let labels = strings == 6 ? names : ["G", "D", "A", "E"]
        var out = "\(title)\nAccordatura: \(strings == 6 ? "Mi La Re Sol Si Mi" : "Mi La Re Sol") · \(Int(score.bpm.rounded())) BPM · 4/4\n"
        out += "Un trattino = un sedicesimo. Tablatura stimata da IsoLR: controllala a orecchio.\n\n"
        for row in stride(from: 0, to: score.bars.count, by: 4) {
            var lines = (0..<strings).map { "\(labels[$0])|" }
            for b in row..<min(row + 4, score.bars.count) {
                var cells = [[String]](repeating: [String](repeating: "--", count: Score.perBar), count: strings)
                for (k, ev) in score.bars[b].enumerated() where !ev.tieIn {
                    for (s, f) in pos[b][k] { cells[s][ev.start] = String(f).count == 1 ? "\(f)-" : "\(f)" }
                }
                for s in 0..<strings { lines[s] += cells[s].joined() + "|" }
            }
            out += "Battuta \(row + 1)\n" + lines.joined(separator: "\n") + "\n\n"
        }
        return out
    }
}

// MARK: MusicXML

enum MusicXML {
    /// Che tipo di pentagramma: chiave e, per chitarra e basso, la tablatura sotto.
    enum Kind {
        case treble, bass, guitar, bassGuitar
        var tuning: [Int]? { self == .guitar ? Tab.guitar : self == .bassGuitar ? Tab.bass : nil }
    }

    static func kind(for stem: String, notes: [Note]) -> Kind {
        if stem == "guitar" { return .guitar }
        if stem == "bass" { return .bassGuitar }
        let pitches = notes.map { $0.pitch }.sorted()
        let median = pitches.isEmpty ? 60 : pitches[pitches.count / 2]
        return median < 57 ? .bass : .treble
    }

    static let sharpNames = ["C", "C", "D", "D", "E", "F", "F", "G", "G", "A", "A", "B"]
    static let sharpAlter = [0, 1, 0, 1, 0, 0, 1, 0, 1, 0, 1, 0]
    static let flatNames = ["C", "D", "D", "E", "E", "F", "G", "G", "A", "A", "B", "B"]
    static let flatAlter = [0, -1, 0, -1, 0, 0, -1, 0, -1, 0, -1, 0]

    static func data(_ score: Score, kind: Kind, title: String, instrument: String, program: UInt8) -> Data {
        let tab = kind.tuning.map { Tab.positions(score, tuning: $0) }
        var x = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">
        <score-partwise version="4.0">
          <work><work-title>\(esc(title))</work-title></work>
          <identification><encoding><software>IsoLR</software></encoding></identification>
          <part-list>
            <score-part id="P1"><part-name>\(esc(instrument))</part-name>
              <midi-instrument id="P1-I1"><midi-program>\(Int(program) + 1)</midi-program></midi-instrument></score-part>

        """
        if tab != nil {
            x += "    <score-part id=\"P2\"><part-name>\(esc(instrument)) (tab)</part-name></score-part>\n"
        }
        x += "  </part-list>\n"
        x += part("P1", score, kind: kind, tab: nil)
        if let tab, let tuning = kind.tuning { x += part("P2", score, kind: kind, tab: (tab, tuning)) }
        x += "</score-partwise>\n"
        return Data(x.utf8)
    }

    private static func part(_ id: String, _ score: Score, kind: Kind, tab: ([[[(string: Int, fret: Int)]]], [Int])?) -> String {
        let flats = score.fifths < 0
        var x = "  <part id=\"\(id)\">\n"
        for (b, bar) in score.bars.enumerated() {
            x += "    <measure number=\"\(b + 1)\">\n"
            if b == 0 {
                x += "      <attributes><divisions>4</divisions><key><fifths>\(score.fifths)</fifths></key>"
                x += "<time><beats>4</beats><beat-type>4</beat-type></time>"
                if let (_, tuning) = tab {
                    x += "<clef><sign>TAB</sign><line>5</line></clef><staff-details><staff-lines>\(tuning.count)</staff-lines>"
                    for (i, p) in tuning.reversed().enumerated() {
                        let step = sharpNames[p % 12], alter = sharpAlter[p % 12]
                        x += "<staff-tuning line=\"\(i + 1)\"><tuning-step>\(step)</tuning-step>\(alter != 0 ? "<tuning-alter>\(alter)</tuning-alter>" : "")<tuning-octave>\(p / 12 - 1)</tuning-octave></staff-tuning>"
                    }
                    x += "</staff-details>"
                } else {
                    switch kind {
                    case .treble: x += "<clef><sign>G</sign><line>2</line></clef>"
                    case .bass: x += "<clef><sign>F</sign><line>4</line></clef>"
                    // Chitarra e basso si scrivono un'ottava sopra di come suonano
                    case .guitar: x += "<clef><sign>G</sign><line>2</line><clef-octave-change>-1</clef-octave-change></clef>"
                    case .bassGuitar: x += "<clef><sign>F</sign><line>4</line><clef-octave-change>-1</clef-octave-change></clef>"
                    }
                }
                x += "</attributes>\n"
                x += "      <direction placement=\"above\"><direction-type><metronome><beat-unit>quarter</beat-unit><per-minute>\(Int(score.bpm.rounded()))</per-minute></metronome></direction-type><sound tempo=\"\(Int(score.bpm.rounded()))\"/></direction>\n"
            }
            for (k, ev) in bar.enumerated() {
                let pieces = Score.split(ev.length)
                for (i, f) in pieces.enumerated() {
                    let tieIn = ev.tieIn || i > 0, tieOut = ev.tieOut || i < pieces.count - 1
                    if ev.pitches.isEmpty {
                        x += "      <note><rest/><duration>\(f.length)</duration><type>\(f.type)</type>\(f.dot ? "<dot/>" : "")</note>\n"
                        continue
                    }
                    let frets = tab?.0[b][k]
                    for (j, p) in ev.pitches.enumerated() {
                        let pc = p % 12
                        let step = flats ? flatNames[pc] : sharpNames[pc], alter = flats ? flatAlter[pc] : sharpAlter[pc]
                        x += "      <note>\(j > 0 ? "<chord/>" : "")<pitch><step>\(step)</step>\(alter != 0 ? "<alter>\(alter)</alter>" : "")<octave>\(p / 12 - 1)</octave></pitch>"
                        x += "<duration>\(f.length)</duration>"
                        if tieIn { x += "<tie type=\"stop\"/>" }
                        if tieOut { x += "<tie type=\"start\"/>" }
                        x += "<type>\(f.type)</type>\(f.dot ? "<dot/>" : "")"
                        var notations = ""
                        if tieIn { notations += "<tied type=\"stop\"/>" }
                        if tieOut { notations += "<tied type=\"start\"/>" }
                        // Corda e tasto: la corda 1 è la più acuta. Le note fuori dalla chitarra restano senza
                        if let frets, let sf = frets.first(where: { (tab!.1[$0.string] + $0.fret) % 12 == pc }) {
                            notations += "<technical><string>\(sf.string + 1)</string><fret>\(sf.fret)</fret></technical>"
                        }
                        if !notations.isEmpty { x += "<notations>\(notations)</notations>" }
                        x += "</note>\n"
                    }
                }
            }
            x += "    </measure>\n"
        }
        return x + "  </part>\n"
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
