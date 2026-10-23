import XCTest
import AVFoundation

/// Il motore senza il modello di IA: spettrogramma, pezzi e ricucitura, lettura e scrittura dell'audio.
/// Il modello vero è provato a parte, quando viene convertito (Tools/convert_demucs.py).
final class EngineTests: XCTestCase {

    private func noise(_ n: Int, seed: UInt64 = 1) -> [Float] {
        var g = seed
        return (0..<n).map { _ in
            g = g &* 6364136223846793005 &+ 1442695040888963407
            return (Float(Int64(bitPattern: g >> 11) % 20000) - 10000) / 20000 * 0.8
        }
    }

    // MARK: Spettrogramma

    func testReflectPadLikePyTorch() {
        // torch.nn.functional.pad([1,2,3,4,5], (2,3), mode="reflect") = [3,2,1,2,3,4,5,4,3,2]
        XCTAssertEqual(Spectrogram.reflectPad([1, 2, 3, 4, 5], left: 2, right: 3), [3, 2, 1, 2, 3, 4, 5, 4, 3, 2])
    }

    /// Due note per canale, senza componente continua.
    private func tones(_ n: Int) -> [[Float]] {
        let t = (0..<n).map { Double($0) / 44_100 }
        return [t.map { Float(0.3 * sin(2 * .pi * 330 * $0) + 0.1 * sin(2 * .pi * 2500 * $0)) },
                t.map { Float(0.2 * sin(2 * .pi * 550 * $0) - 0.15 * sin(2 * .pi * 120 * $0)) }]
    }

    /// Andata e ritorno: identico, tranne i primi e gli ultimi ~35 ms, dove Demucs scarta due colonne per lato.
    func testRoundTripGivesBackTheSignal() {
        let s = Spectrogram()
        for n in [44_100, 343_980, 9_000] {
            let x = tones(n)[0]
            let z = s.forward(x)
            XCTAssertEqual(z.re.count, s.bins * s.frames(for: n))
            let y = s.inverse(re: z.re, im: z.im, length: n)
            XCTAssertEqual(y.count, n)
            var err: Float = 0
            for i in 2048..<(n - 2048) { err = max(err, abs(x[i] - y[i])) }
            XCTAssertLessThan(err, 1e-4, "lunghezza \(n)")
        }
    }

    func testSineLandsOnItsFrequency() {
        let s = Spectrogram()
        let bin = 100   // 100 × 44100 / 4096 ≈ 1077 Hz
        let n = 44_100
        let x = (0..<n).map { Float(sin(2 * Double.pi * Double(bin) * Double($0) / 4096)) * 0.5 }
        let z = s.forward(x)
        let le = s.frames(for: n)
        let t = le / 2
        var best = 0
        var bestMag: Float = 0
        for k in 0..<s.bins {
            let m = hypot(z.re[k * le + t], z.im[k * le + t])
            if m > bestMag { bestMag = m; best = k }
        }
        XCTAssertEqual(best, bin)
        // Normalizzato come torch.stft(normalized=True): ampiezza 0,5 × somma della finestra (2048) / 2 / √4096 = 8
        XCTAssertEqual(bestMag, 8, accuracy: 0.05)
    }

    // MARK: Pezzi e ricucitura

    func testOffsetsCoverTheSong() {
        let seg = 1000
        let starts = Separator.offsets(length: 3500, segment: seg, overlap: 0.25)
        XCTAssertEqual(starts, [0, 750, 1500, 2250, 3000])
        let w = Separator.weights(segment: seg)
        XCTAssertEqual(w.count, seg)
        XCTAssertEqual(w.max(), 1)
        XCTAssertGreaterThan(w.min()!, 0)
    }

    /// Un finto modello che dà a ogni strumento una parte fissa del pezzo che riceve:
    /// con la normalizzazione, i pezzi e la ricucitura giusti, ogni traccia è quella parte della canzone.
    final class FakeCore: SeparationCore {
        let segment: Int
        let sources = ["drums", "bass", "other", "vocals"]
        let share: [Float] = [0.1, 0.2, 0.3, 0.4]
        /// true: risponde con lo spettrogramma (e onda zero); false: con l'onda (e spettrogramma zero).
        let viaSpectrum: Bool
        init(segment: Int, viaSpectrum: Bool) { self.segment = segment; self.viaSpectrum = viaSpectrum }

        func run(spec: [Float], wave: [Float]) throws -> (spec: [Float], wave: [Float]) {
            var specOut = [Float](), waveOut = [Float]()
            for s in share {
                // Lavora sui valori normalizzati: con la canzone senza componente continua, la media è quasi zero
                if viaSpectrum {
                    specOut += spec.map { $0 * s }
                    waveOut += [Float](repeating: 0, count: wave.count)
                } else {
                    specOut += [Float](repeating: 0, count: spec.count)
                    waveOut += wave.map { $0 * s }
                }
            }
            return (specOut, waveOut)
        }
    }

    func testSeparationWithFakeModelKeepsTheShares() throws {
        let n = 30_000
        let mix = tones(n)
        for viaSpectrum in [true, false] {
            let sep = Separator(core: FakeCore(segment: 8192, viaSpectrum: viaSpectrum))
            var last = 0.0
            let out = try sep.separate(mix, progress: { last = $0 })
            XCTAssertEqual(last, 1, accuracy: 1e-9)
            XCTAssertEqual(out.count, 4)
            // Ogni traccia ≈ quota × canzone (tranne i primi e gli ultimi ~35 ms, come in Demucs)
            let inside = 2048..<(n - 2048)
            for (s, share) in [Float(0.1), 0.2, 0.3, 0.4].enumerated() {
                var err: Float = 0, peak: Float = 0
                for c in 0..<2 {
                    for i in inside {
                        err = max(err, abs(out[s][c][i] - share * mix[c][i]))
                        peak = max(peak, abs(mix[c][i]))
                    }
                }
                XCTAssertLessThan(err / peak, 0.05, "strumento \(s), \(viaSpectrum ? "spettrogramma" : "onda")")
            }
            // E la somma delle tracce torna la canzone
            var sumErr: Float = 0
            for c in 0..<2 {
                for i in inside {
                    let total = out[0][c][i] + out[1][c][i] + out[2][c][i] + out[3][c][i]
                    sumErr = max(sumErr, abs(total - mix[c][i]))
                }
            }
            XCTAssertLessThan(sumErr, 0.05)
        }
    }

    func testCancelStops() {
        let sep = Separator(core: FakeCore(segment: 8192, viaSpectrum: false))
        let mix = [noise(40_000), noise(40_000, seed: 2)]
        XCTAssertThrowsError(try sep.separate(mix, isCancelled: { true })) { e in
            XCTAssertTrue(e is CancellationError)
        }
    }

    // MARK: Audio

    func testWriteAndReadBackWithResample() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("audiolr-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Stereo a 44,1 kHz: torna uguale (a meno dei 24 bit)
        let n = 22_050
        let tone = (0..<n).map { Float(sin(2 * Double.pi * 440 * Double($0) / 44_100)) * 0.5 }
        let wav = dir.appendingPathComponent("prova.wav")
        try AudioIO.writeWAV([tone, tone.map { -$0 }], to: wav)
        let back = try AudioIO.read(wav)
        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back[0].count, n)
        XCTAssertEqual(back[0][1000], tone[1000], accuracy: 1e-4)
        XCTAssertEqual(back[1][1000], -tone[1000], accuracy: 1e-4)

        // Mono a 48 kHz: diventa stereo a 44,1 kHz, con la durata giusta
        let n48 = 48_000
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n48))!
        buf.frameLength = AVAudioFrameCount(n48)
        for i in 0..<n48 { buf.floatChannelData![0][i] = Float(sin(2 * Double.pi * 440 * Double(i) / 48_000)) * 0.5 }
        let mono = dir.appendingPathComponent("mono48.wav")
        do {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                                           AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            let f = try AVAudioFile(forWriting: mono, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try f.write(from: buf)
        }
        let st = try AudioIO.read(mono)
        XCTAssertEqual(st.count, 2)
        XCTAssertEqual(Double(st[0].count), 44_100, accuracy: 50)
        XCTAssertEqual(st[0], st[1])
    }
}
