import XCTest

/// Warp (mappa, griglia, «Metti a tempo») e Rimonta (blocchi, giunzioni, analisi).
final class WarpTests: XCTestCase {
    let sr = 44_100.0

    // MARK: Warp

    func testMapAndInverse() {
        // Battute di 2 s, 2,5 s, 1,5 s → a 120 BPM in 4/4 ognuna dura 2 s
        let m = WarpMap.toTempo(downbeats: [1, 3, 5.5, 7], beatsPerBar: 4, bpm: 120, natural: 100)
        XCTAssertEqual(m.map(0), 0, accuracy: 1e-9, "l'inizio della canzone resta all'inizio")
        XCTAssertEqual(m.map(1), 1, accuracy: 1e-9)
        XCTAssertEqual(m.map(3), 3, accuracy: 1e-9)
        XCTAssertEqual(m.map(5.5), 5, accuracy: 1e-9)
        XCTAssertEqual(m.map(7), 7, accuracy: 1e-9)
        XCTAssertEqual(m.map(8.5), 9, accuracy: 1e-9, "dopo l'ultimo segnaposto vale l'ultima battuta")
        for s in stride(from: 0.0, to: 10, by: 0.37) { XCTAssertEqual(m.inverse(m.map(s)), s, accuracy: 1e-9) }
        XCTAssertEqual(m.rate(atSource: 4), 1.25, accuracy: 1e-9, "la battuta lunga si legge più veloce")
        XCTAssertEqual(m.rate(atSource: 6), 0.75, accuracy: 1e-9)
        XCTAssertEqual(m.extremeRate, 1.0 / 0.75, accuracy: 1e-9)
    }

    func testFewMarksUseTheWholeSongRatio() {
        let m = WarpMap.toTempo(downbeats: [2], beatsPerBar: 4, bpm: 120, natural: 100)
        XCTAssertEqual(m.map(12), 10, accuracy: 1e-9, "100 BPM → 120: tutto più veloce dello stesso rapporto")
    }

    func testBeatsFromMarks() {
        let g = Warp.beats(downbeats: [1, 3, 5], beatsPerBar: 4, duration: 6.2)
        // Prima del primo: 0,5 · 0 ; tra i segnaposto ogni 0,5 s ; dopo l'ultimo fino a 6,2 s
        XCTAssertEqual(g.firstDownbeat, 2)
        XCTAssertEqual(g.beats.first!, 0, accuracy: 1e-9)
        XCTAssertEqual(g.beats[g.firstDownbeat], 1, accuracy: 1e-9)
        XCTAssertEqual(g.beats[g.firstDownbeat + 4], 3, accuracy: 1e-9)
        XCTAssertEqual(g.beats.last!, 6, accuracy: 1e-9)
        XCTAssertEqual(Warp.bpm(downbeats: [1, 3, 5], beatsPerBar: 4)!, 120, accuracy: 1e-9)
        let old = SongStructure(beats: [], firstDownbeat: 0, beatsPerBar: 4, sections: [SongSection(start: 0, end: 6, label: "Strofa", group: 0)])
        let s = Warp.structure(downbeats: [1, 3, 5], old: old, duration: 6.2)
        XCTAssertEqual(s.downbeats.prefix(3).map { ($0 * 1000).rounded() }, [1000, 3000, 5000])
        XCTAssertEqual(s.sections, old.sections)
    }

    func testAnalysisFollowsTheMap() {
        let m = WarpMap.toTempo(downbeats: [0, 2.5, 5], beatsPerBar: 4, bpm: 120, natural: 96)
        let structure = SongStructure(beats: stride(from: 0.0, to: 5, by: 0.625).map { $0 }, firstDownbeat: 0, beatsPerBar: 4,
                                      sections: [SongSection(start: 0, end: 2.5, label: "Strofa", group: 0), SongSection(start: 2.5, end: 5, label: "Ritornello", group: 1)])
        var a = SongAnalysis(bpm: 96, keyRoot: 2, minor: false, keyConfidence: 0.7, structure: structure)
        a.chords = [ChordSpan(start: 2.5, end: 5, root: 7, minor: false)]
        let out = Warp.analysis(a, map: m, bpm: 120, duration: 5)
        XCTAssertEqual(out.bpm, 120)
        XCTAssertEqual(out.keyRoot, 2)
        XCTAssertEqual(out.structure!.sections[1].start, 2, accuracy: 1e-9)
        XCTAssertEqual(out.chords![0].start, 2, accuracy: 1e-9)
        XCTAssertEqual(out.chords![0].end, 4, accuracy: 1e-9)
        // Battiti regolari: ogni 0,5 s
        let b = out.structure!.beats
        for i in 1..<b.count { XCTAssertEqual(b[i] - b[i - 1], 0.5, accuracy: 1e-6) }
    }

    /// Un colpo sul secondo segnaposto finisce dove dice la mappa; la lunghezza è quella nuova.
    func testRenderPutsTheHitOnTheGrid() throws {
        // Battute di 2,2 s e 1,8 s → 2 s ciascuna (120 BPM in 4/4)
        let marks = [0.0, 2.2, 4.0]
        let n = Int(6.0 * sr)
        var x = [Float](repeating: 0, count: n)
        // Un tono basso continuo (il TimePitch ha bisogno di musica) e un colpo forte a 2,2 s e a 4,0 s
        for i in 0..<n { x[i] = 0.05 * Float(sin(2 * .pi * 110 * Double(i) / sr)) }
        for t in [2.2, 4.0] { let a = Int(t * sr); for i in 0..<400 { x[a + i] += Float(0.9 * exp(-Double(i) / 60)) } }
        let m = WarpMap.toTempo(downbeats: marks, beatsPerBar: 4, bpm: 120, natural: 120)
        let out = try Warp.render([x, x], map: m)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(Double(out[0].count), m.map(6) * sr, accuracy: 600)
        for (src, dst) in [(2.2, 2.0), (4.0, 4.0)] {
            let at = onset(out[0], near: dst)
            XCTAssertEqual(at, dst, accuracy: 0.010, "il colpo di \(src) s deve cadere a \(dst) s (è a \(at))")
        }
    }

    /// A tempo uguale con la griglia regolare non cambia niente (o quasi).
    func testRenderAtNaturalTempoIsNearlyTheSame() throws {
        let n = Int(4.0 * sr)
        let x = (0..<n).map { Float(0.3 * sin(2 * .pi * 220 * Double($0) / sr)) }
        let m = WarpMap.toTempo(downbeats: [0, 2, 4], beatsPerBar: 4, bpm: 120, natural: 120)
        let out = try Warp.render([x, x], map: m)
        XCTAssertEqual(out[0].count, n, accuracy: 2)
        var err = 0.0, e = 0.0
        for i in Int(0.3 * sr)..<Int(3.5 * sr) { err += Double((out[0][i] - x[i]) * (out[0][i] - x[i])); e += Double(x[i] * x[i]) }
        XCTAssertLessThan(err / e, 0.05, "a rapporto 1 la traccia resta quasi uguale")
    }

    /// Il primo colpo forte dopo `t - 0,1` s.
    private func onset(_ x: [Float], near t: Double) -> Double {
        let a = max(0, Int((t - 0.1) * sr)), b = min(x.count, Int((t + 0.1) * sr))
        guard b > a else { return -1 }
        let peak = x[a..<b].map(abs).max() ?? 0
        for i in a..<b where abs(x[i]) > peak * 0.5 { return Double(i) / sr }
        return -1
    }

    // MARK: Rimonta

    private let parts = SongStructure(beats: stride(from: 0.0, to: 8, by: 0.5).map { $0 }, firstDownbeat: 0, beatsPerBar: 4,
                                      sections: [SongSection(start: 0, end: 2, label: "Intro", group: 0), SongSection(start: 2, end: 6, label: "Strofa", group: 1),
                                                 SongSection(start: 6, end: 8, label: "Ritornello", group: 2)])

    func testBlocksFromSections() {
        let a = Arrangement.from(parts, duration: 8.3)
        XCTAssertEqual(a.blocks.map(\.label), ["Intro", "Strofa", "Ritornello"])
        XCTAssertEqual(a.blocks.last!.srcEnd, 8.3, "la coda resta nell'ultimo blocco")
        XCTAssertEqual(a.duration, 8.3, accuracy: 1e-9)
        XCTAssertTrue(a.isOriginal)
        XCTAssertEqual(Arrangement.from(nil, duration: 5).blocks.count, 1)
    }

    func testSplitSnapsToTheBar() {
        var a = Arrangement.from(parts, duration: 8)
        XCTAssertTrue(a.split(1, at: 1.7))            // 3,7 s → battuta a 4 s
        XCTAssertEqual(a.blocks[1].srcEnd, 4)
        XCTAssertEqual(a.blocks[2].srcStart, 4)
        XCTAssertFalse(a.split(0, at: 0.05), "troppo vicino al bordo")
        XCTAssertTrue(a.isOriginal, "dividere non cambia la canzone")
    }

    func testMoveDuplicateRemove() {
        var a = Arrangement.from(parts, duration: 8)
        a.duplicate(2)
        XCTAssertEqual(a.blocks.map(\.label), ["Intro", "Strofa", "Ritornello", "Ritornello"])
        XCTAssertNotEqual(a.blocks[2].id, a.blocks[3].id)
        a.remove(1)
        XCTAssertEqual(a.blocks.map(\.label), ["Intro", "Ritornello", "Ritornello"])
        a.move(0, to: 2)
        XCTAssertEqual(a.blocks.map(\.label), ["Ritornello", "Ritornello", "Intro"])
        XCTAssertEqual(a.duration, 6, accuracy: 1e-9)
        XCTAssertEqual(a.start(of: 2), 4, accuracy: 1e-9)
        XCTAssertEqual(a.locate(4.5)!.index, 2)
        XCTAssertFalse(a.isOriginal)
    }

    func testRenderLengthAndJoins() {
        let n = Int(8 * sr)
        // Ogni secondo un valore diverso: si riconosce da dove viene ogni pezzo
        let x = (0..<n).map { Float(Int(Double($0) / sr) + 1) * 0.1 }
        let same = Arrangement.from(parts, duration: 8).render([x, x])
        XCTAssertEqual(same[0], x, "nell'ordine di partenza la traccia resta identica")
        var a = Arrangement.from(parts, duration: 8)
        a.move(2, to: 1)                               // Intro (0–2 s), Ritornello (6–8 s), Strofa (2–6 s)
        let out = a.render([x, x])
        XCTAssertEqual(out[0].count, n)
        XCTAssertEqual(out[0][Int(0.5 * sr)], 0.1, accuracy: 1e-6, "all'inizio l'intro")
        XCTAssertEqual(out[0][Int(2.5 * sr)], 0.7, accuracy: 1e-6, "poi il ritornello")
        XCTAssertEqual(out[0][Int(5 * sr)], 0.4, accuracy: 1e-6, "poi la strofa")
        // Alla giunzione (2 s) in 10 ms l'intro (0,2) lascia il posto a quello che precede il ritornello (0,6)
        let j = Int(2 * sr), f = Int(Arrangement.fade * sr)
        XCTAssertEqual(out[0][j - f], 0.2, accuracy: 0.005)
        XCTAssertEqual(out[0][j - 1], 0.6, accuracy: 0.005)
        for i in (j - f + 1)..<j { XCTAssertLessThan(abs(out[0][i] - out[0][i - 1]), 0.01, "dissolvenza senza salti") }
    }

    func testArrangedAnalysis() {
        var analysis = SongAnalysis(bpm: 120, keyRoot: 0, minor: false, keyConfidence: 0.9, structure: parts)
        analysis.chords = [ChordSpan(start: 0, end: 4, root: 0, minor: false), ChordSpan(start: 4, end: 8, root: 7, minor: false)]
        var a = Arrangement.from(parts, duration: 8)
        a.remove(1)                                    // Intro, Ritornello
        a.duplicate(1)                                 // Intro, Ritornello, Ritornello
        let out = a.analysis(analysis)
        XCTAssertEqual(out.bpm, 120)
        XCTAssertEqual(out.structure!.sections.map(\.label), ["Intro", "Ritornello", "Ritornello"])
        XCTAssertEqual(out.structure!.sections[2].start, 4, accuracy: 1e-9)
        XCTAssertEqual(out.structure!.beats.count, 12)
        XCTAssertEqual(out.structure!.downbeats.map { ($0 * 10).rounded() }, [0, 20, 40])
        XCTAssertEqual(out.chords!.map(\.root), [0, 7, 7])
        XCTAssertEqual(out.chords![1].start, 2, accuracy: 1e-9)
    }
}
