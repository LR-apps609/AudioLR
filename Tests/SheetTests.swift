import XCTest

final class SheetTests: XCTestCase {
    private func note(_ a: Double, _ b: Double, _ p: Int) -> Note { Note(start: a, end: b, pitch: p, velocity: 90) }

    func testNotesOnTheBeats() {
        // 120 BPM: un battito = 0,5 s, un sedicesimo = 0,125 s
        let s = Score.build([note(0, 0.5, 60), note(0.5, 1.0, 62), note(1.0, 2.0, 64)], structure: nil, bpm: 120, monophonic: true)
        XCTAssertEqual(s.bars.count, 1)
        XCTAssertEqual(s.bars[0].map(\.length), [4, 4, 8])
        XCTAssertEqual(s.bars[0].map(\.pitches), [[60], [62], [64]])
    }

    func testRestsAndTiesAcrossTheBar() {
        // Pausa di un battito, poi una nota che passa la stanghetta
        let s = Score.build([note(0.5, 3.0, 67)], structure: nil, bpm: 120, monophonic: true)
        XCTAssertEqual(s.bars.count, 2)
        XCTAssertEqual(s.bars[0].first?.pitches, [])
        XCTAssertTrue(s.bars[0].last!.tieOut)
        XCTAssertTrue(s.bars[1].first!.tieIn)
        XCTAssertEqual(s.bars[0].last!.length + s.bars[1].first!.length, 20)
        XCTAssertEqual(s.bars[1].reduce(0) { $0 + $1.length }, 16)
    }

    func testFollowsTheRealBeats() {
        // Battiti irregolari: la nota sul quinto battito va all'inizio della seconda battuta
        let beats = [0.0, 0.5, 1.1, 1.6, 2.2, 2.7, 3.3, 3.8, 4.4]
        let st = SongStructure(beats: beats, firstDownbeat: 0, beatsPerBar: 4, sections: [])
        let s = Score.build([note(0, 0.5, 60), note(2.2, 2.7, 62)], structure: st, bpm: 100, monophonic: true)
        XCTAssertEqual(s.bars[1].first?.pitches, [62])
        XCTAssertEqual(s.bars[1].first?.start, 0)
    }

    func testDurationsSplitIntoFigures() {
        XCTAssertEqual(Score.split(5).map { $0.length }, [4, 1])
        XCTAssertEqual(Score.split(12).map { $0.length }, [12])
        XCTAssertEqual(Score.split(15).map { $0.length }, [12, 3])
    }

    func testKeySignature() {
        XCTAssertEqual(Score(bars: [], bpm: 120, keyRoot: 7, minor: false).fifths, 1)    // Sol maggiore
        XCTAssertEqual(Score(bars: [], bpm: 120, keyRoot: 2, minor: true).fifths, -1)    // Re minore
        XCTAssertEqual(Score(bars: [], bpm: 120, keyRoot: 9, minor: true).fifths, 0)     // La minore
    }

    func testBassTabStaysLowOnTheNeck() {
        // Mi1 (corda vuota), La1, Do2, Re2
        let s = Score.build([note(0, 0.5, 28), note(0.5, 1, 33), note(1, 1.5, 36), note(1.5, 2, 38)], structure: nil, bpm: 120, monophonic: true)
        let p = Tab.positions(s, tuning: Tab.bass)[0].map { $0.first! }
        XCTAssertEqual(p.map { $0.string }, [3, 2, 2, 1])
        XCTAssertEqual(p.map { $0.fret }, [0, 0, 3, 0])
        let t = Tab.text(s, tuning: Tab.bass, title: "Prova")
        XCTAssertTrue(t.contains("E|0-------"), t)
        XCTAssertTrue(t.contains("G|"))
    }

    func testMusicXMLIsWellFormed() throws {
        let s = Score.build([note(0, 0.5, 64), note(0, 0.5, 67), note(0.5, 2.6, 69)], structure: nil, bpm: 120, monophonic: false)
        let d = MusicXML.data(s, kind: .guitar, title: "Prova & co", instrument: "Chitarra", program: 25)
        let doc = try XMLDocument(data: d)
        XCTAssertEqual(try doc.nodes(forXPath: "//part").count, 2)
        XCTAssertGreaterThan(try doc.nodes(forXPath: "//technical/fret").count, 0)
        XCTAssertGreaterThan(try doc.nodes(forXPath: "//chord").count, 0)
        XCTAssertGreaterThan(try doc.nodes(forXPath: "//tie").count, 0)
    }
}
