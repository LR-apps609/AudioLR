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
    /// Menu Vista › Dettagli della separazione (⌘I).
    static let audiolrDetails = Notification.Name("audiolrDetails")
}

struct ContentView: View {
    @EnvironmentObject private var job: SeparationJob
    @StateObject private var player = StemPlayer()
    @StateObject private var mixer = MixPlayer()
    @State private var exported: URL?
    @State private var makingStemFile = false
    @State private var stemFileError: String?
    @State private var dropping = false
    @State private var news: [String] = []
    @AppStorage(Quality.key) private var qualityRaw = Quality.best.rawValue
    @AppStorage("showLibrary") private var showLibrary = true
    @State private var showGuide = false
    @State private var showDetails = false
    @AppStorage("showPractice") private var showPractice = false
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var typing = TypingFocus.shared
    private var quality: Quality { Quality(rawValue: qualityRaw) ?? .best }

    var body: some View {
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
            job.enqueue(urls, quality: quality)
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
            // Se nella canzone non c'è (es. chitarra in Veloce), il primo strumento che c'è
            let mine = MixState.Instrument.mine.flatMap { available.contains($0) ? $0 : nil }
            guard let i = mine ?? available.first else { return }
            if mixer.state.without == i { mixer.state.apply(.all) } else { without(i) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .audiolrPlay)) { _ in
            guard job.phase == .done else { return }
            player.stop()
            mixer.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .audiolrExport)) { _ in exportMix() }
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
                Text("AudioLR").font(.system(size: 22, weight: .bold, design: .rounded))
                // Se lo spazio non basta (libreria aperta, finestra stretta) si accorcia invece di andare a capo
                ViewThatFits(in: .horizontal) {
                    Text("Separa voce e strumenti di qualsiasi canzone")
                    Text("Voce e strumenti separati")
                }
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Chip(text: "Tutto sul tuo Mac", symbol: "lock.fill", tint: Theme.green)
                .help("La canzone non viene caricata su internet")
            HStack(spacing: 2) {
                toolButton(showLibrary ? "sidebar.left" : "sidebar.left", help: showLibrary ? "Nascondi la libreria" : "Mostra la libreria") {
                    showLibrary.toggle()
                }
                toolButton("questionmark.circle", help: "Come si usa") { showGuide = true }
                    .popover(isPresented: $showGuide, arrowEdge: .bottom) {
                        GuideView { showGuide = false; openWindow(id: "faq") }
                    }
                toolButton("clock.arrow.circlepath", help: "Cronologia (⌘Y)") { openWindow(id: "history") }
                toolButton("person.crop.circle", help: "Account (⇧⌘A)") { openWindow(id: "account") }
                SettingsLink {
                    Image(systemName: "gearshape").font(.system(size: 15, weight: .medium)).frame(width: 30, height: 28)
                }
                .buttonStyle(.borderless)
                .help("Impostazioni (⌘,)")
                .accessibilityLabel("Impostazioni")
            }
            .padding(3)
            .background(Capsule().fill(Theme.card.opacity(0.8)))
            .overlay(Capsule().strokeBorder(Theme.stroke))
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
            // Qualità: Massima (di serie) o Veloce
            VStack(spacing: 6) {
                Picker("Qualità", selection: $qualityRaw) {
                    ForEach(Quality.allCases) { q in Text(q.title).tag(q.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 360)
                Text(quality.detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
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
            songTitle
            // La canzone: si colora man mano che viene separata
            WaveformView(peaks: job.mixPeaks.isEmpty ? Self.placeholderPeaks : job.mixPeaks,
                         color: Theme.brass, dim: Theme.ink.opacity(job.mixPeaks.isEmpty ? 0.07 : 0.18),
                         progress: separatingProgress, barWidth: 2.5, spacing: 1.5)
                .frame(height: 64)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.well))
            // Le quattro tracce che stanno nascendo
            VStack(spacing: 8) {
                ForEach(Theme.stems(for: job.quality), id: \.self) { key in
                    let info = Stem.info(key)
                    HStack(spacing: 10) {
                        StemBadge(key: key, symbol: info.symbol, size: 24)
                        Text(info.name).font(.system(size: 12, weight: .semibold)).frame(width: 110, alignment: .leading)
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.ink.opacity(0.08))
                                Capsule().fill(Theme.color(key).gradient)
                                    .frame(width: max(0, g.size.width * (separatingProgress ?? 0)))
                            }
                        }
                        .frame(height: 6)
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline) {
                Text(percentText).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                VStack(alignment: .leading, spacing: 2) {
                    Text(stepText).font(.system(size: 13, weight: .semibold))
                    Text(detailText).font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                if !job.queue.isEmpty {
                    Chip(text: job.queue.count == 1 ? "1 in coda" : "\(job.queue.count) in coda", symbol: "list.bullet", tint: Theme.brass)
                        .help(job.queue.map { $0.deletingPathExtension().lastPathComponent }.joined(separator: "\n"))
                }
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                songTitle
                Spacer()
                Button { showDetails = true } label: { Label("Dettagli", systemImage: "info.circle") }
                    .popover(isPresented: $showDetails, arrowEdge: .bottom) { DetailsView().environmentObject(job) }
                    .help("Tempi di ogni fase, file di partenza, motore e di cosa è fatta la canzone")
                Menu {
                    ForEach(job.midiStems) { s in
                        Button(job.midiFiles[s.key] != nil ? "\(s.name) · mostra il file" : s.name) { job.makeMidi(s) }
                    }
                } label: {
                    if let k = job.midiWorking {
                        Label("Note di \(Stem.info(k).name.lowercased())…", systemImage: "pianokeys")
                    } else {
                        Label("MIDI", systemImage: "pianokeys")
                    }
                }
                .fixedSize()
                .disabled(job.midiWorking != nil || job.midiStems.isEmpty)
                .help(job.midiError.map { "Non riuscito: \($0)" } ?? "Le note di una traccia in un file MIDI, da trascinare in GarageBand o Logic")
                Button {
                    if let f = job.folder { NSWorkspace.shared.activateFileViewerSelecting([f]) }
                } label: { Label("Mostra nel Finder", systemImage: "folder") }
                Button {
                    player.stop()
                    mixer.stop()
                    job.reset()
                } label: { Label("Un'altra canzone", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
            }
            transport
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(MixPlayer.mixable(job.stems)) { stem in
                        MixerRow(stem: stem, mixer: mixer)
                    }
                    splitRows
                    let mixed = Set(MixPlayer.mixable(job.stems).map(\.key))
                    let others = job.stems.filter { !mixed.contains($0.key) }
                    if !others.isEmpty {
                        Divider().padding(.vertical, 4)
                        ForEach(others) { StemRow(stem: $0, player: player) }
                    }
                }
                .padding(.bottom, 4)
            }
            FlowLayout(spacing: 6, lineSpacing: 6, centered: false) {
                Chip(text: job.quality.title, symbol: job.quality.symbol, tint: Theme.brass)
                if let e = job.engineText { Chip(text: e, symbol: "cpu", tint: Theme.green) }
                if let t = job.elapsed { Chip(text: "in " + formatTime(t), symbol: "timer", tint: Color.secondary) }
                if let a = job.analysis {
                    Chip(text: a.bpmText, symbol: "metronome", tint: Theme.color("drums"))
                        .help("Tempo stimato dalla batteria · se ti sembra lento, può essere \(Int((a.bpm * 2).rounded())) BPM")
                    Chip(text: a.keyName, symbol: "music.note", tint: Theme.color("piano"))
                        .help("Tonalità \(a.keyShort) · Camelot \(a.camelot)\(a.keyConfidence < 0.5 ? " · incerta: la canzone cambia tonalità o è poco tonale" : "")")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Trascina una traccia in GarageBand, Logic o nel Finder. Clic sull'onda per ascoltare da quel punto.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(22)
        .onAppear { mixer.load(job.stems, folder: job.folder) }
        .onChange(of: job.stems) { _, stems in mixer.load(stems, folder: job.folder) }
        .onDisappear { mixer.stop() }
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
                        .keyboardShortcut(kind == .drums ? "d" : "v", modifiers: [.command, .shift])
                        .help("\(kind == .drums ? "⇧⌘D" : "⇧⌘V") · la prima volta scarica il modello (\(kind.downloadSize))")
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

    /// Sala prove: velocità, tono, un passaggio da ripetere.
    private var practiceBar: some View {
        HStack(spacing: 14) {
            Label("Sala prove", systemImage: "music.note.house").font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.brass)
            HStack(spacing: 6) {
                Image(systemName: "tortoise").font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: $mixer.rate, in: 0.5...1.5, step: 0.05).frame(width: 120)
                    .accessibilityLabel("Velocità")
                Image(systemName: "hare").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("\(Int((mixer.rate * 100).rounded()))%").font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                    .frame(width: 38, alignment: .leading)
            }
            .help("Velocità senza cambiare il tono")
            Stepper(value: $mixer.semitones, in: -6...6) {
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
            Spacer()
            if mixer.rate != 1 || mixer.semitones != 0 || mixer.loopA != nil {
                Button("Normale") { mixer.resetPractice() }.controlSize(.small)
                    .help("Velocità e tono originali, niente ripetizione")
            }
        }
        .padding(.horizontal, 4)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var transportBar: some View {
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
                    .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                    .onAppear { mixer.tick() }
                    .task(id: Int(mixer.position * (mixer.isLooping ? 25 : 4))) { mixer.tick() }
            }
            Toggle(isOn: $showPractice) { Label("Prove", systemImage: "music.note.house") }
                .toggleStyle(.button).controlSize(.small)
                .help("Sala prove: velocità, tono e ripetizione di un passaggio (⌥⌘P)")
                .accessibilityLabel("Sala prove")
            Picker("Scorciatoie", selection: Binding(
                get: { mixer.state.preset?.rawValue ?? "" },
                set: { if let p = MixState.Preset(rawValue: $0) { mixer.state.apply(p) } })) {
                ForEach(MixState.Preset.allCases.filter { $0 != .backing || mixer.keys.contains("lead") }) { p in Text(p.title).tag(p.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: mixer.keys.contains("lead") ? 340 : 250)
            withoutMenu
            Spacer()
            Menu {
                Button("Esporta il mix (⌘E)") { exportMix() }
                Button("Esporta per DJ: .stem.mp4 (⌥⌘E)") { exportStemFile() }
            } label: {
                if mixer.exporting || makingStemFile { ProgressView().controlSize(.small) } else { Label("Esporta il mix", systemImage: "square.and.arrow.up") }
            } primaryAction: { exportMix() }
            .menuStyle(.button)
            .fixedSize()
            .disabled(mixer.exporting || makingStemFile || job.folder == nil)
            .help("Salva quello che senti, con muto, solo e volumi, accanto alle tracce (velocità e tono della Sala prove restano quelli originali)")
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
                    .font(.system(size: 16, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                if job.duration > 0 {
                    Text(formatTime(job.duration)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }

    private var footer: some View {
        Text("Le canzoni non lasciano mai il tuo Mac · Le tracce vanno in \(Prefs.displayName(of: Prefs.folder))")
            .font(.system(size: 11)).foregroundStyle(.tertiary)
    }

    // MARK: Testi

    /// Onda finta e bassa, mentre la canzone non è ancora letta.
    static let placeholderPeaks: [Float] = (0..<200).map { Float(0.05 + 0.04 * sin(Double($0) * 0.3)) }

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
        case .downloading: return "Scarico il modello di IA"
        case .reading: return "Leggo la canzone"
        case .tuning: return "Provo il motore del tuo Mac"
        case .separating: return job.quality == .fast ? "Separo voce e strumenti" : "Separo voce e strumenti · \(job.quality.title)"
        case .saving: return "Salvo le tracce"
        default: return ""
        }
    }

    private var detailText: String {
        switch job.phase {
        case .downloading: return "Solo la prima volta, \(job.quality.downloadSize). Poi funziona anche senza internet."
        case .tuning: return "Solo la prima volta: confronto Neural Engine e grafica per scegliere il più preciso"
        case .separating: return job.remaining.map(Self.timeLeft) ?? "Calcolo il tempo che manca…"
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
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(available.isEmpty)
        .help("Togli la tua parte e suonaci sopra (⇧⌘K: l'ultimo strumento scelto)")
        .accessibilityLabel("Senza il mio strumento")
    }

    /// Il file per Traktor e Mixxx: canzone intera più batteria, basso, altri strumenti e voce.
    private func exportStemFile() {
        guard job.phase == .done, !makingStemFile, let f = job.folder else { return }
        let song = job.song
        makingStemFile = true
        let stems = job.stems, title = job.title
        Task {
            defer { makingStemFile = false }
            do {
                let url = try await StemFile.make(stems: stems, song: song, folder: f, title: title)
                exported = url
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                stemFileError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func exportMix() {
        guard job.phase == .done, !mixer.exporting, let f = job.folder else { return }
        Task {
            if let url = try? await mixer.export(stems: job.stems, folder: f, title: job.title) {
                exported = url
                NSWorkspace.shared.activateFileViewerSelecting([url])
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
            job.enqueue(panel.urls, quality: quality)
        }
    }
}

// MARK: - Una traccia

struct StemRow: View {
    let stem: Stem
    @ObservedObject var player: StemPlayer
    @State private var hover = false

    var body: some View {
        let playing = player.current == stem.url
        HStack(spacing: 12) {
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
            Button { NSWorkspace.shared.activateFileViewerSelecting([stem.url]) } label: {
                Image(systemName: "folder").font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .help("Mostra il file nel Finder")
            .accessibilityLabel("Mostra \(stem.name) nel Finder")
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
                    Text("AudioLR è aggiornata").font(.system(size: 18, weight: .bold, design: .rounded))
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

    var body: some View {
        let muted = mixer.state.muted.contains(stem.key)
        let solo = mixer.state.solo.contains(stem.key)
        let audible = mixer.state.effectiveGain(stem.key) > 0
        HStack(spacing: 10) {
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
            toggle("M", on: muted, tint: Theme.voiceMute, help: muted ? "Riattiva" : "Muto") {
                if muted { mixer.state.muted.remove(stem.key) } else { mixer.state.muted.insert(stem.key) }
            }
            toggle("S", on: solo, tint: Theme.brass, help: solo ? "Togli solo" : "Solo") {
                if solo { mixer.state.solo.remove(stem.key) } else { mixer.state.solo.insert(stem.key) }
            }
            Slider(value: Binding(get: { mixer.state.gain[stem.key] ?? 1 }, set: { mixer.state.gain[stem.key] = $0 }), in: 0...1.5)
                .frame(width: 90)
                .tint(Theme.color(stem.key))
                .help("Volume")
                .accessibilityLabel("Volume \(stem.name)")
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
            Button { NSWorkspace.shared.activateFileViewerSelecting([stem.url]) } label: {
                Image(systemName: "folder").font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("Mostra il file nel Finder")
            .accessibilityLabel("Mostra \(stem.name) nel Finder")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(solo ? Theme.color(stem.key).opacity(0.10) : Theme.well.opacity(0.6)))
        .onDrag { NSItemProvider(contentsOf: stem.url) ?? NSItemProvider() }
    }

    private func toggle(_ label: String, on: Bool, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 11, weight: .bold, design: .rounded))
                .frame(width: 22, height: 22)
                .foregroundStyle(on ? .white : Color.secondary)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? tint : Theme.ink.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("\(help) \(stem.name)")
    }
}
