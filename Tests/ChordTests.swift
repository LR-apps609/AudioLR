import XCTest

final class ChordTests: XCTestCase {
    /// Una triade suonata con armonici (come un pianoforte semplice), più la fondamentale nel basso.
    private func song(_ chords: [(Int, Bool)], seconds each: Double = 2) -> (harmonic: [Float], bass: [Float]) {
        let sr = 44_100.0, n = Int(each * sr)
        var h = [Float](), b = [Float]()
        for (root, minor) in chords {
            let notes = [root, root + (minor ? 3 : 4), root + 7].map { 261.63 * pow(2, Double($0) / 12) }
            let low = 65.41 * pow(2, Double(root) / 12)
            for j in 0..<n {
                let t = Double(j) / sr
                var x = 0.0
                for f in notes { for k in 1...4 { x += sin(2 * .pi * f * Double(k) * t) / Double(k * k) } }
                h.append(Float(0.1 * x))
                b.append(Float(0.3 * sin(2 * .pi * low * t)))
            }
        }
        return (h, b)
    }

    func testFindsTheProgression() {
        // C – Am – F – G
        let s = song([(0, false), (9, true), (5, false), (7, false)])
        let beats = stride(from: 0.0, to: 8, by: 0.5).map { $0 }
        let c = Chords.detect(harmonic: s.harmonic, bass: s.bass, beats: beats, key: (0, false))
        XCTAssertEqual(c.map { $0.name() }, ["C", "Am", "F", "G"])
        XCTAssertEqual(c[1].start, 2, accuracy: 0.01)
        XCTAssertEqual(c.last!.end, 8, accuracy: 0.01)
    }

    func testSilenceIsNoChord() {
        var s = song([(2, true)])
        s.harmonic += [Float](repeating: 0, count: 44_100 * 2)
        s.bass += [Float](repeating: 0, count: 44_100 * 2)
        let c = Chords.detect(harmonic: s.harmonic, bass: s.bass, beats: nil, key: nil)
        XCTAssertEqual(c.map { $0.name() }, ["Dm", "—"])
    }

    func testNamesAndTransposition() {
        let a = ChordSpan(start: 0, end: 1, root: 9, minor: true)
        XCTAssertEqual(a.name(), "Am")
        XCTAssertEqual(a.name(italian: true), "Lam")
        XCTAssertEqual(a.name(shift: 2), "Bm")
        XCTAssertEqual(a.name(shift: -10), "Bm")
        XCTAssertEqual(ChordSpan(start: 0, end: 1, root: nil, minor: false).name(), "—")
    }

    func testDiatonicChords() {
        XCTAssertTrue(Chords.inKey(root: 9, minor: true, key: (0, false)))
        XCTAssertTrue(Chords.inKey(root: 7, minor: false, key: (9, true)))
        XCTAssertFalse(Chords.inKey(root: 1, minor: false, key: (0, false)))
    }
}
