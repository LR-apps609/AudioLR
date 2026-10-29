import Foundation

// ════════════════════════════════════════════════════════════════════
//  Le note di una traccia nell'editor piano roll: la griglia (sedicesimi
//  sui battiti veri della canzone), l'aggancio, e le modifiche (sposta,
//  allunga, aggiungi, togli, selezione a rettangolo) con «Annulla» e
//  «Ripristina». Le note si salvano accanto alle tracce, rilevate e
//  modificate: i file MIDI, lo spartito e la tab usano quelle modificate.
//  Le stesse regole sono in windows/ui/core/notes.js.
// ════════════════════════════════════════════════════════════════════

/// Una nota nell'editor: come `Note`, più un numero per riconoscerla mentre si trascina.
struct EditNote: Equatable, Codable, Identifiable {
    var id: Int
    var start: Double
    var end: Double
    var pitch: Int
    var velocity: Int

    var note: Note { Note(start: start, end: end, pitch: pitch, velocity: velocity) }
}

enum NoteGrid {
    /// Una nota non è mai più corta di 30 ms.
    static let minLength = 0.03

    /// I sedicesimi della canzone: quattro per battito, sui battiti veri; prima e dopo con il passo vicino.
    static func make(structure: SongStructure?, bpm: Double, duration: Double) -> [Double] {
        let beats = (structure?.beats.count ?? 0) > 1 ? structure!.beats : nil
        let period = beats.map { ($0.last! - $0.first!) / Double($0.count - 1) } ?? 60 / max(30, bpm > 0 ? bpm : 120)
        var b = beats ?? [0]
        var t = b[0] - period
        while t > 0 { b.insert(t, at: 0); t -= period }
        if b[0] > 0 { b.insert(0, at: 0) }
        while b.last! < duration { b.append(b.last! + period) }
        var out: [Double] = []
        for i in 0..<(b.count - 1) {
            let step = (b[i + 1] - b[i]) / 4
            for k in 0..<4 {
                let t = b[i] + Double(k) * step
                if t >= 0 && t <= duration + 1e-9 { out.append(t) }
            }
        }
        return out
    }

    /// Il punto della griglia più vicino. Senza griglia il tempo resta com'è.
    static func snap(_ t: Double, _ g: [Double]?) -> Double {
        guard let g, !g.isEmpty else { return t }
        var lo = 0, hi = g.count - 1
        while hi - lo > 1 { let m = (lo + hi) / 2; if g[m] <= t { lo = m } else { hi = m } }
        return abs(g[lo] - t) <= abs(g[hi] - t) ? g[lo] : g[hi]
    }

    /// Le altezze da mostrare: dalla più bassa alla più alta con un po' di margine, almeno due ottave.
    static func range(_ notes: [EditNote]) -> ClosedRange<Int> {
        guard let lo0 = notes.map(\.pitch).min(), let hi0 = notes.map(\.pitch).max() else { return 48...72 }
        var lo = lo0 - 3, hi = hi0 + 3
        while hi - lo < 24 { lo -= 1; hi += 1 }
        return max(0, lo)...min(127, hi)
    }
}

/// L'editor: le note con un numero ciascuna, la storia per «Annulla», le note rilevate per «Ripristina».
struct NoteEditor {
    let detected: [Note]
    private(set) var notes: [EditNote]
    private(set) var history: [[EditNote]] = []
    private var next: Int
    /// Riaperte già modificate (salvate così con la canzone).
    private var base: Bool

    init(detected: [Note], edited: [Note]? = nil) {
        self.detected = detected
        notes = (edited ?? detected).enumerated().map { EditNote(id: $0.offset + 1, start: $0.element.start, end: $0.element.end,
                                                                 pitch: $0.element.pitch, velocity: $0.element.velocity) }
        next = notes.count + 1
        base = edited != nil
    }

    var edited: Bool { base || !history.isEmpty }
    var canUndo: Bool { !history.isEmpty }

    func find(_ id: Int) -> EditNote? { notes.first { $0.id == id } }

    private mutating func save() {
        history.append(notes)
        if history.count > 200 { history.removeFirst() }
    }

    private static func clampPitch(_ p: Int) -> Int { max(0, min(127, p)) }

    /// Sposta le note scelte di `dt` secondi e `dp` semitoni; con la griglia l'inizio della prima si aggancia.
    mutating func move(_ ids: Set<Int>, dt: Double, dp: Int, grid: [Double]?) {
        let sel = notes.filter { ids.contains($0.id) }
        guard let first = sel.min(by: { $0.start < $1.start }) else { return }
        save()
        var shift = grid == nil ? dt : NoteGrid.snap(first.start + dt, grid) - first.start
        if first.start + shift < 0 { shift = -first.start }
        for i in notes.indices where ids.contains(notes[i].id) {
            let len = notes[i].end - notes[i].start
            notes[i].start += shift
            notes[i].end = notes[i].start + len
            notes[i].pitch = Self.clampPitch(notes[i].pitch + dp)
        }
    }

    /// Allunga o accorcia una nota: la fine va a `end` (agganciata alla griglia se c'è).
    mutating func resize(_ id: Int, end: Double, grid: [Double]?) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        save()
        notes[i].end = max(notes[i].start + NoteGrid.minLength, grid == nil ? end : NoteGrid.snap(end, grid))
    }

    /// Una nota nuova: inizio agganciato, lunga un sedicesimo (o `length` secondi senza griglia).
    @discardableResult
    mutating func add(start: Double, pitch: Int, grid: [Double]?, length: Double = 0.25) -> Int {
        save()
        let s = max(0, grid == nil ? start : NoteGrid.snap(start, grid))
        var e = s + length
        if let g = grid, let i = g.firstIndex(of: s), i + 1 < g.count { e = g[i + 1] }
        let n = EditNote(id: next, start: s, end: max(s + NoteGrid.minLength, e), pitch: Self.clampPitch(pitch), velocity: 96)
        next += 1
        notes.append(n)
        return n.id
    }

    mutating func remove(_ ids: Set<Int>) {
        guard !ids.isEmpty else { return }
        save()
        notes.removeAll { ids.contains($0.id) }
    }

    /// Le note dentro il rettangolo (tempo t0…t1, altezze p0…p1, compresi).
    func within(t0: Double, t1: Double, p0: Int, p1: Int) -> Set<Int> {
        let a = min(t0, t1), b = max(t0, t1), lo = min(p0, p1), hi = max(p0, p1)
        return Set(notes.filter { $0.end > a && $0.start < b && $0.pitch >= lo && $0.pitch <= hi }.map(\.id))
    }

    mutating func undo() { if let last = history.popLast() { notes = last } }

    /// Di nuovo le note rilevate: non sono più «modificate».
    mutating func reset() {
        var fresh: [EditNote] = []
        for n in detected {
            fresh.append(EditNote(id: next, start: n.start, end: n.end, pitch: n.pitch, velocity: n.velocity))
            next += 1
        }
        notes = fresh
        base = false
        history = []
    }

    /// Le note in ordine (per il file MIDI e lo spartito).
    var list: [Note] { notes.map(\.note).sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) } }

    /// Per trascinare: si riparte dalle note di prima del gesto, così un trascinamento è un solo passo di «Annulla».
    mutating func restore(_ before: [EditNote], keepingHistory h: [[EditNote]]) {
        notes = before
        history = h
    }
}

/// Le note di una canzone accanto alle sue tracce: «isolr-note-<traccia>.json», rilevate e modificate.
enum NoteStore {
    private struct Saved: Codable {
        var version = 1
        var detected: [Saved.N]
        var edited: [Saved.N]?
        struct N: Codable { var start: Double; var end: Double; var pitch: Int; var velocity: Int }
    }

    static func url(folder: URL, key: String) -> URL { folder.appendingPathComponent("isolr-note-\(key).json") }

    static func load(folder: URL, key: String) -> (detected: [Note], edited: [Note]?)? {
        guard let data = try? Data(contentsOf: url(folder: folder, key: key)),
              let s = try? JSONDecoder().decode(Saved.self, from: data) else { return nil }
        let conv = { (l: [Saved.N]) in l.map { Note(start: $0.start, end: $0.end, pitch: $0.pitch, velocity: $0.velocity) } }
        return (conv(s.detected), s.edited.map(conv))
    }

    static func save(folder: URL, key: String, detected: [Note], edited: [Note]?) throws {
        let conv = { (l: [Note]) in l.map { Saved.N(start: $0.start, end: $0.end, pitch: $0.pitch, velocity: $0.velocity) } }
        let data = try JSONEncoder().encode(Saved(detected: conv(detected), edited: edited.map(conv)))
        try data.write(to: url(folder: folder, key: key), options: .atomic)
    }

    /// Le note modificate a mano, se ci sono (per i file MIDI, spartito e tab).
    static func edited(folder: URL, key: String) -> [Note]? { load(folder: folder, key: key)?.edited }
}
