import SwiftUI
import AppKit

// ════════════════════════════════════════════════════════════════════
//  Aiuto: le domande frequenti (FAQ, con ricerca) e «Segnala un bug»,
//  che prepara un rapporto con le informazioni del Mac già compilate.
// ════════════════════════════════════════════════════════════════════

/// Le domande frequenti, divise per argomento. Separate dalla finestra così si possono provare.
enum FAQ {
    struct Entry: Identifiable, Hashable {
        let topic: String
        let question: String
        let answer: String
        var id: String { question }
    }

    static let topics: [(name: String, symbol: String)] = [
        ("Primi passi", "play.circle"),
        ("Qualità", "sparkles"),
        ("Mixer ed esportazione", "slider.horizontal.3"),
        ("File e cartelle", "folder"),
        ("Velocità e motore", "cpu"),
        ("Aggiornamenti e privacy", "lock.shield"),
        ("Se qualcosa non va", "wrench.and.screwdriver"),
    ]

    static let all: [Entry] = [
        Entry(topic: "Primi passi", question: "Come separo una canzone?",
              answer: "Trascina il file nella finestra, oppure premi ⌘O e sceglilo. AudioLR crea le tracce di voce, batteria, basso, altri strumenti e la base senza voce. Puoi trascinare anche più canzoni o un album intero: vengono separate una dopo l'altra."),
        Entry(topic: "Primi passi", question: "Quali file posso usare?",
              answer: "MP3, M4A/AAC, WAV, AIFF, FLAC, ALAC e in generale ogni file audio che il Mac sa aprire. I file protetti da DRM (per esempio scaricati da Apple Music) non si possono aprire."),
        Entry(topic: "Primi passi", question: "Posso separare una cartella intera?",
              answer: "Sì: trascina la cartella nella finestra, oppure scegli «Apri una canzone…» (⌘O) e seleziona la cartella. AudioLR mette in coda tutte le canzoni che contiene, anche nelle sottocartelle, in ordine di nome, e le separa una dopo l'altra mentre fai altro. Le tracce già create da AudioLR nella cartella vengono saltate."),
        Entry(topic: "Primi passi", question: "Perché la prima volta ci mette di più?",
              answer: "Con la versione completa (il file .dmg) i modelli sono già dentro l'app: al primo avvio AudioLR li installa e prepara il Neural Engine in sottofondo, una volta sola. Con la versione leggera, al primo uso AudioLR scarica i modelli di IA (circa 330 MB per Massima, 540 MB per Studio, 80 MB per Veloce) e prova il motore del tuo Mac per scegliere il più preciso. Succede una volta sola: poi funziona anche senza internet."),
        Entry(topic: "Primi passi", question: "Dove ritrovo le canzoni già separate?",
              answer: "Nella libreria a sinistra (⌘L per mostrarla o nasconderla): un clic riapre la separazione con il mixer, senza rifarla. Nella Cronologia (⌘Y, o il tasto con l'orologio in alto) trovi tutte le separazioni con data, qualità, durata, tempo impiegato, BPM e tonalità; doppio clic per riaprirne una."),
        Entry(topic: "Qualità", question: "Che differenza c'è tra Massima e Veloce?",
              answer: "Massima usa BS-RoFormer SW, un modello che in un solo passaggio separa voce, batteria, basso, chitarra, pianoforte e altri strumenti: molto più pulito di Veloce, e circa metà del tempo delle versioni di prima. Studio aggiunge il modello voce più pulito che esista oggi: il massimo della qualità, ma la più lenta. Veloce usa un solo modello ed è circa 4 volte più rapida. Puoi cambiare con ⌥⌘1 e ⌥⌘2."),
        Entry(topic: "Qualità", question: "Che cos'è la qualità Studio?",
              answer: "Studio usa per la voce il modello più pulito che abbiamo provato (BS-RoFormer): meno strumenti nella voce e una base karaoke più piena. Gli strumenti sono quelli di Massima, con il basso ancora più pulito: unisce SW e un modello Demucs specializzato nel basso. È circa 2 volte più lenta di Massima: conviene quando la voce deve essere perfetta, per esempio per un remix. ⌥⌘3 per sceglierla."),
        Entry(topic: "Qualità", question: "Nella voce si sente ancora un po' di musica: posso migliorarla?",
              answer: "Usa Massima o, meglio ancora, Studio. In Impostazioni › Generale puoi anche scegliere «Precisione» per la voce: ogni punto della canzone passa più volte nel modello, con passaggi più morbidi (circa 2 volte più lento). Le canzoni molto riverberate o con cori fitti restano le più difficili per qualsiasi app."),
        Entry(topic: "Qualità", question: "La base karaoke suona un po' scura: è normale?",
              answer: "La base è la canzone meno la voce: dove voce e strumenti suonano le stesse frequenze, togliere la voce toglie anche un po' di brillantezza. Le prossime versioni migliorano proprio questo punto."),
        Entry(topic: "Qualità", question: "Sento un suono distorto o «fritto»: cosa faccio?",
              answer: "Dalla versione 0.6.1 le tracce vengono abbassate quanto basta per non superare mai il massimo, e il mixer ha un limitatore. Se lo senti ancora, segnala la canzone con «Segnala un bug» (⌥⌘B), indicando in quale traccia e in quale minuto."),
        Entry(topic: "Mixer ed esportazione", question: "Come funziona il mixer?",
              answer: "Ogni traccia ha M (muto), S (solo) e il volume. Spazio suona o mette in pausa tutte le tracce insieme. Le scorciatoie Tutto (⌘0), Karaoke (⌘K) e Solo voce (⌘J) cambiano il mix in un clic."),
        Entry(topic: "Mixer ed esportazione", question: "Posso separare cassa, rullante e piatti?",
              answer: "Sì: dopo una separazione premi «Dividi la batteria» (⇧⌘D) sotto il mixer. La batteria viene divisa in cassa, rullante, tom, charleston, ride e crash, ognuno con la sua corsia nel mixer. La prima volta scarica un modello di circa 200 MB."),
        Entry(topic: "Qualità", question: "Chitarra e pianoforte hanno tracce proprie?",
              answer: "Sì, in Massima qualità: oltre a voce, batteria e basso ricevi chitarra, pianoforte e gli altri strumenti. Se preferisci quattro tracce, in Impostazioni › Tracce togli «Chitarra e pianoforte in tracce proprie»: finiranno in «Altri strumenti»."),
        Entry(topic: "Qualità", question: "Ci sono archi, fiati o synth separati?",
              answer: "Non ancora: oggi non esiste un modello libero abbastanza preciso per archi e fiati. Restano in «Altri strumenti». Appena ce ne sarà uno all'altezza, arriverà con un aggiornamento."),
        Entry(topic: "Mixer ed esportazione", question: "Posso avere le note in MIDI?",
              answer: "Sì: dopo una separazione apri il menu «MIDI» in alto e scegli la traccia (voce, basso, chitarra, pianoforte…). AudioLR trova le note con Basic Pitch di Spotify, direttamente sul Mac, e salva un file .mid accanto alle tracce, al tempo della canzone: trascinalo in GarageBand o Logic. Funziona meglio sulle tracce con una nota per volta, come voce e basso."),
        Entry(topic: "Mixer ed esportazione", question: "Posso togliere il mio strumento e suonarci sopra?",
              answer: "Sì: nel mixer apri «Senza…» e scegli batteria, basso, chitarra o pianoforte. La tua parte sparisce e il resto della band suona. AudioLR ricorda l'ultimo strumento scelto: ⇧⌘K lo toglie o lo rimette in un attimo. Con «Esporta il mix» salvi la versione «Senza batteria» (o basso…) per esercitarti anche fuori dall'app. Con la Sala prove puoi anche rallentarla."),
        Entry(topic: "Mixer ed esportazione", question: "Come rallento un passaggio per impararlo?",
              answer: "Apri la Sala prove (⌥⌘P, o il tasto con la casetta nel trasporto). La velocità va dal 50% al 150% senza cambiare il tono; «Tono» sposta di semitoni senza cambiare la velocità. Per ripetere un passaggio premi A all'inizio e B alla fine (⌘[ e ⌘] mentre suona): il mixer torna da solo ad A. Velocità e tono valgono solo per l'ascolto, il mix esportato resta originale."),
        Entry(topic: "Mixer ed esportazione", question: "Come imparo un passaggio difficile un po' alla volta?",
              answer: "Apri la Sala prove (⌥⌘P), segna l'inizio con A (⌘[) e la fine con B (⌘]), poi attiva «Rampa»: il passaggio parte al 70% della velocità e a ogni giro accelera del 5%, fino al 100%. Il tono resta quello originale."),
        Entry(topic: "Mixer ed esportazione", question: "Posso tenere i cori nel karaoke?",
              answer: "Sì: dopo una separazione premi «Separa voce e cori» (⇧⌘V). La voce viene divisa in voce solista e cori; nel mixer compare la scorciatoia «Con i cori», che toglie solo la voce principale. La prima volta scarica un modello di circa 200 MB."),
        Entry(topic: "Mixer ed esportazione", question: "Cosa sono BPM e tonalità sotto il mixer?",
              answer: "Dopo ogni separazione AudioLR stima il tempo (BPM, dalla batteria) e la tonalità (dagli strumenti, senza voce e batteria). Passa sopra con il mouse per vedere la sigla (es. Am) e il codice Camelot dei DJ (es. 8A). Se il tempo ti sembra la metà di quello giusto, è il doppio: succede con i brani molto veloci."),
        Entry(topic: "Mixer ed esportazione", question: "Come salvo il mio mix?",
              answer: "Premi «Esporta il mix» (⌘E): AudioLR salva quello che senti, con muto, solo e volumi, accanto alle tracce, nel formato scelto nelle Impostazioni."),
        Entry(topic: "Mixer ed esportazione", question: "Posso usare le tracce in Traktor o Mixxx?",
              answer: "Sì: dal tasto «Esporta il mix» scegli «Esporta per DJ» (⌥⌘E). AudioLR crea «Canzone.stem.mp4», il formato Stem di Native Instruments: la canzone intera più batteria, basso, altri strumenti e voce, in AAC a 320 kbps. Traktor e Mixxx lo aprono con le quattro tracce; Musica e gli altri lettori suonano la canzone intera. In Impostazioni › Tracce puoi farlo creare a ogni separazione."),
        Entry(topic: "Mixer ed esportazione", question: "Posso usare le tracce in GarageBand o Logic?",
              answer: "Sì: trascina una traccia dalla finestra direttamente in GarageBand, Logic, Ableton o nel Finder. Tutte le tracce hanno la stessa durata e partono insieme, quindi restano allineate."),
        Entry(topic: "File e cartelle", question: "Dove vengono salvate le tracce?",
              answer: "Di serie in Musica › AudioLR, una cartella per canzone. Puoi cambiarla in Impostazioni › Tracce. ⇧⌘R mostra nel Finder la cartella della canzone aperta."),
        Entry(topic: "File e cartelle", question: "Quale formato scelgo?",
              answer: "WAV 24 bit è il più fedele e va bene ovunque. WAV 16 bit occupa meno. FLAC e ALAC sono senza perdita e più leggeri (ALAC si apre bene in Musica e GarageBand)."),
        Entry(topic: "File e cartelle", question: "Quanto spazio occupano i modelli? Posso eliminarli?",
              answer: "Circa 600 MB in tutto. In Impostazioni › Motore vedi lo spazio esatto e puoi eliminarli: si riscaricano da soli alla prossima separazione."),
        Entry(topic: "Velocità e motore", question: "Perché ci mette tanto?",
              answer: "La separazione è un calcolo pesante che avviene tutto sul tuo Mac. Sui Mac con chip Apple usa il Neural Engine ed è molto più rapida che sui Mac Intel. Veloce è circa 4 volte più rapida di Massima. In «Dettagli» (⌘I) vedi quanto tempo ha richiesto ogni fase."),
        Entry(topic: "Velocità e motore", question: "Cos'è «Prova il motore»?",
              answer: "Al primo uso di ogni modello AudioLR confronta Neural Engine e grafica su un pezzo della canzone e usa il più preciso. In Impostazioni › Motore puoi rifare la prova."),
        Entry(topic: "Velocità e motore", question: "Posso usare il Mac mentre separa?",
              answer: "Sì. Il Mac può scaldarsi e la ventola girare: è normale. Puoi annullare in qualsiasi momento con ⌘."),
        Entry(topic: "Aggiornamenti e privacy", question: "Le mie canzoni vengono caricate su internet?",
              answer: "No. Tutto il calcolo avviene sul tuo Mac. Internet serve solo per scaricare i modelli la prima volta e per controllare gli aggiornamenti."),
        Entry(topic: "Aggiornamenti e privacy", question: "Come si aggiorna AudioLR?",
              answer: "AudioLR controlla da sola all'apertura e ogni poche ore: quando esce una versione nuova compare in alto a destra il tasto «Aggiornamento disponibile», un clic e si installa. Puoi anche controllare a mano dal menu AudioLR › Controlla aggiornamenti…, oppure fare doppio clic su un file .audiolr: si installa in pochi secondi e l'app si riapre."),
        Entry(topic: "Aggiornamenti e privacy", question: "Posso usare le tracce di canzoni famose?",
              answer: "Per uso personale (studio, pratica, karaoke) sì. Pubblicare o vendere tracce di brani altrui richiede il permesso di chi ne ha i diritti."),
        Entry(topic: "Se qualcosa non va", question: "La separazione si è fermata con un errore",
              answer: "Premi «Riprova». Se l'errore torna, controlla di avere almeno 2 GB liberi sul disco e prova con Veloce. Poi usa «Segnala un bug» (⌥⌘B): il rapporto contiene già le informazioni del Mac."),
        Entry(topic: "Se qualcosa non va", question: "Il download dei modelli non parte",
              answer: "Serve internet solo la prima volta. Controlla la connessione e riprova; se sei in una rete aziendale o scolastica, GitHub potrebbe essere bloccato."),
        Entry(topic: "Se qualcosa non va", question: "macOS dice che AudioLR non si può aprire",
              answer: "Clic destro sull'app › Apri › Apri. Serve una volta sola, perché AudioLR non viene dall'App Store."),
    ]

    /// Le domande che contengono tutte le parole cercate (nella domanda, nella risposta o nell'argomento).
    static func search(_ text: String, in entries: [Entry] = all) -> [Entry] {
        let words = text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).map(String.init)
        guard !words.isEmpty else { return entries }
        return entries.filter { e in
            let hay = (e.topic + " " + e.question + " " + e.answer).lowercased().folding(options: .diacriticInsensitive, locale: nil)
            return words.allSatisfy { hay.contains($0) }
        }
    }
}

struct FAQView: View {
    @State private var search = ""
    @State private var open: Set<String> = []
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let found = FAQ.search(search)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                LogoMark(size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Domande frequenti").font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("Come si usa AudioLR, in breve").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("Cerca una domanda", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            .padding(18)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if found.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "questionmark.bubble").font(.system(size: 28)).foregroundStyle(.tertiary)
                            Text("Nessuna risposta per «\(search)»").foregroundStyle(.secondary)
                            Button("Chiedi segnalando un problema…") { openWindow(id: "bug") }
                        }
                        .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    ForEach(FAQ.topics, id: \.name) { topic in
                        let entries = found.filter { $0.topic == topic.name }
                        if !entries.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(topic.name.uppercased(), systemImage: topic.symbol)
                                    .font(.system(size: 10.5, weight: .bold)).tracking(1.1).foregroundStyle(Theme.brass)
                                ForEach(entries) { e in row(e, expanded: !search.isEmpty || open.contains(e.id)) }
                            }
                        }
                    }
                }
                .padding(18)
            }
            Divider()
            HStack {
                Text("Non hai trovato la risposta?").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button { openWindow(id: "bug") } label: { Label("Segnala un bug", systemImage: "ladybug") }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 480, idealHeight: 620)
        .background(Theme.background)
        .tint(Theme.brass)
    }

    private func row(_ e: FAQ.Entry, expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if open.contains(e.id) { open.remove(e.id) } else { open.insert(e.id) }
                }
            } label: {
                HStack {
                    Text(e.question).font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(e.answer).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
    }
}

// MARK: - Segnala un bug

/// Il rapporto: cosa è successo, come rifarlo, e le informazioni del Mac (senza dati personali né canzoni).
struct BugReport {
    enum Kind: String, CaseIterable, Identifiable {
        case bug, sound, slow, idea
        var id: String { rawValue }
        var title: String {
            switch self {
            case .bug: return "Qualcosa non funziona"
            case .sound: return "Problema di suono"
            case .slow: return "Troppo lenta"
            case .idea: return "Idea o richiesta"
            }
        }
    }

    var kind: Kind = .bug
    var summary = ""
    var steps = ""
    var includeSystem = true

    static let repo = URL(string: "https://github.com/LR-apps609/AudioLR")!

    var title: String {
        let s = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return "[\(kind.title)] " + (s.isEmpty ? "senza titolo" : String(s.prefix(80)))
    }

    func body(system: String) -> String {
        var b = "### Cosa è successo\n\(summary.isEmpty ? "—" : summary)\n\n### Come rifarlo\n\(steps.isEmpty ? "—" : steps)\n"
        if includeSystem { b += "\n### Il Mac\n```\n\(system)\n```\n" }
        return b
    }

    /// Pagina di GitHub con il rapporto già compilato (testo tagliato se troppo lungo per un indirizzo).
    func issueURL(system: String) -> URL {
        var c = URLComponents(url: Self.repo.appendingPathComponent("issues/new"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "title", value: title),
                        URLQueryItem(name: "body", value: String(body(system: system).prefix(6000))),
                        URLQueryItem(name: "labels", value: kind == .idea ? "enhancement" : "bug")]
        return c.url!
    }

    /// Versione, macOS, modello del Mac, chip, memoria, impostazioni e ultimo errore.
    @MainActor static func systemInfo() -> String {
        let p = ProcessInfo.processInfo
        let job = SeparationJob.shared
        var lines = [
            "AudioLR \(UpdateCheck.current) (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))",
            "macOS \(p.operatingSystemVersionString)",
            "Mac: \(sysctl("hw.model")) · \(chip())",
            String(format: "Memoria: %.0f GB · processori: %d", Double(p.physicalMemory) / 1_073_741_824, p.activeProcessorCount),
            "Qualità: \(Quality.current.title) · formato: \(Prefs.format.title) · voce: \(Prefs.voiceOverlap == 4 ? "precisione" : "equilibrio")",
        ]
        var seen = Set<String>()
        for name in [ModelStore.name] + Quality.studio.everyModel + Quality.best.everyModel where seen.insert(name).inserted {
            if let d = EngineChoice.current(name) { lines.append("Motore \(name): \(d.text)") }
        }
        if case .failed(let msg) = job.phase { lines.append("Ultimo errore: \(msg)") }
        if !job.timings.isEmpty {
            lines.append("Tempi: " + job.timings.map { "\($0.name) \(formatTime($0.seconds))" }.joined(separator: " · "))
        }
        if job.duration > 0 { lines.append("Durata canzone: \(formatTime(job.duration))") }
        // Gli ultimi passi del registro: dicono dove si è fermata una separazione
        let log = AppLog.tail(20)
        if !log.isEmpty { lines.append("Registro (ultimi passi):\n" + log) }
        return lines.joined(separator: "\n")
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buf)
    }

    private static func chip() -> String {
        let brand = sysctl("machdep.cpu.brand_string")
        return brand == "?" ? "chip sconosciuto" : brand
    }
}

struct BugReportView: View {
    @State private var report = BugReport()
    @State private var system = ""
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "ladybug.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.voiceMute.gradient))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Segnala un bug").font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("Più dettagli dai, più in fretta si sistema").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(18)
            Form {
                Picker("Tipo", selection: $report.kind) {
                    ForEach(BugReport.Kind.allCases) { k in Text(k.title).tag(k) }
                }
                TextField("Cosa è successo", text: $report.summary, prompt: Text("Es. la voce si sente nella batteria"), axis: .vertical)
                    .lineLimit(2...4)
                TextField("Come rifarlo", text: $report.steps, prompt: Text("Es. Massima, canzone MP3 di 3 min, al minuto 1:20"), axis: .vertical)
                    .lineLimit(3...6)
                Section {
                    Toggle("Includi le informazioni del Mac", isOn: $report.includeSystem)
                    if report.includeSystem {
                        Text(system).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                } footer: {
                    Text("Nessuna canzone, nessun nome di file personale: solo versione, Mac e impostazioni.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Button(copied ? "Copiato" : "Copia il rapporto") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.title + "\n\n" + report.body(system: system), forType: .string)
                    copied = true
                }
                Spacer()
                Button("Annulla") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Invia su GitHub…") {
                    NSWorkspace.shared.open(report.issueURL(system: system))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(report.summary.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(18)
        }
        .frame(width: 520, height: 600)
        .background(Theme.background)
        .tint(Theme.brass)
        .onAppear { system = BugReport.systemInfo() }
    }
}
