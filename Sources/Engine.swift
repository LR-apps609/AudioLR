import Foundation
import CoreML

// ════════════════════════════════════════════════════════════════════
//  Qualità e motore.
//  • Rapida (chiave interna «fast»): htdemucs, un modello per tutti gli strumenti.
//  • Massima: un solo modello, BS-RoFormer «SW», per voce, batteria, basso,
//    chitarra, pianoforte e altro. Sulla voce vale quanto un modello voce a
//    parte (11,46 contro 11,53 dB sulle 50 canzoni di MUSDB) e ci mette metà
//    del tempo. Se SW non si può usare, i modelli htdemucs_ft. È quella di serie.
//  • Studio: la stessa su tutti i Mac, tre passaggi. Voce: media di Revive V3e e
//    SW sulla canzone intera. Strumenti: media di SW sulla base senza voce e SW
//    sulla canzone. Banco severo, 50 canzoni intere: voce 12,21 dB, batteria 12,34,
//    basso 11,29, altro 9,64. La più pulita.
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

    // Studio, la stessa su tutti i Mac: voce = media(Revive, SW sulla canzone); strumenti = media(SW sulla base,
    // SW sulla canzone). Sulle 50 canzoni intere di MUSDB (banco severo) uguale o meglio della ricetta di prima
    // con cinque passaggi (voce 12,21 dB contro 12,11, basso 11,29 contro 10,93, altro 9,64 contro 9,45):
    // Demucs e la seconda voce nella media non aiutavano. Le funzioni qui sotto restano per i modelli aggiuntivi.
    var swOnBase: Bool { true }

    /// Un Demucs specializzato nel basso per la media di Studio: non più usato (vedi sopra).
    var bassModel: String? { nil }

    /// Un secondo modello voce per la media di Studio: non più usato (vedi sopra).
    var secondVoice: String? { nil }

    /// In Studio SW passa anche sulla canzone intera: la sua voce è il terzo membro della squadra
    /// e i suoi strumenti entrano nelle medie di batteria, basso e altro.
    var swOnMix: Bool { self == .studio }

    /// Demucs sulla base per le medie degli strumenti di Studio: non più usato (vedi sopra).
    var helperModel: String? { nil }

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

    /// Le qualità con i modelli RoFormer (tutte tranne Rapida).
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
        case .fast: return "Rapida"
        case .best: return "Massima qualità"
        case .studio: return "Studio"
        }
    }

    var detail: String { detail(appleChip: SeparationJob.hasNeuralEngine) }

    /// La riga sotto la qualità (Impostazioni › Tracce e suggerimento della scheda). Il tempo di Rapida è lo stesso
    /// della scheda (`cardTime`, «circa 30 secondi»): prima diceva «circa 20 s», anche sui Mac Intel (dal tester t16).
    func detail(appleChip: Bool) -> String {
        switch self {
        case .fast: return appleChip ? "Un modello per tutto · circa 30 s a canzone" : "Un modello per tutto · qualche minuto a canzone su un Mac Intel"
        case .best: return "Sei tracce con BS-RoFormer SW, chitarra e piano compresi · pulita e veloce"
        case .studio: return "Ogni traccia da una squadra di modelli: la voce da due, gli strumenti da due passaggi · la più pulita, la più lenta"
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
        case .studio: return "circa 5 minuti"
        }
    }

    /// Lo stesso, per un Mac Intel (senza Neural Engine): la frase del chip Apple prometteva «circa 3 minuti» anche
    /// dove Massima ne prende decine (bug b-3, caso della cognata). Misurato il 07/11 sul Mac Intel di GitHub con la
    /// 0.41: Massima 275–296 s per 35 s di canzone, cioè circa 30 minuti per 4 minuti (la 0.40 il doppio). Un Mac Intel
    /// vero può essere più svelto della macchina virtuale: si dice un intervallo. Rapida e Studio stimati, detti larghi.
    var cardTimeIntel: String {
        switch self {
        case .fast: return "qualche minuto su un Mac Intel"
        case .best: return "20–35 minuti su un Mac Intel"
        case .studio: return "40 minuti o più su un Mac Intel"
        }
    }

    /// La scheda della qualità su questo Mac: se ha già fatto separazioni con questa qualità, il tempo viene dalla sua
    /// velocità vera (mediana delle ultime 5, riportata a una canzone di 4 minuti); altrimenti la frase fissa adatta.
    func cardTime(history: [HistoryItem], appleChip: Bool) -> String {
        let rates = history.filter { $0.quality == rawValue }.prefix(5).compactMap { h -> Double? in
            guard let d = h.duration, let s = h.seconds, d >= 20, s > 0 else { return nil }
            return s / d
        }.sorted()
        guard !rates.isEmpty else { return appleChip ? cardTime : cardTimeIntel }
        let seconds = rates[rates.count / 2] * 240
        if seconds < 90 { return "circa \(max(10, Int((seconds / 10).rounded()) * 10)) secondi su questo Mac" }
        return "circa \(Int((seconds / 60).rounded())) minuti su questo Mac"
    }

    /// Da scaricare la prima volta: i file .mlpackage.zip della release «modelli-1» (HTDemucs 79 MB; StrumentiSW2
    /// 328 MB; Studio StrumentiSW2 + VoceRevive 298 MB = 626 MB). Studio diceva «circa 1 GB» (dal tester t16).
    var downloadSize: String {
        switch self {
        case .fast: return "circa 80 MB"
        case .best: return "circa 330 MB"
        case .studio: return "circa 630 MB"
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

        var text: String { text(neuralEngine: SeparationJob.hasNeuralEngine) }

        /// Il motivo a parole. Su un Mac Intel non si nomina il Neural Engine, che non c'è: dopo un risultato non
        /// plausibile si diceva «il Neural Engine qui ha dato un risultato sbagliato» anche lì (dal tester t16).
        func text(neuralEngine: Bool) -> String {
            if units == .all {
                return neuralEngine
                    ? String(format: "Neural Engine e grafica (verificato: %.0f dB)", agreement)
                    : "Grafica e processore"
            }
            if agreement == EngineChoice.fasterCPU { return "Processore (su questo Mac è più veloce della grafica)" }
            if agreement == EngineChoice.fasterGPU { return "Grafica (su questo Mac è più veloce del processore)" }
            if units == .cpuOnly {
                return neuralEngine ? "Solo processore (Neural Engine e grafica qui non riescono a calcolare)"
                                    : "Solo processore (la grafica qui non riesce a calcolare)"
            }
            if agreement > 0 { return String(format: "Grafica (il Neural Engine qui è impreciso: %.0f dB)", agreement) }
            if agreement == EngineChoice.chosenGPU { return "Grafica (scelta nelle Impostazioni)" }
            if agreement == EngineChoice.slowANE { return "Grafica (il Neural Engine era troppo lento ad aprire il modello)" }
            if agreement == EngineChoice.lowMemoryGPU { return "Grafica (la più rapida su un Mac con 8 GB)" }
            return neuralEngine ? "Grafica (il Neural Engine qui ha dato un risultato sbagliato)"
                                : "Grafica (il primo calcolo qui ha dato un risultato sbagliato)"
        }
    }

    /// Come sceglie il motore, a parole (Impostazioni › Motore e Domande frequenti). Sui Mac Intel non c'è il
    /// Neural Engine: lì si gareggia in velocità tra processore e grafica (`SeparationJob.race`) (dal tester t16).
    static func howItChooses(neuralEngine: Bool) -> String {
        neuralEngine
            ? "Al primo uso di ogni modello IsoLR confronta Neural Engine e grafica su un pezzo della canzone, e usa il più preciso."
            : "Al primo uso di ogni modello IsoLR prova processore e grafica su un pezzo della canzone, e usa il più veloce."
    }

    /// Il modello non si apre su `units` ma sul processore sì (di solito memoria quasi piena). «Solo grafica» si
    /// consiglia solo dove serve: sui Mac Intel il selettore è disattivato e chi ha già la grafica l'ha già scelta.
    static func openFailedMessage(units: MLComputeUnits, neuralEngine: Bool) -> String {
        let place: String
        switch units {
        case .cpuAndGPU: place = "sulla grafica"
        case .cpuAndNeuralEngine: place = "sul Neural Engine"
        case .all: place = neuralEngine ? "su Neural Engine e grafica" : "su grafica e processore"
        default: place = "su questo Mac"
        }
        let advice = neuralEngine && units != .cpuAndGPU ? ", oppure scegli «Solo grafica» in Impostazioni › Motore" : ""
        return "il modello non si apre \(place) (memoria quasi piena?): chiudi le altre app e riprova" + advice
    }

    static func key(_ model: String) -> String { "engine.\(model)" }

    /// Valori speciali di `agreement`: Neural Engine troppo lento ad aprire il modello; grafica scelta nelle Impostazioni.
    static let slowANE = -1.0
    static let chosenGPU = -2.0
    static let lowMemoryGPU = -3.0
    /// Mac senza Neural Engine (Intel): non c'è niente da confrontare, il modello lavora su grafica e processore
    static let noANE = -4.0
    /// Mac Intel, dopo la gara del motore: un pezzo cronometrato sul processore e uno sulla grafica.
    /// Misurato sul Mac Intel di GitHub (i7, grafica senza accelerazione vera): il processore da solo 48 s a pezzo,
    /// «tutti i motori» 161 s, con le stesse tracce. Con una Radeon la grafica può invece vincere.
    static let fasterCPU = -5.0
    static let fasterGPU = -6.0
    /// Mac Intel, modelli Demucs (Rapida): restano su grafica e processore, senza gara.
    static let intelDemucs = -7.0

    /// La grafica vince solo se è davvero più veloce (10%): a parità si resta sul processore, che non scalda la grafica.
    static func decideSpeed(cpu: Double, gpu: Double?) -> Decision {
        if let g = gpu, g < cpu * 0.9 { return Decision(units: .cpuAndGPU, agreement: fasterGPU) }
        return Decision(units: .cpuOnly, agreement: fasterCPU)
    }

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
        // Mac Intel con la scelta delle versioni fino alla 0.40 («tutti i motori», spesso la grafica lenta): si rifà la gara
        if agreement == noANE { return nil }
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
