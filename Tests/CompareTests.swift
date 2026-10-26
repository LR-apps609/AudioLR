import XCTest

final class CompareTests: XCTestCase {
    /// Una melodia di note tenute (con armonici), con pause tra una nota e l'altra.
    private func melody(_ notes: [Double], cents: Double = 0, delay: Double = 0, octave: Int = 0) -> [Float] {
        let sr = 44_100.0, note = 0.5, gap = 0.1
        var x = [Float](repeating: 0, count: Int((Double(notes.count) * (note + gap) + 1) * sr))
        for (k, m) in notes.enumerated() {
            let f = 440 * pow(2, (m - 69 + cents / 100) / 12 + Double(octave))
            let start = Int((Double(k) * (note + gap) + delay + 0.2) * sr)
            for i in 0..<Int(note * sr) {
                let t = Double(i) / sr
                let env = min(1, t / 0.01) * min(1, (note - t) / 0.02)
                x[start + i] = Float(0.3 * env * (sin(2 * .pi * f * t) + 0.4 * sin(4 * .pi * f * t)))
            }
        }
        return x
    }

    private let tune: [Double] = [60, 62, 64, 65, 67, 65, 64, 62, 60, 64, 67, 72]

    func testSameMelodyIsInTune() throws {
        let r = try Compare.run(take: melody(tune), original: melody(tune))
        XCTAssertGreaterThan(r.inTune, 0.95)
        XCTAssertEqual(r.cents, 0, accuracy: 5)
        XCTAssertEqual(r.offsetMs, 0, accuracy: 10)
    }

    func testSharpAndLate() throws {
        let r = try Compare.run(take: melody(tune, cents: 30, delay: 0.05), original: melody(tune))
        XCTAssertEqual(r.cents, 30, accuracy: 6)
        XCTAssertEqual(r.offsetMs, 50, accuracy: 15)
    }

    func testOutOfTune() throws {
        let r = try Compare.run(take: melody(tune, cents: 100), original: melody(tune))
        XCTAssertLessThan(r.inTune, 0.2)
    }

    func testOctaveCountsAsSameNote() throws {
        let r = try Compare.run(take: melody(tune, octave: 1), original: melody(tune))
        XCTAssertGreaterThan(r.inTune, 0.9)
    }

    func testSilenceIsAnError() {
        XCTAssertThrowsError(try Compare.run(take: [Float](repeating: 0, count: 44_100 * 3), original: melody(tune)))
    }

    func testYinFindsA440() {
        let sr = 11_025.0
        let x = (0..<2048).map { Float(sin(2 * .pi * 440 * Double($0) / sr)) }
        XCTAssertEqual(Compare.yin(x, 0, sr: sr) ?? 0, 440, accuracy: 2)
    }
}
