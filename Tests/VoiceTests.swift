import XCTest
import CoreML

/// Il modello voce RoFormer: STFT come torch, bande e maschere, ricucitura dei pezzi;
/// poi, se il modello è pubblicato, il confronto con il RoFormer originale.
final class VoiceTests: XCTestCase {

    private func tones(_ n: Int) -> [[Float]] {
        let t = (0..<n).map { Double($0) / 44_100 }
        return [t.map { Float(0.3 * sin(2 * .pi * 330 * $0) + 0.1 * sin(2 * .pi * 2500 * $0)) },
                t.map { Float(0.2 * sin(2 * .pi * 550 * $0) - 0.15 * sin(2 * .pi * 120 * $0)) }]
    }

    func testPlainSTFTRoundTrip() {
        let s = PlainSTFT(nfft: 2048, hop: 441)
        let x = tones(8820)[0]
        let z = s.forward(x)
        let T = s.frames(for: x.count)
        XCTAssertEqual(T, 21)
        XCTAssertEqual(z.re.count, 1025 * T)
        let y = s.inverse(re: z.re, im: z.im, frames: T, length: x.count)
        var err: Float = 0
        for i in 0..<x.count { err = max(err, abs(x[i] - y[i])) }
        XCTAssertLessThan(err, 1e-4)
    }

    func testPlainSTFTScaleLikeTorch() {
        // Seno a una frequenza esatta: torch.stft non normalizzata dà ampiezza/2 × somma della finestra (1024)
        let s = PlainSTFT(nfft: 2048, hop: 441)
        let k = 64
        let x = (0..<8820).map { Float(sin(2 * Double.pi * Double(k) * Double($0) / 2048)) }
        let z = s.forward(x)
        let T = s.frames(for: x.count), t = T / 2
        XCTAssertEqual(hypot(z.re[k * T + t], z.im[k * T + t]), 512, accuracy: 1)
    }

    /// Bande finte che coprono ogni frequenza una volta: con maschera 1 la voce deve essere la canzone intera.
    private func identity(chunk: Int) -> VoiceRoFormer {
        let F = 1025
        let cfg = RoFormerConfig(n_fft: 2048, hop: 441, chunk: chunk, frames: chunk / 441 + 1,
                                 freq_indices: Array(0..<(2 * F)), num_bands_per_freq: [Double](repeating: 1, count: F),
                                 sources: ["vocals"])
        let v = VoiceRoFormer(model: nil, config: cfg)
        v.fakeNetwork = { x in
            var m = [Float](repeating: 0, count: x.count)
            for i in stride(from: 0, to: m.count, by: 2) { m[i] = 1 }
            return m
        }
        return v
    }

    func testMaskOfOneGivesBackTheMix() throws {
        let v = identity(chunk: 8820)
        let piece = tones(8820)
        let out = try v.runChunk(piece)
        for c in 0..<2 {
            var err: Float = 0
            for i in 0..<8820 { err = max(err, abs(out[c][i] - piece[c][i])) }
            XCTAssertLessThan(err, 1e-4, "canale \(c)")
        }
    }

    func testChunksAreStitchedBack() throws {
        let v = identity(chunk: 8820)
        let mix = tones(30_000)
        var last = 0.0
        let out = try v.separate(mix, progress: { last = $0 })
        XCTAssertEqual(last, 1, accuracy: 1e-9)
        var err: Float = 0
        for c in 0..<2 { for i in 0..<30_000 { err = max(err, abs(out[c][i] - mix[c][i])) } }
        XCTAssertLessThan(err, 1e-3)
    }

    func testTwoWorkersGiveTheSameResultAsOne() throws {
        let one = identity(chunk: 8820), a = identity(chunk: 8820), b = identity(chunk: 8820)
        let mix = tones(60_000)
        let single = try one.separate(mix)
        let double = try a.separate(mix, helpers: [b])
        var err: Float = 0
        for c in 0..<2 { for i in 0..<60_000 { err = max(err, abs(single[c][i] - double[c][i])) } }
        XCTAssertLessThan(err, 1e-5, "dividere i pezzi tra due copie non cambia il risultato")
        // Anche con meno sovrapposizione («Rapida») la canzone torna intera
        a.overlap = 1.5
        let fast = try a.separate(mix, helpers: [b])
        var e2: Float = 0
        for c in 0..<2 { for i in 0..<60_000 { e2 = max(e2, abs(fast[c][i] - mix[c][i])) } }
        XCTAssertLessThan(e2, 1e-3)
    }

    func testImplausibleVoiceIsCaught() {
        let v = identity(chunk: 8820)
        v.fakeNetwork = { x in [Float](repeating: 40, count: x.count) }
        XCTAssertThrowsError(try v.separate(tones(20_000))) { XCTAssertTrue($0 is ImplausibleResult) }
    }

    func testHamming() {
        let w = VoiceRoFormer.hamming(5)
        XCTAssertEqual(w[0], 0.08, accuracy: 1e-6)
        XCTAssertEqual(w[2], 1, accuracy: 1e-6)
    }

    // MARK: Più strumenti (BS-RoFormer SW)

    func testSeveralStemsFromOneModel() throws {
        // Due strumenti finti: il primo prende tutto (maschera 1), il secondo niente
        let F = 1025, chunk = 8820
        let cfg = RoFormerConfig(n_fft: 2048, hop: 441, chunk: chunk, frames: chunk / 441 + 1,
                                 freq_indices: Array(0..<(2 * F)), num_bands_per_freq: [Double](repeating: 1, count: F),
                                 sources: ["other", "vocals"])
        let v = RoFormer(model: nil, config: cfg)
        v.fakeNetwork = { x in
            var m = [Float](repeating: 0, count: x.count * 2)
            for i in stride(from: 0, to: x.count, by: 2) { m[i] = 1 }
            return m
        }
        XCTAssertEqual(v.stemCount, 2)
        XCTAssertEqual(v.primary, 1, "runChunk/separate restituiscono la voce")
        let mix = tones(20_000)
        let all = try v.separateAll(mix)
        XCTAssertEqual(all.count, 2)
        var err: Float = 0, rest: Float = 0
        for c in 0..<2 { for i in 0..<20_000 { err = max(err, abs(all[0][c][i] - mix[c][i])); rest = max(rest, abs(all[1][c][i])) } }
        XCTAssertLessThan(err, 1e-3)
        XCTAssertLessThan(rest, 1e-6)
        XCTAssertEqual(try v.separate(mix)[0], all[1][0])
    }

    func testArrangeSWStems() {
        let one = [[Float]](repeating: [1, 1], count: 2)
        let names = ["bass", "drums", "other", "vocals", "guitar", "piano"]
        let audio = names.map { _ in one }
        let voice = [[Float]](repeating: [5, 5], count: 2)
        let (k1, a1) = SeparationJob.arrange(names, audio, voice: voice, split: true)
        XCTAssertEqual(k1, ["vocals", "drums", "bass", "guitar", "piano", "other"])
        XCTAssertEqual(a1[0], voice, "la voce viene dal modello voce, non da SW")
        let (k2, a2) = SeparationJob.arrange(names, audio, voice: voice, split: false)
        XCTAssertEqual(k2, ["vocals", "drums", "bass", "other"])
        XCTAssertEqual(a2[3][0], [3, 3], "chitarra e piano finiscono in «Altri strumenti»")
        let (k3, _) = SeparationJob.arrange(names, audio, voice: nil, split: true)
        XCTAssertEqual(k3.first, "vocals", "senza modello voce si usa la voce di SW")
    }

    func testStemsShownForQuality() {
        XCTAssertEqual(Theme.stems(for: .fast, split: true), ["vocals", "drums", "bass", "other"])
        XCTAssertEqual(Theme.stems(for: .best, split: true).count, 6)
        XCTAssertEqual(Theme.stems(for: .best, split: false).count, 4)
        XCTAssertEqual(Quality.best.allModels, ["StrumentiSW2"], "Massima: un solo modello, SW")
        XCTAssertTrue(Quality.best.everyModel.contains("HTDemucsFT-0"))
        XCTAssertEqual(Quality.studio.allModels, ["VoceStudio3", "StrumentiSW2", "HTDemucsFT-1"], "Studio: il basso da Demucs")
        XCTAssertNil(Quality.best.bassModel, "Massima resta con SW da solo")
        // La seconda voce di Studio solo se scelta nelle Impostazioni
        let old = UserDefaults.standard.object(forKey: Prefs.doubleVoiceKey)
        UserDefaults.standard.set(true, forKey: Prefs.doubleVoiceKey)
        XCTAssertEqual(Quality.studio.allModels, ["VoceStudio3", "VoceRoFormer9", "StrumentiSW2", "HTDemucsFT-1"])
        XCTAssertNil(Quality.best.secondVoice)
        UserDefaults.standard.set(old, forKey: Prefs.doubleVoiceKey)
        XCTAssertEqual(Quality.fallbackVoice(for: "VoceStudio3"), "VoceRoFormer9")
        XCTAssertEqual(Quality.fallbackVoice(for: "VoceRoFormer9"), "VoceRoFormer")
        XCTAssertNil(Quality.fallbackVoice(for: "VoceRoFormer"))
        XCTAssertTrue(Quality.studio.everyModel.contains("VoceRoFormer"), "i modelli di riserva si dimenticano anche loro")
        XCTAssertEqual(Theme.stems(for: .studio, split: true).count, 6)
    }

    // MARK: Con il modello vero

    func testInstrumentsMatchSW() async throws { try await matchesOriginal("StrumentiSW2", label: "Strumenti SW") }

    func testStudioVoiceMatchesBSRoFormer() async throws { try await matchesOriginal("VoceStudio3", label: "Voce Studio") }

    func testLeadVoiceMatchesKaraokeRoFormer() async throws { try await matchesOriginal("VoceCori3", label: "Voce e cori") }

    /// Un pezzo di prova separato dall'app e dal modello originale (Tools/convert_roformer.py): tutti gli strumenti insieme.
    private func matchesOriginal(_ name: String, label: String) async throws {
        // Sul Mac di GitHub (senza Neural Engine) i modelli grandi impiegano anche 20 minuti per un pezzo
        executionTimeAllowance = 5400
        let (data, resp) = try await EndToEndTests.fixture("\(name)-prova.f32")
        guard (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 8 else { throw XCTSkip("\(name) non ancora pubblicato") }
        let all: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let n = Int(all[0]), S = Int(all[1])
        let mix = [Array(all[2..<(2 + n)]), Array(all[(2 + n)..<(2 + 2 * n)])]
        let model: RoFormer
        do { model = try await ModelStore.shared.roformer(name) { _ in } } catch { throw XCTSkip("\(name) non disponibile") }
        XCTAssertEqual(model.config.chunk, n)
        XCTAssertEqual(model.stemCount, S)
        let start = Date()
        let out = try model.runChunkAll(mix)
        var ref: [Float] = [], est: [Float] = []
        for k in 0..<S {
            for c in 0..<2 {
                let o = 2 + 2 * n + (k * 2 + c) * n
                ref += all[o..<(o + n)]
                est += out[k][c]
            }
        }
        let q = EndToEndTests.snr(ref, est)
        let line = String(format: "\(label): %.1f dB dal modello originale, pezzo da %.1f s in %.1f s",
                          q, Double(n) / 44_100, Date().timeIntervalSince(start))
        print(line)
        let path = "/tmp/audiolr-passi.txt"
        let old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? (old + line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertGreaterThan(q, 25, "\(label): l'app dà un risultato diverso dal modello originale")
    }

    func testVoiceMatchesRoFormer() async throws {
        executionTimeAllowance = 600
        let (data, resp) = try await EndToEndTests.fixture("VoceRoFormer9-prova.f32")
        guard (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 8 else { throw XCTSkip("modello voce non ancora pubblicato") }
        let all: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let n = Int(all[0])
        let mix = [Array(all[2..<(2 + n)]), Array(all[(2 + n)..<(2 + 2 * n)])]
        let ref = [Array(all[(2 + 2 * n)..<(2 + 3 * n)]), Array(all[(2 + 3 * n)..<(2 + 4 * n)])]
        let voice: VoiceRoFormer
        do { voice = try await ModelStore.shared.voice { _ in } } catch { throw XCTSkip("modello voce non disponibile") }
        XCTAssertEqual(voice.config.chunk, n)
        let start = Date()
        let out = try voice.runChunk(mix)
        let q = EndToEndTests.snr(ref[0] + ref[1], out[0] + out[1])
        let line = String(format: "Voce RoFormer: %.1f dB dal modello originale, pezzo da %.1f s in %.1f s",
                          q, Double(n) / 44_100, Date().timeIntervalSince(start))
        print(line)
        let path = "/tmp/audiolr-passi.txt"
        let old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? (old + line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertGreaterThan(q, 25, "la voce dell'app è diversa da quella del RoFormer originale")
        EndToEndTests.checkChannels("voce", ref: ref, est: out, mix: mix)
    }
}
