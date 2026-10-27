import SwiftUI
import AppKit

// ════════════════════════════════════════════════════════════════════
//  L'editor Warp: la forma d'onda del mix con un segnaposto sul primo
//  battito di ogni battuta. Si trascinano dove IsoLR ha sbagliato, si
//  ascoltano con il clic, poi «Salva la griglia» oppure «Metti a tempo».
// ════════════════════════════════════════════════════════════════════

struct WarpView: View {
    @EnvironmentObject private var job: SeparationJob
    @ObservedObject var mixer: MixPlayer
    var onClose: () -> Void

    @StateObject private var preview = PreviewPlayer()
    @State private var mix: [[Float]] = []
    @State private var peaks: [Float] = []
    @State private var duration = 0.0
    @State private var marks: [Double] = []
    @State private var original: [Double] = []
    @State private var selected: Int?
    /// Punti per secondo: 0 = tutta la canzone nella finestra.
    @State private var zoom: CGFloat = 0
    @State private var bpm = 120
    @State private var working: Double?
    @State private var error: String?
    @State private var saved = false
    @State private var dragStart: Double?

    private var beatsPerBar: Int { job.analysis?.structure?.beatsPerBar ?? 4 }
    private var gridBPM: Double? { Warp.bpm(downbeats: marks, beatsPerBar: beatsPerBar) }
    private var map: WarpMap {
        WarpMap.toTempo(downbeats: marks, beatsPerBar: beatsPerBar, bpm: Double(bpm), natural: gridBPM ?? job.analysis?.bpm ?? Double(bpm))
    }
    /// Oltre 4 volte più lenta o più veloce la voce suona finta: si avvisa.
    private var tooFar: Bool { marks.count >= 2 && map.extremeRate > 4 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            toolbar
            wave
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
            Image(systemName: "metronome.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.brass.gradient))
            VStack(alignment: .leading, spacing: 1) {
                Text("Warp · \(job.title)").font(.system(size: 18, weight: .bold, design: .rounded)).lineLimit(1)
                Text("Un segnaposto sul primo battito di ogni battuta: trascinalo dove serve. Doppio clic aggiunge, ⌫ toglie quello scelto.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                if preview.isPlaying { preview.stop() } else { listen() }
            } label: {
                Label(preview.isPlaying ? "Ferma" : "Ascolta con il clic", systemImage: preview.isPlaying ? "stop.fill" : "play.fill")
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(mix.isEmpty)
            .help("Il mix con un clic su ogni battito della griglia, dal segnaposto scelto (spazio)")
            Divider().frame(height: 18)
            Button { setZoom(currentPPS / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-")
                .help("Riduci (⌘−)")
                .accessibilityLabel("Riduci")
            Button { setZoom(currentPPS * 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("+")
                .help("Ingrandisci (⌘+)")
                .accessibilityLabel("Ingrandisci")
            Button("Tutta") { zoom = 0 }.help("Tutta la canzone nella finestra")
            Spacer()
            Text(gridBPM.map { String(format: "Griglia: %.1f BPM · %d battute", $0, max(0, marks.count - 1)) } ?? "Servono almeno due segnaposto")
                .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
            Button("Ripristina") { marks = original; selected = nil }
                .disabled(marks == original)
                .help("Torna alla griglia trovata da IsoLR")
            // ⌫ toglie il segnaposto scelto
            Button("") { removeSelected() }
                .keyboardShortcut(.delete, modifiers: [])
                .frame(width: 0, height: 0).opacity(0)
                .accessibilityHidden(true)
        }
        .controlSize(.regular)
    }

    /// Punti per secondo adesso (con «tutta», quelli che fanno stare la canzone nella finestra).
    @State private var fitPPS: CGFloat = 4
    private var currentPPS: CGFloat { zoom > 0 ? zoom : fitPPS }
    private func setZoom(_ v: CGFloat) { zoom = max(fitPPS, min(240, v)) }

    private var wave: some View {
        GeometryReader { geo in
            let fit = duration > 0 ? max(1, (geo.size.width - 2) / CGFloat(duration)) : 4
            let pps = zoom > 0 ? zoom : fit
            let width = max(geo.size.width - 2, CGFloat(duration) * pps)
            ScrollView(.horizontal, showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.well)
                    if peaks.isEmpty {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        WaveformView(peaks: peaks, color: Theme.color("drums").opacity(0.75), barWidth: 2, spacing: 1)
                            .padding(.top, 30).padding(.bottom, 8)
                    }
                    // Doppio clic su un punto vuoto: un segnaposto nuovo
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture(count: 2, coordinateSpace: .local) { p in add(at: Double(p.x / pps)) }
                        .onTapGesture { selected = nil }
                    ForEach(Array(marks.enumerated()), id: \.offset) { i, t in
                        marker(i, t, pps: pps, height: geo.size.height - 16)
                    }
                    TimelineView(.periodic(from: .now, by: 0.05)) { _ in
                        if preview.isPlaying {
                            Rectangle().fill(Theme.ink.opacity(0.85)).frame(width: 2)
                                .offset(x: CGFloat(preview.position) * pps - 1)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .frame(width: width, height: geo.size.height - 16)
            }
            .gesture(MagnificationGesture().onEnded { s in setZoom(pps * s) })
            .onAppear { fitPPS = fit }
            .onChange(of: geo.size.width) { _, _ in fitPPS = fit }
            .onChange(of: duration) { _, _ in fitPPS = fit }
        }
        .frame(minHeight: 220)
    }

    /// Il segnaposto `i`: linea, maniglia con il numero della battuta, trascinabile tra i vicini.
    private func marker(_ i: Int, _ t: Double, pps: CGFloat, height: CGFloat) -> some View {
        let on = selected == i
        return VStack(spacing: 0) {
            Text("\(i + 1)")
                .font(.system(size: 10, weight: .bold)).monospacedDigit()
                .foregroundStyle(on ? Color.white : Theme.ink)
                .padding(.horizontal, 5).frame(minWidth: 20, minHeight: 18)
                .background(Capsule().fill(on ? AnyShapeStyle(Theme.brass.gradient) : AnyShapeStyle(Theme.card)))
                .overlay(Capsule().strokeBorder(Theme.brass.opacity(0.7), lineWidth: 1))
            Rectangle().fill(on ? Theme.brass : Theme.brass.opacity(0.55)).frame(width: on ? 2 : 1)
        }
        .frame(height: height)
        .contentShape(Rectangle().inset(by: -4))
        .offset(x: CGFloat(t) * pps - 10)
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { v in
                if dragStart == nil { dragStart = t; selected = i }
                let lo = i > 0 ? marks[i - 1] + 0.1 : 0
                let hi = i + 1 < marks.count ? marks[i + 1] - 0.1 : duration
                marks[i] = max(lo, min(hi, (dragStart ?? t) + Double(v.translation.width / pps)))
            }
            .onEnded { _ in dragStart = nil })
        .onTapGesture { selected = i }
        .help("Battuta \(i + 1) · \(formatTime(t)) — trascina per spostarla")
        .accessibilityLabel("Segnaposto della battuta \(i + 1), a \(formatTime(t))")
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            Button("Salva la griglia") { saveGrid() }
                .disabled(marks.count < 2 || job.analysis?.structure == nil)
                .help("Metronomo, parti della canzone e passaggio A–B seguiranno questa griglia")
            if saved { Label("Salvata", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.green).font(.system(size: 12)) }
            Spacer()
            if let w = working {
                ProgressView(value: w).frame(width: 140)
                Text("Metto a tempo… \(Int(w * 100))%").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            } else if let e = error {
                Text("Non riuscito: \(e)").font(.system(size: 12)).foregroundStyle(Theme.voiceMute).lineLimit(2)
            } else if tooFar {
                Text("Alcune battute andrebbero stirate più di 4 volte: controlla i segnaposto")
                    .font(.system(size: 12)).foregroundStyle(Theme.voiceMute).lineLimit(2)
            }
            Text("Metti a tempo").font(.system(size: 12.5, weight: .semibold))
            Stepper(value: $bpm, in: 40...240) {
                TextField("BPM", value: $bpm, format: .number).frame(width: 46).multilineTextAlignment(.trailing)
            }
            Text("BPM").font(.system(size: 12)).foregroundStyle(.secondary)
            Button("Chiudi") { onClose() }.keyboardShortcut(.cancelAction)
            Button("Crea versione a tempo") { makeVersion() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(mix.isEmpty || working != nil || tooFar)
                .help("Una canzone nuova in libreria, «\(job.title) (\(bpm) BPM)»: ogni battuta dura uguale, il tono non cambia. L'originale resta com'è.")
        }
        .controlSize(.regular)
    }

    // MARK: Azioni

    private func load() async {
        let stems = job.stems, state = mixer.state
        let a = job.analysis
        bpm = Int((a?.bpm ?? 120).rounded())
        let audio = await Task.detached(priority: .userInitiated) { EditAudio.mix(stems, state: state) }.value
        let p = await Task.detached(priority: .userInitiated) { EditAudio.peaks(audio) }.value
        mix = audio
        peaks = p
        duration = Double(audio.first?.count ?? 0) / AudioIO.sampleRate
        if let s = a?.structure, s.downbeats.count >= 2 {
            marks = s.downbeats.filter { $0 <= duration }
        } else if let b = a?.bpm, b > 0, duration > 0 {
            // Senza griglia: una battuta ogni 4 battiti dal tempo stimato, da sistemare a mano
            marks = stride(from: 0.0, to: duration, by: 240 / b).map { $0 }
        }
        original = marks
    }

    private func add(at t: Double) {
        guard t > 0, t < duration else { return }
        if marks.contains(where: { abs($0 - t) < 0.15 }) { return }
        marks.append(t)
        marks.sort()
        selected = marks.firstIndex(of: t)
        saved = false
    }

    private func removeSelected() {
        guard let i = selected, marks.indices.contains(i) else { return }
        marks.remove(at: i)
        selected = nil
        saved = false
    }

    private func listen() {
        let from = selected.map { marks[$0] } ?? 0
        let grid = Warp.beats(downbeats: marks, beatsPerBar: beatsPerBar, duration: duration)
        let clicks = grid.beats.enumerated().map { (time: $0.element, strong: ($0.offset - grid.firstDownbeat) % beatsPerBar == 0 && $0.offset >= grid.firstDownbeat) }
        preview.play(mix, from: max(0, from - 0.5), clicks: clicks)
    }

    private func saveGrid() {
        guard let old = job.analysis?.structure, marks.count >= 2 else { return }
        job.saveGrid(Warp.structure(downbeats: marks, old: old, duration: duration))
        original = marks
        saved = true
    }

    private func makeVersion() {
        guard let folder = job.folder else { return }
        preview.stop()
        let m = map, stems = job.stems, target = Double(bpm), length = duration
        let title = "\(job.title) (\(bpm) BPM)", root = folder.deletingLastPathComponent(), format = Prefs.format
        // La griglia corretta vale anche per l'analisi della versione nuova
        var a = job.analysis
        if let s = a?.structure, marks.count >= 2 { a?.structure = Warp.structure(downbeats: marks, old: s, duration: length) }
        let analysis = a.map { Warp.analysis($0, map: m, bpm: target, duration: length) }
        working = 0
        error = nil
        Task {
            do {
                let (dir, seconds) = try await Task.detached(priority: .userInitiated) {
                    try EditAudio.writeVersion(stems, title: title, into: root, format: format,
                                               progress: { p in Task { @MainActor in working = p } },
                                               transform: { try Warp.render($0, map: m) })
                }.value
                working = nil
                onClose()
                job.addVersion(folder: dir, duration: seconds, analysis: analysis)
            } catch {
                AppLog.write("Metti a tempo non riuscito: \(error.localizedDescription)")
                working = nil
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
