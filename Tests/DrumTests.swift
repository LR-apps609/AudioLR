import XCTest

/// La batteria divisa (MDX23C DrumSep): spettri, ricucitura, mixer; poi il confronto con il modello originale.
final class DrumTests: XCTestCase {

    private func beat(_ n: Int) -> [[Float]] {
        let t = (0..<n).map { Double($0) / 44_100 }
        return [t.map { Float(0.5 * sin(2 * .pi * 60 * $0) * exp(-($0.truncatingRemainder(dividingBy: 0.5)) * 8)) },
                t.map { Float(0.4 * sin(2 * .pi * 200 * $0) * exp(-($0.truncatingRemainder(dividingBy: 0.25)) * 12)) }]
    }

    /// Rete finta: la prima parte è tutta la batteria, le altre silenzio.
    private func identity() -> DrumSplitter {
        let chunk = 512 * 63
        let cfg = SpectralConfig(n_fft: 2048, hop: 512, dim_f: 1024, chunk: chunk, frames: chunk / 512 + 1,
                                 sources: ["kick", "snare", "toms"])
        let d = DrumSplitter(model: nil, config: cfg)
        d.fakeNetwork = { x in x + [Float](repeating: 0, count: x.count * 2) }
        return d
    }

    func testIdentitySplitGivesBackTheDrums() throws {
        let d = identity()
        let drums = beat(100_000)
        let parts = try d.separate(drums)
        XCTAssertEqual(parts.count, 3)
        for c in 0..<2 {
            XCTAssertGreaterThan(EndToEndTests.snr(drums[c], parts[0][c]), 40, "canale \(c)")
            XCTAssertLessThan(parts[1][c].map(abs).max() ?? 1, 1e-6)
        }
    }

    func testMixerUsesDrumPartsInsteadOfDrums() {
        func stem(_ k: String) -> Stem { Stem(key: k, name: k, symbol: "", url: URL(fileURLWithPath: "/tmp/\(k).wav")) }
        let base = ["vocals", "drums", "bass", "other", "instrumental"].map(stem)
        XCTAssertEqual(MixPlayer.mixable(base).map(\.key), ["vocals", "drums", "bass", "other"])
        let split = base + ["kick", "snare"].map(stem)
        XCTAssertEqual(MixPlayer.mixable(split).map(\.key), ["vocals", "bass", "other", "kick", "snare"])
        XCTAssertLessThan(Stem.info("kick").order, Stem.info("bass").order, "le parti della batteria vengono subito dopo la batteria")
        XCTAssertGreaterThan(Stem.info("kick").order, Stem.info("drums").order)
        XCTAssertEqual(Stem.info("hh").name, "Charleston")
    }

    func testVoiceSplitInMixer() {
        func stem(_ k: String) -> Stem { Stem(key: k, name: k, symbol: "", url: URL(fileURLWithPath: "/tmp/\(k).wav")) }
        let stems = ["vocals", "drums", "bass", "lead", "backing", "instrumental"].map(stem)
        XCTAssertEqual(MixPlayer.mixable(stems).map(\.key), ["drums", "bass", "lead", "backing"])
        var m = MixState()
        m.apply(.backing)
        XCTAssertEqual(m.effectiveGain("lead"), 0)
        XCTAssertEqual(m.effectiveGain("backing"), 1)
        XCTAssertEqual(m.preset, .backing)
        XCTAssertEqual(MixPlayer.exportName(state: m, title: "Brano"), "Brano – Karaoke con cori")
        m.apply(.karaoke)
        XCTAssertEqual(m.effectiveGain("backing"), 0)
        XCTAssertEqual(m.effectiveGain("vocals"), 0)
        // Muto a mano sulla voce intera: è ancora «Karaoke»
        m.apply(.all)
        m.muted = ["vocals"]
        XCTAssertEqual(m.preset, .karaoke)
        m.muted = []
        m.solo = ["lead", "backing"]
        XCTAssertEqual(m.preset, .voice)
        XCTAssertLessThan(Stem.info("backing").order, Stem.info("drums").order)
    }

    func testDrumPartsAreFoundAgainInTheLibrary() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("drums-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["Voce", "Batteria", "Cassa", "Charleston"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent("Song – \(name).wav").path, contents: Data())
        }
        XCTAssertEqual(History.stems(in: dir, title: "Song").map(\.key), ["vocals", "drums", "kick", "hh"])
    }

    // MARK: Con il modello vero

    func testDrumsMatchDrumSep() async throws {
        executionTimeAllowance = 600
        let (data, resp) = try await EndToEndTests.fixture("BatteriaDrumSep-prova.f32")
        guard (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 8 else { throw XCTSkip("modello batteria non ancora pubblicato") }
        let all: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let n = Int(all[0]), S = Int(all[1])
        let mix = [Array(all[2..<(2 + n)]), Array(all[(2 + n)..<(2 + 2 * n)])]
        let model: DrumSplitter
        do { model = try await ModelStore.shared.drums { _ in } } catch { throw XCTSkip("modello batteria non disponibile") }
        XCTAssertEqual(model.config.chunk, n)
        XCTAssertEqual(model.stemCount, S)
        let start = Date()
        let out = try model.runChunk(mix)
        var ref: [Float] = [], est: [Float] = []
        for k in 0..<S {
            for c in 0..<2 {
                let o = 2 + 2 * n + (k * 2 + c) * n
                ref += all[o..<(o + n)]
                est += out[k][c]
            }
        }
        let q = EndToEndTests.snr(ref, est)
        let line = String(format: "Batteria DrumSep: %.1f dB dal modello originale, pezzo da %.1f s in %.1f s",
                          q, Double(n) / 44_100, Date().timeIntervalSince(start))
        print(line)
        let path = "/tmp/audiolr-passi.txt"
        let old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? (old + line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertGreaterThan(q, 25, "la batteria divisa dall'app è diversa da quella di DrumSep originale")
    }
}
