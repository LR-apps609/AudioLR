import Foundation
import CoreML

// ════════════════════════════════════════════════════════════════════
//  Qualità e motore.
//  • Veloce: htdemucs, un modello per tutti gli strumenti.
//  • Massima: un solo modello, BS-RoFormer «SW», per voce, batteria, basso,
//    chitarra, pianoforte e altro. Sulla voce vale quanto un modello voce a
//    parte (11,46 contro 11,53 dB sulle 50 canzoni di MUSDB) e ci mette metà
//    del tempo. Se SW non si può usare, i modelli htdemucs_ft. È quella di serie.
//  • Studio: la voce dal modello più pulito (BS-RoFormer viperx), poi SW
//    sugli strumenti della base. La più pulita, la più lenta.
//  • Il motore: al primo uso di ogni modello AudioLR prova un pezzo della
//    canzone sia con il Neural Engine sia con la grafica. Se i due risultati
//    non coincidono, il Neural Engine di questo Mac è impreciso con quel
//    modello e da lì in poi si usa la grafica.
// ════════════════════════════════════════════════════════════════════

enum Quality: String, CaseIterable, Identifiable {
    case fast, best, studio
    var id: String { rawValue }

    static let key = "quality"
    static var current: Quality {
        get { Quality(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .best }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    var models: [String] {
        switch self {
        case .fast: return [ModelStore.name]
        case .best, .studio: return (0..<4).map { "HTDemucsFT-\($0)" }
        }
    }

    /// Il modello per la voce, se questa qualità ne usa uno a parte (RoFormer: molto più pulito di Demucs sulla voce).
    var voiceModel: String? {
        switch self {
        case .fast: return nil
        case .best: return nil
        case .studio: return "VoceStudio"
        }
    }

    /// Il modello per gli strumenti, se questa qualità ne usa uno a parte (BS-RoFormer a sei strumenti).
    /// Senza (o se non riesce), si usano i modelli Demucs di `models`.
    var instrumentModel: String? {
        switch self {
        case .fast: return nil
        case .best, .studio: return "StrumentiSW"
        }
    }

    /// Il modello Demucs specializzato nella voce: con il modello voce RoFormer non si usa.
    static let voiceSpecialist = "HTDemucsFT-3"

    /// Il modello voce di riserva (pezzi da 2 s): più leggero, se quello da 8 s non riesce su questo Mac.
    static let lightVoice = "VoceRoFormer"

    /// Se un modello voce non riesce su questo Mac (memoria, Mac più vecchio), quello più leggero da provare.
    static func fallbackVoice(for name: String) -> String? {
        switch name {
        case "VoceStudio": return "VoceRoFormer8"
        case "VoceRoFormer8": return lightVoice
        default: return nil
        }
    }

    /// Tutto quello che va scaricato per questa qualità (i modelli Demucs di riserva solo se servono).
    var allModels: [String] {
        let extra = [voiceModel, instrumentModel].compactMap { $0 }
        return instrumentModel == nil ? extra + models : extra
    }

    /// Tutti i modelli che questa qualità può usare, compresi quelli di riserva.
    var everyModel: [String] {
        var all = [voiceModel, instrumentModel].compactMap { $0 } + models
        var v = voiceModel
        while let next = v.flatMap(Quality.fallbackVoice) { all.append(next); v = next }
        return all
    }

    /// Le qualità con i modelli RoFormer (tutte tranne Veloce).
    var isRoFormer: Bool { voiceModel != nil }

    var symbol: String {
        switch self {
        case .fast: return "hare.fill"
        case .best: return "sparkles"
        case .studio: return "star.circle.fill"
        }
    }

    var title: String {
        switch self {
        case .fast: return "Veloce"
        case .best: return "Massima qualità"
        case .studio: return "Studio"
        }
    }

    var detail: String {
        switch self {
        case .fast: return "Un modello per tutto · circa 20 s a canzone"
        case .best: return "Sei tracce con BS-RoFormer SW, chitarra e piano compresi · pulita e veloce"
        case .studio: return "La voce più pulita (BS-RoFormer viperx) più SW sugli strumenti · la più lenta"
        }
    }

    /// Da scaricare la prima volta.
    var downloadSize: String {
        switch self {
        case .fast: return "circa 80 MB"
        case .best: return "circa 330 MB"
        case .studio: return "circa 390 MB"
        }
    }
}

/// La scelta del motore per ogni modello, fatta una volta sola su questo Mac e ricordata.
enum EngineChoice {
    /// Sotto questa soglia Neural Engine e grafica danno risultati diversi in modo udibile.
    /// 20 dB = differenza dell'1% dell'energia: molto sotto l'errore della separazione stessa (circa 11 dB),
    /// quindi non si sente. Prima era 30: troppo severa, molti Mac con chip Apple finivano sulla sola grafica.
    static let threshold = 20.0

    struct Decision: Equatable {
        let units: MLComputeUnits
        /// Quanto Neural Engine e grafica coincidono, in dB.
        let agreement: Double

        var text: String {
            if units == .all {
                return SeparationJob.hasNeuralEngine
                    ? String(format: "Neural Engine e grafica (verificato: %.0f dB)", agreement)
                    : "Grafica e processore"
            }
            return agreement > 0
                ? String(format: "Grafica (il Neural Engine qui è impreciso: %.0f dB)", agreement)
                : "Grafica (il Neural Engine qui ha dato un risultato sbagliato)"
        }
    }

    static func key(_ model: String) -> String { "engine.\(model)" }

    static func stored(_ model: String, defaults: UserDefaults = .standard) -> Decision? {
        guard let d = defaults.dictionary(forKey: key(model)),
              let raw = d["units"] as? Int, let units = MLComputeUnits(rawValue: raw),
              let agreement = d["agreement"] as? Double else { return nil }
        // La scelta si rifà con la soglia attuale; 0 vuol dire «il Neural Engine ha sbagliato davvero»: resta la grafica
        return agreement > 0 ? decide(agreement: agreement) : Decision(units: units, agreement: agreement)
    }

    static func decide(agreement: Double) -> Decision {
        Decision(units: agreement >= threshold ? .all : .cpuAndGPU, agreement: agreement)
    }

    static func store(_ d: Decision, for model: String, defaults: UserDefaults = .standard) {
        defaults.set(["units": d.units.rawValue, "agreement": d.agreement], forKey: key(model))
    }

    /// Dimentica le scelte: alla prossima separazione si riprova.
    static func reset(defaults: UserDefaults = .standard) {
        for q in Quality.allCases { for m in q.everyModel { defaults.removeObject(forKey: key(m)) } }
    }
}
