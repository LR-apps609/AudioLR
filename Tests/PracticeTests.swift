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
}
