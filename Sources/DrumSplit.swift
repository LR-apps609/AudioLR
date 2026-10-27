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
    var overlap: Double = 4

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
            let prediction: MLFeatureProvider
            do { prediction = try model.prediction(from: input) } catch {
                AppLog.write("Core ML non riesce a calcolare la batteria: \(error.localizedDescription)")
                throw ImplausibleResult()
            }
            guard let out = prediction.featureValue(for: "spec_out")?.multiArrayValue else {
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
                            isCancelled: isCancelled, runners: [runChunk])
    }
}

extension ModelStore {
    /// Il modello della batteria, pronto (scaricato e preparato se serve).
    func drums(units: MLComputeUnits = .all, progress: @escaping (Double) -> Void) async throws -> DrumSplitter {
        let cfg = try JSONDecoder().decode(SpectralConfig.self, from: try await config(DrumSplitter.modelName))
        return DrumSplitter(model: try await mlModel(DrumSplitter.modelName, units: units, progress: progress), config: cfg)
    }
}

/// Le divisioni in più, a richiesta dopo la separazione: la batteria nelle sue parti, la voce in solista e cori.
enum ExtraSplit: String, CaseIterable, Identifiable {
    case vocals, gender, drums
    var id: String { rawValue }

    /// La traccia che si divide.
    var source: String { self == .drums ? "drums" : "vocals" }
    /// Le tracce che ne escono.
    var parts: [String] {
        switch self {
        case .drums: return DrumSplitter.parts
        case .vocals: return ["lead", "backing"]
        case .gender: return ["male", "female"]
        }
    }
    var modelName: String {
        switch self {
        case .drums: return DrumSplitter.modelName
        case .vocals: return "VoceCori3"
        case .gender: return "VoceDuetto"
        }
    }

    var title: String {
        switch self {
        case .drums: return "Dividi la batteria"
        case .vocals: return "Separa voce e cori"
        case .gender: return "Separa voce maschile e femminile"
        }
    }
    var detail: String {
        switch self {
        case .drums: return "Cassa, rullante, tom, charleston, ride e crash in corsie proprie"
        case .vocals: return "La voce principale da una parte, i cori dall'altra: karaoke tenendo i cori"
        case .gender: return "Nei duetti la voce di uomo da una parte, quella di donna dall'altra: canti solo la tua parte"
        }
    }
    var symbol: String {
        switch self {
        case .drums: return "square.split.2x2"
        case .vocals: return "person.2.wave.2"
        case .gender: return "person.2.fill"
        }
    }
    var working: String {
        switch self {
        case .drums: return "Divido la batteria"
        case .vocals: return "Separo voce e cori"
        case .gender: return "Separo le voci di uomo e di donna"
        }
    }
    var downloadSize: String { self == .gender ? "circa 270 MB" : "circa 200 MB" }

    /// Divide la traccia: (nomi delle parti, parti).
    func run(_ audio: [[Float]], units: MLComputeUnits, progress: @escaping (Double) -> Void,
             isCancelled: @escaping () -> Bool) async throws -> (names: [String], parts: [[[Float]]]) {
        switch self {
        case .drums:
            let model = try await ModelStore.shared.drums(units: units) { p in progress(p * 0.2) }
            let parts = try model.separate(audio, progress: { progress(0.2 + 0.78 * $0) }, isCancelled: isCancelled)
            return (model.config.sources, parts)
        case .vocals:
            let model = try await ModelStore.shared.roformer(modelName, units: units) { p in progress(p * 0.2) }
            let lead = try model.separate(audio, progress: { progress(0.2 + 0.78 * $0) }, isCancelled: isCancelled)
            // I cori sono la voce meno la voce principale
            let backing = (0..<2).map { c in zip(audio[c], lead[c]).map { $0 - $1 } }
            return (["lead", "backing"], [lead, backing])
        case .gender:
            let model = try await ModelStore.shared.roformer(modelName, units: units) { p in progress(p * 0.2) }
            let parts = try model.separateAll(audio, progress: { progress(0.2 + 0.78 * $0) }, isCancelled: isCancelled)
            let names = model.config.sources.map { $0.lowercased() }
            guard let m = names.firstIndex(of: "male"), let f = names.firstIndex(of: "female") else {
                throw SeparationError("il modello delle voci non ha le tracce attese")
            }
            return (["male", "female"], [parts[m], parts[f]])
        }
    }
}
