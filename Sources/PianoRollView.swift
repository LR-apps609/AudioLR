import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// ════════════════════════════════════════════════════════════════════
//  Le note di una traccia nell'app (piano roll): tastiera a sinistra, note
//  nel colore della traccia (più piene se suonate forte), griglia sulle
//  battute vere, testina del mixer. Si ascoltano con un suono dell'app
//  (Piano, Synth, Basso: banco General MIDI del Mac), da sole, con la traccia
//  vera o insieme, e seguono velocità, tono e A–B del mixer. Si correggono e
//  si salvano con la canzone; il file MIDI si trascina in Logic o Ableton.
//  Le regole sono in NoteEdit.swift.
// ════════════════════════════════════════════════════════════════════

/// Il suono delle note: un campionatore con il banco General MIDI di macOS (se c'è; se no il suono di serie).
@MainActor
final class NoteSynth {
    enum Sound: String, CaseIterable, Identifiable {
        case piano, synth, bass
        var id: String { rawValue }
        var title: String { switch self { case .piano: "Piano"; case .synth: "Synth"; case .bass: "Basso" } }
        var program: UInt8 { switch self { case .piano: 0; case .synth: 81; case .bass: 33 } }
    }

    private let engine = AVAudioEngine()
    private let sampler = AVAudioUnitSampler()
    private var started = false
    private(set) var sound: Sound = .piano

    static let bank = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")

    func setSound(_ s: Sound) {
        sound = s
        guard start() else { return }
        if FileManager.default.fileExists(atPath: Self.bank.path) {
            try? sampler.loadSoundBankInstrument(at: Self.bank, program: s.program,
                                                 bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: UInt8(kAUSampler_DefaultBankLSB))
        }
    }

    @discardableResult
    private func start() -> Bool {
        if started { return true }
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        do { try engine.start(); started = true } catch { AppLog.write("Suono delle note non disponibile: \(error.localizedDescription)") }
        return started
    }

    func on(_ pitch: Int, velocity: Int) {
        guard start() else { return }
        sampler.startNote(UInt8(max(0, min(127, pitch))), withVelocity: UInt8(max(1, min(127, velocity))), onChannel: 0)
    }
    func off(_ pitch: Int) { if started { sampler.stopNote(UInt8(max(0, min(127, pitch))), onChannel: 0) } }
    func allOff() { if started { for p in 0...127 { sampler.stopNote(UInt8(p), onChannel: 0) } } }
    func stop() { allOff(); if started { engine.stop(); started = false } }
}

struct PianoRollView: View {
    @EnvironmentObject private var job: SeparationJob
    @ObservedObject var mixer: MixPlayer
    let stem: Stem
    /// Note già pronte (le schermate di prova); nil = salvate con la canzone o Basic Pitch.
    var preloaded: [Note]? = nil
    var onClose: () -> Void

    enum Listen: String, CaseIterable, Identifiable {
        case notes, track, both
        var id: String { rawValue }
        var title: String { switch self { case .notes: "Note"; case .track: "Traccia"; case .both: "Insieme" } }
    }

    @State private var editor: NoteEditor?
    @State private var selection: Set<Int> = []
    @State private var t0 = 0.0
    @State private var span = 16.0
    @State private var low = 48
    @State private var high = 72
    @State private var listen: Listen = .both
    @State private var sound: NoteSynth.Sound = .piano
    @State private var status = ""
    @State private var saved: MixState?
    @State private var drag: DragState?
    @State private var synth = NoteSynth()
    @State private var playing: [Int: (pitch: Int, end: Double)] = [:]
    @State private var lastPos = -1.0
    @State private var timer: Timer?
    @AppStorage("pianoSound") private var soundRaw = ""

    private struct DragState {
        enum Kind { case move, resize, rect }
        var kind: Kind
        var id: Int = 0
        var start: CGPoint
        var current: CGPoint
        var before: [EditNote] = []
        var history: [[EditNote]] = []
        var moved = false
    }

    private let keyWidth: CGFloat = 46
    private var duration: Double { max(mixer.duration, 1) }
    private var grid: [Double] { NoteGrid.make(structure: job.analysis?.structure, bpm: job.analysis?.bpm ?? 120, duration: duration) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            toolbar
            roll
            Slider(value: Binding(get: { t0 }, set: { t0 = $0 }), in: 0...max(0.001, duration - span))
                .controlSize(.small)
                .accessibilityLabel("Scorri la canzone")
            Divider()
            footer
        }
        .padding(22)
        .frame(minWidth: 900, idealWidth: 1040, minHeight: 560, idealHeight: 640)
        .background(Theme.background)
        .onAppear(perform: appear)
        .task { await load() }
        .onDisappear(perform: disappear)
    }

    // MARK: Parti

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "pianokeys").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.color(stem.key).gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text("Note · \(stem.name)").font(.system(size: 18, weight: .bold, design: .rounded))
                Text("Trascina una nota per spostarla, il bordo destro per allungarla. Doppio clic ne aggiunge una, ⌫ toglie le scelte. ⌥: senza aggancio alla griglia.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { toggle() } label: { Label(mixer.isPlaying ? "Pausa" : "Ascolta", systemImage: mixer.isPlaying ? "pause.fill" : "play.fill") }
                .keyboardShortcut(.space, modifiers: [])
            Text("\(formatTime(mixer.position)) / \(formatTime(mixer.duration))").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            Picker("Ascolta", selection: $listen) { ForEach(Listen.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(width: 230)
                .onChange(of: listen) { _, _ in applyListen() }
            Picker("Suono", selection: $sound) { ForEach(NoteSynth.Sound.allCases) { Text($0.title).tag($0) } }
                .labelsHidden().frame(width: 100)
                .onChange(of: sound) { _, s in synth.setSound(s); soundRaw = s.rawValue }
            Spacer()
            Button { zoom(2) } label: { Image(systemName: "minus.magnifyingglass") }.help("Allontana (⌘−)").keyboardShortcut("-")
            Button { zoom(0.5) } label: { Image(systemName: "plus.magnifyingglass") }.help("Avvicina (⌘+)").keyboardShortcut("+")
            Button { shiftView(-12) } label: { Image(systemName: "chevron.down") }.help("Un'ottava più giù")
            Button { shiftView(12) } label: { Image(systemName: "chevron.up") }.help("Un'ottava più su")
            Button { edit { $0.undo() }; selection = [] } label: { Label("Annulla", systemImage: "arrow.uturn.backward") }
                .keyboardShortcut("z").disabled(!(editor?.canUndo ?? false))
            Button { edit { $0.reset() }; selection = [] } label: { Label("Ripristina", systemImage: "arrow.counterclockwise") }
                .help("Torna alle note trovate da IsoLR").disabled(editor == nil)
            // ⌘A: tutte le note (tasto invisibile, solo la scorciatoia)
            Button("") { if let e = editor { selection = Set(e.notes.map(\.id)) } }.keyboardShortcut("a").opacity(0).frame(width: 0).accessibilityHidden(true)
        }
        .controlSize(.regular)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(info).font(.system(size: 12)).foregroundStyle(.secondary)
            if !status.isEmpty { Text(status).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            // Si trascina direttamente in Logic, Ableton o GarageBand: un file .mid con queste note
            Label("Trascina in Logic o Ableton", systemImage: "hand.draw")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.brass, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .onDrag { NSItemProvider(contentsOf: midiFile()) ?? NSItemProvider() }
                .help("Trascina questo riquadro nella finestra di Logic, Ableton o GarageBand: arriva il file MIDI con queste note")
                .disabled(editor == nil)
            Button("Fatto") { onClose() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Theme.brass)
        }
    }

    private var info: String {
        guard let e = editor else { return "" }
        return "\(e.notes.count) note" + (e.edited ? " · modificate" : "") + (selection.isEmpty ? "" : " · \(selection.count) scelte")
    }

    // MARK: Disegno

    private var roll: some View {
        GeometryReader { geo in
            let size = geo.size
            TimelineView(.animation(paused: !mixer.isPlaying)) { _ in
                SketchView { sz in sketch(sz) }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.well))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .gesture(dragGesture(size))
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { v in addNote(at: v.location, size: size) })
            .simultaneousGesture(SpatialTapGesture(count: 1).onEnded { v in tap(at: v.location, size: size) })
            .gesture(MagnifyGesture().onEnded { v in zoom(1 / max(0.2, Double(v.magnification))) })
            .onKeyPress(.delete) { deleteSelection(); return .handled }
            .onKeyPress(.deleteForward) { deleteSelection(); return .handled }
            .onKeyPress(.upArrow) { transposeSelection(NSEvent.modifierFlags.contains(.shift) ? 12 : 1); return .handled }
            .onKeyPress(.downArrow) { transposeSelection(NSEvent.modifierFlags.contains(.shift) ? -12 : -1); return .handled }
            .focusable()
            .focusEffectDisabled()
            .accessibilityLabel("Le note della traccia: tastiera a sinistra, tempo da sinistra a destra")
        }
        .frame(minHeight: 320)
    }

    private func rowHeight(_ h: CGFloat) -> CGFloat { h / CGFloat(high - low + 1) }
    private func x(_ t: Double, _ w: CGFloat) -> CGFloat { keyWidth + CGFloat((t - t0) / span) * (w - keyWidth) }
    private func t(_ x: CGFloat, _ w: CGFloat) -> Double { t0 + Double((x - keyWidth) / max(1, w - keyWidth)) * span }
    private func y(_ p: Int, _ h: CGFloat) -> CGFloat { CGFloat(high - p) * rowHeight(h) }
    private func p(_ y: CGFloat, _ h: CGFloat) -> Int { high - Int(floor(y / rowHeight(h))) }

    private func sketch(_ sz: CGSize) -> Sketch {
        var k = Sketch()
        let w = sz.width, h = sz.height, rh = rowHeight(h)
        let black: Set<Int> = [1, 3, 6, 8, 10]
        for q in low...high {
            let yy = y(q, h)
            if black.contains(q % 12) { k.fill(Path(CGRect(x: keyWidth, y: yy, width: w - keyWidth, height: rh)), Theme.stroke) }
            if q % 12 == 0 { k.fill(Path(CGRect(x: keyWidth, y: yy + rh - 1, width: w - keyWidth, height: 1)), Theme.stroke) }
        }
        // Griglia: sedicesimi tenui quando c'è spazio, battiti, battute più forti
        if span / Double(max(1, w - keyWidth)) * 6 < 0.12 {
            for g in grid where g >= t0 && g <= t0 + span {
                k.fill(Path(CGRect(x: x(g, w), y: 0, width: 0.5, height: h)), Theme.stroke)
            }
        }
        if let s = job.analysis?.structure {
            for (i, b) in s.beats.enumerated() where b >= t0 && b <= t0 + span {
                let bar = (i - s.firstDownbeat) % max(1, s.beatsPerBar) == 0
                k.fill(Path(CGRect(x: x(b, w), y: 0, width: 1, height: h)), bar ? Theme.ink.opacity(0.35) : Theme.stroke)
            }
        }
        // Le note
        let color = Theme.color(stem.key)
        for n in editor?.notes ?? [] where n.end >= t0 && n.start <= t0 + span && n.pitch >= low && n.pitch <= high {
            let x0 = max(keyWidth, x(n.start, w)), x1 = x(n.end, w)
            let r = CGRect(x: x0, y: y(n.pitch, h) + 1, width: max(2, x1 - x0), height: max(2, rh - 2))
            let path = Path(roundedRect: r, cornerRadius: min(3, rh / 2))
            k.fill(path, color.opacity(0.45 + 0.55 * Double(n.velocity) / 127))
            if selection.contains(n.id) { k.stroke(path, Theme.ink, StrokeStyle(lineWidth: 2)) }
        }
        if let d = drag, d.kind == .rect {
            let r = CGRect(x: min(d.start.x, d.current.x), y: min(d.start.y, d.current.y), width: abs(d.current.x - d.start.x), height: abs(d.current.y - d.start.y))
            k.stroke(Path(r), Theme.brass, StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        // Tastiera
        k.fill(Path(CGRect(x: 0, y: 0, width: keyWidth, height: h)), Theme.card)
        for q in low...high {
            let yy = y(q, h), isBlack = black.contains(q % 12)
            k.fill(Path(CGRect(x: 0, y: yy, width: isBlack ? keyWidth * 0.62 : keyWidth, height: rh)), isBlack ? Theme.ink.opacity(0.8) : Theme.card)
            k.fill(Path(CGRect(x: 0, y: yy + rh - 0.5, width: keyWidth, height: 0.5)), Theme.stroke)
            if q % 12 == 0 && rh >= 7 {
                k.text("Do\(q / 12 - 1)", at: CGPoint(x: keyWidth * 0.8, y: yy + rh / 2), size: min(10, rh), color: .secondary)
            }
        }
        k.fill(Path(CGRect(x: keyWidth - 1, y: 0, width: 1, height: h)), Theme.stroke)
        let pos = mixer.position
        if pos >= t0 && pos <= t0 + span { k.fill(Path(CGRect(x: x(pos, w) - 1, y: 0, width: 2, height: h)), Theme.brass) }
        return k
    }

    // MARK: Gesti

    private func hit(_ pt: CGPoint, _ size: CGSize) -> (EditNote, Bool)? {
        guard let e = editor else { return nil }
        let tt = t(pt.x, size.width), pp = p(pt.y, size.height)
        for n in e.notes.reversed() where n.pitch == pp && tt >= n.start && tt <= n.end {
            return (n, x(n.end, size.width) - pt.x <= 6)
        }
        return nil
    }

    private func dragGesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                guard var e = editor else { return }
                if drag == nil {
                    if let found = hit(v.startLocation, size) {
                        let (n, edge) = found
                        if !selection.contains(n.id) {
                            if !NSEvent.modifierFlags.contains(.shift) { selection = [] }
                            selection.insert(n.id)
                        }
                        drag = DragState(kind: edge ? .resize : .move, id: n.id, start: v.startLocation, current: v.location, before: e.notes, history: e.history)
                    } else {
                        if !NSEvent.modifierFlags.contains(.shift) { selection = [] }
                        drag = DragState(kind: .rect, start: v.startLocation, current: v.location)
                    }
                }
                guard var d = drag else { return }
                d.current = v.location
                if d.kind != .rect {
                    // Si riparte sempre dalle note di prima del gesto: un trascinamento è un solo passo di «Annulla»
                    let g = NSEvent.modifierFlags.contains(.option) ? nil : grid
                    e.restore(d.before, keepingHistory: d.history)
                    if d.kind == .move {
                        e.move(selection, dt: t(v.location.x, size.width) - t(d.start.x, size.width),
                               dp: p(v.location.y, size.height) - p(d.start.y, size.height), grid: g)
                    } else {
                        e.resize(d.id, end: t(v.location.x, size.width), grid: g)
                    }
                    d.moved = true
                    editor = e
                }
                drag = d
            }
            .onEnded { _ in
                guard let d = drag else { return }
                drag = nil
                if d.kind == .rect, let e = editor {
                    selection.formUnion(e.within(t0: t(d.start.x, size.width), t1: t(d.current.x, size.width),
                                                 p0: p(d.start.y, size.height), p1: p(d.current.y, size.height)))
                } else if d.moved { persist() }
            }
    }

    private func tap(at pt: CGPoint, size: CGSize) {
        if pt.x < keyWidth { audition(p(pt.y, size.height), velocity: 100); return }
        if let n = hit(pt, size)?.0 {
            if !NSEvent.modifierFlags.contains(.shift) { selection = [] }
            selection.insert(n.id)
            audition(n.pitch, velocity: n.velocity)
        } else if !NSEvent.modifierFlags.contains(.shift) { selection = [] }
    }

    private func addNote(at pt: CGPoint, size: CGSize) {
        guard pt.x >= keyWidth, editor != nil, hit(pt, size) == nil else { return }
        var id = 0
        edit { id = $0.add(start: t(pt.x, size.width), pitch: p(pt.y, size.height), grid: NSEvent.modifierFlags.contains(.option) ? nil : grid) }
        selection = [id]
    }

    private func deleteSelection() {
        guard !selection.isEmpty else { return }
        let s = selection
        edit { $0.remove(s) }
        selection = []
    }

    private func transposeSelection(_ d: Int) {
        guard !selection.isEmpty else { return }
        let s = selection
        edit { $0.move(s, dt: 0, dp: d, grid: nil) }
    }

    private func edit(_ change: (inout NoteEditor) -> Void) {
        guard var e = editor else { return }
        change(&e)
        editor = e
        persist()
    }

    private func zoom(_ f: Double) {
        let mid = t0 + span / 2
        span = max(1, min(duration, span * f))
        t0 = max(0, min(duration - span, mid - span / 2))
    }

    private func shiftView(_ d: Int) {
        let size = high - low
        low = max(0, min(127 - size, low + d))
        high = low + size
    }

    private func audition(_ pitch: Int, velocity: Int) {
        synth.on(pitch, velocity: velocity)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { synth.off(pitch) }
    }

    // MARK: Ascolto

    private func appear() {
        // Le schermate di prova: niente suono né orologio
        guard preloaded == nil else { return }
        mixer.pause()
        saved = mixer.state
        sound = NoteSynth.Sound(rawValue: soundRaw) ?? (stem.key == "bass" ? .bass : .piano)
        synth.setSound(sound)
        applyListen()
        timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            Task { @MainActor in schedule() }
        }
    }

    private func disappear() {
        guard preloaded == nil else { return }
        timer?.invalidate()
        mixer.pause()
        synth.stop()
        if let s = saved { mixer.state = s }
    }

    /// Solo le note: tutte le tracce mute (il mixer va avanti per il tempo); traccia e insieme: la traccia in solo.
    private func applyListen() {
        var s = saved ?? mixer.state
        s.muted = []
        s.solo = []
        if listen == .notes { s.muted = Set(mixer.keys) } else { s.solo = [stem.key] }
        mixer.state = s
        if listen == .track { synth.allOff(); playing = [:] }
    }

    private func toggle() {
        synth.allOff(); playing = [:]
        mixer.toggle()
    }

    /// Ogni 10 ms: accende le note appena iniziate e spegne quelle finite (con tono e velocità del mixer).
    private func schedule() {
        let pos = mixer.position
        defer { lastPos = pos }
        guard mixer.isPlaying, listen != .track, let e = editor else {
            if !playing.isEmpty { synth.allOff(); playing = [:] }
            return
        }
        if pos < lastPos - 0.05 { synth.allOff(); playing = [:]; lastPos = pos - 0.001 }
        for (id, v) in playing where pos >= v.end { synth.off(v.pitch); playing[id] = nil }
        for n in e.notes where n.start > lastPos && n.start <= pos && playing[n.id] == nil {
            let pitch = n.pitch + mixer.semitones
            synth.on(pitch, velocity: n.velocity)
            playing[n.id] = (pitch, n.end)
        }
        // La testina in vista
        if drag == nil, pos > t0 + span * 0.92 || pos < t0 { t0 = max(0, min(duration - span, pos - span * 0.1)) }
    }

    // MARK: File

    private func load() async {
        if let pre = preloaded { setUp(NoteEditor(detected: pre)); return }
        guard let folder = job.folder else { return }
        status = "Cerco le note della traccia (Basic Pitch)…"
        do {
            let found = try await SeparationJob.notes(for: stem, folder: folder)
            setUp(NoteEditor(detected: found.detected, edited: found.edited))
            status = found.detected.isEmpty && found.edited == nil ? "Nessuna nota trovata: aggiungine con un doppio clic." : ""
        } catch {
            status = "Non riesco a trovare le note: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    private func setUp(_ e: NoteEditor) {
        editor = e
        let r = NoteGrid.range(e.notes)
        low = r.lowerBound
        high = max(r.upperBound, low + 24)
        span = min(duration, 16)
    }

    /// Le note si salvano con la canzone a ogni modifica; i file MIDI già creati si rifanno al prossimo clic.
    private func persist() {
        guard let e = editor, let folder = job.folder, preloaded == nil else { return }
        do {
            try NoteStore.save(folder: folder, key: stem.key, detected: e.detected, edited: e.edited ? e.list : nil)
            job.forgetMidi(stem.key)
        } catch { status = "Non riesco a salvare le note" }
    }

    /// Il file .mid con le note di adesso (con il Transpose del mixer), per trascinarlo in un programma musicale.
    private func midiFile() -> URL {
        let shift = mixer.semitones
        let name = "\(job.title) – \(stem.name)\(Downloads.suffix(shift))"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).mid")
        let notes = (editor?.list ?? []).map { Note(start: $0.start, end: $0.end, pitch: max(0, min(127, $0.pitch + shift)), velocity: $0.velocity) }
        try? MidiFile.data(notes, bpm: job.analysis?.bpm ?? 120, program: MidiFile.program(for: stem.key), name: name).write(to: url, options: .atomic)
        return url
    }
}
