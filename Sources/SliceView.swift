import SwiftUI
import AppKit
import AVFoundation

// ════════════════════════════════════════════════════════════════════
//  Slice to MIDI: una traccia (di serie la batteria) tagliata sui suoi
//  colpi. Le fette si vedono sulla forma d'onda (segnaposto da trascinare,
//  doppio clic divide, «Unisci» unisce), si suonano con 16 pad (clic, o i
//  tasti 1 2 3 4 / Q W E R / A S D F / Z X C V) e si esportano: fette WAV,
//  un file MIDI che le suona nel ritmo originale (nota 36 = fetta 1) e un
//  LEGGIMI per Ableton e Logic. Le regole sono in Slicer.swift.
// ════════════════════════════════════════════════════════════════════

/// Suona le fette: un lettore per la fetta, si interrompe se ne parte un'altra.
@MainActor
final class PadPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var ready = false
    private let format = AVAudioFormat(standardFormatWithSampleRate: AudioIO.sampleRate, channels: 2)!

    func play(_ audio: [[Float]]) {
        if !ready {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            ready = (try? engine.start()) != nil
        }
        guard ready, let n = audio.first?.count, n > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return }
        buf.frameLength = AVAudioFrameCount(n)
        for c in 0..<2 {
            let src = audio[min(c, audio.count - 1)]
            src.withUnsafeBufferPointer { buf.floatChannelData![c].update(from: $0.baseAddress!, count: n) }
        }
        node.stop()
        node.scheduleBuffer(buf, at: nil)
        node.play()
    }

    func stop() { node.stop(); if ready { engine.stop(); ready = false } }
}

struct SliceView: View {
    @EnvironmentObject private var job: SeparationJob
    @ObservedObject var mixer: MixPlayer
    /// La traccia di partenza (nil = la batteria, se c'è).
    var startKey: String? = nil
    /// Audio già pronto (le schermate di prova); nil = si legge la traccia.
    var preloaded: [[Float]]? = nil
    var onClose: () -> Void

    static let keys: [Character] = ["1", "2", "3", "4", "q", "w", "e", "r", "a", "s", "d", "f", "z", "x", "c", "v"]

    @State private var key = ""
    @State private var audio: [[Float]] = []
    @State private var peaks: [Float] = []
    @State private var slices: [AudioSlice] = []
    @State private var selected: Int?
    @State private var page = 0
    @State private var sensitivity = 0.5
    @State private var t0 = 0.0
    @State private var span = 20.0
    @State private var lit: [Int: Date] = [:]
    @State private var dragging: Int?
    @State private var status = ""
    @State private var working = false
    @State private var player = PadPlayer()

    private var stems: [Stem] {
        job.stems.filter { $0.key != "instrumental" }.sorted { ($0.key == "drums" ? 0 : 1) < ($1.key == "drums" ? 0 : 1) }
    }
    private var duration: Double { Double(audio.first?.count ?? 0) / AudioIO.sampleRate }
    private var rate: Double { AudioIO.sampleRate }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            toolbar
            wave
            Slider(value: Binding(get: { t0 }, set: { t0 = $0 }), in: 0...max(0.001, duration - span)).controlSize(.small)
                .accessibilityLabel("Scorri la traccia")
            pads
            Divider()
            footer
        }
        .padding(22)
        .frame(minWidth: 900, idealWidth: 1040, minHeight: 600, idealHeight: 660)
        .background(Theme.background)
        .onAppear { mixer.pause(); key = startKey.flatMap { k in stems.first { $0.key == k }?.key } ?? stems.first?.key ?? "" }
        .task(id: key) { await load() }
        .onDisappear { player.stop() }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            guard press.modifiers.isEmpty || press.modifiers == .shift else { return .ignored }
            if let c = press.characters.lowercased().first, let k = Self.keys.firstIndex(of: c) { play(page * 16 + k); return .handled }
            if press.key == .rightArrow, !slices.isEmpty { play(min(slices.count - 1, (selected ?? -1) + 1)); return .handled }
            if press.key == .leftArrow, !slices.isEmpty { play(max(0, (selected ?? 1) - 1)); return .handled }
            return .ignored
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.grid.4x3.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.color(key).gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text("Slice to MIDI").font(.system(size: 18, weight: .bold, design: .rounded))
                Text("La traccia tagliata sui suoi colpi. Trascina un segnaposto per spostarlo, doppio clic divide una fetta. Suona le fette con i pad o con i tasti 1–4, Q–R, A–F, Z–V.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Traccia", selection: $key) { ForEach(stems) { Text($0.name).tag($0.key) } }
                .labelsHidden().frame(width: 170)
            Text("Sensibilità").font(.system(size: 12)).foregroundStyle(.secondary)
            Slider(value: $sensitivity, in: 0...1).frame(width: 140)
                .onChange(of: sensitivity) { _, _ in detect() }
                .help("Più alta: più fette (anche i colpi deboli)")
            Spacer()
            Button("Unisci") { if let s = selected { slices = Slicer.merge(slices, s) } }
                .disabled(selected == nil || selected! >= slices.count - 1)
                .help("Unisce la fetta scelta con la successiva")
            Button { zoom(2) } label: { Image(systemName: "minus.magnifyingglass") }.help("Allontana")
            Button { zoom(0.5) } label: { Image(systemName: "plus.magnifyingglass") }.help("Avvicina")
        }
    }

    private var wave: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1 / 30, paused: lit.isEmpty)) { tl in
                SketchView { sz in sketch(sz, now: tl.date) }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.well))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { v in
                    if dragging == nil { dragging = near(v.startLocation.x, geo.size.width) }
                    if let d = dragging { slices = Slicer.move(slices, d, to: Int(time(v.location.x, geo.size.width) * rate), rate: rate); selected = d }
                }
                .onEnded { _ in dragging = nil })
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { v in
                let at = Int(time(v.location.x, geo.size.width) * rate)
                slices = Slicer.split(slices, at: at, rate: rate)
                selected = slices.firstIndex { at >= $0.start && at < $0.end }
            })
            .simultaneousGesture(SpatialTapGesture(count: 1).onEnded { v in
                let at = Int(time(v.location.x, geo.size.width) * rate)
                if let i = slices.firstIndex(where: { at >= $0.start && at < $0.end }) { play(i) }
            })
            .accessibilityLabel("Forma d'onda della traccia con le fette")
        }
        .frame(height: 220)
    }

    private func x(_ t: Double, _ w: CGFloat) -> CGFloat { CGFloat((t - t0) / max(0.001, span)) * w }
    private func time(_ x: CGFloat, _ w: CGFloat) -> Double { t0 + Double(x / max(1, w)) * span }

    private func near(_ px: CGFloat, _ w: CGFloat) -> Int? {
        var best: Int?, d: CGFloat = 7
        for (i, s) in slices.enumerated() where i > 0 {
            let dx = abs(x(Double(s.start) / rate, w) - px)
            if dx < d { d = dx; best = i }
        }
        return best
    }

    private func sketch(_ sz: CGSize, now: Date) -> Sketch {
        var k = Sketch()
        let w = sz.width, h = sz.height, color = Theme.color(key)
        for (i, s) in slices.enumerated() {
            let x0 = x(Double(s.start) / rate, w), x1 = x(Double(s.end) / rate, w)
            guard x1 >= 0, x0 <= w else { continue }
            k.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: h)), color.opacity(i == selected ? 0.22 : i % 2 == 1 ? 0.07 : 0.03))
        }
        // Forma d'onda
        if !peaks.isEmpty, duration > 0 {
            let per = Double(peaks.count) / duration
            var px: CGFloat = 0
            while px < w {
                let a = Int((time(px, w) * per).rounded(.down)), b = max(a + 1, Int((time(px + 2, w) * per).rounded(.down)))
                var m: Float = 0
                let lo = max(0, a), hi = min(peaks.count, b)
                if lo < hi { for i in lo..<hi { m = max(m, peaks[i]) } }
                let bh = max(1, CGFloat(m) * (h - 24))
                k.fill(Path(CGRect(x: px, y: h / 2 - bh / 2, width: 1.5, height: bh)), color)
                px += 2
            }
        }
        // Segnaposto numerati
        for (i, s) in slices.enumerated() {
            let xx = x(Double(s.start) / rate, w)
            guard xx >= -2, xx <= w + 2 else { continue }
            let on = (lit[i] ?? .distantPast) > now
            k.fill(Path(CGRect(x: xx - (on ? 3 : 1), y: 0, width: on ? 6 : 2, height: h)), i == selected ? Theme.ink : Theme.brass)
            k.text("\(i + 1)", at: CGPoint(x: xx + 4, y: 9), size: 10, color: Theme.brass, leading: true)
        }
        return k
    }

    private var pads: some View {
        HStack(spacing: 8) {
            Button { page -= 1 } label: { Image(systemName: "chevron.left") }.disabled(page == 0).help("Pad precedenti")
            TimelineView(.animation(minimumInterval: 1 / 30, paused: lit.isEmpty)) { tl in
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 8) {
                    ForEach(0..<16, id: \.self) { k in pad(page * 16 + k, k, now: tl.date) }
                }
            }
            .frame(maxWidth: .infinity)
            Button { page += 1 } label: { Image(systemName: "chevron.right") }.disabled((page + 1) * 16 >= slices.count).help("Pad successivi")
        }
    }

    private func pad(_ i: Int, _ k: Int, now: Date) -> some View {
        let ok = i < slices.count, on = (lit[i] ?? .distantPast) > now, color = Theme.color(key)
        return Button { play(i) } label: {
            VStack(spacing: 2) {
                Text(ok ? "\(i + 1)" : "").font(.system(size: 14, weight: .bold))
                Text(ok ? String(Self.keys[k]).uppercased() : "").font(.system(size: 10)).foregroundStyle(on ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(on ? .white : Theme.ink)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? color : color.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(i == selected ? color : color.opacity(0.4)))
            .shadow(color: on ? color.opacity(0.6) : .clear, radius: 8)
            .scaleEffect(on ? 0.97 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!ok)
        .accessibilityLabel(ok ? "Fetta \(i + 1)" : "Vuoto")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(info).font(.system(size: 12)).foregroundStyle(.secondary)
            if !status.isEmpty { Text(status).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            Button("Chiudi") { onClose() }.keyboardShortcut(.cancelAction)
            Button { export() } label: { Label("Esporta fette e MIDI", systemImage: "square.and.arrow.down") }
                .buttonStyle(.borderedProminent).tint(Theme.brass)
                .disabled(slices.isEmpty || working || preloaded != nil && job.folder == nil)
                .help("Una cartella con le fette in WAV, il file MIDI e le istruzioni per Ableton e Logic")
        }
    }

    private var info: String {
        var s = "\(slices.count) fette"
        if let i = selected, i < slices.count {
            let f = slices[i]
            s += " · scelta la \(i + 1) (\(formatTime(Double(f.start) / rate)), \(Int((Double(f.end - f.start) / rate * 1000).rounded())) ms)"
        }
        return s
    }

    // MARK: Azioni

    private func load() async {
        guard !key.isEmpty else { return }
        if let pre = preloaded { setUp(pre); return }
        guard let stem = job.stems.first(where: { $0.key == key }) else { return }
        status = "Leggo la traccia…"
        let url = stem.url
        let read = await Task.detached(priority: .userInitiated) { try? AudioIO.read(url) }.value
        status = ""
        if let a = read { setUp(a) } else { status = "Non riesco a leggere la traccia" }
    }

    private func setUp(_ a: [[Float]]) {
        audio = a
        peaks = EditAudio.peaks(a, perSecond: 200)
        t0 = 0
        span = min(max(1, duration), 20)
        detect()
    }

    private func detect() {
        guard !audio.isEmpty else { return }
        slices = Slicer.slices(Slicer.onsets(audio, sensitivity: sensitivity), length: audio[0].count)
        selected = nil
        page = 0
    }

    private func play(_ i: Int) {
        guard i >= 0, i < slices.count else { return }
        let part = Slicer.render(audio, slices[i])
        player.play(part)
        lit[i] = Date().addingTimeInterval(min(0.4, Double(part.first?.count ?? 0) / rate))
        selected = i
        if i / 16 != page { page = i / 16 }
        let t = Double(slices[i].start) / rate
        if t < t0 || t > t0 + span { t0 = max(0, min(duration - span, t - span * 0.1)) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { lit = lit.filter { $0.value > Date() } }
    }

    private func zoom(_ f: Double) {
        let mid = t0 + span / 2
        span = max(0.5, min(max(0.5, duration), span * f))
        t0 = max(0, min(duration - span, mid - span / 2))
    }

    private func export() {
        guard let folder = job.folder, !slices.isEmpty else { return }
        let a = audio, list = slices, title = job.title, name = Stem.info(key).name, bpm = job.analysis?.bpm
        let root = folder.deletingLastPathComponent()
        working = true
        status = "Salvo le fette…"
        Task.detached(priority: .userInitiated) {
            do {
                let dir = try Slicer.export(a, slices: list, title: title, stem: name, bpm: bpm, into: root)
                await MainActor.run {
                    working = false
                    status = "Esportate \(list.count) fette, il file MIDI e il LEGGIMI in «\(dir.lastPathComponent)»."
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
            } catch {
                await MainActor.run { working = false; status = "Esportazione non riuscita: \(error.localizedDescription)" }
            }
        }
    }
}
