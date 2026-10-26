import Foundation
import Accelerate

// ════════════════════════════════════════════════════════════════════
//  Battiti, battute e parti della canzone, calcolati sulle tracce separate.
//  • Battiti: dagli attacchi della batteria, con la programmazione dinamica
//    di Ellis (2007): ogni battito cade su un attacco forte e lontano dal
//    precedente quanto vuole il tempo.
//  • Primo battito della battuta (4/4): dove il basso attacca e gli accordi
//    cambiano più spesso, tra le quattro posizioni possibili.
//  • Parti: le battute si confrontano tra loro (accordi, timbro, voce); i
//    punti dove la canzone «cambia» dividono le parti, le parti che si
//    somigliano hanno la stessa lettera. Il ritornello è la parte con la voce
//    che torna più volte ed è più forte; senza voce: intro, strumentale, finale.
//  Solo calcoli sul segnale, niente modelli da scaricare. Le parti sono una
//  stima: si possono sempre spostare a mano.
// ════════════════════════════════════════════════════════════════════

struct SongSection: Codable, Equatable {
    /// Secondi dall'inizio della canzone.
    let start: Double
    let end: Double
    /// «Intro», «Strofa», «Ritornello», «Ponte», «Strumentale», «Finale».
    let label: String
    /// Le parti con lo stesso numero si somigliano (A, B, C…).
    let group: Int
}

struct SongStructure: Codable, Equatable {
    /// I battiti, in secondi.
    let beats: [Double]
    /// Indice in `beats` del primo battito di una battuta.
    let firstDownbeat: Int
    let beatsPerBar: Int
    let sections: [SongSection]

    /// I primi battiti di ogni battuta.
    var downbeats: [Double] { stride(from: firstDownbeat, to: beats.count, by: beatsPerBar).map { beats[$0] } }
}

enum Rhythm {
    static let rate = 44_100.0
    static let hop = 441                                    // 100 colonne al secondo

    // MARK: Battiti

    /// Battiti (in colonne) dalla forza degli attacchi `env` e dal periodo `period` (colonne per battito).
    static func beats(env: [Float], period: Double, tightness: Double = 100) -> [Int] {
        let n = env.count
        guard n > Int(period * 4), period >= 2 else { return [] }
        // Gli attacchi si normalizzano, così la tolleranza sul tempo pesa allo stesso modo in ogni canzone
        let sd = max(1e-9, Double(vDSP.standardDeviation(env)))
        let e = env.map { Double($0) / sd }
        var score = [Double](repeating: 0, count: n)
        var back = [Int](repeating: -1, count: n)
        let lo = Int((period / 2).rounded()), hi = Int((period * 2).rounded())
        for t in 0..<n {
            var best = 0.0, arg = -1
            if t - lo >= 0 {
                for p in max(0, t - hi)...(t - lo) {
                    let d = log(Double(t - p) / period)
                    let s = score[p] - tightness * d * d
                    if arg < 0 || s > best { best = s; arg = p }
                }
            }
            score[t] = e[t] + max(0, best)
            back[t] = best > 0 ? arg : -1
        }
        // L'ultimo battito: il punteggio più alto nell'ultimo periodo
        var t = (max(0, n - Int(period))..<n).max { score[$0] < score[$1] } ?? n - 1
        var out: [Int] = []
        while t >= 0 { out.append(t); t = back[t] }
        return out.reversed()
    }

    /// Valore medio di `x` attorno alla colonna `i` (±w).
    private static func around(_ x: [Float], _ i: Int, _ w: Int = 3) -> Double {
        let a = max(0, i - w), b = min(x.count, i + w + 1)
        guard b > a else { return 0 }
        var s: Float = 0
        for k in a..<b { s = max(s, x[k]) }
        return Double(s)
    }

    /// Tra le `bpb` posizioni, quella del primo battito: dove attacca il basso (o la cassa) e cambiano gli accordi.
    static func downbeatPhase(beats: [Int], low: [Float], change: [Double], bpb: Int = 4) -> Int {
        guard beats.count >= bpb * 2 else { return 0 }
        var best = 0, bestScore = -Double.infinity
        let lowMax = max(1e-9, Double(low.max() ?? 1))
        for phase in 0..<bpb {
            var s = 0.0, n = 0
            for i in stride(from: phase, to: beats.count, by: bpb) {
                s += around(low, beats[i]) / lowMax + (i < change.count ? change[i] : 0)
                n += 1
            }
            let score = n > 0 ? s / Double(n) : 0
            if score > bestScore { bestScore = score; best = phase }
        }
        return best
    }

    // MARK: Caratteristiche per battito

    /// Note (Do…Si) per finestre di `hop` campioni, normalizzate: una riga per finestra.
    static func chromaFrames(_ x: [Float], fft: Int = 8192, hop: Int = 4410) -> [[Double]] {
        let s = PlainSTFT(nfft: fft, hop: hop)
        let z = s.forward(x)
        let T = s.frames(for: x.count), F = s.bins
        var pc = [Int](repeating: -1, count: F)
        for f in 1..<F {
            let hz = Double(f) * rate / Double(fft)
            guard hz >= 55, hz <= 5000 else { continue }
            pc[f] = ((Int((69 + 12 * log2(hz / 440)).rounded()) % 12) + 12) % 12
        }
        var out = [[Double]](repeating: [Double](repeating: 0, count: 12), count: T)
        for t in 0..<T {
            var total = 0.0
            for f in 1..<F where pc[f] >= 0 {
                let m = Double(hypot(z.re[f * T + t], z.im[f * T + t]))
                out[t][pc[f]] += m
                total += m
            }
            if total > 1e-9 { for i in 0..<12 { out[t][i] /= total } }
        }
        return out
    }

    /// Energia (RMS) di `x` tra i campioni `a` e `b`.
    static func rms(_ x: [Float], _ a: Int, _ b: Int) -> Double {
        let a = max(0, min(x.count, a)), b = max(a, min(x.count, b))
        guard b > a else { return 0 }
        return Double(x[a..<b].withUnsafeBufferPointer { vDSP.rootMeanSquare($0) })
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        var ab = 0.0, aa = 0.0, bb = 0.0
        for i in 0..<min(a.count, b.count) { ab += a[i] * b[i]; aa += a[i] * a[i]; bb += b[i] * b[i] }
        return aa > 0 && bb > 0 ? ab / sqrt(aa * bb) : 0
    }

    // MARK: Parti

    /// Dove la canzone cambia: novità di Foote sulla matrice delle somiglianze tra battute (kernel a scacchiera).
    static func novelty(_ sim: [[Double]], half: Int = 4) -> [Double] {
        let n = sim.count
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var s = 0.0
            for a in -half..<half {
                for b in -half..<half {
                    let x = i + a, y = i + b
                    guard x >= 0, y >= 0, x < n, y < n else { continue }
                    // Stessa parte (entrambi prima o entrambi dopo): +; a cavallo: −
                    let sign: Double = (a < 0) == (b < 0) ? 1 : -1
                    let g = exp(-0.5 * (pow((Double(a) + 0.5) / Double(half), 2) + pow((Double(b) + 0.5) / Double(half), 2)))
                    s += sign * g * sim[x][y]
                }
            }
            out[i] = max(0, s)
        }
        return out
    }

    /// I confini (indici di battuta) dai picchi della novità: almeno `minBars` battute per parte.
    static func boundaries(_ nov: [Double], minBars: Int = 4) -> [Int] {
        let n = nov.count
        guard n > minBars * 2 else { return [0, n] }
        let mean = nov.reduce(0, +) / Double(n)
        let sd = sqrt(nov.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(n))
        let threshold = mean + 0.5 * sd
        var peaks: [(i: Int, v: Double)] = []
        for i in 1..<(n - 1) where nov[i] > threshold && nov[i] >= nov[i - 1] && nov[i] >= nov[i + 1] {
            peaks.append((i, nov[i]))
        }
        // I più forti per primi; un picco troppo vicino a uno già scelto si scarta
        var chosen: [Int] = []
        for p in peaks.sorted(by: { $0.v > $1.v }) where chosen.allSatisfy({ abs($0 - p.i) >= minBars }) && p.i >= minBars && n - p.i >= minBars {
            chosen.append(p.i)
        }
        return [0] + chosen.sorted() + [n]
    }

    /// Le parti si raggruppano per somiglianza: una parte nuova va nel gruppo più simile, se lo è abbastanza.
    static func groups(_ features: [[Double]], threshold: Double = 0.93) -> [Int] {
        var centers: [[Double]] = [], counts: [Int] = [], out: [Int] = []
        for f in features {
            var best = -1, bestSim = -1.0
            for (g, c) in centers.enumerated() {
                let s = cosine(f, c)
                if s > bestSim { bestSim = s; best = g }
            }
            if best >= 0 && bestSim >= threshold {
                out.append(best)
                let k = Double(counts[best])
                centers[best] = zip(centers[best], f).map { ($0 * k + $1) / (k + 1) }
                counts[best] += 1
            } else {
                out.append(centers.count)
                centers.append(f)
                counts.append(1)
            }
        }
        return out
    }

    /// I nomi delle parti dai gruppi, dalla voce e dal volume.
    static func labels(groups: [Int], vocal: [Double], loud: [Double]) -> [String] {
        let n = groups.count
        guard n > 0 else { return [] }
        let maxLoud = max(1e-9, loud.max() ?? 1)
        let sung = (0..<n).map { vocal[$0] > 0.12 }
        var count: [Int: Int] = [:]
        for g in groups { count[g, default: 0] += 1 }
        // Ritornello: tra i gruppi cantati, quello che torna di più e suona più forte
        var chorus: Int?
        var bestScore = -1.0
        for g in Set(groups) {
            let idx = (0..<n).filter { groups[$0] == g && sung[$0] }
            guard !idx.isEmpty, count[g, default: 0] >= 2 else { continue }
            let s = Double(count[g, default: 0]) + 2 * idx.map { loud[$0] / maxLoud }.reduce(0, +) / Double(idx.count)
            if s > bestScore { bestScore = s; chorus = g }
        }
        var out: [String] = []
        var seenChorus = false
        for i in 0..<n {
            if !sung[i] {
                out.append(i == 0 ? "Intro" : i == n - 1 ? "Finale" : "Strumentale")
            } else if groups[i] == chorus {
                out.append("Ritornello"); seenChorus = true
            } else if count[groups[i], default: 0] == 1 && seenChorus && i < n - 1 {
                out.append("Ponte")
            } else {
                out.append("Strofa")
            }
        }
        return out
    }

    /// Battiti, battute e parti di una canzone separata (mono di ogni gruppo di tracce).
    static func structure(rhythm: [Float], low: [Float], harmonic: [Float], vocal: [Float], all: [Float], bpm: Double) -> SongStructure? {
        let fps = rate / Double(hop)
        let env = Analysis.onsetEnvelope(rhythm, hop: hop)
        let beatCols = beats(env: env, period: fps * 60 / bpm)
        guard beatCols.count >= 16 else { return nil }
        let lowEnv = Analysis.onsetEnvelope(low, hop: hop)
        // Cambio di accordi a ogni battito: la nota media del battito prima contro quella del battito dopo
        let chroma = chromaFrames(harmonic)
        let cps = rate / 4410
        func chromaMean(_ a: Double, _ b: Double) -> [Double] {
            let i0 = max(0, Int(a * cps)), i1 = min(chroma.count, max(i0 + 1, Int(b * cps)))
            guard i1 > i0 else { return [Double](repeating: 0, count: 12) }
            var m = [Double](repeating: 0, count: 12)
            for i in i0..<i1 { for k in 0..<12 { m[k] += chroma[i][k] } }
            return m.map { $0 / Double(i1 - i0) }
        }
        let times = beatCols.map { Double($0) / fps }
        var change = [Double](repeating: 0, count: times.count)
        for i in 1..<(times.count - 1) {
            change[i] = 1 - cosine(chromaMean(times[i - 1], times[i]), chromaMean(times[i], times[i + 1]))
        }
        let bpb = 4
        let first = downbeatPhase(beats: beatCols, low: lowEnv, change: change, bpb: bpb)
        // Battute: dal primo battito, quattro battiti l'una
        let bars = stride(from: first, to: times.count - 1, by: bpb).map { i -> (Double, Double) in
            (times[i], i + bpb < times.count ? times[i + bpb] : times[times.count - 1])
        }
        guard bars.count >= 8 else {
            return SongStructure(beats: times, firstDownbeat: first, beatsPerBar: bpb, sections: [])
        }
        // Una riga per battuta: accordi (12) e timbro (volume per fasce, normalizzato), più la voce
        let sr = rate
        let feats: [[Double]] = bars.map { a, b in
            let c = chromaMean(a, b)
            let s0 = Int(a * sr), s1 = Int(b * sr)
            let l = rms(all, s0, s1) + 1e-9
            return c + [rms(low, s0, s1) / l, rms(harmonic, s0, s1) / l, rms(vocal, s0, s1) / l, rms(rhythm, s0, s1) / l]
        }
        var sim = [[Double]](repeating: [Double](repeating: 0, count: bars.count), count: bars.count)
        for i in 0..<bars.count { for j in i..<bars.count { let s = cosine(feats[i], feats[j]); sim[i][j] = s; sim[j][i] = s } }
        let cuts = boundaries(novelty(sim))
        var segFeat: [[Double]] = [], vocalShare: [Double] = [], loud: [Double] = []
        for k in 0..<(cuts.count - 1) {
            let r = cuts[k]..<cuts[k + 1]
            var m = [Double](repeating: 0, count: feats[0].count)
            for i in r { for j in 0..<m.count { m[j] += feats[i][j] } }
            segFeat.append(m.map { $0 / Double(r.count) })
            let s0 = Int(bars[r.lowerBound].0 * sr), s1 = Int(bars[r.upperBound - 1].1 * sr)
            let l = rms(all, s0, s1) + 1e-9
            vocalShare.append(rms(vocal, s0, s1) / l)
            loud.append(l)
        }
        let g = groups(segFeat)
        let names = labels(groups: g, vocal: vocalShare, loud: loud)
        var sections: [SongSection] = []
        for k in 0..<(cuts.count - 1) {
            let start = k == 0 ? 0 : bars[cuts[k]].0
            let end = k == cuts.count - 2 ? Double(all.count) / sr : bars[cuts[k + 1]].0
            // Due parti uguali di fila diventano una sola
            if let last = sections.last, last.label == names[k], last.group == g[k] {
                sections[sections.count - 1] = SongSection(start: last.start, end: end, label: last.label, group: last.group)
            } else {
                sections.append(SongSection(start: start, end: end, label: names[k], group: g[k]))
            }
        }
        return SongStructure(beats: times, firstDownbeat: first, beatsPerBar: bpb, sections: sections)
    }
}
