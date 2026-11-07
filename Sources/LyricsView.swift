import SwiftUI
import AppKit

// ════════════════════════════════════════════════════════════════════
//  «Testo»: le parole della voce a tempo con il mixer (⌥⌘L, «Vai più a
//  fondo» › «Testo»). Si trascrive una volta (Whisper, sul Mac), poi la riga
//  in corso si illumina e la parola cantata diventa d'oro; un clic su una
//  riga salta lì; la riga scelta si corregge a mano (testo e tempo).
//  Esporta .lrc e .srt; il video karaoke è in KaraokeVideo.swift.
// ════════════════════════════════════════════════════════════════════

struct LyricsView: View {
    @EnvironmentObject private var job: SeparationJob
    @ObservedObject var mixer: MixPlayer
    /// Testo già pronto (le schermate di prova); nil = salvato con la canzone o da trascrivere.
    var preloaded: Lyrics? = nil
    var onClose: () -> Void

    @State private var lyrics: Lyrics?
    @State private var selected: Int?
    @State private var editText = ""
    @State private var status = ""
    @State private var working = false
    @State private var progress: Double?
    /// Quando è cominciata la trascrizione e il lavoro, per il tempo che scorre e per «Annulla» (bug b-9: sui Mac
    /// Intel Whisper ci mette minuti e si vedeva solo una rotellina)
    @State private var started = Date()
    @State private var work: Task<Void, Never>?
    @State private var showVideo = false
    @AppStorage("lyricsLanguage") private var language = ""

    private var voice: Stem? { job.stems.first { $0.key == "vocals" } ?? job.stems.first { $0.key == "lead" } }
    private var lines: [LyricLine] { lyrics.map { Lyrics.lines($0.words) } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let lyr = lyrics, !lyr.words.isEmpty {
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    lyricList(lyr)
                }
                if let s = selected, s < lines.count { editor(lines[s]) }
            } else {
                empty
            }
            footer
        }
        .padding(22)
        .frame(minWidth: 760, idealWidth: 860, minHeight: 560, idealHeight: 640)
        .background(Theme.background)
        .onAppear(perform: load)
        .sheet(isPresented: $showVideo) {
            if let lyr = lyrics { KaraokeVideoSheet(lyrics: lyr) { showVideo = false }.environmentObject(job) }
        }
    }

    // MARK: Parti

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Testo").font(.system(size: 20, weight: .bold, design: .rounded))
                Text(job.title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Picker("Lingua", selection: $language) {
                ForEach(LyricsEngine.languages, id: \.name) { l in Text(l.name).tag(l.code ?? "") }
            }
            .frame(width: 190)
            .help("La lingua del testo: «Automatica» la riconosce da sola")
            Button { transcribe() } label: {
                Label(lyrics == nil ? "Trascrivi la voce" : "Rifai", systemImage: "waveform.and.mic")
            }
            .disabled(working || voice == nil)
            .help("Trascrive la voce separata con Whisper, tutto sul Mac (la prima volta scarica il modello, circa 500 MB)")
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "text.quote").font(.system(size: 34)).foregroundStyle(Theme.brass)
            if working {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(status + " · " + formatTime(Date().timeIntervalSince(started))).font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                }
                if let p = progress { ProgressView(value: p).frame(width: 260) } else { ProgressView().controlSize(.small) }
                Button("Annulla") { cancelTranscription() }
                    .keyboardShortcut(.cancelAction)
                    .help("Ferma la trascrizione: il testo che c'era resta com'era")
            } else {
                Text(voice == nil ? "Questa canzone non ha la traccia della voce." : "Il testo non c'è ancora.")
                    .font(.system(size: 14, weight: .semibold))
                Text(status.isEmpty ? "«Trascrivi la voce» ascolta la voce separata e scrive il testo, parola per parola, con i tempi."
                                    : status)
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func lyricList(_ lyr: Lyrics) -> some View {
        let ls = lines
        let now = Lyrics.current(ls, words: lyr.words, at: mixer.position)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(ls.indices, id: \.self) { i in
                        lineRow(ls[i], index: i, words: lyr.words, now: now)
                            .id(i)
                    }
                }
                .padding(.vertical, 8)
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.well))
            .onChange(of: now?.line) { _, l in
                if let l, mixer.isPlaying { withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(l, anchor: .center) } }
            }
        }
    }

    private func lineRow(_ line: LyricLine, index i: Int, words: [LyricWord], now: (line: Int, word: Int?)?) -> some View {
        let isNow = now?.line == i
        let past = (now?.line ?? -1) > i
        return Button {
            selected = i
            editText = line.text
            jump(to: line.start)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(timeLabel(line.start))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                    .frame(width: 44, alignment: .trailing)
                lineText(line, words: words, word: isNow ? now?.word : nil)
                    .font(.system(size: isNow ? 20 : 16, weight: isNow ? .bold : .medium, design: .rounded))
                    .foregroundStyle(past ? Color.secondary : Theme.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected == i ? Theme.brass.opacity(0.14) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Clic: ascolta da qui e correggi la riga")
    }

    /// La riga con la parola cantata in oro.
    private func lineText(_ line: LyricLine, words: [LyricWord], word: Int?) -> Text {
        var t = Text("")
        for i in line.words {
            let piece = Text(words[i].text.trimmingCharacters(in: .whitespaces) + " ")
            t = t + (i == word ? piece.foregroundColor(Theme.brass) : piece)
        }
        return t
    }

    private func editor(_ line: LyricLine) -> some View {
        HStack(spacing: 8) {
            TextField("Testo della riga", text: $editText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { apply(line) }
            Button("Applica") { apply(line) }.disabled(editText == line.text)
            Button { move(line, by: -0.1) } label: { Text("−0,1 s").monospacedDigit() }
                .help("La riga arriva prima")
            Button { move(line, by: 0.1) } label: { Text("+0,1 s").monospacedDigit() }
                .help("La riga arriva dopo")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { mixer.isPlaying ? mixer.pause() : mixer.play(from: mixer.position) } label: {
                Label(mixer.isPlaying ? "Pausa" : "Ascolta", systemImage: mixer.isPlaying ? "pause.fill" : "play.fill")
            }
            .keyboardShortcut(.space, modifiers: [])
            Text(status).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button("Esporta .lrc") { export("lrc") }.disabled(lines.isEmpty)
                .help("Il testo con i tempi delle righe, per i lettori musicali e i karaoke")
            Button("Esporta .srt") { export("srt") }.disabled(lines.isEmpty)
                .help("Il testo come sottotitoli, per i programmi video")
            Button("Video karaoke…") { mixer.pause(); showVideo = true }.disabled(lines.isEmpty)
                .help("Un video con la base e il testo che si illumina, per YouTube o Instagram")
            Button("Chiudi") { onClose() }.keyboardShortcut(.cancelAction)
        }
    }

    // MARK: Azioni

    private func load() {
        if let p = preloaded { lyrics = p; return }
        if let f = job.folder { lyrics = Lyrics.load(in: f) }
    }

    private func jump(to t: Double) {
        guard mixer.duration > 0 else { return }
        mixer.seek(to: t / mixer.duration)
    }

    private func save() {
        guard let lyr = lyrics, let f = job.folder, preloaded == nil else { return }
        do { try lyr.save(in: f) } catch { status = "Non riesco a salvare il testo: \(error.localizedDescription)" }
    }

    private func apply(_ line: LyricLine) {
        guard var lyr = lyrics else { return }
        lyr.words = Lyrics.rewrite(lyr.words, line: line, to: editText)
        lyr.edited = true
        lyrics = lyr
        save()
    }

    private func move(_ line: LyricLine, by dt: Double) {
        guard var lyr = lyrics else { return }
        lyr.words = Lyrics.shift(lyr.words, line: line, by: dt)
        lyr.edited = true
        lyrics = lyr
        save()
    }

    private func transcribe() {
        guard let v = voice else { return }
        working = true
        status = "Scarico il modello del testo (solo la prima volta)…"
        progress = 0
        let lang = language.isEmpty ? nil : language
        let folder = job.folder
        started = Date()
        work = Task {
            do {
                try await LyricsEngine.prepare { p in Task { @MainActor in progress = p } }
                await MainActor.run { progress = nil }
                let result = try await LyricsEngine.transcribe(voice: v.url, language: lang) { s in
                    Task { @MainActor in status = s }
                }
                if Task.isCancelled { return }
                await MainActor.run {
                    lyrics = result
                    working = false
                    status = result.words.isEmpty ? "Nessuna parola trovata nella voce" : "\(result.words.count) parole"
                    if let f = folder { try? result.save(in: f) }
                    AppLog.write("Testo: \(result.words.count) parole, lingua \(result.language ?? "?")")
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    working = false
                    progress = nil
                    status = "Non riuscito: \(error.localizedDescription)"
                    AppLog.write("Testo non riuscito: \(error.localizedDescription)")
                }
            }
        }
    }

    private func cancelTranscription() {
        work?.cancel()
        work = nil
        working = false
        progress = nil
        status = "Trascrizione annullata"
        AppLog.write("Testo: annullato dall'utente")
    }

    private func export(_ ext: String) {
        let text = ext == "lrc" ? Lyrics.lrc(lines, title: job.title) : Lyrics.srt(lines)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(job.title).\(ext)"
        if let f = job.folder { panel.directoryURL = f }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            status = "Salvato: \(url.lastPathComponent)"
        } catch {
            status = "Non riesco a salvare: \(error.localizedDescription)"
        }
    }

    private func timeLabel(_ s: Double) -> String {
        let t = Int(s.rounded(.down))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// In «Esercitati»: la riga del testo che si canta adesso e la prossima (solo se la canzone ha il testo).
struct LyricsStrip: View {
    @ObservedObject var mixer: MixPlayer
    let folder: URL?
    @State private var lyrics: Lyrics?

    var body: some View {
        Group {
            if let lyr = lyrics, !lyr.words.isEmpty {
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    let ls = Lyrics.lines(lyr.words)
                    let now = Lyrics.current(ls, words: lyr.words, at: mixer.position)
                    let next = (now?.line ?? ls.firstIndex { $0.start > mixer.position } ?? ls.count) + (now == nil ? 0 : 1)
                    VStack(spacing: 2) {
                        Text(now.map { ls[$0.line].text } ?? " ")
                            .font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(Theme.brass)
                        Text(next < ls.count ? ls[next].text : " ")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear { lyrics = folder.flatMap { Lyrics.load(in: $0) } }
        .onChange(of: folder) { _, f in lyrics = f.flatMap { Lyrics.load(in: $0) } }
    }
}
