import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// ════════════════════════════════════════════════════════════════════
//  La finestra: trascini una canzone, la guardi separarsi in quattro
//  tracce, le ascolti una per una.
// ════════════════════════════════════════════════════════════════════

extension Notification.Name {
    /// Menu Archivio › Apri una canzone… (⌘O): la finestra apre il pannello di scelta.
    static let audiolrOpenSong = Notification.Name("audiolrOpenSong")
    /// Menu Mix: scorciatoia del mixer (l'oggetto è il nome di MixState.Preset).
    static let audiolrPreset = Notification.Name("audiolrPreset")
    /// Menu Mix: senza uno strumento (l'oggetto è il nome di MixState.Instrument; nessuno = il mio strumento).
    static let audiolrWithout = Notification.Name("audiolrWithout")
    /// Menu Mix › Suona / pausa.
    static let audiolrPlay = Notification.Name("audiolrPlay")
    /// Menu Mix › Esporta il mix (⌘E).
    static let audiolrExport = Notification.Name("audiolrExport")
    /// Menu Mix › Esporta per DJ (.stem.mp4).
    static let audiolrStemFile = Notification.Name("audiolrStemFile")
    /// Menu Mix › Inizio / fine del passaggio da ripetere (⌘[ e ⌘]): l'oggetto è «A» o «B».
    static let audiolrLoop = Notification.Name("audiolrLoop")
    /// Menu Mix › Warp (⌥⌘G) e Rimonta (⌥⌘X): gli editor della canzone aperta.
    static let audiolrWarp = Notification.Name("audiolrWarp")
    static let audiolrArrange = Notification.Name("audiolrArrange")
    static let audiolrNotes = Notification.Name("audiolrNotes")
    static let audiolrSlice = Notification.Name("audiolrSlice")
    /// Menu Vista › Dettagli della separazione (⌘I).
    static let audiolrDetails = Notification.Name("audiolrDetails")
}

struct ContentView: View {
    @EnvironmentObject private var job: SeparationJob
    @StateObject private var player = StemPlayer()
    @StateObject private var mixer = MixPlayer()
    @ObservedObject private var recorder = TakeRecorder.shared
    /// Le registrazioni della canzone aperta (la più recente per prima).
    @State private var takes: [URL] = []
    /// Il confronto della registrazione con una traccia («Voce», «Basso»…).
    @State private var comparison: (name: String, result: CompareResult)?
    @State private var comparing = false
    @ObservedObject private var warmup = Warmup.shared
    @ObservedObject private var updateNotice = UpdateNotice.shared
    /// Larghezza della parte principale: sotto la soglia i tasti mostrano solo l'icona, così niente esce dalla finestra.
    @State private var mainWidth: CGFloat = 1200
    private var compact: Bool { mainWidth < 1000 }
    @State private var exported: URL?
    @State private var unselected: Set<String> = []
    @State private var downloading = false
    @State private var downloadError: String?
    @State private var makingStemFile = false
    @State private var stemFileError: String?
    @State private var dropping = false
    @State private var news: [String] = []
    @AppStorage(Quality.key) private var qualityRaw = Quality.best.rawValue
    @AppStorage("showLibrary") private var showLibrary = true
    /// Il carico sul computer: con «leggero» le schede della qualità cambiano tempi ed etichetta
    @State private var showGuide = false
    @AppStorage(Prefs.sleepAfterBatchKey) private var sleepAfterBatch = false
    @State private var showDetails = false
    @State private var showWarp = false
    @State private var showArrange = false
    @State private var notesStem: Stem?
    @State private var showSlice = false
    @AppStorage("showPractice") private var showPractice = false
    @AppStorage("italianChords") private var italianChords = false
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var typing = TypingFocus.shared
    private var quality: Quality { Quality(rawValue: qualityRaw) ?? .best }

    var body: some View {
        // La larghezza vera della finestra (non quella del contenuto, che potrebbe essere più larga):
        // da qui si decide se i tasti mostrano solo l'icona
        GeometryReader { g in
            content
                .frame(width: g.size.width, height: g.size.height)
                .onChange(of: g.size.width, initial: true) { _, w in mainWidth = w - (showLibrary ? 251 : 0) }
                .onChange(of: showLibrary) { _, lib in
                    mainWidth = g.size.width - (lib ? 251 : 0)
                    widenIfNeeded(library: lib)
                }
        }
        // Con la libreria aperta serve più spazio: la finestra non si stringe oltre il punto in cui i tasti escono
        .frame(minWidth: showLibrary ? 1180 : 930)
    }

    /// Aprendo la libreria in una finestra stretta, la finestra si allarga invece di tagliare il contenuto.
    private func widenIfNeeded(library: Bool) {
        let need: CGFloat = library ? 1180 : 930
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && $0.frame.width < need }) else { return }
        var f = w.frame
        f.size.width = need
        w.setFrame(f, display: true, animate: true)
    }

    private var content: some View {
        HStack(spacing: 0) {
            if showLibrary {
                LibraryView()
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            main
        }
        .animation(.easeInOut(duration: 0.2), value: showLibrary)
        .background(StudioBackground())
        .foregroundStyle(Theme.ink)
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            player.stop()
            job.prepare(urls, quality: quality)
            return true
        } isTargeted: { dropping = $0 }
        .onAppear { news = WhatsNew.pending() }
        .onReceive(NotificationCenter.default.publisher(for: .audiolrOpenSong)) { _ in choose() }
        .onReceive(NotificationCenter.default.publisher(for: .audiolrPreset)) { n in
            if job.phase == .done, let raw = n.object as? String, let p = MixState.Preset(rawValue: raw) { mixer.state.apply(p) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .audiolrWithout)) { n in
            guard job.phase == .done else { return }
            if let raw = n.object as? String, let i = MixState.Instrument(rawValue: raw) { without(i); return }
            // ⇧⌘K: il mio strumento (l'ultimo scelto); se è già tolto, si torna a tutto
            // Se nella canzone non c'è (es. chitarra in Rapida), il primo strumento che c'è
            let mine = MixState.Instrument.mine.flatMap { available.contains($0) ? $0 : nil }
            guard let i = mine ?? available.first else { return }
            if mixer.state.without == i { mixer.state.apply(.all) } else { without(i) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .audiolrPlay)) { _ in
            guard job.phase == .done else { return }
            player.stop()
            mixer.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .audiolrExport)) { _ in downloadMix(range: nil) }
        .onReceive(NotificationCenter.default.publisher(for: .audiolrStemFile)) { _ in exportStemFile() }
        .alert("Il file per DJ non è riuscito", isPresented: Binding(get: { stemFileError != nil }, set: { if !$0 { stemFileError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(stemFileError ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .audiolrLoop)) { n in
            guard job.phase == .done else { return }
            showPractice = true
            if (n.object as? String) == "A" { mixer.markLoopStart() } else { mixer.markLoopEnd() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .audiolrDetails)) { _ in
            if job.phase == .done { showDetails = true }
        }
        .sheet(isPresented: Binding(get: { !news.isEmpty }, set: { if !$0 { news = [] } })) {
            WhatsNewSheet(items: news) { news = [] }
        }
    }

    private var main: some View {
        VStack(spacing: 16) {
            header
            Group {
                switch job.phase {
                case .idle: dropZone
                case .downloading, .reading, .tuning, .separating, .saving: working
                case .done: results
                case .failed(let msg): failed(msg)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .card(radius: 20)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Theme.brass, lineWidth: dropping ? 2.5 : 0)
            )
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: job.phase)
            footer
        }
        .padding(22)
    }

    // MARK: Testata

    private var header: some View {
        HStack(spacing: 12) {
            LogoMark(size: 38, animated: job.isBusy)
            VStack(alignment: .leading, spacing: 1) {
                // Il nome non si accorcia mai: è il primo a cui si dà spazio
                Text("IsoLR").font(.system(size: 22, weight: .bold, design: .rounded)).fixedSize()
                // Se lo spazio non basta (libreria aperta, finestra stretta) si accorcia invece di andare a capo
                ViewThatFits(in: .horizontal) {
                    Text("Separa voce e strumenti di qualsiasi canzone")
                    Text("Voce e strumenti separati")
                    Text("")
                }
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            // Versione nuova: un tasto ben visibile, un clic e si installa
            if let rel = updateNotice.available {
                Button { Task { await UpdateCheck.installNow(rel) } } label: {
                    HStack(spacing: 6) {
                        if updateNotice.downloading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.down.circle.fill") }
                        // Con poco spazio il testo si accorcia: il tasto resta sempre visibile e intero
                        Text(updateNotice.downloading ? (compact ? rel.version : "Scarico la \(rel.version)…")
                             : compact ? "Aggiorna · \(rel.version)" : "Aggiornamento disponibile · \(rel.version)")
                            .lineLimit(1)
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(Theme.brass.gradient))
                }
                .buttonStyle(.plain)
                .fixedSize()
                .disabled(updateNotice.downloading)
                .help("Hai la \(UpdateCheck.current): clic per scaricare e installare la \(rel.version). IsoLR si riapre da sola.")
                .accessibilityLabel("Aggiornamento disponibile, versione \(rel.version)")
                .transition(.scale.combined(with: .opacity))
            }
            // A destra quattro tasti, con il loro nome: libreria, aiuto, segnala, impostazioni.
            // Cronologia e account sono in fondo alla libreria; la privacy nella riga in fondo alla finestra
            HStack(spacing: 8) {
                toolButton("sidebar.left", help: showLibrary ? "Nascondi la libreria (⌘L)" : "Mostra la libreria (⌘L)") {
                    showLibrary.toggle()
                }
                Button { showGuide = true } label: { Label("Aiuto", systemImage: "questionmark.circle") }
                    .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                    .help("Come si usa IsoLR")
                    .popover(isPresented: $showGuide, arrowEdge: .bottom) {
                        GuideView { showGuide = false; openWindow(id: "faq") }
                    }
                // In vista, non solo nei menu: chi ha un problema lo segnala con un clic, con il Mac e il registro già scritti
                Button { openWindow(id: "bug") } label: { Label("Segnala", systemImage: "ladybug") }
                    .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                    .help("Segnala un problema o un'idea (⌥⌘B): il rapporto è già compilato con il Mac e l'ultimo errore")
                SettingsLink { Label("Impostazioni", systemImage: "gearshape") }
                    .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                    .help("Impostazioni (⌘,)")
            }
            .controlSize(.large)
        }
    }

    private func toolButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).frame(width: 30, height: 28)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: Inizio

    private var dropZone: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            IdleBars(count: 32, height: 76)
                .frame(maxWidth: 360)
                .opacity(dropping ? 1 : 0.9)
                .scaleEffect(dropping ? 1.06 : 1)
                .animation(.spring(response: 0.35), value: dropping)
            if job.pending.isEmpty {
                VStack(spacing: 6) {
                    Text(dropping ? "Lascia pure" : "Trascina qui una canzone")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("Anche più canzoni insieme · MP3, M4A, WAV, AIFF, FLAC")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Button { choose() } label: {
                    Label("Scegli una canzone…", systemImage: "music.note.list").padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                pendingSong
            }
            // Qualità: Rapida, Massima (di serie) o Studio
            // Tre schede che dicono cosa si ottiene e quanto ci vuole, invece dei nomi dei modelli
            VStack(spacing: 8) {
                Text("COME LA VUOI?").font(.system(size: 10, weight: .bold)).tracking(1.2).foregroundStyle(.tertiary)
                HStack(spacing: 10) {
                    ForEach(Quality.allCases) { q in qualityCard(q) }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
            // Canzone pronta: parte solo da qui
            if !job.pending.isEmpty {
                Button { player.stop(); job.startPending(quality: quality) } label: {
                    Label(job.pending.count == 1 ? "Separa · \(quality.title)" : "Separa \(job.pending.count) canzoni · \(quality.title)",
                          systemImage: "play.fill")
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                // Invio avvia la separazione, ma non mentre si scrive nella ricerca della libreria
                .keyboardShortcut(typing.typing ? nil : .defaultAction)
                .help("Avvia la separazione con la qualità scelta (Invio)")
            }
            // Primo avvio: modelli che si installano e Neural Engine che si prepara (si può già separare)
            if let w = warmup.text {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(w).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
            Spacer(minLength: 0)
            if job.history.isEmpty || showLibrary {
                VStack(spacing: 8) {
                    Text("RICEVERAI").font(.system(size: 10, weight: .bold)).tracking(1.2).foregroundStyle(.tertiary)
                    FlowLayout(spacing: 8, lineSpacing: 8) {
                        ForEach(Theme.stems(for: quality) + ["instrumental"], id: \.self) { key in
                            let info = Stem.info(key)
                            Chip(text: info.name, symbol: info.symbol, tint: Theme.color(key))
                        }
                    }
                    .frame(maxWidth: 560)
                }
                .padding(.bottom, 6)
            } else {
                recents
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                .foregroundStyle(dropping ? Theme.brass : Theme.stroke)
                .padding(12)
        )
    }

    private func qualityCard(_ q: Quality) -> some View {
        let on = quality == q
        let tracks = Theme.stems(for: q).count
        return Button { qualityRaw = q.rawValue } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: q.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(on ? Theme.brass : Color.secondary)
                    Text(q == .best ? "Massima" : q.title).font(.system(size: 14, weight: .semibold))
                }
                Text("\(tracks) tracce · \(q.cardLine)").font(.system(size: 11.5)).foregroundStyle(.secondary)
                Text(q.cardTime).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .frame(width: 170, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? Theme.brass.opacity(0.12) : Theme.well.opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? Theme.brass : Theme.stroke, lineWidth: on ? 1.5 : 1))
            // La scelta brilla, come un tasto acceso su un mixer
            .goldGlow(on, radius: 12)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help(q.detail)
        .accessibilityLabel("\(q.title): \(tracks) tracce, \(q.cardLine), \(q.cardTime)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// La canzone trascinata o scelta, in attesa di «Separa»: si vede bene cosa partirà.
    private var pendingSong: some View {
        VStack(spacing: 6) {
            Text(job.pending.count == 1 ? "CANZONE PRONTA" : "\(job.pending.count) CANZONI PRONTE")
                .font(.system(size: 10, weight: .bold)).tracking(1.2).foregroundStyle(.tertiary)
            HStack(spacing: 10) {
                Image(systemName: job.pending.count == 1 ? "music.note" : "music.note.list")
                    .font(.system(size: 18)).foregroundStyle(Theme.brass)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.pending[0].deletingPathExtension().lastPathComponent)
                        .font(.system(size: 17, weight: .semibold, design: .rounded)).lineLimit(1).truncationMode(.middle)
                    if job.pending.count > 1 {
                        Text("e altre \(job.pending.count - 1)").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                Button { job.clearPending() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 15)) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Togli la canzone").accessibilityLabel("Togli la canzone")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: 460)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
            Text("Scegli la qualità, poi premi «Separa»").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    /// Le ultime separazioni: un clic le riapre.
    private var recents: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RECENTI").font(.system(size: 10, weight: .bold)).tracking(1.2).foregroundStyle(.tertiary)
                .padding(.leading, 4)
            VStack(spacing: 2) {
                ForEach(job.history.prefix(4)) { item in RecentRow(item: item) }
            }
        }
        .frame(maxWidth: 460)
        .padding(.bottom, 4)
    }

    // MARK: Lavoro in corso

    private var working: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                songTitle
                Spacer(minLength: 8)
                RecLight()
            }
            // La canzone: la parte già separata in oro, con la testina luminosa. Prima di leggerla, barre che si muovono
            Group {
                if job.mixPeaks.isEmpty {
                    IdleBars(count: 34, height: 76).frame(maxWidth: .infinity)
                } else {
                    GlowWaveform(peaks: job.mixPeaks, progress: separatingProgress ?? 0)
                }
            }
                .frame(height: 76)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.well))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
            // Le tracce che stanno nascendo: un equalizzatore per ognuna, nel suo colore
            let keys = Theme.stems(for: job.quality)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: keys.count), spacing: 10) {
                ForEach(Array(keys.enumerated()), id: \.element) { i, key in
                    StemForming(key: key, progress: separatingProgress ?? 0, index: i)
                }
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline) {
                Text(percentText).font(.system(size: 34, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.brass).goldGlow(radius: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(stepText).font(.system(size: 13, weight: .semibold))
                    // Si aggiorna ogni secondo: il passo in corso e da quanto, così non sembra mai fermo
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(detailText).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !job.queue.isEmpty {
                    Chip(text: job.queue.count == 1 ? "1 in coda" : "\(job.queue.count) in coda", symbol: "list.bullet", tint: Theme.brass)
                        .help(job.queue.map { $0.deletingPathExtension().lastPathComponent }.joined(separator: "\n"))
                }
                // Album di notte: il Mac resta sveglio mentre separa; a fine lavoro, se scelto, va in stop
                Toggle(isOn: $sleepAfterBatch) { Label("Poi metti in stop il Mac", systemImage: "moon.zzz") }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .help("Mentre IsoLR separa il Mac non va in stop. Con questa scelta, un minuto dopo la fine dell'ultima canzone il Mac va in stop.")
                Button(job.queue.isEmpty ? "Annulla" : "Annulla tutto") { job.cancel() }.controlSize(.large)
            }
            steps
        }
        .padding(24)
    }

    /// Le fasi del lavoro, con la spunta su quelle finite.
    private var steps: some View {
        let names = ["Modello", "Lettura", "Separazione", "Salvataggio"]
        let current: Int = {
            switch job.phase {
            case .downloading: return 0
            case .reading: return 1
            case .tuning, .separating: return 2
            case .saving: return 3
            default: return 4
            }
        }()
        return HStack(spacing: 6) {
            ForEach(names.indices, id: \.self) { i in
                HStack(spacing: 4) {
                    Image(systemName: i < current ? "checkmark.circle.fill" : (i == current ? "circle.dotted" : "circle"))
                        .foregroundStyle(i <= current ? Theme.brass : Color.secondary.opacity(0.5))
                    Text(names[i]).foregroundStyle(i <= current ? Theme.ink : Color.secondary)
                }
                .font(.system(size: 11, weight: .medium))
                if i < names.count - 1 {
                    Rectangle().fill(Theme.stroke).frame(width: 18, height: 1)
                }
            }
        }
    }

    // MARK: Risultati

    private var results: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                songTitle
                transport
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(MixPlayer.mixable(job.stems)) { stem in
                            MixerRow(stem: stem, mixer: mixer, selected: selection(stem.key), onDownload: { downloadOne(stem) })
                        }
                        splitRows
                        let mixed = Set(MixPlayer.mixable(job.stems).map(\.key))
                        let others = job.stems.filter { !mixed.contains($0.key) }
                        if !others.isEmpty {
                            Divider().padding(.vertical, 4)
                            ForEach(others) { StemRow(stem: $0, player: player, selected: selection($0.key), onDownload: { [s = $0] in downloadOne(s) }) }
                        }
                    }
                    .padding(.bottom, 4)
                }
                if let q = job.qualityNote {
                    Chip(text: q, symbol: "exclamationmark.triangle.fill", tint: Theme.voiceMute)
                        .help("Un modello non si è potuto usare (memoria o download): riprova chiudendo le altre app. Dettagli in «Dettagli della separazione».")
                }
                Text("Clic sull'onda per ascoltare da quel punto · le tracce si possono anche trascinare in GarageBand, Logic o nel Finder")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            sidePanel
        }
        .padding(22)
        .onAppear { mixer.load(job.stems, folder: job.folder); mixer.setGrid(job.analysis) }
        .onChange(of: job.analysis) { _, a in mixer.setGrid(a) }
        .onChange(of: job.folder) { _, _ in unselected = [] }
        .onChange(of: job.stems) { _, stems in mixer.load(stems, folder: job.folder) }
        .onDisappear { mixer.stop() }
        .modifier(EditorSheets(showWarp: $showWarp, showArrange: $showArrange, notesStem: $notesStem, showSlice: $showSlice, job: job, mixer: mixer))
    }

    /// Le divisioni in più: «Separa voce e cori» e «Dividi la batteria», con la barra mentre lavorano.
    @ViewBuilder private var splitRows: some View {
        if let kind = job.splitting {
            HStack(spacing: 10) {
                ProgressView(value: job.splitProgress).tint(Theme.color(kind.source)).frame(maxWidth: .infinity)
                Text("\(kind.working) · \(Int(job.splitProgress * 100))%").font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Annulla") { job.cancelSplit() }.controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        } else {
            ForEach(ExtraSplit.allCases.filter { job.canSplit($0) }) { kind in
                HStack(spacing: 10) {
                    Image(systemName: kind.symbol).foregroundStyle(Theme.color(kind.source)).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(kind.title).font(.system(size: 12.5, weight: .semibold))
                        Text(job.splitErrors[kind].map { "Non riuscito: \($0). Riprova." } ?? kind.detail)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(kind == .drums ? "Dividi" : "Separa") { mixer.stop(); job.split(kind) }
                        .keyboardShortcut(kind == .drums ? "d" : kind == .gender ? "u" : "v", modifiers: [.command, .shift])
                        .help("\(kind == .drums ? "⇧⌘D" : kind == .gender ? "⇧⌘U" : "⇧⌘V") · la prima volta scarica il modello (\(kind.downloadSize))")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4])).foregroundStyle(Theme.stroke))
            }
        }
    }

    /// Il trasporto del mixer: suona tutto insieme, scorciatoie, esportazione del mix; sotto, la Sala prove.
    private var transport: some View {
        VStack(spacing: 8) {
            transportBar
            if showPractice { practiceBar }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.well))
        .animation(.easeInOut(duration: 0.15), value: showPractice)
    }

    /// Sala prove: le parti della canzone e il metronomo; sotto velocità, tono, un passaggio da ripetere.
    private var practiceBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                sectionStrip
                Toggle(isOn: $mixer.metronome) { Label("Metronomo", systemImage: "metronome") }
                    .toggleStyle(.button).controlSize(.small)
                    .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                    .disabled(!mixer.canClick)
                    .help(mixer.canClick ? "Un clic su ogni battito della canzone, più forte sul primo della battuta"
                                         : "Il metronomo segue i battiti trovati nelle separazioni fatte dalla 0.31: separa di nuovo la canzone")
                Toggle(isOn: $mixer.countIn) { Label("Conteggio", systemImage: "4.circle") }
                    .toggleStyle(.button).controlSize(.small)
                    .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                    .disabled(!mixer.canCount)
                    .help("Prima di partire, una battuta di clic al tempo della canzone (1, 2, 3, 4)")
            }
            if let chords = job.analysis?.chords, !chords.isEmpty { chordRow(chords) }
            practiceControls
            recordRow
        }
        .padding(.horizontal, 4)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Registrati sopra la base: il tasto rosso, il volume del microfono, poi la registrazione da riascoltare.
    private var recordRow: some View {
        HStack(spacing: 10) {
            Button {
                if recorder.recording { Task { await finishRecording() } } else { Task { await startRecording() } }
            } label: {
                Label(recorder.recording ? "Ferma" : "Registrati", systemImage: recorder.recording ? "stop.fill" : "record.circle")
                    .foregroundStyle(recorder.recording ? Color.primary : Color.red)
            }
            .controlSize(.small)
            .disabled(job.folder == nil || mixer.duration == 0)
            .help(recorder.recording ? "Ferma e metti a tempo la registrazione"
                                     : "Registra dal microfono o dalla scheda audio mentre suona la base (da A, o da dove sei, con una battuta di conteggio)")
            if recorder.recording {
                Capsule().fill(Color.primary.opacity(0.1)).frame(width: 90, height: 6)
                    .overlay(alignment: .leading) {
                        Capsule().fill(recorder.level > 0.9 ? Color.red : Color.green).frame(width: 90 * CGFloat(min(1, recorder.level)), height: 6)
                    }
                    .accessibilityLabel("Volume del microfono")
                Text(recorder.level > 0.9 ? "Troppo forte: abbassa il microfono" : "Registrazione in corso…")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if let t = mixer.take {
                Picker("Registrazione", selection: Binding(get: { t }, set: { mixer.setTake($0) })) {
                    ForEach(takes, id: \.self) { Text($0.deletingPathExtension().lastPathComponent).tag($0) }
                }
                .labelsHidden().fixedSize().controlSize(.small)
                Toggle(isOn: $mixer.takeOn) { Image(systemName: mixer.takeOn ? "speaker.wave.2.fill" : "speaker.slash") }
                    .toggleStyle(.button).controlSize(.small)
                    .help(mixer.takeOn ? "Senti la registrazione insieme alla base" : "La registrazione tace")
                Slider(value: $mixer.takeVolume, in: 0...2).frame(width: 80).controlSize(.small)
                    .accessibilityLabel("Volume della registrazione")
                Menu {
                    ForEach(MixPlayer.mixable(job.stems)) { st in
                        Button(st.name) { compare(t, with: st) }
                    }
                } label: {
                    Label(comparing ? "Confronto…" : "Confronta", systemImage: "chart.xyaxis.line")
                }
                .menuStyle(.button).fixedSize().controlSize(.small)
                .disabled(comparing)
                .help("Confronta la registrazione con la parte originale: intonazione e tempo")
                Button("Scarica") { downloadTake(t) }.controlSize(.small)
                    .help("Salva la registrazione (a tempo con la canzone) nel formato scelto")
                Button { deleteTake(t) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Sposta la registrazione nel Cestino")
            } else {
                Text("Suona o canta sopra la base: la registrazione si mette a tempo da sola")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
        }
        .onAppear { takes = job.folder.map(TakeRecorder.takes(in:)) ?? [] }
        .onChange(of: job.folder) { _, f in
            if recorder.recording { recorder.cancel(); mixer.recording = false }
            takes = f.map(TakeRecorder.takes(in:)) ?? []
        }
        .sheet(isPresented: Binding(get: { comparison != nil }, set: { if !$0 { comparison = nil } })) {
            if let c = comparison { CompareView(name: c.name, result: c.result) { comparison = nil } }
        }
        .alert("Registrazione", isPresented: Binding(get: { recorder.error != nil }, set: { if !$0 { recorder.error = nil } })) {
            Button("OK") { recorder.error = nil }
        } message: { Text(recorder.error ?? "") }
    }

    private func startRecording() async {
        guard await TakeRecorder.allowed() else { recorder.error = TakeRecorder.Problem.denied.errorDescription; return }
        do { try recorder.start() } catch {
            recorder.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        mixer.recording = true
        mixer.onPlay = { recorder.started($0) }
        mixer.onStopped = { Task { await finishRecording() } }
        // Da A se c'è un passaggio, altrimenti da dove si è; sempre con una battuta di conteggio
        mixer.play(from: mixer.loopA ?? mixer.position, counting: true, forceCount: true)
    }

    private func finishRecording() async {
        guard recorder.recording, let folder = job.folder else { return }
        if mixer.isPlaying { mixer.pause() }
        mixer.recording = false
        mixer.onPlay = nil
        mixer.onStopped = nil
        do {
            if let url = try await recorder.stop(into: folder, songDuration: mixer.duration, extraOffset: Prefs.recordOffset) {
                takes = TakeRecorder.takes(in: folder)
                mixer.setTake(url)
            }
        } catch { recorder.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    private func compare(_ take: URL, with stem: Stem) {
        comparing = true
        Task {
            do {
                let r = try await Task.detached(priority: .userInitiated) {
                    func mono(_ a: [[Float]]) -> [Float] {
                        guard a.count > 1 else { return a.first ?? [] }
                        return zip(a[0], a[1]).map { ($0 + $1) / 2 }
                    }
                    return try Compare.run(take: mono(try AudioIO.read(take)), original: mono(try AudioIO.read(stem.url)))
                }.value
                comparison = (stem.name, r)
            } catch { recorder.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            comparing = false
        }
    }

    private func downloadTake(_ url: URL) {
        let stem = Stem(key: "take", name: url.deletingPathExtension().lastPathComponent, symbol: "mic", url: url)
        downloadOne(stem)
    }

    private func deleteTake(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        takes = job.folder.map(TakeRecorder.takes(in:)) ?? []
        mixer.setTake(takes.first)
    }

    /// L'accordo che suona adesso, grande, e i prossimi tre: si legge mentre si suona.
    /// Con il tono cambiato gli accordi si spostano insieme alla musica.
    private func chordRow(_ chords: [ChordSpan]) -> some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let t = mixer.position
            let i = chords.firstIndex { t < $0.end } ?? chords.count - 1
            let next = chords[(i + 1)...].filter { $0.root != nil }.prefix(3)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Accordi").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(chords[i].name(italian: italianChords, shift: mixer.semitones))
                    .font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(Theme.brass)
                    .frame(minWidth: 56, alignment: .leading)
                    .accessibilityLabel("Accordo adesso: \(chords[i].name(italian: true, shift: mixer.semitones))")
                ForEach(Array(next.enumerated()), id: \.offset) { k, c in
                    Text(c.name(italian: italianChords, shift: mixer.semitones))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(k == 0 ? Color.primary.opacity(0.75) : Color.secondary)
                }
                if let n = next.first {
                    Text("tra \(max(0, Int(((n.start - t) / max(0.25, mixer.rate)).rounded(.up)))) s")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
                }
                Spacer()
                Picker("Nomi", selection: $italianChords) {
                    Text("C D E").tag(false)
                    Text("Do Re Mi").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                .help("Nomi degli accordi all'inglese (C, Am) o all'italiana (Do, Lam)")
            }
        }
        .help("Accordi stimati dagli strumenti (maggiori e minori): con il tono cambiato si spostano anche loro")
    }

    /// Le parti della canzone in proporzione alla durata: un clic ne ripete una.
    @ViewBuilder private var sectionStrip: some View {
        let parts = mixer.structure?.sections ?? []
        if parts.isEmpty || mixer.duration <= 0 {
            Text(mixer.structure == nil ? "Le parti della canzone (strofa, ritornello…) compaiono nelle separazioni fatte dalla 0.31"
                                        : "Parti della canzone non riconosciute: segna A e B a mano")
                .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            GeometryReader { geo in
                let w = geo.size.width, d = mixer.duration
                ZStack(alignment: .leading) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                        let on = abs((mixer.loopA ?? -9) - p.start) < 0.05 && abs((mixer.loopB ?? -9) - min(d, p.end)) < 0.05
                        Button { mixer.practice(from: p.start, to: p.end) } label: {
                            Text(p.label)
                                .font(.system(size: 10.5, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                                .foregroundStyle(on ? Color.white : Color.primary.opacity(0.8))
                                .padding(.horizontal, 5)
                                .frame(width: max(0, w * (min(d, p.end) - p.start) / d - 1), height: 24, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(on ? AnyShapeStyle(Theme.brass.gradient) : AnyShapeStyle(Theme.brass.opacity(0.10 + 0.07 * Double(p.group % 4)))))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .offset(x: w * p.start / d)
                        .help("Ripeti «\(p.label)» (\(formatTime(p.start))–\(formatTime(min(d, p.end))))")
                        .accessibilityLabel("Ripeti \(p.label), da \(formatTime(p.start))")
                    }
                    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                        Rectangle().fill(Color.primary.opacity(0.7)).frame(width: 2, height: 28)
                            .offset(x: max(0, min(w - 2, w * mixer.position / d - 1)))
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: 28)
            .frame(maxWidth: .infinity)
        }
    }

    /// Velocità, tono, un passaggio da ripetere.
    private var practiceControls: some View {
        HStack(spacing: 14) {
            if !compact {
                Label("Esercitati", systemImage: "music.note").font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.brass)
            }
            HStack(spacing: 6) {
                Image(systemName: "tortoise").font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: $mixer.rate, in: 0.5...1.5, step: 0.05).frame(width: compact ? 90 : 120)
                    .accessibilityLabel("Velocità")
                Image(systemName: "hare").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("\(Int((mixer.rate * 100).rounded()))%").font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                    .frame(width: 38, alignment: .leading)
            }
            .help("Velocità senza cambiare il tono")
            Stepper(value: $mixer.semitones, in: PitchShift.range) {
                Text("Tono \(mixer.semitones > 0 ? "+" : "")\(mixer.semitones)").font(.system(size: 11.5, weight: .medium)).monospacedDigit()
            }
            .help("Semitoni in su o in giù, senza cambiare la velocità")
            HStack(spacing: 4) {
                Button(mixer.loopA.map { "A " + formatTime($0) } ?? "A") { mixer.markLoopStart() }
                    .help("Inizio del passaggio da ripetere (⌘[)")
                Button(mixer.loopB.map { "B " + formatTime($0) } ?? "B") { mixer.markLoopEnd() }
                    .help("Fine del passaggio: da qui si torna ad A (⌘])")
                if mixer.loopA != nil || mixer.loopB != nil {
                    Button { mixer.clearLoop() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).help("Togli la ripetizione")
                }
            }
            .controlSize(.small)
            Toggle(isOn: $mixer.ramp) {
                Text(mixer.ramp ? (compact ? "" : "Rampa ") + "\(Int((MixPlayer.rampStart * 100).rounded()))→\(Int((MixPlayer.rampTarget * 100).rounded()))%" : "Rampa")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .toggleStyle(.button).controlSize(.small)
            .disabled(!mixer.isLooping)
            .help("Il passaggio A-B riparte ogni volta un po' più veloce: dal 70% al 100%, +5% a giro")
            Spacer()
            if mixer.rate != 1 || mixer.semitones != 0 || mixer.loopA != nil {
                Button("Normale") { mixer.resetPractice() }.controlSize(.small)
                    .help("Velocità e tono originali, niente ripetizione")
            }
        }
    }

    /// La barra del mixer: se Tutto/Karaoke/Solo voce non ci stanno affiancati, diventano un menu.
    /// Niente viene mai stretto sotto la misura delle sue parole (e quindi niente si sovrappone).
    private var transportBar: some View {
        transportRow(segmented: segmentsFit)
    }

    /// Ci stanno i tasti affiancati? Lo spazio della barra (la colonna meno i margini) contro quello che serve
    /// agli altri tasti più ai segmenti, con le misure di macOS 26 (controlli più grandi) e un po' di margine.
    private var segmentsFit: Bool { transportSpace >= 360 + segmentsWidth }
    /// «Esercitati» e «Senza…» con il nome: solo se c'è posto anche per i segmenti affiancati
    private var transportLabels: Bool { transportSpace >= 500 + segmentsWidth }
    /// Lo spazio della barra: la colonna meno i margini e il riquadro «Scarica» a destra
    private var transportSpace: CGFloat { mainWidth - 108 - 288 }
    private var segmentsWidth: CGFloat { mixer.keys.contains("lead") ? 350 : 260 }

    @ViewBuilder
    private func presetControl(segmented: Bool) -> some View {
        let presets = MixState.Preset.allCases.filter { $0 != .backing || mixer.keys.contains("lead") }
        if segmented {
            Picker("Scorciatoie", selection: Binding(
                get: { mixer.state.preset?.rawValue ?? "" },
                set: { if let p = MixState.Preset(rawValue: $0) { mixer.state.apply(p) } })) {
                ForEach(presets) { p in Text(p.title).tag(p.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(minWidth: compact ? 0 : (mixer.keys.contains("lead") ? 340 : 250))
            .fixedSize()
        } else {
            Menu {
                ForEach(presets) { p in
                    Button { mixer.state.apply(p) } label: {
                        if mixer.state.preset == p { Label(p.title, systemImage: "checkmark") } else { Text(p.title) }
                    }
                }
            } label: {
                Text(mixer.state.preset?.title ?? "Mix personale").lineLimit(1)
            }
            .menuStyle(.button)
            .fixedSize()
            .help("Tutto, Karaoke, Solo voce")
        }
    }

    private func transportRow(segmented: Bool) -> some View {
        HStack(spacing: 12) {
            Button {
                player.stop()
                mixer.toggle()
            } label: {
                Image(systemName: mixer.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Theme.brass.gradient))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(typing.typing ? nil : KeyboardShortcut(.space, modifiers: []))
            .help(mixer.isPlaying ? "Pausa (spazio)" : "Suona tutte le tracce insieme (spazio)")
            .accessibilityLabel(mixer.isPlaying ? "Pausa" : "Suona il mix")
            // Con la ripetizione attiva si controlla più spesso, per tornare ad A senza pause
            TimelineView(.periodic(from: .now, by: mixer.isLooping ? 0.04 : 0.25)) { _ in
                Text("\(formatTime(mixer.position)) / \(formatTime(mixer.duration))")
                    .fixedSize()
                    .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                    .onAppear { mixer.tick() }
                    .task(id: Int(mixer.position * (mixer.isLooping ? 25 : 4))) { mixer.tick() }
            }
            presetControl(segmented: segmented)
            withoutMenu
            // Transpose: sempre a vista, non solo in «Esercitati»
            TransposeButton(mixer: mixer, compact: !transportLabels).fixedSize()
            Spacer(minLength: 4)
            // Velocità, tono, ripetizione di un passaggio: tutto quello che serve a chi suona
            Toggle(isOn: $showPractice) { Label("Esercitati", systemImage: "music.note") }
                .toggleStyle(.button)
                .labelStyle(transportLabels ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
                .fixedSize()
                .help("Esercitati: velocità, tono e ripetizione di un passaggio (⌥⌘P)")
                .accessibilityLabel("Esercitati")
        }
    }

    // MARK: Errore

    private func failed(_ msg: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.slash").font(.system(size: 40, weight: .medium)).foregroundStyle(Theme.brass)
            Text("Non ci sono riuscito").font(.system(size: 19, weight: .semibold, design: .rounded))
            Text(Self.sentence(msg)).font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            HStack {
                if let s = job.song { Button("Riprova") { job.start(s, quality: quality) }.buttonStyle(.borderedProminent) }
                Button("Scegli un'altra canzone…") { job.reset(); choose() }
                Button("Segnala il problema…") { openWindow(id: "bug") }
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(30)
    }

    private var songTitle: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.brass.gradient))
            VStack(alignment: .leading, spacing: 1) {
                Text(job.title)
                    .font(.system(size: 17, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                // Tutto in una riga, a parole: durata, qualità, quanto ci ha messo, tempo e tonalità
                Text(infoLine).font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    .help(job.analysis.map { "Tonalità \($0.keyShort) · Camelot \($0.camelot) · se il tempo ti sembra lento, può essere \(Int(($0.bpm * 2).rounded())) BPM" } ?? "")
            }
        }
    }

    /// «4:40 · Studio · fatta in 8 min 56 s · 115 BPM · Do maggiore»
    private var infoLine: String {
        var parts: [String] = []
        if job.duration > 0 { parts.append(formatTime(job.duration)) }
        parts.append(job.quality.title)
        if let t = job.elapsed { parts.append("fatta in " + DockProgress.duration(t)) }
        if let a = job.analysis { parts.append(a.bpmText); parts.append(a.keyName) }
        return parts.joined(separator: " · ")
    }

    // MARK: Scarica e vai più a fondo

    @AppStorage("downloadFormat") private var downloadFormatRaw = OutputFormat.wav24.rawValue
    /// Con la tonalità cambiata: i file si scaricano trasposti (di serie) o nell'originale.
    @State private var downloadTransposed = true
    /// Di quanti semitoni spostare i file scaricati (0 = tonalità originale).
    private var downloadShift: Int { downloadTransposed ? mixer.semitones : 0 }
    private var downloadFormat: OutputFormat { OutputFormat(rawValue: downloadFormatRaw) ?? .wav24 }

    /// Le tracce scelte per «Scarica le selezionate»: di serie tutte (si tiene chi è stato tolto).
    private func selection(_ key: String) -> Binding<Bool> {
        Binding(get: { !unselected.contains(key) }, set: { on in if on { unselected.remove(key) } else { unselected.insert(key) } })
    }
    private var selectedStems: [Stem] { job.stems.filter { !unselected.contains($0.key) } }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Scarica").font(.system(size: 15, weight: .bold, design: .rounded))
                Picker("Formato", selection: $downloadFormatRaw) {
                    ForEach(OutputFormat.allCases) { f in Text(f.title).tag(f.rawValue) }
                }
                .help(downloadFormat.detail)
                if mixer.semitones != 0 {
                    Toggle(isOn: $downloadTransposed) {
                        Text(job.analysis.map { "In \(Transpose.keyName(root: $0.keyRoot, minor: $0.minor, shift: mixer.semitones)) (\(PitchShift.label(mixer.semitones)))" }
                             ?? "Nella tonalità scelta (\(PitchShift.label(mixer.semitones)))")
                            .font(.system(size: 12))
                    }
                    .help(downloadTransposed ? "I file si scaricano nella tonalità che senti" : "I file si scaricano nella tonalità originale")
                }
                Button { downloadMany(job.stems) } label: {
                    Label("Tutte le tracce", systemImage: "square.and.arrow.down.on.square").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button { downloadMany(selectedStems) } label: {
                    Text(selectedStems.count == 1 ? "La traccia selezionata" : "Le \(selectedStems.count) selezionate").frame(maxWidth: .infinity)
                }
                .disabled(selectedStems.isEmpty || selectedStems.count == job.stems.count)
                .help("Scegli le tracce con le caselle a sinistra di ogni traccia")
                Button { downloadMix(range: nil) } label: { Text("Il mix che senti").frame(maxWidth: .infinity) }
                    .help("Quello che senti adesso: con muto, solo, volumi e «Senza…»")
                Button { downloadMix(range: (mixer.loopA ?? 0, mixer.loopB ?? 0)) } label: {
                    Text("Il passaggio A–B").frame(maxWidth: .infinity)
                }
                .disabled(mixer.loopA == nil || mixer.loopB == nil)
                .help(mixer.loopA == nil || mixer.loopB == nil ? "Prima segna A e B in «Esercitati»" : "Solo il passaggio tra A e B, con il mix che senti")
                Button { exportStemFile() } label: { Text("File per DJ (.stem.mp4)").frame(maxWidth: .infinity) }
                    .disabled(makingStemFile)
                    .help("Traktor e Mixxx: la canzone intera più batteria, basso, altri strumenti e voce")
                if downloading || mixer.exporting || makingStemFile {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Preparo i file…").font(.system(size: 11)).foregroundStyle(.secondary) }
                } else {
                    Text("Scegli tu dove salvarle. Le tracce restano anche in \(Prefs.displayName(of: Prefs.folder)).")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.well.opacity(0.7)))

            VStack(alignment: .leading, spacing: 8) {
                Text("Vai più a fondo").font(.system(size: 15, weight: .bold, design: .rounded))
                // Warp e Rimonta: le versioni nuove della canzone (a tempo, rimontata)
                HStack(spacing: 6) {
                    Button { mixer.stop(); showWarp = true } label: { Label("Warp", systemImage: "metronome").frame(maxWidth: .infinity) }
                        .help("Warp: correggi la griglia dei battiti e metti la canzone a tempo fisso (⌥⌘G)")
                    Button { mixer.stop(); showArrange = true } label: { Label("Rimonta", systemImage: "scissors").frame(maxWidth: .infinity) }
                        .help("Rimonta: taglia, sposta, duplica o togli le parti della canzone (⌥⌘X)")
                }
                .disabled(job.stems.isEmpty || job.folder == nil)
                // Le note nell'app (piano roll) e la traccia tagliata sui colpi (Slice to MIDI)
                HStack(spacing: 6) {
                    Menu {
                        ForEach(job.midiStems) { s in Button(s.name) { mixer.pause(); notesStem = s } }
                    } label: { Label("Note", systemImage: "pianokeys") }
                    .help("Le note di una traccia: vedile, ascoltale e correggile (⌥⌘N)")
                    .disabled(job.midiStems.isEmpty)
                    Button { mixer.pause(); showSlice = true } label: { Label("Slice", systemImage: "square.grid.4x3.fill").frame(maxWidth: .infinity) }
                        .help("Slice to MIDI: la batteria (o un'altra traccia) tagliata sui colpi, da suonare con i pad e portare in Ableton o Logic (⌥⌘S)")
                }
                .disabled(job.stems.isEmpty || job.folder == nil)
                Menu {
                    ForEach(job.midiStems) { s in
                        Button(job.midiFiles[downloadShift == 0 ? s.key : "\(s.key)\(downloadShift)"] != nil ? "\(s.name) · mostra il file" : s.name) { job.makeMidi(s, shift: downloadShift) }
                    }
                } label: {
                    Text(job.midiWorking.map { "Note di \(Stem.info($0).name.lowercased())…" } ?? "File: MIDI, spartito e tab")
                }
                .disabled(job.midiWorking != nil || job.midiStems.isEmpty)
                .help(job.midiError.map { "Non riuscito: \($0)" } ?? "Le note di una traccia: file MIDI (GarageBand, Logic), spartito MusicXML (MuseScore, Guitar Pro) e, per chitarra e basso, la tablatura")
                Button { showDetails = true } label: { Text("Dettagli della separazione").frame(maxWidth: .infinity, alignment: .leading) }
                    .popover(isPresented: $showDetails, arrowEdge: .leading) { DetailsView().environmentObject(job) }
                    .help("Tempi di ogni fase, file di partenza, motore e di cosa è fatta la canzone (⌘I)")
                Button {
                    if let f = job.folder { NSWorkspace.shared.activateFileViewerSelecting([f]) }
                } label: { Text("Apri la cartella delle tracce").frame(maxWidth: .infinity, alignment: .leading) }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.well.opacity(0.7)))
            Spacer(minLength: 0)
        }
        .frame(width: 270)
        .alert("Non sono riuscito a salvare", isPresented: Binding(get: { downloadError != nil }, set: { if !$0 { downloadError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(downloadError ?? "") }
    }

    private func downloadOne(_ stem: Stem) {
        let f = downloadFormat, shift = downloadShift
        guard let url = Downloads.askFile(name: Downloads.fileName(title: job.title, stem: stem, format: f, shift: shift), format: f) else { return }
        downloading = true
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try Downloads.write(stem, to: url, format: f, shift: shift) }.value
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { downloadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            downloading = false
        }
    }

    private func downloadMany(_ stems: [Stem]) {
        guard !stems.isEmpty, let folder = Downloads.askFolder() else { return }
        let f = downloadFormat, title = job.title, shift = downloadShift
        downloading = true
        Task {
            do {
                let dir = try await Task.detached(priority: .userInitiated) { try Downloads.writeAll(stems, title: title, into: folder, format: f, shift: shift) }.value
                NSWorkspace.shared.activateFileViewerSelecting([dir])
            } catch { downloadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            downloading = false
        }
    }

    private func downloadMix(range: (Double, Double)?) {
        guard job.phase == .done, !mixer.exporting, let folder = job.folder else { return }
        let f = downloadFormat, shift = downloadShift
        var name = MixPlayer.exportName(state: mixer.state, title: job.title) + Downloads.suffix(shift)
        if let r = range { name += " (\(formatTime(r.0))–\(formatTime(r.1)))" }
        guard let url = Downloads.askFile(name: "\(name).\(f.fileExtension)", format: f) else { return }
        Task {
            do {
                let done = try await mixer.export(stems: job.stems, folder: folder, title: job.title, to: url, format: f, range: range, shift: shift)
                exported = done
                NSWorkspace.shared.activateFileViewerSelecting([done])
            } catch { downloadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    private var footer: some View {
        Text("Le canzoni non lasciano mai il tuo Mac · Le tracce vanno in \(Prefs.displayName(of: Prefs.folder))")
            .font(.system(size: 11)).foregroundStyle(.tertiary)
    }

    // MARK: Testi


    private var separatingProgress: Double? {
        switch job.phase {
        case .separating(let p): return p
        case .saving: return 1
        default: return 0
        }
    }

    private var percentText: String {
        switch job.phase {
        case .downloading(let p): return "\(Int(p * 100))%"
        case .separating(let p): return "\(Int(p * 100))%"
        case .saving: return "100%"
        default: return "0%"
        }
    }

    private var stepText: String {
        switch job.phase {
        case .downloading: return job.installing ? "Installo il modello di IA" : "Scarico il modello di IA"
        case .reading: return "Leggo la canzone"
        case .tuning: return "Provo il motore del tuo Mac"
        case .separating: return job.quality == .fast ? "Separo voce e strumenti" : "Separo voce e strumenti · \(job.quality.title)"
        case .saving: return "Salvo le tracce"
        default: return ""
        }
    }

    private var detailText: String {
        switch job.phase {
        case .downloading: return job.installing
            ? "Scaricato: lo verifico e lo installo sul Mac. Solo la prima volta, qualche decina di secondi."
            : "Solo la prima volta, \(job.quality.downloadSize). Poi funziona anche senza internet."
        case .tuning, .reading:
            if let d = job.stepDetail { return d + " · " + formatTime(Date().timeIntervalSince(job.stepStarted)) }
            return "Solo la prima volta: il Neural Engine adatta i modelli a questo Mac e li confronto con la grafica."
        case .separating(let p):
            if let r = job.remaining, p > 0 { return Self.timeLeft(r) }
            if let d = job.stepDetail { return d + " · " + formatTime(Date().timeIntervalSince(job.stepStarted)) }
            return "Calcolo il tempo che manca…"
        case .saving: return "\(Prefs.format.title) in \(Prefs.displayName(of: Prefs.folder))"
        default: return " "
        }
    }

    /// «il file è vuoto» → «Il file è vuoto.»
    static func sentence(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + String(s.dropFirst()) + "."
    }

    static func timeLeft(_ s: Double) -> String {
        if s < 10 { return "Quasi fatto" }
        if s < 60 { return "Circa \(Int((s / 5).rounded()) * 5) secondi" }
        let m = Int((s / 60).rounded())
        return m == 1 ? "Circa 1 minuto" : "Circa \(m) minuti"
    }

    /// Salva il mix che si sente e lo mostra nel Finder.
    /// Gli strumenti che questa canzone ha davvero (chitarra e piano solo se divisi).
    private var available: [MixState.Instrument] {
        MixState.Instrument.allCases.filter { !$0.keys.isDisjoint(with: mixer.keys) }
    }

    private func without(_ i: MixState.Instrument) {
        guard available.contains(i) else { return }
        mixer.state.apply(without: i)
        MixState.Instrument.mine = i
    }

    /// «Senza il mio strumento»: per suonare sopra la canzone la propria parte.
    private var withoutMenu: some View {
        Menu {
            ForEach(available) { i in
                Button { without(i) } label: {
                    Label(i.without, systemImage: mixer.state.without == i ? "checkmark" : i.symbol)
                }
            }
            if mixer.state.without != nil {
                Divider()
                Button("Tutte le tracce") { mixer.state.apply(.all) }
            }
        } label: {
            Label(mixer.state.without?.without ?? "Senza…", systemImage: "music.note.list")
                .lineLimit(1)
                // Con poco spazio solo l'icona, colorata quando uno strumento è tolto (il nome compare passandoci sopra)
                .labelStyle(transportLabels ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
                .foregroundStyle(!transportLabels && mixer.state.without != nil ? Theme.brass : Theme.ink)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(available.isEmpty)
        .help((mixer.state.without.map { $0.without + " · " } ?? "") + "Togli la tua parte e suonaci sopra (⇧⌘K: l'ultimo strumento scelto)")
        .accessibilityLabel("Senza il mio strumento")
    }

    /// Il file per Traktor e Mixxx: canzone intera più batteria, basso, altri strumenti e voce.
    private func exportStemFile() {
        guard job.phase == .done, !makingStemFile, let f = job.folder else { return }
        let song = job.song
        makingStemFile = true
        let stems = job.stems, title = job.title, shift = downloadShift
        Task {
            defer { makingStemFile = false }
            do {
                let url = try await StemFile.make(stems: stems, song: song, folder: f, title: title, shift: shift)
                exported = url
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                stemFileError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Scegli una o più canzoni, o una cartella intera, da separare"
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            player.stop()
            job.prepare(panel.urls, quality: quality)
        }
    }
}

// MARK: - Una traccia

struct StemRow: View {
    let stem: Stem
    @ObservedObject var player: StemPlayer
    var selected: Binding<Bool>? = nil
    var onDownload: (() -> Void)? = nil
    @State private var hover = false

    var body: some View {
        let playing = player.current == stem.url
        HStack(spacing: 12) {
            if let selected {
                Toggle("", isOn: selected).toggleStyle(.checkbox).labelsHidden()
                    .help("Scegli questa traccia per «Scarica le selezionate»")
                    .accessibilityLabel("Scegli \(stem.name) per il download")
            }
            StemBadge(key: stem.key, symbol: stem.symbol, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(stem.name).font(.system(size: 13, weight: .semibold))
                Text(playing ? "In ascolto" : stem.url.pathExtension.uppercased()).font(.system(size: 10.5)).foregroundStyle(playing ? Theme.color(stem.key) : Color.secondary)
            }
            .frame(width: 118, alignment: .leading)

            TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing)) { _ in
                GeometryReader { g in
                    WaveformView(peaks: stem.peaks, color: Theme.color(stem.key),
                                 dim: Theme.color(stem.key).opacity(0.35),
                                 progress: playing ? player.progress : nil,
                                 playhead: playing ? player.progress : nil)
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { p in
                            player.play(stem.url, from: Double(p.x / max(g.size.width, 1)))
                        }
                }
            }
            .frame(height: 34)

            Button { player.toggle(stem.url) } label: {
                Image(systemName: playing ? "stop.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.color(stem.key).gradient))
            }
            .buttonStyle(.plain)
            .help(playing ? "Ferma" : "Ascolta")
            .accessibilityLabel(playing ? "Ferma \(stem.name)" : "Ascolta \(stem.name)")
            if let onDownload {
                Button(action: onDownload) { Label("Scarica", systemImage: "arrow.down.to.line") }
                    .controlSize(.small)
                    .fixedSize()
                    .help("Salva solo questa traccia, nel formato scelto a destra")
                    .accessibilityLabel("Scarica \(stem.name)")
            } else {
                Button { NSWorkspace.shared.activateFileViewerSelecting([stem.url]) } label: {
                    Image(systemName: "folder").font(.system(size: 13))
                }
                .buttonStyle(.borderless)
                .help("Mostra il file nel Finder")
                .accessibilityLabel("Mostra \(stem.name) nel Finder")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(playing ? Theme.color(stem.key).opacity(0.12) : (hover ? Theme.ink.opacity(0.04) : Theme.well.opacity(0.6))))
        .onHover { hover = $0 }
        // Si può trascinare la traccia direttamente in un'altra app (GarageBand, Logic, Finder…)
        .onDrag { NSItemProvider(contentsOf: stem.url) ?? NSItemProvider() }
    }
}

/// Ascolto di una traccia alla volta.
@MainActor
final class StemPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var current: URL?
    private var player: AVAudioPlayer?

    /// 0…1: a che punto è la traccia che suona.
    var progress: Double {
        guard let p = player, p.duration > 0 else { return 0 }
        return p.currentTime / p.duration
    }

    func toggle(_ url: URL) {
        if current == url { stop() } else { play(url, from: 0) }
    }

    func play(_ url: URL, from position: Double) {
        if current != url {
            stop()
            guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
            p.delegate = self
            player = p
            current = url
        }
        guard let p = player else { return }
        p.currentTime = max(0, min(1, position)) * p.duration
        p.play()
    }

    func stop() {
        player?.stop()
        player = nil
        current = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

// MARK: - Novità dopo un aggiornamento

enum WhatsNew {
    static let key = "lastRunVersion"

    /// Le novità da mostrare una volta, dopo un aggiornamento (non al primo avvio).
    static func pending(defaults: UserDefaults = .standard, current: String = UpdateCheck.current, text: String = News.text) -> [String] {
        let last = defaults.string(forKey: key)
        defaults.set(current, forKey: key)
        guard let last, News.newer(current, than: last) else { return [] }
        return News.items(since: last, in: text)
    }
}

struct WhatsNewSheet: View {
    let items: [String]
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                LogoMark(size: 44, animated: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("IsoLR è aggiornata").font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("Versione \(UpdateCheck.current)").font(.system(size: 12)).foregroundStyle(Theme.brass)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(items, id: \.self) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(Theme.brass).frame(width: 6, height: 6)
                            Text(item).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxHeight: 260)
            HStack { Spacer(); Button("Inizia") { close() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }
        }
        .padding(24)
        .frame(width: 440)
    }
}

// MARK: - Una separazione recente

struct RecentRow: View {
    let item: HistoryItem
    @EnvironmentObject private var job: SeparationJob
    @State private var hover = false

    var body: some View {
        Button { job.open(item) } label: {
            HStack(spacing: 10) {
                LogoMark(size: 22)
                Text(item.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(History.when(item.date)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? Theme.ink.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Riapri le tracce di «\(item.title)»")
        .contextMenu {
            Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.folderURL]) }
            Button("Togli dai recenti") { job.forget(item) }
        }
    }
}

// MARK: - Una traccia del mixer

struct MixerRow: View {
    let stem: Stem
    @ObservedObject var mixer: MixPlayer
    /// La casella per «Scarica le selezionate»
    var selected: Binding<Bool>? = nil
    var onDownload: (() -> Void)? = nil

    var body: some View {
        let muted = mixer.state.muted.contains(stem.key)
        let solo = mixer.state.solo.contains(stem.key)
        let audible = mixer.state.effectiveGain(stem.key) > 0
        HStack(spacing: 10) {
            if let selected {
                Toggle("", isOn: selected).toggleStyle(.checkbox).labelsHidden()
                    .help("Scegli questa traccia per «Scarica le selezionate»")
                    .accessibilityLabel("Scegli \(stem.name) per il download")
            }
            StemBadge(key: stem.key, symbol: stem.symbol, size: 32)
                .opacity(audible ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 1) {
                Text(stem.name).font(.system(size: 13, weight: .semibold))
                if let share = stem.share {
                    Text(String(format: "%.0f%% della canzone", share * 100))
                        .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                        .help(stem.peakDB.map { String(format: "Picco %.1f dB", $0) } ?? "")
                }
            }
            .frame(width: 112, alignment: .leading)
            toggle(muted ? "speaker.slash.fill" : "speaker.slash", on: muted, tint: Theme.voiceMute,
                   help: muted ? "Torna a sentirla" : "Silenzia questa traccia") {
                if muted { mixer.state.muted.remove(stem.key) } else { mixer.state.muted.insert(stem.key) }
            }
            toggle("headphones", on: solo, tint: Theme.brass, help: solo ? "Torna a sentire tutto" : "Ascolta solo questa traccia") {
                if solo { mixer.state.solo.remove(stem.key) } else { mixer.state.solo.insert(stem.key) }
            }
            Slider(value: Binding(get: { mixer.state.gain[stem.key] ?? 1 }, set: { mixer.state.gain[stem.key] = $0 }), in: 0...1.5)
                .frame(width: 90)
                .tint(Theme.color(stem.key))
                .help("Volume")
                .accessibilityLabel("Volume \(stem.name)")
            // Il livello della traccia in questo istante (dalla sua forma d'onda): si muove mentre suona
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !mixer.isPlaying)) { _ in
                let p = mixer.duration > 0 ? mixer.position / mixer.duration : 0
                let i = min(stem.peaks.count - 1, max(0, Int(p * Double(stem.peaks.count))))
                let level = mixer.isPlaying && audible && !stem.peaks.isEmpty ? Double(stem.peaks[i]).squareRoot() : 0
                LevelMeter(level: level, color: Theme.color(stem.key))
            }
            .frame(width: 6, height: 30)
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !mixer.isPlaying)) { _ in
                GeometryReader { g in
                    let p = mixer.duration > 0 ? mixer.position / mixer.duration : 0
                    // A riposo, dall'inizio, l'onda è a colori pieni; mentre suona si colora la parte ascoltata
                    let started = mixer.isPlaying || mixer.position > 0.05
                    WaveformView(peaks: stem.peaks, color: Theme.color(stem.key),
                                 dim: Theme.color(stem.key).opacity(0.35),
                                 progress: audible ? (started ? p : nil) : 0, playhead: started ? p : nil)
                        .opacity(audible ? 1 : 0.35)
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { pt in
                            mixer.seek(to: Double(pt.x / max(g.size.width, 1)))
                            if !mixer.isPlaying { mixer.toggle() }
                        }
                }
            }
            .frame(height: 30)
            if let onDownload {
                Button(action: onDownload) { Label("Scarica", systemImage: "arrow.down.to.line") }
                    .controlSize(.small)
                    .fixedSize()
                    .help("Salva solo questa traccia, nel formato scelto a destra")
                    .accessibilityLabel("Scarica \(stem.name)")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(solo ? Theme.color(stem.key).opacity(0.10) : Theme.well.opacity(0.6)))
        .onDrag { NSItemProvider(contentsOf: stem.url) ?? NSItemProvider() }
    }

    private func toggle(_ symbol: String, on: Bool, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 24)
                .foregroundStyle(on ? .white : Color.secondary)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? tint : Theme.ink.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("\(help) \(stem.name)")
    }
}

/// Uno stile di etichetta scelto al volo (solo icona quando lo spazio è poco).
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// Il risultato del confronto: un voto, intonazione e tempo in parole, e le due linee dell'altezza.
struct CompareView: View {
    let name: String
    let result: CompareResult
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(result.verdict).font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(Theme.brass)
                Text("· \(Int((result.inTune * 100).rounded()))% intonato rispetto a «\(name)»").font(.system(size: 15, weight: .medium))
                Spacer()
            }
            HStack(spacing: 22) {
                fact("Intonazione", abs(result.cents) < 10 ? "Centrata" :
                        "\(Int(abs(result.cents).rounded())) cent \(result.cents > 0 ? "crescente" : "calante")",
                     abs(result.cents) < 10 ? "in media sei sulla nota giusta" : (result.cents > 0 ? "in media un filo sopra la nota" : "in media un filo sotto la nota"))
                fact("Tempo", abs(result.offsetMs) < 15 ? "A tempo" :
                        "\(Int(abs(result.offsetMs).rounded())) ms \(result.offsetMs > 0 ? "in ritardo" : "in anticipo")",
                     abs(result.offsetMs) < 15 ? "gli attacchi combaciano" : "gli attacchi in media rispetto all'originale")
                fact("Confrontati", "\(Int(result.seconds.rounded())) s", "da \(formatTime(result.start)) a \(formatTime(result.end))")
            }
            PitchLines(result: result)
                .frame(height: 220)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.well))
            HStack(spacing: 16) {
                legend(Theme.brass, "Originale")
                legend(.red, "Tu")
                Text("Un'ottava sopra o sotto conta come la stessa nota").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Button("Fatto", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 720)
    }

    private func fact(_ title: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit()
            Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 5) { Capsule().fill(c).frame(width: 14, height: 3); Text(t).font(.system(size: 11)) }
    }
}

/// Le due linee dell'altezza nel tempo; le tue note si portano all'ottava dell'originale per confrontarle.
struct PitchLines: View {
    let result: CompareResult

    var body: some View {
        Canvas { ctx, size in
            let all = (result.original + result.mine).compactMap { $0 }
            guard let lo0 = all.min(), let hi0 = all.max(), result.original.count > 1 else { return }
            let lo = lo0 - 2, hi = max(lo0 + 12, hi0 + 2)
            let n = result.original.count
            func pt(_ i: Int, _ m: Double) -> CGPoint {
                CGPoint(x: 10 + (size.width - 20) * CGFloat(i) / CGFloat(n - 1), y: size.height - 10 - (size.height - 20) * CGFloat((m - lo) / (hi - lo)))
            }
            // Righe dei semitoni (più marcate sui Do)
            for m in Int(lo.rounded(.up))...Int(hi) {
                let y = pt(0, Double(m)).y
                ctx.fill(Path(CGRect(x: 10, y: y, width: size.width - 20, height: m % 12 == 0 ? 1 : 0.5)),
                         with: .color(.primary.opacity(m % 12 == 0 ? 0.18 : 0.06)))
            }
            func line(_ v: [Double?], _ c: Color, follow: Bool) {
                var p = Path(), open = false
                for i in 0..<min(n, v.count) {
                    guard var m = v[i] else { open = false; continue }
                    if follow, let o = result.original[i] { m -= 12 * ((m - o) / 12).rounded() }
                    if open { p.addLine(to: pt(i, m)) } else { p.move(to: pt(i, m)); open = true }
                }
                ctx.stroke(p, with: .color(c), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            line(result.original, Theme.brass, follow: false)
            line(result.mine, .red.opacity(0.85), follow: true)
        }
        .accessibilityLabel("Le linee dell'altezza: originale e la tua registrazione")
    }
}

/// Gli editor Warp e Rimonta come fogli sopra i risultati, aperti dal riquadro «Vai più a fondo» o dal menu Mix.
/// A parte: il corpo di ContentView è già al limite di quello che il compilatore controlla in tempo.
struct EditorSheets: ViewModifier {
    @Binding var showWarp: Bool
    @Binding var showArrange: Bool
    @Binding var notesStem: Stem?
    @Binding var showSlice: Bool
    let job: SeparationJob
    let mixer: MixPlayer

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .audiolrWarp)) { _ in
                if job.phase == .done, !job.stems.isEmpty { mixer.stop(); showWarp = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: .audiolrArrange)) { _ in
                if job.phase == .done, !job.stems.isEmpty { mixer.stop(); showArrange = true }
            }
            .sheet(isPresented: $showWarp) { WarpView(mixer: mixer) { showWarp = false }.environmentObject(job) }
            .sheet(isPresented: $showArrange) { ArrangeView(mixer: mixer) { showArrange = false }.environmentObject(job) }
            .onReceive(NotificationCenter.default.publisher(for: .audiolrNotes)) { _ in
                if job.phase == .done, let s = job.midiStems.first { mixer.pause(); notesStem = s }
            }
            .onReceive(NotificationCenter.default.publisher(for: .audiolrSlice)) { _ in
                if job.phase == .done, !job.stems.isEmpty { mixer.pause(); showSlice = true }
            }
            .sheet(item: $notesStem) { s in PianoRollView(mixer: mixer, stem: s) { notesStem = nil }.environmentObject(job) }
            .sheet(isPresented: $showSlice) { SliceView(mixer: mixer) { showSlice = false }.environmentObject(job) }
    }
}
