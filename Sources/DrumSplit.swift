import Foundation
import CoreML

// ════════════════════════════════════════════════════════════════════
//  La batteria divisa: dalla traccia della batteria, con MDX23C
//  «DrumSep», escono cassa, rullante, tom, charleston, ride e crash.
//  Core ML fa solo la rete; qui ci sono STFT e iSTFT.
//  Tools/convert_mdx23c.py ne contiene la copia in Python, confrontata
//  con il modello originale: se qui cambia qualcosa, va cambiato anche lì.
// ════════════════════════════════════════════════════════════════════

/// La descrizione che accompagna il modello (BatteriaDrumSep.json).
struct SpectralConfig: Codable {
    let n_fft: Int
    let hop: Int
    let dim_f: Int
    let chunk: Int
    let frames: Int
    let sources: [String]
}

final class DrumSplitter {
    static let modelName = "BatteriaDrumSep"
    /// Le parti della batteria, nell'ordine in cui si mostrano.
    static let parts = ["kick", "snare", "toms", "hh", "ride", "crash"]

    let model: MLModel?
    let config: SpectralConfig
    let stft: PlainSTFT
    /// Per i test: una rete finta al posto del modello (riceve lo spettro, restituisce gli spettri degli strumenti).
    var fakeNetwork: (([Float]) -> [Float])?
    /// Quanto si sovrappongono due pezzi (i pezzi sono corti, 3 s: con 4 i passaggi non si sentono).
    var overlap = 4

    init(model: MLModel?, config: SpectralConfig) {
        self.model = model
        self.config = config
        stft = PlainSTFT(nfft: config.n_fft, hop: config.hop)
    }

    var stemCount: Int { config.sources.count }

    /// Un pezzo di `chunk` campioni per canale → ogni parte della batteria (parte × canale × campione).
    func runChunk(_ piece: [[Float]]) throws -> [[[Float]]] {
        let T = config.frames, DF = config.dim_f, F = stft.bins, S = stemCount
        let z = piece.map { stft.forward($0) }
        precondition(z[0].re.count == F * T, "pezzo della misura sbagliata")
        // Ingresso (1, 4, dim_f, T): sinistro reale, sinistro immaginario, destro reale, destro immaginario
        var x = [Float](repeating: 0, count: 4 * DF * T)
        for c in 0..<2 {
            for f in 0..<DF {
                for t in 0..<T {
                    x[((c * 2) * DF + f) * T + t] = z[c].re[f * T + t]
                    x[((c * 2 + 1) * DF + f) * T + t] = z[c].im[f * T + t]
                }
            }
        }
        let y: [Float]
        if let fake = fakeNetwork {
            y = fake(x)
        } else {
            guard let model else { throw SeparationError("modello della batteria non disponibile") }
            let input = try MLDictionaryFeatureProvider(dictionary: ["spec": try CoreMLSeparationCore.array(x, shape: [1, 4, DF, T])])
            guard let out = try model.prediction(from: input).featureValue(for: "spec_out")?.multiArrayValue else {
                throw SeparationError("il modello della batteria non ha dato risultati")
            }
            y = CoreMLSeparationCore.floats(out)
        }
        guard y.count == S * 4 * DF * T else { throw SeparationError("il modello della batteria ha risposto con misure inattese") }
        var all: [[[Float]]] = []
        for k in 0..<S {
            var stem: [[Float]] = []
            for c in 0..<2 {
                // Le frequenze sopra dim_f restano a zero
                var re = [Float](repeating: 0, count: F * T), im = re
                let r0 = (k * 4 + c * 2) * DF * T, i0 = (k * 4 + c * 2 + 1) * DF * T
                for f in 0..<DF {
                    for t in 0..<T {
                        re[f * T + t] = y[r0 + f * T + t]
                        im[f * T + t] = y[i0 + f * T + t]
                    }
                }
                stem.append(stft.inverse(re: re, im: im, frames: T, length: piece[c].count))
            }
            all.append(stem)
        }
        return all
    }

    /// Tutta la traccia della batteria → le sue parti.
    func separate(_ drums: [[Float]], progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }) throws -> [[[Float]]] {
        try RoFormer.stitch(drums, chunk: config.chunk, overlap: overlap, stems: stemCount, progress: progress,
                            isCancelled: isCancelled, run: runChunk)
    }
}

extension ModelStore {
    /// Il modello della batteria, pronto (scaricato e preparato se serve).
    func drums(units: MLComputeUnits = .all, progress: @escaping (Double) -> Void) async throws -> DrumSplitter {
        let cfg = try JSONDecoder().decode(SpectralConfig.self, from: try await config(DrumSplitter.modelName))
        return DrumSplitter(model: try await mlModel(DrumSplitter.modelName, units: units, progress: progress), config: cfg)
    }
}
