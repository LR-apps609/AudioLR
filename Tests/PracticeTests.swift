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
}
