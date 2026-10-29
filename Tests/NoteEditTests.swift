import XCTest

/// Piano roll e Slice to MIDI: le regole senza disegno né suono (come windows/ui/core/test/notes.test.js).
final class NoteEditTests: XCTestCase {

    // MARK: Piano roll

    func testGridAndSnap() {
        let s = SongStructure(beats: [1, 1.5, 2, 2.5], firstDownbeat: 0, beatsPerBar: 4, sections: [])
        let g = NoteGrid.make(structure: s, bpm: 120, duration: 3.2)
        XCTAssertEqual(g.first!, 0, accuracy: 1e-9)
        XCTAssertTrue(g.contains { abs($0 - 1.125) < 1e-9 }, "sedicesimo dentro il battito")
        XCTAssertTrue(g.contains { abs($0 - 3) < 1e-9 }, "dopo l'ultimo battito, stesso passo")
        XCTAssertEqual(NoteGrid.snap(1.13, g), 1.125, accuracy: 1e-9)
        XCTAssertEqual(NoteGrid.snap(5, nil), 5)
        let plain = NoteGrid.make(structure: nil, bpm: 60, duration: 2)
        XCTAssertEqual(plain[1] - plain[0], 0.25, accuracy: 1e-9, "senza battiti: dal BPM")
    }

    func testEditsWithUndoAndReset() {
        var e = NoteEditor(detected: [Note(start: 0.5, end: 1, pitch: 60, velocity: 80), Note(start: 1, end: 1.5, pitch: 64, velocity: 70)])
        let g = NoteGrid.make(structure: nil, bpm: 120, duration: 4)
        let a = e.notes[0].id, b = e.notes[1].id
        e.move([a], dt: 0.11, dp: 2, grid: g)
        XCTAssertEqual(e.find(a)!.start, 0.625, accuracy: 1e-9, "inizio agganciato al sedicesimo")
        XCTAssertEqual(e.find(a)!.end - e.find(a)!.start, 0.5, accuracy: 1e-9, "lunghezza invariata")
        XCTAssertEqual(e.find(a)!.pitch, 62)
        e.resize(b, end: 1.02, grid: g)
        XCTAssertEqual(e.find(b)!.end, 1 + NoteGrid.minLength, accuracy: 1e-9, "mai più corta del minimo")
        let c = e.add(start: 2.01, pitch: 67, grid: g)
        XCTAssertEqual(e.find(c)!.start, 2, accuracy: 1e-9)
        XCTAssertEqual(e.find(c)!.end, 2.125, accuracy: 1e-9, "lunga un sedicesimo")
        XCTAssertEqual(e.within(t0: 0, t1: 3, p0: 66, p1: 68), [c], "selezione a rettangolo")
        e.remove([c])
        XCTAssertEqual(e.notes.count, 2)
        e.undo()
        XCTAssertEqual(e.notes.count, 3, "annulla la cancellazione")
        e.undo(); e.undo(); e.undo()
        XCTAssertEqual(e.find(a)!.start, 0.5, accuracy: 1e-9, "annulla fino all'inizio")
        XCTAssertFalse(e.edited)
        e.move([a], dt: -5, dp: 0, grid: nil)
        XCTAssertEqual(e.find(a)!.start, 0, accuracy: 1e-9, "mai prima dell'inizio")
        e.reset()
        XCTAssertEqual(e.list.map(\.pitch), [60, 64], "ripristina le note rilevate")
        XCTAssertFalse(e.edited, "dopo Ripristina non sono più modificate")
        XCTAssertTrue(NoteEditor(detected: [], edited: [Note(start: 0, end: 1, pitch: 60, velocity: 90)]).edited, "riaperte modificate")
        XCTAssertEqual(NoteGrid.range([EditNote(id: 1, start: 0, end: 1, pitch: 60, velocity: 1)]), 48...72, "almeno due ottave")
    }

    func testNotesSavedWithTheSong() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("note-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let det = [Note(start: 0, end: 1, pitch: 40, velocity: 90)]
        try NoteStore.save(folder: dir, key: "bass", detected: det, edited: nil)
        XCTAssertNil(NoteStore.edited(folder: dir, key: "bass"))
        try NoteStore.save(folder: dir, key: "bass", detected: det, edited: [Note(start: 0, end: 2, pitch: 52, velocity: 90)])
        XCTAssertEqual(NoteStore.edited(folder: dir, key: "bass")?.first?.pitch, 52)
        XCTAssertEqual(NoteStore.load(folder: dir, key: "bass")?.detected, det)
    }

    // MARK: Slice

    private func clicks(_ times: [Double], rate: Double, length: Double) -> [[Float]] {
        var x = [Float](repeating: 0, count: Int(length * rate))
        var seed: UInt64 = 7
        for t in times {
            let s = Int(t * rate)
            for i in 0..<2000 where s + i < x.count {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let r = Float(Double(seed >> 11) / Double(1 << 53)) * 2 - 1
                x[s + i] = r * Float(exp(-Double(i) / 300))
            }
        }
        return [x, x]
    }

    func testOnsetsOfAFakeDrum() {
        let rate = 44_100.0, times = [0.25, 0.75, 1.0, 1.5, 1.625]
        let on = Slicer.onsets(clicks(times, rate: rate, length: 2), rate: rate, sensitivity: 0.5)
        XCTAssertEqual(on.count, times.count, "trovati \(on.count)")
        for (o, t) in zip(on, times) { XCTAssertEqual(Double(o) / rate, t, accuracy: 0.01) }
        XCTAssertEqual(Slicer.onsets([[Float](repeating: 0, count: 44_100)], rate: rate), [], "silenzio: nessun colpo")
        XCTAssertEqual(Slicer.onsets(clicks([0, 0.5], rate: rate, length: 1), rate: rate).first, 0, "un colpo proprio all'inizio della traccia")
    }

    func testSlicesEditsAudioAndMidi() throws {
        let rate = 1000.0
        var l = Slicer.slices([100, 400, 700], length: 1000, rate: rate, preroll: 0.005)
        XCTAssertEqual(l, [AudioSlice(start: 95, end: 395), AudioSlice(start: 395, end: 695), AudioSlice(start: 695, end: 1000)])
        l = Slicer.move(l, 1, to: 10, rate: rate)
        XCTAssertEqual(l[1].start, 105, "non scavalca la fetta prima")
        XCTAssertEqual(l[0].end, 105)
        l = Slicer.merge(l, 0)
        XCTAssertEqual(l, [AudioSlice(start: 95, end: 695), AudioSlice(start: 695, end: 1000)])
        l = Slicer.split(l, at: 300, rate: rate)
        XCTAssertEqual(l.count, 3)
        let r = Slicer.render([[Float](repeating: 1, count: 1000)], AudioSlice(start: 0, end: 100), rate: rate, fade: 0.01)
        XCTAssertEqual(r[0].count, 100)
        XCTAssertEqual(r[0][0], 0, "dissolvenza all'inizio")
        XCTAssertEqual(r[0][50], 1)
        let mid = [UInt8](Slicer.midi(l, rate: rate, bpm: 120))
        XCTAssertEqual(String(bytes: mid[0..<4], encoding: .ascii), "MThd")
        var ons: [UInt8] = []
        for i in 0..<(mid.count - 2) where mid[i] == 0x90 { ons.append(mid[i + 1]) }
        XCTAssertEqual(ons, [36, 37, 38])
        XCTAssertEqual(Slicer.fileName(0), "Slice 01.wav")
        XCTAssertEqual(Slicer.note(of: 200), 127)
        XCTAssertTrue(Slicer.readme(title: "Canzone", stem: "Batteria", count: 3, bpm: 120).contains("Drum Rack"))
    }

    func testExportWritesSlicesMidiAndReadme() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("slice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = clicks([0.1, 0.6], rate: AudioIO.sampleRate, length: 1)
        let list = Slicer.slices(Slicer.onsets(audio), length: audio[0].count)
        let out = try Slicer.export(audio, slices: list, title: "Prova", stem: "Batteria", bpm: 100, into: dir)
        let files = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        XCTAssertEqual(files, ["LEGGIMI.txt", "Prova – Slice Batteria.mid", "Slice 01.wav", "Slice 02.wav"])
        XCTAssertEqual(out.lastPathComponent, "Prova – Slice Batteria")
    }
}
