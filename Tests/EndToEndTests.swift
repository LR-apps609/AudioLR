import XCTest
import CoreML

/// La prova vera: il modello scaricato dalle Release separa una canzone di prova, e il risultato
/// si confronta con quello di Demucs originale (Tools/make_fixture.py). Se la prova o il modello
/// non sono ancora pubblicati, il test viene saltato.
final class EndToEndTests: XCTestCase {
    static let fixtureURL = ModelStore.base.appendingPathComponent("HTDemucs-prova.f32")

    private func fixture() async throws -> (mix: [[Float]], expected: [[[Float]]]) {
        let (data, resp) = try await URLSession.shared.data(from: Self.fixtureURL)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 8 else {
            throw XCTSkip("prova di fedeltà non ancora pubblicata")
        }
        let all: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let n = Int(all[0]), S = Int(all[1])
        XCTAssertEqual(all.count, 2 + 2 * n + S * 2 * n)
        var p = 2
        func take() -> [Float] { defer { p += n }; return Array(all[p..<(p + n)]) }
        let mix = [take(), take()]
        let expected = (0..<S).map { _ in [take(), take()] }
        return (mix, expected)
    }

    static func snr(_ ref: [Float], _ est: [Float]) -> Double {
        var num = 0.0, den = 0.0
        for i in 0..<ref.count {
            num += Double(ref[i]) * Double(ref[i])
            let d = Double(ref[i] - est[i]); den += d * d
        }
        return 10 * log10(num / max(den, 1e-20))
    }

    func testSeparationMatchesDemucs() async throws {
        let (mix, expected) = try await fixture()

        // Il modello come lo usa l'app (scaricato e preparato da ModelStore), ma solo sul processore:
        // il risultato è lo stesso su ogni Mac e il confronto è preciso
        do { _ = try await ModelStore.shared.load { _ in } } catch {
            throw XCTSkip("modello non disponibile: \(error.localizedDescription)")
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuOnly
        let core = try CoreMLSeparationCore(model: MLModel(contentsOf: ModelStore.compiled, configuration: cfg))
        XCTAssertEqual(core.sources, ["drums", "bass", "other", "vocals"])
        XCTAssertEqual(core.segment, 343_980)

        let start = Date()
        let out = try Separator(core: core).separate(mix)
        let seconds = Date().timeIntervalSince(start)

        var report: [String] = []
        let mixAll = mix[0] + mix[1]
        for (s, name) in core.sources.enumerated() {
            let ref = expected[s][0] + expected[s][1], est = out[s][0] + out[s][1]
            let q = Self.snr(ref, est)
            // Uno strumento quasi muto ha poco segnale: lì conta che l'errore sia piccolo rispetto alla canzone
            let vsMix = Self.snr(mixAll, zip(mixAll, zip(ref, est)).map { $0.0 - ($0.1.0 - $0.1.1) })
            report.append("\(name) \(String(format: "%.1f", q)) dB")
            // 16 bit contro 32 bit di PyTorch: oltre 25 dB la differenza non si sente
            XCTAssertTrue(q > 25 || vsMix > 35, "\(name): troppo diverso da Demucs (\(q) dB, \(vsMix) dB sulla canzone)")
        }
        let audio = Double(mix[0].count) / AudioIO.sampleRate
        let line = "Fedeltà a Demucs: " + report.joined(separator: " · ") +
            String(format: " — %.1f s di audio in %.1f s (solo processore)", audio, seconds)
        print(line)
        // Il workflow la mostra nella pagina della compilazione
        try? line.write(toFile: "/tmp/audiolr-fedelta.txt", atomically: true, encoding: .utf8)
    }

    // MARK: Prove per passaggi: spettrogramma, ritorno all'onda, un pezzo intero

    private static func load(_ name: String) async throws -> [Float] {
        let (data, resp) = try await URLSession.shared.data(from: ModelStore.base.appendingPathComponent(name))
        guard (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 16 else { throw XCTSkip("\(name) non ancora pubblicato") }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private static func relErr(_ a: [Float], _ b: [Float]) -> Double {
        var e: Float = 0, m: Float = 0
        for i in 0..<min(a.count, b.count) { e = max(e, abs(a[i] - b[i])); m = max(m, abs(b[i])) }
        return Double(e / max(m, 1e-12))
    }

    private static func note(_ line: String) {
        print(line)
        let path = "/tmp/audiolr-passi.txt"
        let old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? (old + line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    func testStepsMatchDemucs() async throws {
        let all = try await Self.load("HTDemucs-passi.f32")
        let n = Int(all[0]), T = Int(all[1]), L = Int(all[2]), S = Int(all[3])
        var p = 4
        func take(_ k: Int) -> [Float] { defer { p += k }; return Array(all[p..<(p + k)]) }
        let x = take(n)
        let zRe = take(2048 * T), zIm = take(2048 * T)
        let z2Re = take(2048 * T), z2Im = take(2048 * T)
        let back = take(n)
        let piece = [take(L), take(L)]
        let segOut = (0..<S).map { _ in [take(L), take(L)] }
        XCTAssertEqual(p, all.count)

        // 1. Spettrogramma
        let stft = Spectrogram()
        let z = stft.forward(x)
        let eRe = Self.relErr(z.re, zRe), eIm = Self.relErr(z.im, zIm)
        let eConj = Self.relErr(z.im.map { -$0 }, zIm)
        Self.note(String(format: "STFT: reale %.1e, immaginaria %.1e (coniugata %.1e)", eRe, eIm, eConj))
        XCTAssertLessThan(eRe, 1e-3, "STFT: parte reale diversa da Demucs")
        XCTAssertLessThan(eIm, 1e-3, "STFT: parte immaginaria diversa da Demucs")

        // 2. Ritorno all'onda
        let y = stft.inverse(re: z2Re, im: z2Im, length: n)
        let eBack = Self.relErr(y, back)
        let eBackConj = Self.relErr(stft.inverse(re: z2Re, im: z2Im.map { -$0 }, length: n), back)
        Self.note(String(format: "iSTFT: %.1e (coniugata %.1e)", eBack, eBackConj))
        XCTAssertLessThan(eBack, 1e-3, "iSTFT diversa da Demucs")

        // 3. Un pezzo intero con il modello vero
        do { _ = try await ModelStore.shared.load { _ in } } catch { throw XCTSkip("modello non disponibile") }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuOnly
        let core = try CoreMLSeparationCore(model: MLModel(contentsOf: ModelStore.compiled, configuration: cfg))
        let t0 = Date()
        _ = stft.forward(piece[0]); _ = stft.forward(piece[1])
        let tStft = Date().timeIntervalSince(t0)
        let t1 = Date()
        let res = try Separator(core: core).runSegment(piece)
        let tAll = Date().timeIntervalSince(t1)
        var parts: [String] = []
        for s in 0..<S {
            let q = Self.snr(segOut[s][0] + segOut[s][1], res[s][0] + res[s][1])
            parts.append("\(core.sources[s]) \(String(format: "%.1f", q)) dB")
        }
        Self.note("Pezzo intero: " + parts.joined(separator: " · ") +
                  String(format: " — %.1f s in tutto, di cui STFT %.1f s", tAll, tStft * 1))
    }
}
