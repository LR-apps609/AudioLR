import XCTest

/// Le regole delle tre animazioni (uguali a windows/ui/core/anim.js).
final class AnimationTests: XCTestCase {
    func testPulseOnRealBeats() {
        let beats = [0.5, 1.0, 1.5, 2.0]
        XCTAssertEqual(BeatPulse.pulse(at: 0.2, beats: beats, bpm: 120), 0, "prima del primo battito: fermo")
        XCTAssertEqual(BeatPulse.pulse(at: 1.0, beats: beats, bpm: nil), 1, accuracy: 1e-9, "sul battito: pieno")
        XCTAssertGreaterThan(BeatPulse.pulse(at: 1.05, beats: beats, bpm: nil), BeatPulse.pulse(at: 1.15, beats: beats, bpm: nil), "poi scende")
        XCTAssertEqual(BeatPulse.pulse(at: 1.3, beats: beats, bpm: nil), 0, "tra un battito e l'altro: fermo")
        XCTAssertEqual(BeatPulse.pulse(at: 3.0, beats: beats, bpm: nil), 0, "dopo l'ultimo battito: fermo")
    }

    func testPulseFromBpmWithoutBeats() {
        // 120 BPM: un battito ogni mezzo secondo, da zero
        XCTAssertEqual(BeatPulse.pulse(at: 1.0, beats: [], bpm: 120), 1, accuracy: 1e-9)
        XCTAssertEqual(BeatPulse.pulse(at: 1.4, beats: [], bpm: 120), 0)
        XCTAssertEqual(BeatPulse.pulse(at: 1.0, beats: [], bpm: nil), 0, "né battiti né BPM: fermo")
    }

    func testCelebrationTiming() {
        XCTAssertEqual(Celebration.progress(elapsed: 0), 0)
        XCTAssertEqual(Celebration.progress(elapsed: Celebration.duration / 2) ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertNil(Celebration.progress(elapsed: Celebration.duration), "finita: si toglie")
        XCTAssertNil(Celebration.progress(elapsed: -1))
        let c = Celebration.confetti()
        XCTAssertEqual(c.count, 24)
        XCTAssertEqual(Set(c.map(\.color)), Set(0..<6), "tutti i colori delle tracce")
        XCTAssertEqual(Celebration.easeOut(1), 1, accuracy: 1e-9)
    }
}
