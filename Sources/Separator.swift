import Foundation
import CoreML
import Accelerate

// ════════════════════════════════════════════════════════════════════
//  Separazione di una canzone: la si divide in pezzi di ~7,8 secondi che
//  si sovrappongono di un quarto, ogni pezzo passa nel modello, e i pezzi
//  si ricuciono con una dissolvenza a triangolo. È lo stesso procedimento
//  di Demucs (apply_model con overlap 0,25), fatto in Swift.
// ════════════════════════════════════════════════════════════════════

/// La rete neurale: riceve spettrogramma e onda di un pezzo, già normalizzati, e restituisce quelli di ogni strumento.
protocol SeparationCore {
    /// Campioni per pezzo (a 44,1 kHz).
    var segment: Int { get }
    /// Nomi degli strumenti, nell'ordine delle uscite (per HTDemucs: drums, bass, other, vocals).
    var sources: [String] { get }
    /// spec: 4 × bins × frames (sinistro reale, sinistro immaginario, destro reale, destro immaginario); wave: 2 × segment.
    /// Restituisce spec: S × 4 × bins × frames e wave: S × 2 × segment.
    func run(spec: [Float], wave: [Float]) throws -> (spec: [Float], wave: [Float])
}

/// Il primo pezzo è uscito incoerente (le tracce sommate non danno la canzone): succede se l'unità di calcolo
/// sbaglia con i numeri a 16 bit (per esempio il solo processore dei Mac Intel). Si riprova con un'altra.
struct ImplausibleResult: Error {}

struct SeparationError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

final class Separator {
    let core: SeparationCore
    let stft = Spectrogram()
    /// Quanto si sovrappongono due pezzi vicini.
    var overlap = 0.25

    init(core: SeparationCore) { self.core = core }

    /// Dove comincia ogni pezzo, per una canzone di `length` campioni.
    static func offsets(length: Int, segment: Int, overlap: Double) -> [Int] {
        let step = max(1, Int((1 - overlap) * Double(segment)))
        return Array(stride(from: 0, to: length, by: step))
    }

    /// Peso di ogni campione di un pezzo: sale fino a metà e poi scende, così i pezzi si ricuciono senza scalini.
    static func weights(segment: Int) -> [Float] {
        let half = segment / 2
        var w = [Float](repeating: 0, count: segment)
        for i in 0..<half { w[i] = Float(i + 1) }
        for i in half..<segment { w[i] = Float(segment - i) }
        let top = w.max() ?? 1
        return w.map { $0 / top }
    }

    static func meanStd(_ x: [Float]) -> (mean: Float, std: Float) {
        guard x.count > 1 else { return (x.first ?? 0, 0) }
        var sum = 0.0
        for v in x { sum += Double(v) }
        let mean = sum / Double(x.count)
        var sq = 0.0
        for v in x { let d = Double(v) - mean; sq += d * d }
        // Come torch.std: divide per n − 1
        return (Float(mean), Float((sq / Double(x.count - 1)).squareRoot()))
    }

    /// Separa una canzone stereo (2 canali, 44,1 kHz). Restituisce per ogni strumento i due canali.
    /// `progress` riceve 0…1; se `isCancelled` diventa vero, si ferma con un errore.
    func separate(_ mix: [[Float]], progress: (Double) -> Void = { _ in },
                  isCancelled: () -> Bool = { false }) throws -> [[[Float]]] {
        precondition(mix.count == 2 && mix[0].count == mix[1].count, "serve un audio stereo")
        let length = mix[0].count
        let seg = core.segment
        let S = core.sources.count

        // Come Demucs: tutta la canzone a media 0 e deviazione 1, poi si torna alla scala originale
        var mono = [Float](repeating: 0, count: length)
        for i in 0..<length { mono[i] = (mix[0][i] + mix[1][i]) / 2 }
        let stats = Self.meanStd(mono)
        let gMean = stats.mean
        let gStd = stats.std < 1e-8 ? 1 : stats.std
        let norm = mix.map { ch in ch.map { ($0 - gMean) / gStd } }

        var out = [[[Float]]](repeating: [[Float]](repeating: [Float](repeating: 0, count: length), count: 2), count: S)
        var total = [Float](repeating: 0, count: length)
        let w = Self.weights(segment: seg)
        let starts = Self.offsets(length: length, segment: seg, overlap: overlap)

        for (n, offset) in starts.enumerated() {
            if isCancelled() { throw CancellationError() }
            // L'ultimo pezzo è più corto: si completa con l'audio prima (e silenzio dopo la fine), centrato come in Demucs
            let chunk = min(seg, length - offset)
            let delta = seg - chunk
            let from = offset - delta / 2
            var piece = [[Float]](repeating: [Float](repeating: 0, count: seg), count: 2)
            for c in 0..<2 {
                let lo = max(0, from), hi = min(length, from + seg)
                if lo < hi { for i in lo..<hi { piece[c][i - from] = norm[c][i] } }
            }
            let result = try runSegment(piece)
            if n == 0, !Self.plausible(piece: piece, result: result) { throw ImplausibleResult() }
            let trim = delta / 2
            for s in 0..<S {
                for c in 0..<2 {
                    result[s][c].withUnsafeBufferPointer { r in
                        for i in 0..<chunk { out[s][c][offset + i] += w[i] * r[trim + i] }
                    }
                }
            }
            for i in 0..<chunk { total[offset + i] += w[i] }
            progress(Double(n + 1) / Double(starts.count))
        }

        for s in 0..<S {
            for c in 0..<2 {
                for i in 0..<length { out[s][c][i] = out[s][c][i] / total[i] * gStd + gMean }
            }
        }
        return out
    }

    /// Le tracce sommate devono ridare (quasi) il pezzo: con Demucs la differenza è sotto −15 dB,
    /// un calcolo sbagliato la porta sopra lo 0 dB. Il limite (−6 dB) sta in mezzo, con ampio margine.
    static func plausible(piece: [[Float]], result: [[[Float]]]) -> Bool {
        var signal = 0.0, error = 0.0
        for c in 0..<2 {
            for i in 0..<piece[c].count {
                var sum: Float = 0
                for s in result.indices { sum += result[s][c][i] }
                let v = Double(piece[c][i]), d = Double(sum) - v
                if !d.isFinite { return false }
                signal += v * v
                error += d * d
            }
        }
        return signal == 0 || error / signal < 0.25
    }

    /// Un pezzo di `segment` campioni (2 canali) → per ogni strumento, 2 canali.
    func runSegment(_ piece: [[Float]]) throws -> [[[Float]]] {
        let seg = piece[0].count
        let le = stft.frames(for: seg)
        let plane = stft.bins * le
        let S = core.sources.count

        // Spettrogramma, normalizzato
        let left = stft.forward(piece[0]), right = stft.forward(piece[1])
        var spec = left.re + left.im + right.re + right.im
        let (mean, std) = Self.meanStd(spec)
        let k = 1 / (1e-5 + std)
        for i in 0..<spec.count { spec[i] = (spec[i] - mean) * k }

        // Onda, normalizzata
        var wave = piece[0] + piece[1]
        let (meanT, stdT) = Self.meanStd(wave)
        let kt = 1 / (1e-5 + stdT)
        for i in 0..<wave.count { wave[i] = (wave[i] - meanT) * kt }

        let (specOut, waveOut) = try core.run(spec: spec, wave: wave)
        guard specOut.count == S * 4 * plane, waveOut.count == S * 2 * seg else {
            throw SeparationError("il modello ha risposto con misure inattese")
        }

        var result = [[[Float]]]()
        for s in 0..<S {
            var channels = [[Float]]()
            for c in 0..<2 {
                let base = (s * 4 + c * 2) * plane
                let re = specOut[base..<(base + plane)].map { $0 * std + mean }
                let im = specOut[(base + plane)..<(base + 2 * plane)].map { $0 * std + mean }
                var x = stft.inverse(re: re, im: im, length: seg)
                let wb = (s * 2 + c) * seg
                for i in 0..<seg { x[i] += waveOut[wb + i] * stdT + meanT }
                channels.append(x)
            }
            result.append(channels)
        }
        return result
    }
}

// MARK: - Core ML

/// Il modello HTDemucs convertito da Tools/convert_demucs.py.
final class CoreMLSeparationCore: SeparationCore {
    let model: MLModel
    let segment: Int
    let frames: Int
    let bins: Int
    let sources: [String]

    init(model: MLModel) throws {
        self.model = model
        let inputs = model.modelDescription.inputDescriptionsByName
        guard let specShape = inputs["spec"]?.multiArrayConstraint?.shape.map(\.intValue), specShape.count == 4,
              let waveShape = inputs["wave"]?.multiArrayConstraint?.shape.map(\.intValue), waveShape.count == 3 else {
            throw SeparationError("il modello di IA non è quello giusto")
        }
        bins = specShape[2]
        frames = specShape[3]
        segment = waveShape[2]
        let meta = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
        sources = (meta?["sources"] ?? "drums,bass,other,vocals").split(separator: ",").map(String.init)
    }

    func run(spec: [Float], wave: [Float]) throws -> (spec: [Float], wave: [Float]) {
        let specIn = try Self.array(spec, shape: [1, 4, bins, frames])
        let waveIn = try Self.array(wave, shape: [1, 2, segment])
        let input = try MLDictionaryFeatureProvider(dictionary: ["spec": specIn, "wave": waveIn])
        let out = try model.prediction(from: input)
        guard let s = out.featureValue(for: "spec_out")?.multiArrayValue,
              let w = out.featureValue(for: "wave_out")?.multiArrayValue else {
            throw SeparationError("il modello non ha dato risultati")
        }
        return (Self.floats(s), Self.floats(w))
    }

    static func array(_ values: [Float], shape: [Int]) throws -> MLMultiArray {
        let a = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
        values.withUnsafeBufferPointer { src in
            a.dataPointer.assumingMemoryBound(to: Float.self).update(from: src.baseAddress!, count: values.count)
        }
        return a
    }

    /// Copia un risultato di Core ML in un array semplice, anche se è a 16 bit o con le righe «allineate».
    /// I passi veri si leggono dentro withUnsafeMutableBytes: per i risultati che Core ML tiene in memoria
    /// grafica possono essere diversi da quelli dichiarati in `strides`.
    static func floats(_ a: MLMultiArray) -> [Float] {
        let shape = a.shape.map(\.intValue)
        let count = shape.reduce(1, *)
        let last = shape.last ?? 1
        let rows = count / max(last, 1)
        var out = [Float](repeating: 0, count: count)
        let type = a.dataType

        a.withUnsafeMutableBytes { raw, rawStrides in
            let strides = rawStrides.isEmpty ? a.strides.map(\.intValue) : rawStrides
            // Dove comincia la riga r (tutti gli indici tranne l'ultimo)
            func rowOffset(_ r: Int) -> Int {
                var rest = r, offset = 0
                for d in stride(from: shape.count - 2, through: 0, by: -1) {
                    offset += (rest % shape[d]) * strides[d]
                    rest /= shape[d]
                }
                return offset
            }
            let step = strides.last ?? 1

            switch type {
            case .float32:
                let p = raw.baseAddress!.assumingMemoryBound(to: Float.self)
                for r in 0..<rows {
                    let o = rowOffset(r)
                    for i in 0..<last { out[r * last + i] = p[o + i * step] }
                }
            case .double:
                let p = raw.baseAddress!.assumingMemoryBound(to: Double.self)
                for r in 0..<rows {
                    let o = rowOffset(r)
                    for i in 0..<last { out[r * last + i] = Float(p[o + i * step]) }
                }
            default:
                // Float16: convertito con Accelerate (il tipo Float16 non esiste sui Mac Intel)
                let p = raw.baseAddress!.assumingMemoryBound(to: UInt16.self)
                var row16 = [UInt16](repeating: 0, count: last)
                var row32 = [Float](repeating: 0, count: last)
                for r in 0..<rows {
                    let o = rowOffset(r)
                    for i in 0..<last { row16[i] = p[o + i * step] }
                    row16.withUnsafeMutableBufferPointer { s in
                        row32.withUnsafeMutableBufferPointer { d in
                            var src = vImage_Buffer(data: s.baseAddress, height: 1, width: vImagePixelCount(last), rowBytes: last * 2)
                            var dst = vImage_Buffer(data: d.baseAddress, height: 1, width: vImagePixelCount(last), rowBytes: last * 4)
                            vImageConvert_Planar16FtoPlanarF(&src, &dst, 0)
                        }
                    }
                    for i in 0..<last { out[r * last + i] = row32[i] }
                }
            }
        }
        return out
    }
}
