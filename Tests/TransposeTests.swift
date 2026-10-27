import XCTest

final class TransposeTests: XCTestCase {
    private func sine(_ hz: Double, seconds: Double = 3) -> [[Float]] {
        let n = Int(seconds * 44_100)
        let x = (0..<n).map { Float(0.4 * sin(2 * .pi * hz * Double($0) / 44_100)) }
        return [x, x]
    }

    /// L'altezza media del pezzo centrale (YIN del confronto con l'originale).
    private func pitch(_ a: [[Float]]) -> Double {
        let x = Compare.decimate(a[0])
        let sr = Compare.rate / Double(Compare.down)
        var found: [Double] = []
        for t in stride(from: x.count / 4, to: 3 * x.count / 4, by: 200) {
            if let hz = Compare.yin(x, t, sr: sr) { found.append(hz) }
        }
        found.sort()
        return found[found.count / 2]
    }

    func testShiftUpAndDownKeepsLength() throws {
        let a = sine(440)
        let up = try PitchShift.apply(a, semitones: 2)
        XCTAssertEqual(up[0].count, a[0].count)
        XCTAssertEqual(pitch(up), 440 * pow(2, 2.0 / 12), accuracy: 6)
        let down = try PitchShift.apply(a, semitones: -5)
        XCTAssertEqual(pitch(down), 440 * pow(2, -5.0 / 12), accuracy: 5)
    }

    func testZeroIsUntouched() throws {
        let a = sine(330)
        XCTAssertEqual(try PitchShift.apply(a, semitones: 0), a)
    }

    func testShiftStaysAligned() throws {
        // Un colpo a 1 s resta a 1 s dopo lo spostamento (il ritardo dell'effetto è tolto)
        var a = [[Float]](repeating: [Float](repeating: 0, count: 44_100 * 2), count: 2)
        for i in 0..<2000 { let v = Float(0.8 * sin(Double(i) * 0.2) * exp(-Double(i) / 400)); a[0][44_100 + i] = v; a[1][44_100 + i] = v }
        let s = try PitchShift.apply(a, semitones: 3)
        var best = 0, m: Float = 0
        for (i, v) in s[0].enumerated() where abs(v) > m { m = abs(v); best = i }
        XCTAssertEqual(Double(best) / 44_100, 1.0, accuracy: 0.03)
    }

    func testKeyNames() {
        XCTAssertEqual(Transpose.keyName(root: 0, minor: false, shift: 2), "Re maggiore")
        XCTAssertEqual(Transpose.keyName(root: 9, minor: true, shift: -2), "Sol minore")
        XCTAssertEqual(Transpose.keyName(root: 11, minor: false, shift: 1), "Do maggiore")
        XCTAssertEqual(Transpose.noteName(60), "Do4")
        XCTAssertEqual(Transpose.noteName(69), "La4")
        XCTAssertEqual(PitchShift.label(-3), "−3")
    }

    func testCapoForHardKeys() {
        // Si maggiore: B F♯ G♯m E → con il capotasto al 4° tasto si suonano G D Em C
        let chords = [(11, false), (6, false), (8, true), (4, false)].enumerated().map {
            ChordSpan(start: Double($0.offset) * 2, end: Double($0.offset + 1) * 2, root: $0.element.0, minor: $0.element.1)
        }
        let c = Transpose.capo(chords: chords, shift: 0)
        XCTAssertEqual(c?.capo, 4)
        XCTAssertEqual(c?.shapes, ["G", "D", "Em", "C"])
        // Do maggiore è già facile: niente capotasto
        let easy = [(0, false), (7, false), (9, true), (5, false)].enumerated().map {
            ChordSpan(start: Double($0.offset), end: Double($0.offset + 1), root: $0.element.0, minor: $0.element.1)
        }
        XCTAssertNil(Transpose.capo(chords: easy, shift: 0))
    }

    func testSuggestForMyVoice() {
        XCTAssertEqual(Transpose.suggest(songHigh: 72, myHigh: 67), -5)     // Do5 → Sol4
        XCTAssertEqual(Transpose.suggest(songHigh: 60, myHigh: 79), 7)      // al massimo +7
    }

    func testVocalRangeOfAMelody() {
        // Una melodia da La3 (57) a Mi4 (64)
        var x = [Float]()
        for m in [57, 59, 60, 62, 64, 62, 60, 59] {
            let f = 440 * pow(2, Double(m - 69) / 12)
            x += (0..<22_050).map { Float(0.3 * sin(2 * .pi * f * Double($0) / 44_100)) }
        }
        let r = Transpose.vocalRange(x)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.low, 57.5, accuracy: 1.2)
        XCTAssertEqual(r!.high, 64, accuracy: 0.6)
    }
}
