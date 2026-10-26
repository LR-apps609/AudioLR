import Foundation
import Accelerate

// ════════════════════════════════════════════════════════════════════
//  Tempo e tonalità della canzone, calcolati sulle tracce separate:
//  il tempo dalla batteria (gli attacchi sono netti, senza voce e
//  accordi di mezzo), la tonalità da tutto tranne batteria e voce.
//  Solo calcoli sul segnale, niente modelli da scaricare.
// ════════════════════════════════════════════════════════════════════

struct SongAnalysis: Codable, Equatable {
    /// Battiti al minuto.
    let bpm: Double
    /// 0 = Do, 1 = Do♯ … 11 = Si.
    let keyRoot: Int
    let minor: Bool
    /// Quanto la tonalità è netta (0…1): sotto 0,5 la canzone cambia spesso tonalità o è poco tonale.
    let keyConfidence: Double
    /// Battiti, battute e parti della canzone (dalla 0.26; nelle separazioni precedenti manca).
    var structure: SongStructure? = nil

    static let names = ["Do", "Do♯", "Re", "Mi♭", "Mi", "Fa", "Fa♯", "Sol", "La♭", "La", "Si♭", "Si"]
    static let english = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

    /// «La minore»
    var keyName: String { Self.names[keyRoot] + (minor ? " minore" : " maggiore") }
    /// «Am», come lo scrivono i musicisti
    var keyShort: String { Self.english[keyRoot] + (minor ? "m" : "") }
    /// Notazione Camelot dei DJ («8A»): tonalità vicine hanno numeri vicini.
    var camelot: String {
        // Do maggiore = 8B, La minore = 8A; ogni quinta in su è +1
        let major = minor ? (keyRoot + 3) % 12 : keyRoot
        let n = ((major * 7) % 12 + 7) % 12 + 1
        return "\(n)\(minor ? "A" : "B")"
    }
    var bpmText: String { "\(Int(bpm.rounded())) BPM" }
}

enum Analysis {
    static let rate = 44_100.0

    /// Tempo e tonalità da una separazione (strumento × canale × campione).
    static func analyze(_ stems: [[[Float]]], sources: [String]) -> SongAnalysis? {
        guard let n = stems.first?.first?.count, n > Int(rate) * 4 else { return nil }
        func mono(_ keys: (String) -> Bool) -> [Float] {
            var m = [Float](repeating: 0, count: n)
            for (i, k) in sources.enumerated() where keys(k) {
                for c in 0..<min(2, stems[i].count) { vDSP.add(m, stems[i][c], result: &m) }
            }
            return m
        }
        let drums = mono { $0 == "drums" }
        let everything = mono { _ in true }
        let rhythm = sources.contains("drums") && energy(drums) > 1e-3 * energy(everything) ? drums : everything
        let harmonic = mono { $0 != "drums" && $0 != "vocals" }
        let key = self.key(energy(harmonic) > 1e-4 * energy(everything) ? harmonic : everything)
        let bpm = tempo(rhythm)
        let bass = mono { $0 == "bass" }
        let vocal = mono { $0 == "vocals" || $0 == "lead" || $0 == "backing" }
        let structure = Rhythm.structure(rhythm: rhythm, low: energy(bass) > 1e-4 * energy(everything) ? bass : rhythm,
                                         harmonic: energy(harmonic) > 1e-4 * energy(everything) ? harmonic : everything,
                                         vocal: vocal, all: everything, bpm: bpm)
        return SongAnalysis(bpm: bpm, keyRoot: key.root, minor: key.minor, keyConfidence: key.confidence, structure: structure)
    }

    private static func energy(_ x: [Float]) -> Float { vDSP.sumOfSquares(x) }

    // MARK: Tempo

    /// Forza degli attacchi: quanto cresce l'energia in ogni banda da un istante al successivo.
    static func onsetEnvelope(_ x: [Float], hop: Int = 441, fft: Int = 1024) -> [Float] {
        let s = PlainSTFT(nfft: fft, hop: hop)
        let z = s.forward(x)
        let T = s.frames(for: x.count), F = s.bins
        var prev = [Float](repeating: 0, count: F)
        var env = [Float](repeating: 0, count: T)
        for t in 0..<T {
            var flux: Float = 0
            for f in 1..<F {
                let mag = log1p(1000 * hypot(z.re[f * T + t], z.im[f * T + t]))
                flux += max(0, mag - prev[f])
                prev[f] = mag
            }
            env[t] = flux
        }
        // Si toglie la media mobile: restano solo gli attacchi
        let w = 16
        var out = [Float](repeating: 0, count: T)
        for t in 0..<T {
            let a = max(0, t - w), b = min(T, t + w + 1)
            var m: Float = 0
            for i in a..<b { m += env[i] }
            out[t] = max(0, env[t] - m / Float(b - a))
        }
        return out
    }

    /// Battiti al minuto tra 70 e 180, dall'autocorrelazione degli attacchi.
    static func tempo(_ x: [Float]) -> Double {
        let hop = 441
        let env = onsetEnvelope(x, hop: hop)
        let fps = rate / Double(hop)                       // 100 colonne al secondo
        let minLag = Int(fps * 60 / 180), maxLag = Int(fps * 60 / 70)
        guard env.count > maxLag * 4 else { return 120 }
        func ac(_ lag: Int) -> Double {
            var s = 0.0
            for i in 0..<(env.count - lag) { s += Double(env[i]) * Double(env[i + lag]) }
            return s / Double(env.count - lag)
        }
        let acs = (0...maxLag * 2).map { $0 >= minLag / 2 ? ac($0) : 0 }
        var best = minLag, bestScore = -Double.infinity
        for lag in minLag...maxLag {
            // Il battito vero si ripete anche al doppio: si premiano i ritardi che tornano
            let bpm = fps * 60 / Double(lag)
            let prior = exp(-0.5 * pow(log2(bpm / 120) / 0.9, 2))
            let score = (acs[lag] + 0.5 * acs[min(lag * 2, acs.count - 1)]) * prior
            if score > bestScore { bestScore = score; best = lag }
        }
        // Precisione sotto la colonna: parabola sui tre punti attorno al massimo
        let y0 = acs[best - 1], y1 = acs[best], y2 = acs[best + 1]
        let d = y0 - 2 * y1 + y2
        let shift = d != 0 ? max(-0.5, min(0.5, 0.5 * (y0 - y2) / d)) : 0
        return fps * 60 / (Double(best) + shift)
    }

    // MARK: Tonalità

    /// Profili di Krumhansl-Kessler: quanto ogni grado «suona» in una tonalità maggiore e minore.
    static let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    /// Energia di ogni nota (Do…Si) in tutta la canzone, tra 55 Hz e 5 kHz.
    static func chroma(_ x: [Float], fft: Int = 8192) -> [Double] {
        let hop = fft
        let s = PlainSTFT(nfft: fft, hop: hop)
        let z = s.forward(x)
        let T = s.frames(for: x.count), F = s.bins
        var pc = [Int](repeating: -1, count: F)
        for f in 1..<F {
            let hz = Double(f) * rate / Double(fft)
            guard hz >= 55, hz <= 5000 else { continue }
            let midi = 69 + 12 * log2(hz / 440)
            pc[f] = ((Int(midi.rounded()) % 12) + 12) % 12
        }
        var c = [Double](repeating: 0, count: 12)
        for t in 0..<T {
            var frame = [Double](repeating: 0, count: 12), total = 0.0
            for f in 1..<F where pc[f] >= 0 {
                let m = Double(hypot(z.re[f * T + t], z.im[f * T + t]))
                frame[pc[f]] += m
                total += m
            }
            // Ogni istante conta uguale, forte o piano
            if total > 1e-6 { for i in 0..<12 { c[i] += frame[i] / total } }
        }
        return c
    }

    static func key(_ x: [Float]) -> (root: Int, minor: Bool, confidence: Double) {
        let c = chroma(x)
        func corr(_ a: [Double], _ b: [Double]) -> Double {
            let ma = a.reduce(0, +) / 12, mb = b.reduce(0, +) / 12
            var num = 0.0, da = 0.0, db = 0.0
            for i in 0..<12 { num += (a[i] - ma) * (b[i] - mb); da += pow(a[i] - ma, 2); db += pow(b[i] - mb, 2) }
            return da > 0 && db > 0 ? num / sqrt(da * db) : 0
        }
        var scores: [(root: Int, minor: Bool, r: Double)] = []
        for root in 0..<12 {
            let rotated = (0..<12).map { c[($0 + root) % 12] }
            scores.append((root, false, corr(rotated, majorProfile)))
            scores.append((root, true, corr(rotated, minorProfile)))
        }
        scores.sort { $0.r > $1.r }
        let best = scores[0]
        // Netta se la migliore stacca le altre (la relativa minore/maggiore è sempre vicina: si guarda la terza)
        let gap = best.r - scores[2].r
        return (best.root, best.minor, max(0, min(1, best.r * 0.6 + gap * 2)))
    }
}
