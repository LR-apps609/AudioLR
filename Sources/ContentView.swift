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
}

struct ContentView: View {
    @EnvironmentObject private var job: SeparationJob
    @StateObject private var player = StemPlayer()
    @State private var dropping = false
    @State private var news: [String] = []
    @AppStorage(Quality.key) private var qualityRaw = Quality.best.rawValue
    private var quality: Quality { Quality(rawValue: qualityRaw) ?? .best }

    var body: some View {
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
        .sheet(isPresented: Binding(get: { !news.isEmpty }, set: { if !$0 { news = [] } })) {
            WhatsNewSheet(items: news) { news = [] }
        }
    }

    // MARK: Testata

    private var header: some View {
        HStack(spacing: 12) {
            LogoMark(size: 38, animated: job.isBusy)
            VStack(alignment: .leading, spacing: 1) {
                Text("AudioLR").font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Separa voce e strumenti di qualsiasi canzone").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Chip(text: "Tutto sul tuo Mac", symbol: "lock.fill", tint: Theme.green)
                .help("La canzone non viene caricata su internet")
        }
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
                .frame(width: 280)
                Text(quality.detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
            Spacer(minLength: 0)
            if job.history.isEmpty {
                VStack(spacing: 8) {
                    Text("RICEVERAI").font(.system(size: 10, weight: .bold)).tracking(1.2).foregroundStyle(.tertiary)
                    HStack(spacing: 8) {
                        ForEach(Theme.stemOrder + ["instrumental"], id: \.self) { key in
                            let info = Stem.info(key)
                            Chip(text: info.name, symbol: info.symbol, tint: Theme.color(key))
                        }
                    }
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
                ForEach(Theme.stemOrder, id: \.self) { key in
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                songTitle
                Spacer()
                Button {
                    if let f = job.folder { NSWorkspace.shared.activateFileViewerSelecting([f]) }
                } label: { Label("Mostra nel Finder", systemImage: "folder") }
                Button {
                    player.stop()
                    job.reset()
                } label: { Label("Un'altra canzone", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(job.stems) { stem in StemRow(stem: stem, player: player) }
                }
                .padding(.bottom, 4)
            }
            HStack(spacing: 6) {
                Chip(text: job.quality.title, symbol: job.quality == .best ? "sparkles" : "hare.fill", tint: Theme.brass)
                if let e = job.engineText { Chip(text: e, symbol: "cpu", tint: Theme.green) }
                if let t = job.elapsed { Chip(text: "in " + formatTime(t), symbol: "timer", tint: Color.secondary) }
                Spacer()
            }
            Text("Trascina una traccia in GarageBand, Logic o nel Finder. Clic sull'onda per ascoltare da quel punto.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(22)
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
        case .separating: return job.quality == .best ? "Separo voce e strumenti · Massima qualità" : "Separo voce e strumenti"
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

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.message = "Scegli una o più canzoni da separare"
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
