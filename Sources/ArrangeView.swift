import SwiftUI
import AppKit
import UniformTypeIdentifiers

// ════════════════════════════════════════════════════════════════════
//  L'editor Rimonta («taglia e sposta»): la canzone in blocchi, uno per
//  parte. Si divide un blocco sulla battuta, si trascina per cambiare
//  l'ordine, si duplica o si toglie; si ascolta; poi «Crea versione».
// ════════════════════════════════════════════════════════════════════

struct ArrangeView: View {
    @EnvironmentObject private var job: SeparationJob
    @ObservedObject var mixer: MixPlayer
    var onClose: () -> Void

    @StateObject private var preview = PreviewPlayer()
    @State private var mix: [[Float]] = []
    @State private var arr = Arrangement(blocks: [])
    @State private var original = Arrangement(blocks: [])
    @State private var undo: [Arrangement] = []
    @State private var selected: UUID?
    /// Dove tagliare dentro il blocco scelto (secondi dal suo inizio), dall'ultimo clic.
    @State private var cutAt: Double?
    @State private var working: Double?
    @State private var error: String?
    /// La canzone rimontata dell'ultimo ascolto (per la testina).
    @State private var played: Arrangement?

    private var index: Int? { arr.blocks.firstIndex { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            toolbar
            strip
            detail
            Divider()
            footer
        }
        .padding(22)
        .frame(minWidth: 860, idealWidth: 960, minHeight: 470, idealHeight: 520)
        .background(Theme.background)
        .task { await load() }
        .onDisappear { preview.stop() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "scissors").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.color("guitar").gradient))
            VStack(alignment: .leading, spacing: 1) {
                Text("Rimonta · \(job.title)").font(.system(size: 18, weight: .bold, design: .rounded)).lineLimit(1)
                Text("Trascina le parti per cambiare l'ordine. Dividi, duplica o togli quella scelta; poi ascolta e crea la versione nuova.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                if preview.isPlaying { preview.stop() } else { listen() }
            } label: {
                Label(preview.isPlaying ? "Ferma" : "Ascolta", systemImage: preview.isPlaying ? "stop.fill" : "play.fill")
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(mix.isEmpty)
            .help("La canzone rimontata, dalla parte scelta (spazio)")
            Divider().frame(height: 18)
            Button { if let i = index { let at = cutAt ?? arr.blocks[i].length / 2; change { $0.split(i, at: at) } } } label: { Label("Dividi", systemImage: "scissors") }
                .keyboardShortcut("b")
                .disabled(index == nil)
                .help("Divide la parte scelta sulla battuta più vicina al punto cliccato (⌘B)")
            Button { if let i = index { change { $0.duplicate(i) } } } label: { Label("Duplica", systemImage: "plus.square.on.square") }
                .keyboardShortcut("d")
                .disabled(index == nil)
                .help("Una copia della parte scelta, subito dopo (⌘D)")
            Button { if let i = index { change { $0.remove(i) } }; selected = nil } label: { Label("Togli", systemImage: "trash") }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(index == nil || arr.blocks.count < 2)
                .help("Toglie la parte scelta (⌫)")
            Button { if let i = index { change { $0.move(i, to: i - 1) } } } label: { Image(systemName: "arrow.left") }
                .disabled((index ?? 0) == 0)
                .help("Sposta prima")
                .accessibilityLabel("Sposta prima")
            Button { if let i = index { change { $0.move(i, to: i + 1) } } } label: { Image(systemName: "arrow.right") }
                .disabled(index == nil || index! >= arr.blocks.count - 1)
                .help("Sposta dopo")
                .accessibilityLabel("Sposta dopo")
            Spacer()
            Text("\(arr.blocks.count) parti · \(formatTime(arr.duration))\(arr.isOriginal ? "" : " (era \(formatTime(original.duration)))")")
                .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
            Button { if let last = undo.popLast() { arr = last } } label: { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z")
                .disabled(undo.isEmpty)
                .help("Annulla (⌘Z)")
                .accessibilityLabel("Annulla")
            Button("Ripristina") { let o = original; change { $0 = o }; selected = nil }
                .disabled(arr == original)
                .help("Torna all'ordine della canzone")
        }
        .labelStyle(.titleAndIcon)
    }

    /// I blocchi in proporzione alla durata, colorati per gruppo; si trascinano uno sull'altro per cambiare l'ordine.
    private var strip: some View {
        GeometryReader { geo in
            let total = max(arr.duration, original.duration, 0.001)
            let w = geo.size.width
            ZStack(alignment: .leading) {
                HStack(spacing: 2) {
                    ForEach(Array(arr.blocks.enumerated()), id: \.element.id) { i, b in
                        block(b, index: i, width: max(26, w * CGFloat(b.length / total) - 2))
                    }
                }
                TimelineView(.periodic(from: .now, by: 0.05)) { _ in
                    if preview.isPlaying {
                        Rectangle().fill(Theme.ink.opacity(0.85)).frame(width: 2, height: 64)
                            .offset(x: w * CGFloat(preview.position / total) - 1)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(height: 64)
    }

    private func color(_ group: Int) -> Color {
        Theme.color(["vocals", "drums", "bass", "guitar", "piano", "other"][((group % 6) + 6) % 6])
    }

    private func block(_ b: ArrangeBlock, index i: Int, width: CGFloat) -> some View {
        let on = b.id == selected
        return VStack(alignment: .leading, spacing: 2) {
            Text(b.label).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
            Text(formatTime(b.length)).font(.system(size: 10)).monospacedDigit().opacity(0.75).lineLimit(1)
        }
        .foregroundStyle(on ? Color.white : Theme.ink)
        .padding(.horizontal, 6)
        .frame(width: width, height: 60, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(on ? AnyShapeStyle(color(b.group).gradient) : AnyShapeStyle(color(b.group).opacity(0.28))))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(on ? Theme.ink.opacity(0.5) : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture { selected = b.id; cutAt = nil }
        .draggable(b.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first, let from = arr.blocks.firstIndex(where: { $0.id.uuidString == s }), from != i else { return false }
            change { $0.move(from, to: i) }
            selected = arr.blocks[min(i, arr.blocks.count - 1)].id
            return true
        }
        .help("«\(b.label)» · \(formatTime(b.srcStart))–\(formatTime(b.srcEnd)) dell'originale · trascinala su un'altra parte per metterla al suo posto")
        .accessibilityLabel("\(b.label), \(formatTime(b.length))\(on ? ", scelta" : "")")
    }

    /// La parte scelta, grande: un clic segna dove dividerla.
    @ViewBuilder private var detail: some View {
        if let i = index {
            let b = arr.blocks[i]
            VStack(alignment: .leading, spacing: 6) {
                Text("«\(b.label)» · clic sul punto dove dividerla (si aggancia alla battuta più vicina)")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.well)
                        WaveformView(peaks: slicePeaks(b), color: color(b.group).opacity(0.85))
                            .padding(.vertical, 8)
                        ForEach(barsInside(b), id: \.self) { t in
                            Rectangle().fill(Theme.ink.opacity(0.18)).frame(width: 1)
                                .offset(x: g.size.width * CGFloat((t - b.srcStart) / max(0.001, b.length)))
                        }
                        if let c = cutAt {
                            Rectangle().fill(Theme.voiceMute).frame(width: 2)
                                .offset(x: g.size.width * CGFloat(c / max(0.001, b.length)) - 1)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { p in cutAt = Double(p.x / max(1, g.size.width)) * b.length }
                }
            }
            .frame(maxHeight: .infinity)
        } else {
            Text(mix.isEmpty ? "Preparo la canzone…" : "Scegli una parte per dividerla, duplicarla o toglierla; trascinala per spostarla.")
                .font(.system(size: 12)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func barsInside(_ b: ArrangeBlock) -> [Double] { arr.downbeats.filter { $0 > b.srcStart && $0 < b.srcEnd } }

    private func slicePeaks(_ b: ArrangeBlock) -> [Float] {
        guard let n = mix.first?.count, n > 0 else { return [] }
        let a = max(0, min(n, Int(b.srcStart * AudioIO.sampleRate))), e = max(a, min(n, Int(b.srcEnd * AudioIO.sampleRate)))
        guard e > a else { return [] }
        return Peaks.of(mix.map { Array($0[a..<e]) }, count: 240)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let w = working {
                ProgressView(value: w).frame(width: 140)
                Text("Rimonto le tracce… \(Int(w * 100))%").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            } else if let e = error {
                Text("Non riuscito: \(e)").font(.system(size: 12)).foregroundStyle(Theme.voiceMute).lineLimit(2)
            } else {
                Text("Tutte le tracce si rimontano nello stesso modo, con una dissolvenza di 10 ms a ogni giunzione. L'originale resta com'è.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Chiudi") { onClose() }.keyboardShortcut(.cancelAction)
            Button("Crea versione") { makeVersion() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(mix.isEmpty || working != nil || arr.isOriginal)
                .help("Una canzone nuova in libreria, «\(job.title) (rimontata)», con tutte le tracce in quest'ordine")
        }
    }

    // MARK: Azioni

    private func change(_ f: (inout Arrangement) -> Void) {
        undo.append(arr)
        if undo.count > 50 { undo.removeFirst() }
        f(&arr)
        cutAt = nil
        if preview.isPlaying { preview.stop() }
    }

    private func load() async {
        let stems = job.stems, state = mixer.state
        let audio = await Task.detached(priority: .userInitiated) { EditAudio.mix(stems, state: state) }.value
        mix = audio
        let d = Double(audio.first?.count ?? 0) / AudioIO.sampleRate
        arr = Arrangement.from(job.analysis?.structure, duration: d)
        original = arr
        undo = []
    }

    private func listen() {
        let from = index.map { arr.start(of: $0) } ?? 0
        let a = arr
        played = a
        preview.play(a.render(mix), from: from, seconds: 600)
    }

    private func makeVersion() {
        guard let folder = job.folder else { return }
        preview.stop()
        let a = arr, stems = job.stems
        let title = "\(job.title) (rimontata)", root = folder.deletingLastPathComponent(), format = Prefs.format
        let analysis = job.analysis.map { a.analysis($0) }
        working = 0
        error = nil
        Task {
            do {
                let (dir, seconds) = try await Task.detached(priority: .userInitiated) {
                    try EditAudio.writeVersion(stems, title: title, into: root, format: format,
                                               progress: { p in Task { @MainActor in working = p } },
                                               transform: { a.render($0) })
                }.value
                working = nil
                onClose()
                job.addVersion(folder: dir, duration: seconds, analysis: analysis)
            } catch {
                AppLog.write("Rimonta non riuscita: \(error.localizedDescription)")
                working = nil
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
