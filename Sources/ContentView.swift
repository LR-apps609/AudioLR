import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// ════════════════════════════════════════════════════════════════════
//  La finestra: trascini una canzone, aspetti, ascolti le tracce separate.
// ════════════════════════════════════════════════════════════════════

struct ContentView: View {
    @EnvironmentObject private var job: SeparationJob
    @StateObject private var player = StemPlayer()
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 18) {
            header
            Group {
                switch job.phase {
                case .idle: dropZone
                case .downloading, .reading, .separating, .saving: working
                case .done: results
                case .failed(let msg): failed(msg)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .card(radius: 18)
            footer
        }
        .padding(24)
        .background(Theme.background.ignoresSafeArea())
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, !job.isBusy else { return false }
            player.stop()
            job.start(url)
            return true
        } isTargeted: { dropping = $0 }
    }

    // MARK: Parti

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("AudioLR").font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(Theme.ink)
            Text("Separa voce e strumenti, tutto sul tuo Mac").font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 54, weight: .regular))
                .foregroundStyle(dropping ? Theme.brass : Theme.accent)
            Text("Trascina qui una canzone").font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(Theme.ink)
            Text("MP3, M4A, WAV, AIFF, FLAC").font(.system(size: 12)).foregroundStyle(.secondary)
            Button("Scegli una canzone…") { choose() }
                .controlSize(.large)
                .keyboardShortcut("o")
                .padding(.top, 4)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(dropping ? Theme.brass : Theme.stroke)
                .padding(14)
        )
    }

    private var working: some View {
        VStack(spacing: 16) {
            songTitle
            ProgressView(value: progressValue).progressViewStyle(.linear).tint(Theme.accent).frame(maxWidth: 420)
            Text(stepText).font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
            if case .downloading = job.phase {
                Text("Solo la prima volta: circa 80 MB. Poi AudioLR funziona anche senza internet.")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
            Button("Annulla") { job.cancel() }.padding(.top, 6)
        }
        .padding(30)
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                songTitle
                Spacer()
                Button {
                    if let f = job.folder { NSWorkspace.shared.activateFileViewerSelecting([f]) }
                } label: { Label("Mostra nel Finder", systemImage: "folder") }
                Button {
                    player.stop()
                    job.reset()
                } label: { Label("Un'altra canzone", systemImage: "plus") }
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(job.stems) { stem in stemRow(stem) }
                }
            }
        }
        .padding(22)
    }

    private func stemRow(_ stem: Stem) -> some View {
        let playing = player.current == stem.url
        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.color(stem.key).gradient)
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: stem.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white))
            Text(stem.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
            Spacer()
            Button {
                player.toggle(stem.url)
            } label: {
                Image(systemName: playing ? "stop.fill" : "play.fill").frame(width: 18)
            }
            .help(playing ? "Ferma" : "Ascolta")
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([stem.url])
            } label: { Image(systemName: "magnifyingglass") }
            .help("Mostra il file nel Finder")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(playing ? Theme.color(stem.key).opacity(0.14) : Color.clear))
        // Si può trascinare la traccia direttamente in un'altra app (GarageBand, Logic, Finder…)
        .onDrag { NSItemProvider(contentsOf: stem.url) ?? NSItemProvider() }
    }

    private func failed(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundStyle(Theme.brass)
            Text("Non ci sono riuscito").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(Self.sentence(msg)).font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                if let s = job.song { Button("Riprova") { job.start(s) } }
                Button("Scegli un'altra canzone…") { job.reset(); choose() }
            }
            .padding(.top, 4)
        }
        .padding(30)
    }

    private var songTitle: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note").foregroundStyle(Theme.accent)
            Text(job.song?.deletingPathExtension().lastPathComponent ?? "")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private var footer: some View {
        Text("Le canzoni non lasciano mai il tuo Mac. Le tracce finiscono in Musica › AudioLR.")
            .font(.system(size: 11)).foregroundStyle(.tertiary)
    }

    // MARK: Testi e azioni

    private var progressValue: Double {
        switch job.phase {
        case .downloading(let p): return p
        case .separating(let p): return p
        case .saving: return 1
        default: return 0
        }
    }

    private var stepText: String {
        switch job.phase {
        case .downloading(let p): return "Scarico il modello di IA… \(Int(p * 100))%"
        case .reading: return "Leggo la canzone…"
        case .separating(let p):
            var s = "Separo voce e strumenti… \(Int(p * 100))%"
            if let r = job.remaining { s += " · " + Self.timeLeft(r) }
            return s
        case .saving: return "Salvo le tracce…"
        default: return ""
        }
    }

    /// «il file è vuoto» → «Il file è vuoto.»
    static func sentence(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + String(s.dropFirst()) + "."
    }

    static func timeLeft(_ s: Double) -> String {
        if s < 10 { return "quasi fatto" }
        if s < 60 { return "circa \(Int((s / 5).rounded()) * 5) secondi" }
        let m = Int((s / 60).rounded())
        return m == 1 ? "circa 1 minuto" : "circa \(m) minuti"
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "Scegli la canzone da separare"
        if panel.runModal() == .OK, let url = panel.url {
            player.stop()
            job.start(url)
        }
    }
}

/// Ascolto di una traccia alla volta.
@MainActor
final class StemPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var current: URL?
    private var player: AVAudioPlayer?

    func toggle(_ url: URL) {
        if current == url { stop(); return }
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.delegate = self
        p.play()
        player = p
        current = url
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
