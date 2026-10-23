import Foundation
import CoreML

// ════════════════════════════════════════════════════════════════════
//  Qualità e motore.
//  • Veloce: htdemucs, un modello per tutti gli strumenti.
//  • Massima: htdemucs_ft, quattro modelli, ognuno specializzato in uno
//    strumento (più pulito, circa 4 volte più lento). È quella di serie.
//  • Il motore: al primo uso di ogni modello AudioLR prova un pezzo della
//    canzone sia con il Neural Engine sia con la grafica. Se i due risultati
//    non coincidono, il Neural Engine di questo Mac è impreciso con quel
//    modello e da lì in poi si usa la grafica.
// ════════════════════════════════════════════════════════════════════

enum Quality: String, CaseIterable, Identifiable {
    case fast, best
    var id: String { rawValue }

    static let key = "quality"
    static var current: Quality {
        get { Quality(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .best }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    var models: [String] {
        switch self {
        case .fast: return [ModelStore.name]
        case .best: return (0..<4).map { "HTDemucsFT-\($0)" }
        }
    }

    /// Il modello per la voce, se questa qualità ne usa uno a parte (RoFormer: molto più pulito di Demucs sulla voce).
    var voiceModel: String? {
        switch self {
        case .fast: return nil
        case .best: return "VoceRoFormer"
        }
    }

    /// Tutto quello che va scaricato per questa qualità.
    var allModels: [String] { (voiceModel.map { [$0] } ?? []) + models }

    var title: String {
        switch self {
        case .fast: return "Veloce"
        case .best: return "Massima qualità"
        }
    }

    var detail: String {
        switch self {
        case .fast: return "Un modello per tutto · circa 20 s a canzone"
        case .best: return "Voce RoFormer e un modello per strumento · più lenta, molto più pulita"
        }
    }

    /// Da scaricare la prima volta.
    var downloadSize: String {
        switch self {
        case .fast: return "circa 80 MB"
        case .best: return "circa 520 MB"
        }
    }
}

/// La scelta del motore per ogni modello, fatta una volta sola su questo Mac e ricordata.
enum EngineChoice {
    /// Sotto questa soglia Neural Engine e grafica danno risultati diversi in modo udibile.
    static let threshold = 30.0

    struct Decision: Equatable {
        let units: MLComputeUnits
        /// Quanto Neural Engine e grafica coincidono, in dB.
        let agreement: Double

        var text: String {
            units == .all
                ? String(format: "Neural Engine (verificato: %.0f dB)", agreement)
                : String(format: "Grafica (il Neural Engine qui è impreciso: %.0f dB)", agreement)
        }
    }

    static func key(_ model: String) -> String { "engine.\(model)" }

    static func stored(_ model: String, defaults: UserDefaults = .standard) -> Decision? {
        guard let d = defaults.dictionary(forKey: key(model)),
              let raw = d["units"] as? Int, let units = MLComputeUnits(rawValue: raw),
              let agreement = d["agreement"] as? Double else { return nil }
        return Decision(units: units, agreement: agreement)
    }

    static func decide(agreement: Double) -> Decision {
        Decision(units: agreement >= threshold ? .all : .cpuAndGPU, agreement: agreement)
    }

    static func store(_ d: Decision, for model: String, defaults: UserDefaults = .standard) {
        defaults.set(["units": d.units.rawValue, "agreement": d.agreement], forKey: key(model))
    }

    /// Dimentica le scelte: alla prossima separazione si riprova.
    static func reset(defaults: UserDefaults = .standard) {
        for q in Quality.allCases { for m in q.allModels { defaults.removeObject(forKey: key(m)) } }
    }
}
