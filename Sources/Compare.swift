import Foundation
import Accelerate

// ════════════════════════════════════════════════════════════════════
//  Confronto con l'originale: la tua registrazione contro la traccia
//  separata (la voce, il basso…), negli stessi secondi della canzone.
//  • Intonazione: l'altezza (YIN) ogni 10 ms in tutte e due; una nota è
//    «intonata» se sta entro 50 cent dall'originale. Un'ottava sopra o
//    sotto vale lo stesso (una donna che canta la parte di un uomo).
//  • Tempo: gli attacchi delle due tracce, spostati finché combaciano:
//    di quanto sei in anticipo o in ritardo, in media.
//  Solo calcoli sul segnale, niente modelli da scaricare.
// ════════════════════════════════════════════════════════════════════

struct CompareResult: Equatable {
    /// Quota dei momenti intonati (0…1), dove suonano tutte e due.
    let inTune: Double
    /// Di quanto sei in media sopra (+) o sotto (−) l'originale, in cent.
    let cents: Double
    /// Di quanto sei in anticipo (−) o in ritardo (+), in millisecondi.
    let offsetMs: Double
    /// Secondi confrontati (dove suonano tutte e due).
    let seconds: Double
    /// Da dove a dove hai suonato, in secondi della canzone.
    let start: Double
    let end: Double
    /// Le due linee dell'altezza (in semitoni MIDI, nil = silenzio), un punto ogni `step` secondi da `start`.
    let mine: [Double?]
    let original: [Double?]
    let step: Double

    /// «Ottimo», «Buono»…: una parola sul risultato.
    var verdict: String {
        switch inTune {
        case 0.85...: return "Ottimo"
        case 0.7..<0.85: return "Buono"
        case 0.5..<0.7: return "Quasi"
        default: return "Da ripassare"
        }
    }
}

enum Compare {
    static let rate = 44_100.0
    /// Si lavora a 11 025 Hz: basta per l'altezza di voce e strumenti ed è quattro volte più veloce.
    static let down = 4
    static let hop = 110               // 10 ms a 11 025 Hz
    static let frame = 512

    enum Problem: LocalizedError {
        case silent
        var errorDescription: String? {
            switch self {
            case .silent: return "Nella registrazione o nella traccia scelta non c'è abbastanza suono da confrontare."
            }
        }
    }

    static func run(take: [Float], original: [Float]) throws -> CompareResult {
        let a = decimate(take), b = decimate(original)
        let n = min(a.count, b.count)
        guard n > frame * 4 else { throw Problem.silent }
        let sr = rate / Double(down)
        // Dove hai suonato: le colonne con abbastanza volume
        let frames = (n - frame) / hop
        let ra = (0..<frames).map { rms(a, $0 * hop) }, rb = (0..<frames).map { rms(b, $0 * hop) }
        let la = (ra.max() ?? 0) * 0.03, lb = (rb.max() ?? 0) * 0.03
        guard let first = ra.firstIndex(where: { $0 > la }), let last = ra.lastIndex(where: { $0 > la }), last > first + 50 else {
            throw Problem.silent
        }
        var mine = [Double?](), orig = [Double?]()
        var diffs = [Double]()
        for t in first...last {
            let pa = ra[t] > la ? yin(a, t * hop, sr: sr) : nil
            let pb = rb[t] > lb ? yin(b, t * hop, sr: sr) : nil
            mine.append(pa.map(midi))
            orig.append(pb.map(midi))
            if let x = pa, let y = pb {
                // Un'ottava sopra o sotto conta come la stessa nota
                var d = 1200 * log2(x / y)
                d -= 1200 * (d / 1200).rounded()
                diffs.append(d)
            }
        }
        guard diffs.count >= 30 else { throw Problem.silent }
        let inTune = Double(diffs.filter { abs($0) <= 50 }.count) / Double(diffs.count)
        let sorted = diffs.sorted()
        let cents = sorted[sorted.count / 2]
        let offset = lag(onsets(a, from: first, to: last), onsets(b, from: first, to: last))
        let step = Double(hop) / sr
        return CompareResult(inTune: inTune, cents: cents, offsetMs: offset * step * 1000, seconds: Double(diffs.count) * step,
                             start: Double(first) * step, end: Double(last) * step, mine: mine, original: orig, step: step)
    }

    /// Da 44,1 kHz a 11 025 Hz, con un filtro che toglie gli acuti prima (niente suoni «riflessi»).
    static func decimate(_ x: [Float]) -> [Float] {
        guard x.count > 64 else { return [] }
        let taps = 31
        let fc = 0.9 / Double(down) / 2
        var h = [Float](repeating: 0, count: taps)
        for i in 0..<taps {
            let m = Double(i - taps / 2)
            let sinc = m == 0 ? 2 * fc : sin(2 * .pi * fc * m) / (.pi * m)
            h[i] = Float(sinc * (0.54 - 0.46 * cos(2 * .pi * Double(i) / Double(taps - 1))))
        }
        let filtered = vDSP.convolve(x + [Float](repeating: 0, count: taps - 1), withKernel: h)
        return stride(from: 0, to: filtered.count, by: down).map { filtered[$0] }
    }

    static func rms(_ x: [Float], _ at: Int) -> Float {
        guard at + frame <= x.count else { return 0 }
        return x[at..<(at + frame)].withUnsafeBufferPointer { vDSP.rootMeanSquare($0) }
    }

    /// Altezza in Hz con YIN (de Cheveigné e Kawahara, 2002); nil se il suono non ha una nota chiara.
    static func yin(_ x: [Float], _ at: Int, sr: Double, fmin: Double = 60, fmax: Double = 1000, threshold: Float = 0.15) -> Double? {
        let w = frame / 2
        let lo = Int(sr / fmax), hi = min(w - 1, Int(sr / fmin))
        guard at + frame <= x.count, hi > lo + 2 else { return nil }
        var d = [Float](repeating: 0, count: hi + 1)
        x.withUnsafeBufferPointer { p in
            let base = p.baseAddress! + at
            for tau in 1...hi {
                var s: Float = 0
                vDSP_distancesq(base, 1, base + tau, 1, &s, vDSP_Length(w))
                d[tau] = s
            }
        }
        // Differenza normalizzata cumulativa
        var cum: Float = 0
        var nd = [Float](repeating: 1, count: hi + 1)
        for tau in 1...hi {
            cum += d[tau]
            nd[tau] = cum > 0 ? d[tau] * Float(tau) / cum : 1
        }
        var tau = lo
        while tau < hi {
            if nd[tau] < threshold {
                while tau + 1 < hi && nd[tau + 1] < nd[tau] { tau += 1 }
                break
            }
            tau += 1
        }
        guard tau < hi, nd[tau] < threshold else { return nil }
        // Interpolazione parabolica intorno al minimo
        let a = nd[tau - 1], b = nd[tau], c = nd[tau + 1]
        let den = a - 2 * b + c
        let shift = den != 0 ? Double((a - c) / (2 * den)) : 0
        return sr / (Double(tau) + max(-1, min(1, shift)))
    }

    static func midi(_ hz: Double) -> Double { 69 + 12 * log2(hz / 440) }

    /// Forza degli attacchi (crescita del volume) colonna per colonna, tra `from` e `to`.
    static func onsets(_ x: [Float], from: Int, to: Int) -> [Double] {
        var prev = 0.0
        return (from...to).map { t in
            let e = log1p(1000 * Double(rms(x, t * hop)))
            defer { prev = e }
            return max(0, e - prev)
        }
    }

    /// Lo spostamento (in colonne, ±15 = ±150 ms) che fa combaciare meglio gli attacchi:
    /// positivo = la tua registrazione arriva dopo.
    static func lag(_ mine: [Double], _ original: [Double], maxLag: Int = 15) -> Double {
        var best = 0, bestScore = -Double.infinity
        for l in -maxLag...maxLag {
            var s = 0.0
            for i in 0..<original.count {
                let j = i + l
                if j >= 0 && j < mine.count { s += original[i] * mine[j] }
            }
            if s > bestScore { bestScore = s; best = l }
        }
        return Double(best)
    }
}
