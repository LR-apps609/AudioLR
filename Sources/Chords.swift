import Foundation
import Accelerate

// ════════════════════════════════════════════════════════════════════
//  Accordi, calcolati sulle tracce separate senza batteria e senza voce:
//  per ogni battito le note che suonano (croma) si confrontano con le
//  24 triadi maggiori e minori; il basso aiuta a trovare la fondamentale.
//  Poi una scelta su tutta la canzone (Viterbi): cambiare accordo costa un
//  po', così un passaggio veloce di chitarra non diventa un accordo nuovo,
//  e gli accordi della tonalità sono un poco favoriti.
//  Solo calcoli sul segnale, niente modelli da scaricare. È una stima:
//  maggiori e minori, senza settime e sospesi.
// ════════════════════════════════════════════════════════════════════

struct ChordSpan: Codable, Equatable {
    /// Secondi dall'inizio della canzone.
    let start: Double
    let end: Double
    /// 0 = Do … 11 = Si; nil = nessun accordo (silenzio, solo batteria o voce).
    let root: Int?
    let minor: Bool

    /// «Am», «F♯», «—»; `shift` in semitoni (per il tono cambiato in «Esercitati»).
    func name(italian: Bool = false, shift: Int = 0) -> String {
        guard let r = root else { return "—" }
        let k = ((r + shift) % 12 + 12) % 12
        return italian ? SongAnalysis.names[k] + (minor ? "m" : "") : SongAnalysis.english[k] + (minor ? "m" : "")
    }
}

enum Chords {
    static let rate = 44_100.0

    /// Accordi da `harmonic` (strumenti senza batteria e voce) e `bass`, un'etichetta per battito.
    /// Senza battiti si usa una griglia di mezzo secondo.
    static func detect(harmonic: [Float], bass: [Float], beats: [Double]?, key: (root: Int, minor: Bool)?) -> [ChordSpan] {
        let seconds = Double(harmonic.count) / rate
        guard seconds > 2 else { return [] }
        var grid = beats ?? []
        if grid.count < 4 { grid = stride(from: 0.0, to: seconds, by: 0.5).map { $0 } }
        if grid[0] > 0.05 { grid.insert(0, at: 0) }
        if grid[grid.count - 1] < seconds - 0.05 { grid.append(seconds) }
        let treble = chroma(harmonic, low: 110, high: 4200)
        let low = chroma(bass.isEmpty ? harmonic : bass, low: 35, high: 260)
        let fps = rate / Double(hop)
        func mean(_ c: [[Double]], _ a: Double, _ b: Double) -> [Double] {
            let i0 = max(0, min(c.count - 1, Int(a * fps))), i1 = max(i0 + 1, min(c.count, Int(b * fps)))
            var m = [Double](repeating: 0, count: 13)
            for i in i0..<i1 { for k in 0..<13 { m[k] += c[i][k] } }
            return m.map { $0 / Double(i1 - i0) }
        }
        let steps = (0..<(grid.count - 1)).map { (grid[$0], grid[$0 + 1]) }
        let loud = steps.map { mean(treble, $0.0, $0.1)[12] }
        let quiet = (loud.sorted().last ?? 0) * 0.02
        // 24 accordi + «nessuno»
        let states = 25
        var cost = [[Double]](repeating: [Double](repeating: 0, count: states), count: steps.count)
        for (t, s) in steps.enumerated() {
            let c = Array(mean(treble, s.0, s.1).prefix(12)), b = Array(mean(low, s.0, s.1).prefix(12))
            let bmax = max(1e-9, b.max() ?? 0)
            for q in 0..<24 {
                let root = q % 12, minor = q >= 12
                var score = Rhythm.cosine(c, template(root: root, minor: minor))
                score += 0.15 * b[root] / bmax
                if let k = key, inKey(root: root, minor: minor, key: k) { score += 0.04 }
                cost[t][q] = -score
            }
            cost[t][24] = loud[t] <= quiet ? -1 : 0.2
        }
        // Viterbi: restare costa 0, cambiare costa `change`
        let change = 0.18
        var acc = cost[0], back = [[Int]]()
        for t in 1..<steps.count {
            let best = acc.indices.min { acc[$0] < acc[$1] }!
            var next = [Double](repeating: 0, count: states), from = [Int](repeating: 0, count: states)
            for q in 0..<states {
                let stay = acc[q], jump = acc[best] + change
                if stay <= jump { next[q] = stay + cost[t][q]; from[q] = q } else { next[q] = jump + cost[t][q]; from[q] = best }
            }
            acc = next
            back.append(from)
        }
        var path = [Int](repeating: 0, count: steps.count)
        path[steps.count - 1] = acc.indices.min { acc[$0] < acc[$1] }!
        for t in stride(from: steps.count - 1, to: 0, by: -1) { path[t - 1] = back[t - 1][path[t]] }
        // Battiti uguali di fila diventano un accordo solo
        var out: [ChordSpan] = []
        for (t, q) in path.enumerated() {
            let root: Int? = q == 24 ? nil : q % 12, minor = q >= 12 && q < 24
            if let l = out.last, l.root == root, l.minor == minor {
                out[out.count - 1] = ChordSpan(start: l.start, end: steps[t].1, root: root, minor: minor)
            } else {
                out.append(ChordSpan(start: steps[t].0, end: steps[t].1, root: root, minor: minor))
            }
        }
        return out
    }

    /// Fondamentale, terza e quinta (la fondamentale pesa di più).
    static func template(root: Int, minor: Bool) -> [Double] {
        var t = [Double](repeating: 0, count: 12)
        t[root] = 1
        t[(root + (minor ? 3 : 4)) % 12] = 0.8
        t[(root + 7) % 12] = 0.8
        return t
    }

    /// Le triadi della scala: in Do maggiore C, Dm, Em, F, G, Am (la relativa minore usa le stesse).
    static func inKey(root: Int, minor: Bool, key: (root: Int, minor: Bool)) -> Bool {
        let tonic = key.minor ? (key.root + 3) % 12 : key.root
        let d = ((root - tonic) % 12 + 12) % 12
        return minor ? [2, 4, 9].contains(d) : [0, 5, 7].contains(d)
    }

    static let hop = 2205

    /// Croma a 20 colonne al secondo tra `low` e `high` Hz, compresso col logaritmo; l'ultima casella è il volume.
    static func chroma(_ x: [Float], low: Double, high: Double, fft: Int = 8192) -> [[Double]] {
        let s = PlainSTFT(nfft: fft, hop: hop)
        let z = s.forward(x)
        let T = s.frames(for: x.count), F = s.bins
        var pc = [Int](repeating: -1, count: F)
        for f in 1..<F {
            let hz = Double(f) * rate / Double(fft)
            guard hz >= low, hz <= high else { continue }
            pc[f] = ((Int((69 + 12 * log2(hz / 440)).rounded()) % 12) + 12) % 12
        }
        var out = [[Double]](repeating: [Double](repeating: 0, count: 13), count: T)
        for t in 0..<T {
            var total = 0.0
            for f in 1..<F where pc[f] >= 0 {
                let m = Double(hypot(z.re[f * T + t], z.im[f * T + t]))
                out[t][pc[f]] += m * m
                total += m * m
            }
            if total > 1e-12 { for i in 0..<12 { out[t][i] = log1p(100 * out[t][i] / total) } }
            out[t][12] = sqrt(total)
        }
        return out
    }
}
