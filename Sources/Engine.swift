import Foundation
import CoreML

// ════════════════════════════════════════════════════════════════════
//  Qualità e motore.
//  • Veloce: htdemucs, un modello per tutti gli strumenti.
//  • Massima: un solo modello, BS-RoFormer «SW», per voce, batteria, basso,
//    chitarra, pianoforte e altro. Sulla voce vale quanto un modello voce a
//    parte (11,46 contro 11,53 dB sulle 50 canzoni di MUSDB) e ci mette metà
//    del tempo. Se SW non si può usare, i modelli htdemucs_ft. È quella di serie.
//  • Studio: ogni traccia da una squadra di modelli (banco «al massimo», 50
//    canzoni di MUSDB). Voce: media di Revive V3e, Kim e SW sulla canzone intera
//    (12,20 dB contro 11,93 di viperx da solo, e lascia fuori pad e tastiere
//    tenute). Strumenti: SW sulla base senza voce, in squadra con Demucs sulla
//    base e con SW sulla canzone intera. La più pulita.
//  • Il motore: al primo uso di ogni modello IsoLR prova un pezzo della
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
        case .studio: return "VoceRevive"
        }
    }

    /// Il modello per gli strumenti, se questa qualità ne usa uno a parte (BS-RoFormer a sei strumenti).
    /// Senza (o se non riesce), si usano i modelli Demucs di `models`.
    var instrumentModel: String? {
        switch self {
        case .fast: return nil
        case .best, .studio: return "StrumentiSW2"
        }
    }

    /// In Studio il basso è la media di SW e del Demucs specializzato nel basso, sulla base senza voce:
    /// sulle 50 canzoni di MUSDB 9,80 dB contro 9,16 di Demucs da solo e 8,61 di SW. Se non c'è, resta quello di SW.
    var bassModel: String? { self == .studio ? "HTDemucsFT-1" : nil }

    /// In Studio il secondo modello voce, Kim: in squadra con Revive e SW.
    var secondVoice: String? { self == .studio ? "VoceRoFormer9" : nil }

    /// In Studio SW passa anche sulla canzone intera: la sua voce è il terzo membro della squadra
    /// e i suoi strumenti entrano nelle medie di batteria, basso e altro.
    var swOnMix: Bool { self == .studio }

    /// In Studio Demucs (quello di Veloce) sulla base senza voce, per le medie degli strumenti:
    /// batteria 11,19 dB contro 11,09, altro 7,97 contro 7,77 (media con SW sulla base e sulla canzone).
    var helperModel: String? { self == .studio ? ModelStore.name : nil }

    /// Il modello Demucs specializzato nella voce: con il modello voce RoFormer non si usa.
    static let voiceSpecialist = "HTDemucsFT-3"

    /// Il modello voce di riserva (pezzi da 2 s): più leggero, se quello da 8 s non riesce su questo Mac.
    static let lightVoice = "VoceRoFormer"

    /// Se un modello voce non riesce su questo Mac (memoria, Mac più vecchio), quello più leggero da provare.
    static func fallbackVoice(for name: String) -> String? {
        switch name {
        case "VoceRevive", "VoceStudio3": return "VoceRoFormer9"
        case "VoceRoFormer9": return lightVoice
        default: return nil
        }
    }

    /// Tutto quello che va scaricato per questa qualità (i modelli Demucs di riserva solo se servono).
    var allModels: [String] {
        let extra = [voiceModel, secondVoice, instrumentModel, bassModel, helperModel].compactMap { $0 }
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
        case .studio: return "Ogni traccia da una squadra di modelli: la voce da tre, gli strumenti da tre o quattro · la più pulita, la più lenta"
        }
    }

    /// Nella scheda della schermata iniziale: per chi è, a parole.
    var cardLine: String {
        switch self {
        case .fast: return "per provare un'idea"
        case .best: return "pulita e veloce"
        case .studio: return "la più pulita"
        }
    }

    /// Quanto ci mette, circa, per una canzone di 4 minuti su un Mac con chip Apple.
    var cardTime: String {
        switch self {
        case .fast: return "circa 30 secondi"
        case .best: return "circa 3 minuti"
        case .studio: return "circa 15 minuti"
        }
    }

    /// Da scaricare la prima volta.
    var downloadSize: String {
        switch self {
        case .fast: return "circa 80 MB"
        case .best: return "circa 330 MB"
        case .studio: return "circa 1 GB"
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
            if units == .cpuOnly { return "Solo processore (Neural Engine e grafica qui non riescono a calcolare)" }
            if agreement > 0 { return String(format: "Grafica (il Neural Engine qui è impreciso: %.0f dB)", agreement) }
            if agreement == EngineChoice.chosenGPU { return "Grafica (scelta nelle Impostazioni)" }
            if agreement == EngineChoice.slowANE { return "Grafica (il Neural Engine era troppo lento ad aprire il modello)" }
            if agreement == EngineChoice.lowMemoryGPU { return "Grafica (la più rapida su un Mac con 8 GB)" }
            return "Grafica (il Neural Engine qui ha dato un risultato sbagliato)"
        }
    }

    static func key(_ model: String) -> String { "engine.\(model)" }

    /// Valori speciali di `agreement`: Neural Engine troppo lento ad aprire il modello; grafica scelta nelle Impostazioni.
    static let slowANE = -1.0
    static let chosenGPU = -2.0
    static let lowMemoryGPU = -3.0

    /// La scelta da usare adesso per un modello: quella delle Impostazioni («Solo grafica»), o quella ricordata.
    static func current(_ model: String) -> Decision? {
        if Prefs.gpuOnly { return Decision(units: .cpuAndGPU, agreement: chosenGPU) }
        // Con 8 GB il Neural Engine non apre in tempi utili i modelli grandi (misurato su un MacBook Air M2:
        // oltre 4 minuti), mentre la grafica li apre in un secondo e separa una canzone di 4:40 in 2,5 minuti
        if Prefs.lowMemory && SeparationJob.hasNeuralEngine && isLarge(model) {
            return Decision(units: .cpuAndGPU, agreement: lowMemoryGPU)
        }
        return stored(model)
    }

    /// I modelli grandi (RoFormer e batteria divisa, centinaia di MB); i Demucs (80 MB) seguono la prova del motore.
    static func isLarge(_ model: String) -> Bool { !model.hasPrefix("HTDemucs") }

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
