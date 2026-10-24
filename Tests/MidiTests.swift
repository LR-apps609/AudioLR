import XCTest

/// Dall'audio alle note: ricerca delle note, file MIDI, e il modello Basic Pitch su una scala nota.
final class MidiTests: XCTestCase {

    func testNotesFromActivations() {
        let n = 120, K = MidiTranscriber.keys
        var frames = [[Float]](repeating: [Float](repeating: 0, count: K), count: n)
        var onsets = frames
        // Do centrale (60 → indice 39) da 10 a 40, con attacco a 10
        for t in 10..<40 { frames[t][39] = 0.8 }
        onsets[9][39] = 0.2; onsets[10][39] = 0.9; onsets[11][39] = 0.3
        // Un La (69 → 48) senza attacco: lo trova il «trucco Melodia»
        for t in 60..<95 { frames[t][48] = 0.6 }
        let notes = MidiTranscriber.notes(frames: frames, onsets: onsets)
        XCTAssertEqual(notes.map(\.pitch), [60, 69])
        XCTAssertEqual(notes[0].start, MidiTranscriber.time(ofFrame: 10), accuracy: 1e-9)
        XCTAssertEqual(notes[0].velocity, Int((127 * 0.8).rounded()))
        // Troppo corta (meno di 11 colonne): niente nota
        var short = [[Float]](repeating: [Float](repeating: 0, count: K), count: n)
        for t in 20..<26 { short[t][30] = 0.9 }
        XCTAssertTrue(MidiTranscriber.notes(frames: short, onsets: short.map { _ in [Float](repeating: 0, count: K) }).isEmpty)
    }

    func testMidiFile() {
        let notes = [Note(start: 0, end: 0.5, pitch: 60, velocity: 100), Note(start: 0.5, end: 1, pitch: 64, velocity: 90)]
        let d = [UInt8](MidiFile.data(notes, bpm: 120, program: 33, name: "Prova"))
        XCTAssertEqual(Array(d[0..<4]), Array("MThd".utf8))
        XCTAssertEqual(Array(d[8..<10]), [0, 0], "formato 0")
        XCTAssertEqual(Array(d[12..<14]), [0x01, 0xE0], "480 tick per battito")
        XCTAssertEqual(Array(d[14..<18]), Array("MTrk".utf8))
        let len = Int(d[18]) << 24 | Int(d[19]) << 16 | Int(d[20]) << 8 | Int(d[21])
        XCTAssertEqual(len, d.count - 22)
        XCTAssertEqual(Array(d.suffix(3)), [0xFF, 0x2F, 0x00], "fine traccia")
        // Due note accese e due spente; a 120 BPM mezzo secondo = 480 tick (0x83 0x60)
        XCTAssertEqual(d.filter { $0 == 0x90 }.count, 2)
        XCTAssertEqual(d.filter { $0 == 0x80 }.count, 2)
        XCTAssertTrue(zip(d, d.dropFirst()).contains { $0 == 0x83 && $1 == 0x60 })
        XCTAssertTrue(d.contains(0xC0) && d[d.firstIndex(of: 0xC0)! + 1] == 33, "suono del basso")
    }

    func testPrepareHalvesTheRateAndFiltersHighs() {
        let n = 44_100
        func tone(_ f: Double) -> [[Float]] {
            let x = (0..<n).map { Float(0.5 * sin(2 * .pi * f * Double($0) / 44_100)) }
            return [x, x]
        }
        let low = MidiTranscriber.prepare(tone(440))
        XCTAssertEqual(low.count, n / 2)
        let lowPeak = low[2000..<20000].map(abs).max() ?? 0
        XCTAssertEqual(lowPeak, 0.5, accuracy: 0.03)
        let high = MidiTranscriber.prepare(tone(16_000))
        XCTAssertLessThan(high[2000..<20000].map(abs).max() ?? 1, 0.05, "sopra 11 kHz non deve tornare giù come rumore")
    }

    /// Una scala di Do maggiore suonata con armonici: Basic Pitch deve ritrovare quasi tutte le note.
    func testBasicPitchFindsAScale() throws {
        executionTimeAllowance = 600
        let model: MidiTranscriber
        do { model = try MidiTranscriber.bundled() } catch { throw XCTSkip("modello delle note non incluso nel test") }
        let scale = [60, 62, 64, 65, 67, 69, 71, 72]
        let sr = 44_100.0, dur = 0.5
        var x: [Float] = []
        for m in scale {
            let f = 440 * pow(2, Double(m - 69) / 12)
            for i in 0..<Int(dur * sr) {
                let t = Double(i) / sr
                let env = min(1, t * 100) * exp(-t * 3) * min(1, (dur - t) * 50)
                var v = 0.0
                for k in 1...5 { v += sin(2 * .pi * f * Double(k) * t) / Double(k * k) }
                x.append(Float(0.4 * env * v))
            }
        }
        x += [Float](repeating: 0, count: Int(sr))
        let notes = try model.transcribe([x, x])
        var found = 0
        for (i, m) in scale.enumerated() {
            let t0 = Double(i) * dur
            if notes.contains(where: { $0.pitch == m && abs($0.start - t0) < 0.12 }) { found += 1 }
        }
        let line = "MIDI Basic Pitch: \(found) note su \(scale.count) della scala ritrovate (\(notes.count) note in tutto)"
        print(line)
        let path = "/tmp/audiolr-passi.txt"
        let old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? (old + line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertGreaterThanOrEqual(found, 6, line)
    }
}
