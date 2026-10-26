import XCTest

/// Sala prove: velocità, tono e ripetizione restano coerenti anche senza audio.
@MainActor
final class PracticeTests: XCTestCase {

    func testPracticeSettingsReset() {
        let m = MixPlayer()
        m.rate = 0.75
        m.semitones = -3
        XCTAssertEqual(m.rate, 0.75)
        XCTAssertEqual(m.semitones, -3)
        m.resetPractice()
        XCTAssertEqual(m.rate, 1)
        XCTAssertEqual(m.semitones, 0)
        XCTAssertFalse(m.isLooping)
    }

    func testLoopNeedsAnEndAfterTheStart() {
        let m = MixPlayer()
        m.markLoopStart()                // A a 0 s
        XCTAssertEqual(m.loopA, 0)
        m.markLoopEnd()                  // B nello stesso punto: non vale
        XCTAssertNil(m.loopB)
        XCTAssertFalse(m.isLooping)
        m.clearLoop()
        XCTAssertNil(m.loopA)
    }

    /// Rampa di velocità: +5% a ogni giro del passaggio, fino al 100% e non oltre.
    func testRampSteps() {
        var r = MixPlayer.rampStart
        var giri: [Double] = [r]
        while r < MixPlayer.rampTarget { r = MixPlayer.rampNext(r); giri.append(r) }
        XCTAssertEqual(giri, [0.7, 0.75, 0.8, 0.85, 0.9, 0.95, 1.0])
        XCTAssertEqual(MixPlayer.rampNext(1.0), 1.0, "al traguardo resta lì")
        XCTAssertEqual(MixPlayer.rampNext(0.98), 1.0)
    }

    // MARK: Metronomo e conteggio (0.26)

    private func grid() -> SongStructure {
        SongStructure(beats: (0..<16).map { Double($0) * 0.5 + 0.2 }, firstDownbeat: 1, beatsPerBar: 4,
                      sections: [SongSection(start: 0.7, end: 4.7, label: "Strofa", group: 0)])
    }

    func testClicksAccentTheFirstBeatOfTheBar() {
        let c = MixPlayer.clicks(grid(), from: 0, to: 3)
        XCTAssertEqual(c.map(\.time), [0.2, 0.7, 1.2, 1.7, 2.2, 2.7])
        XCTAssertEqual(c.map(\.strong), [false, true, false, false, false, true])
    }

    func testClicksOnlyInsideThePassage() {
        let c = MixPlayer.clicks(grid(), from: 1.2, to: 2.2)
        XCTAssertEqual(c.map(\.time), [1.2, 1.7])
    }

    func testCountInFollowsTheBeats() {
        XCTAssertEqual(MixPlayer.beatPeriod(grid(), bpm: 90, at: 3), 0.5, accuracy: 1e-9)
        // Senza battiti si usa il tempo medio
        XCTAssertEqual(MixPlayer.beatPeriod(nil, bpm: 120, at: 3), 0.5, accuracy: 1e-9)
        XCTAssertEqual(MixPlayer.beatPeriod(nil, bpm: 0, at: 3), 0.5, accuracy: 1e-9)
    }
}
