import XCTest

/// Tempo e tonalità su segnali di cui si sa la risposta.
final class AnalysisTests: XCTestCase {
    private let rate = 44_100.0

    private func clicks(bpm: Double, seconds: Double = 20) -> [Float] {
        let n = Int(seconds * rate)
        var x = [Float](repeating: 0, count: n)
        var g = SystemRandomNumberGenerator()
        let period = 60 / bpm
        for i in 0..<Int(seconds / period) {
            let s = Int(Double(i) * period * rate)
            for j in 0..<min(4000, n - s) {
                let t = Double(j) / rate
                let noise = Double.random(in: -1...1, using: &g)
                x[s + j] += Float(sin(2 * .pi * 60 * t) * exp(-t * 30) * (i % 2 == 0 ? 1 : 0.5) + 0.3 * noise * exp(-t * 80))
            }
        }
        return x
    }

    private func chords(_ prog: [[Int]], seconds: Double = 2) -> [Float] {
        var x: [Float] = []
        for _ in 0..<2 {
            for chord in prog {
                for j in 0..<Int(seconds * rate) {
                    let t = Double(j) / rate
                    var v = 0.0
                    for m in chord {
                        let f = 440 * pow(2, Double(m - 69) / 12)
                        for k in 1...3 { v += sin(2 * .pi * f * Double(k) * t) / Double(k) }
                    }
                    x.append(Float(v * 0.1))
                }
            }
        }
        return x
    }

    func testTempo() {
        for bpm in [128.0, 92, 75] {
            XCTAssertEqual(Analysis.tempo(clicks(bpm: bpm)), bpm, accuracy: 1.5, "\(bpm) BPM")
        }
    }

    func testKey() {
        let cMajor = Analysis.key(chords([[60, 64, 67], [65, 69, 72], [67, 71, 74], [60, 64, 67]]))
        XCTAssertEqual(cMajor.root, 0)
        XCTAssertFalse(cMajor.minor)
        let aMinor = Analysis.key(chords([[57, 60, 64], [62, 65, 69], [64, 68, 71], [57, 60, 64]]))
        XCTAssertEqual(aMinor.root, 9)
        XCTAssertTrue(aMinor.minor)
    }

    func testNames() {
        let a = SongAnalysis(bpm: 127.6, keyRoot: 9, minor: true, keyConfidence: 0.8)
        XCTAssertEqual(a.keyName, "La minore")
        XCTAssertEqual(a.keyShort, "Am")
        XCTAssertEqual(a.camelot, "8A")
        XCTAssertEqual(a.bpmText, "128 BPM")
        XCTAssertEqual(SongAnalysis(bpm: 120, keyRoot: 0, minor: false, keyConfidence: 1).camelot, "8B")
        XCTAssertEqual(SongAnalysis(bpm: 120, keyRoot: 7, minor: false, keyConfidence: 1).camelot, "9B")
        XCTAssertEqual(SongAnalysis(bpm: 120, keyRoot: 4, minor: true, keyConfidence: 1).camelot, "9A")
    }

    func testAnalyzeUsesDrumsForTempo() {
        let drums = clicks(bpm: 100, seconds: 12)
        let harm = chords([[60, 64, 67], [65, 69, 72], [67, 71, 74]], seconds: 2)
        let n = min(drums.count, harm.count)
        let stems: [[[Float]]] = [[Array(drums[..<n]), Array(drums[..<n])], [Array(harm[..<n]), Array(harm[..<n])]]
        let a = Analysis.analyze(stems, sources: ["drums", "other"])
        XCTAssertNotNil(a)
        XCTAssertEqual(a?.bpm ?? 0, 100, accuracy: 1.5)
        XCTAssertEqual(a?.keyRoot, 0)
    }
}
