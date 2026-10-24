import Foundation
import CoreML
import Accelerate

// ════════════════════════════════════════════════════════════════════
//  I modelli RoFormer: Mel-Band per la voce (molti meno strumenti in
//  sottofondo di Demucs) e BS-RoFormer «SW» per gli strumenti (batteria,
//  basso, chitarra, pianoforte, altro). Come per Demucs, Core ML fa solo
//  la rete; qui ci sono STFT, raccolta delle bande, applicazione delle
//  maschere (una per strumento) e ritorno all'onda.
//  Tools/convert_roformer.py ne contiene la copia in Python, confrontata
//  con il modello originale: se qui cambia qualcosa, va cambiato anche lì.
// ════════════════════════════════════════════════════════════════════

/// STFT e iSTFT come torch.stft/istft (finestra di Hann, centrate con riflessione, non normalizzate).
final class PlainSTFT {
    let nfft: Int
    let hop: Int
    var bins: Int { nfft / 2 + 1 }
    private let window: [Float]
    private let forwardDFT: vDSP.DiscreteFourierTransform<Float>
    private let inverseDFT: vDSP.DiscreteFourierTransform<Float>

    init(nfft: Int = 2048, hop: Int = 441) {
        self.nfft = nfft
        self.hop = hop
        window = (0..<nfft).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(nfft))) }
        forwardDFT = try! vDSP.DiscreteFourierTransform(count: nfft, direction: .forward, transformType: .complexComplex, ofType: Float.self)
        inverseDFT = try! vDSP.DiscreteFourierTransform(count: nfft, direction: .inverse, transformType: .complexComplex, ofType: Float.self)
    }

    func frames(for length: Int) -> Int { 1 + length / hop }

    /// Parte reale e immaginaria, `bins × frames` (prima la frequenza).
    func forward(_ x: [Float]) -> (re: [Float], im: [Float]) {
        let T = frames(for: x.count)
        let xp = Spectrogram.reflectPad(x, left: nfft / 2, right: nfft / 2)
        var re = [Float](repeating: 0, count: bins * T), im = re
        var frame = [Float](repeating: 0, count: nfft)
        let zeros = [Float](repeating: 0, count: nfft)
        var oR = [Float](repeating: 0, count: nfft), oI = oR
        for t in 0..<T {
            let s = t * hop
            for n in 0..<nfft { frame[n] = (s + n < xp.count ? xp[s + n] : 0) * window[n] }
            forwardDFT.transform(inputReal: frame, inputImaginary: zeros, outputReal: &oR, outputImaginary: &oI)
            for k in 0..<bins {
                re[k * T + t] = oR[k]
                im[k * T + t] = oI[k]
            }
        }
        return (re, im)
    }

    /// Dallo spettro (`bins × frames`) all'onda lunga `length`.
    func inverse(re: [Float], im: [Float], frames T: Int, length: Int) -> [Float] {
        let total = nfft + hop * (T - 1)
        var buf = [Float](repeating: 0, count: total), env = buf
        var iR = [Float](repeating: 0, count: nfft), iI = iR, oR = iR, oI = iR
        let half = nfft / 2
        let scale = 1 / Float(nfft)
        for t in 0..<T {
            // Spettro completo e simmetrico; le parti immaginarie di 0 e Nyquist non contano (come irfft)
            iR[0] = re[t]; iI[0] = 0
            iR[half] = re[half * T + t]; iI[half] = 0
            for k in 1..<half {
                let r = re[k * T + t], i = im[k * T + t]
                iR[k] = r; iI[k] = i
                iR[nfft - k] = r; iI[nfft - k] = -i
            }
            inverseDFT.transform(inputReal: iR, inputImaginary: iI, outputReal: &oR, outputImaginary: &oI)
            let s = t * hop
            for n in 0..<nfft {
                buf[s + n] += oR[n] * scale * window[n]
                env[s + n] += window[n] * window[n]
            }
        }
        var out = [Float](repeating: 0, count: length)
        for i in 0..<length {
            let j = half + i
            guard j < total else { break }
            out[i] = env[j] > 1e-11 ? buf[j] / env[j] : buf[j]
        }
        return out
    }
}

/// Il modello convertito (es. VoceRoFormer8.mlpackage) con la sua descrizione (VoceRoFormer8.json).
struct RoFormerConfig: Codable {
    let n_fft: Int
    let hop: Int
    let chunk: Int
    let frames: Int
    let freq_indices: [Int]
    let num_bands_per_freq: [Double]
    let sources: [String]
}

/// Un modello RoFormer qualsiasi (voce o più strumenti): stesso codice, cambia solo la descrizione.
typealias RoFormer = VoiceRoFormer

final class VoiceRoFormer {
    let model: MLModel?
    let config: RoFormerConfig
    let stft: PlainSTFT
    /// Per i test: una rete finta al posto del modello (riceve x, restituisce le maschere).
    var fakeNetwork: (([Float]) -> [Float])?
    /// Quanto si sovrappongono due pezzi: 2 = ogni punto è coperto da due pezzi.
    var overlap = 2

    init(model: MLModel?, config: RoFormerConfig) {
        self.model = model
        self.config = config
        stft = PlainSTFT(nfft: config.n_fft, hop: config.hop)
    }

    var fsel: Int { config.freq_indices.count }
    /// Quanti strumenti dà il modello (1 per il modello voce).
    var stemCount: Int { max(config.sources.count, 1) }
    /// Lo strumento restituito da `runChunk`/`separate`: la voce, se il modello la conosce.
    var primary: Int { config.sources.firstIndex(of: "vocals") ?? 0 }

    /// Un pezzo di `chunk` campioni per canale → la voce di quel pezzo.
    func runChunk(_ piece: [[Float]]) throws -> [[Float]] { try runChunkAll(piece)[primary] }

    /// Un pezzo di `chunk` campioni per canale → ogni strumento di quel pezzo (strumento × canale × campione).
    func runChunkAll(_ piece: [[Float]]) throws -> [[[Float]]] {
        let T = config.frames, F = stft.bins, FS = fsel
        let z = piece.map { stft.forward($0) }
        precondition(z[0].re.count == F * T, "pezzo della misura sbagliata")
        // Ingresso: per ogni istante, le frequenze delle bande (reale, immaginaria)
        var x = [Float](repeating: 0, count: T * FS * 2)
        for (j, g) in config.freq_indices.enumerated() {
            let f = g / 2, s = g % 2
            let base = f * T
            for t in 0..<T {
                x[t * FS * 2 + j * 2] = z[s].re[base + t]
                x[t * FS * 2 + j * 2 + 1] = z[s].im[base + t]
            }
        }
        let mask: [Float]
        if let fake = fakeNetwork {
            mask = fake(x)
        } else {
            guard let model else { throw SeparationError("modello voce non disponibile") }
            let input = try MLDictionaryFeatureProvider(dictionary: ["x": try CoreMLSeparationCore.array(x, shape: [1, T, FS * 2])])
            guard let out = try model.prediction(from: input).featureValue(for: "mask")?.multiArrayValue else {
                throw SeparationError("il modello voce non ha dato risultati")
            }
            mask = CoreMLSeparationCore.floats(out)
        }
        let S = stemCount, per = T * FS * 2
        guard mask.count == per * S else { throw SeparationError("il modello ha risposto con misure inattese") }
        var all: [[[Float]]] = []
        for k in 0..<S {
            let o = k * per
            // Le bande si sovrappongono: si sommano le maschere per frequenza e si fa la media
            var sumR = [Float](repeating: 0, count: 2 * F * T), sumI = sumR
            for (j, g) in config.freq_indices.enumerated() {
                for t in 0..<T {
                    sumR[g * T + t] += mask[o + t * FS * 2 + j * 2]
                    sumI[g * T + t] += mask[o + t * FS * 2 + j * 2 + 1]
                }
            }
            var out: [[Float]] = []
            for s in 0..<2 {
                var re = [Float](repeating: 0, count: F * T), im = re
                for f in 0..<F {
                    let g = f * 2 + s
                    let d = Float(max(config.num_bands_per_freq[f], 1e-8))
                    for t in 0..<T {
                        let mr = sumR[g * T + t] / d, mi = sumI[g * T + t] / d
                        let ar = z[s].re[f * T + t], ai = z[s].im[f * T + t]
                        re[f * T + t] = ar * mr - ai * mi
                        im[f * T + t] = ar * mi + ai * mr
                    }
                }
                out.append(stft.inverse(re: re, im: im, frames: T, length: piece[s].count))
            }
            all.append(out)
        }
        return all
    }

    /// Finestra di Hamming per ricucire i pezzi (come audio-separator).
    static func hamming(_ n: Int) -> [Float] {
        guard n > 1 else { return [1] }
        return (0..<n).map { Float(0.54 - 0.46 * cos(2 * Double.pi * Double($0) / Double(n - 1))) }
    }

    /// La voce di tutta la canzone (2 canali), a pezzi sovrapposti.
    func separate(_ mix: [[Float]], progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }) throws -> [[Float]] {
        try separateAll(mix, progress: progress, isCancelled: isCancelled)[primary]
    }

    /// Ogni strumento di tutta la canzone (strumento × canale × campione), a pezzi sovrapposti.
    func separateAll(_ mix: [[Float]], progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }) throws -> [[[Float]]] {
        let length = mix[0].count, chunk = config.chunk, S = stemCount
        let step = max(1, chunk / max(overlap, 1))
        let w = Self.hamming(chunk)
        var out = [[[Float]]](repeating: [[Float]](repeating: [Float](repeating: 0, count: length), count: 2), count: S)
        var count = [Float](repeating: 0, count: length)
        let starts = Array(stride(from: 0, to: length, by: step))
        for (n, start) in starts.enumerated() {
            if isCancelled() { throw CancellationError() }
            let len = min(chunk, length - start)
            var piece = [[Float]](repeating: [Float](repeating: 0, count: chunk), count: 2)
            for c in 0..<2 { for i in 0..<len { piece[c][i] = mix[c][start + i] } }
            let v = try runChunkAll(piece)
            if n == 0, !Self.plausible(piece: piece, stems: v) { throw ImplausibleResult() }
            for k in 0..<S { for c in 0..<2 { for i in 0..<len { out[k][c][start + i] += v[k][c][i] * w[i] } } }
            for i in 0..<len { count[start + i] += w[i] }
            progress(Double(n + 1) / Double(starts.count))
        }
        for i in 0..<length { count[i] = 1 / max(count[i], 1e-10) }
        for k in 0..<S { for c in 0..<2 { for i in 0..<length { out[k][c][i] *= count[i] } } }
        return out
    }

    /// Nessuno strumento può essere più forte della canzone stessa, né contenere numeri non validi.
    static func plausible(piece: [[Float]], stems: [[[Float]]]) -> Bool {
        stems.allSatisfy { plausible(piece: piece, voice: $0) }
    }

    /// La voce non può essere più forte della canzone stessa, né contenere numeri non validi.
    static func plausible(piece: [[Float]], voice: [[Float]]) -> Bool {
        var a = 0.0, b = 0.0
        for c in 0..<2 {
            for i in piece[c].indices {
                let v = Double(voice[c][i])
                if !v.isFinite { return false }
                a += Double(piece[c][i]) * Double(piece[c][i])
                b += v * v
            }
        }
        return a == 0 || b / a < 2
    }
}
