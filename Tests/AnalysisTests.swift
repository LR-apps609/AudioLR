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

/// Battiti, battute e parti su canzoni finte: tempo, primo battito della battuta e ritornello che torna.
final class RhythmTests: XCTestCase {
    let sr = 44_100

    /// Un colpo corto (rumore che si spegne) a ogni battito; il primo di ogni battuta più forte e più basso.
    private func song(bpm: Double, seconds: Double, offsetBeats: Int = 0) -> (drums: [Float], bass: [Float]) {
        let n = Int(seconds * Double(sr))
        var drums = [Float](repeating: 0, count: n), bass = [Float](repeating: 0, count: n)
        let period = 60 / bpm
        var g = SystemRandomNumberGenerator()
        var k = 0
        var t = 0.2
        while t < seconds - 0.3 {
            let s = Int(t * Double(sr))
            let down = (k + offsetBeats) % 4 == 0
            for i in 0..<2000 where s + i < n {
                let env = Float(exp(-Double(i) / 300))
                drums[s + i] += (down ? 0.9 : 0.5) * env * Float.random(in: -1...1, using: &g)
                if down { bass[s + i] += 0.6 * env * Float(sin(2 * Double.pi * 55 * Double(i) / Double(sr))) }
            }
            k += 1
            t += period
        }
        return (drums, bass)
    }

    func testBeatsFollowTheTempo() throws {
        let (drums, bass) = song(bpm: 120, seconds: 30)
        let s = try XCTUnwrap(Rhythm.structure(rhythm: drums, low: bass, harmonic: bass, vocal: [Float](repeating: 0, count: drums.count),
                                               all: drums, bpm: 120))
        let gaps = zip(s.beats.dropFirst(), s.beats).map { $0 - $1 }
        let median = gaps.sorted()[gaps.count / 2]
        XCTAssertEqual(median, 0.5, accuracy: 0.02, "a 120 BPM un battito ogni mezzo secondo")
        XCTAssertGreaterThan(s.beats.count, 50)
    }

    func testDownbeatIsTheStrongBeat() throws {
        // Il primo colpo della canzone è il terzo della battuta: il primo battito vero è il secondo colpo dopo
        let (drums, bass) = song(bpm: 100, seconds: 40, offsetBeats: 2)
        let s = try XCTUnwrap(Rhythm.structure(rhythm: drums, low: bass, harmonic: bass, vocal: [Float](repeating: 0, count: drums.count),
                                               all: drums, bpm: 100))
        // Ogni primo battito della battuta deve cadere dove c'è il basso
        let hits = s.downbeats.filter { t in
            let i = Int(t * Double(sr))
            return Rhythm.rms(bass, i - 500, i + 1500) > 0.05
        }
        XCTAssertGreaterThan(Double(hits.count) / Double(max(1, s.downbeats.count)), 0.8)
    }

    func testSectionLabelsFromRepeats() {
        // Strofa (voce piano), ritornello (voce forte), strofa, ritornello: il gruppo che torna più forte è il ritornello
        let groups = [0, 1, 0, 1, 2]
        let vocal = [0.3, 0.5, 0.3, 0.5, 0.0]
        let loud = [0.2, 0.6, 0.2, 0.6, 0.1]
        XCTAssertEqual(Rhythm.labels(groups: groups, vocal: vocal, loud: loud), ["Strofa", "Ritornello", "Strofa", "Ritornello", "Finale"])
        XCTAssertEqual(Rhythm.labels(groups: [3, 0, 1, 0, 1], vocal: [0, 0.3, 0.5, 0.3, 0.5], loud: [0.1, 0.2, 0.6, 0.2, 0.6]).first, "Intro")
    }

    func testBoundariesAtChanges() {
        // Due blocchi di 8 battute molto diversi: il confine cade sull'ottava
        let a = [1.0, 0, 0], b = [0, 1.0, 0]
        let feats = Array(repeating: a, count: 8) + Array(repeating: b, count: 8)
        var sim = [[Double]](repeating: [Double](repeating: 0, count: 16), count: 16)
        for i in 0..<16 { for j in 0..<16 { sim[i][j] = Rhythm.cosine(feats[i], feats[j]) } }
        XCTAssertEqual(Rhythm.boundaries(Rhythm.novelty(sim)), [0, 8, 16])
    }
}
