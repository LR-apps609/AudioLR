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

    /// Canale per canale: un errore su un solo lato (per esempio il destro) non si nasconde nella somma.
    static func checkChannels(_ name: String, ref: [[Float]], est: [[Float]], mix: [[Float]], file: StaticString = #filePath, line: UInt = #line) {
        for c in 0..<2 {
            let q = snr(ref[c], est[c])
            let vsMix = snr(mix[c], zip(mix[c], zip(ref[c], est[c])).map { $0.0 - ($0.1.0 - $0.1.1) })
            XCTAssertTrue(q > 25 || vsMix > 35, "\(name), canale \(c == 0 ? "sinistro" : "destro"): \(q) dB", file: file, line: line)
        }
    }

    func testSeparationMatchesDemucs() async throws {
        executionTimeAllowance = 400
        let (mix, expected) = try await fixture()

        // Il modello esattamente come lo usa l'app (scaricato e preparato da ModelStore, tutte le unità di calcolo)
        let core: CoreMLSeparationCore
        do { core = try await ModelStore.shared.load { _ in } } catch {
            throw XCTSkip("modello non disponibile: \(error.localizedDescription)")
        }
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
            Self.checkChannels(name, ref: expected[s], est: out[s], mix: mix)
        }
        let audio = Double(mix[0].count) / AudioIO.sampleRate
        let line = "Fedeltà a Demucs: " + report.joined(separator: " · ") +
            String(format: " — %.1f s di audio in %.1f s (Mac di GitHub, senza Neural Engine)", audio, seconds)
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
        executionTimeAllowance = 600
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

        // 3. Un pezzo intero con il modello vero, come lo usa l'app
        let core: CoreMLSeparationCore
        do { core = try await ModelStore.shared.load { _ in } } catch { throw XCTSkip("modello non disponibile") }
        let res = try Separator(core: core).runSegment(piece)
        var parts: [String] = []
        for s in 0..<S {
            let ref = segOut[s][0] + segOut[s][1], est = res[s][0] + res[s][1]
            let q = Self.snr(ref, est)
            let all = piece[0] + piece[1]
            let vsMix = Self.snr(all, zip(all, zip(ref, est)).map { $0.0 - ($0.1.0 - $0.1.1) })
            parts.append(String(format: "%@ %.1f dB", core.sources[s], q))
            XCTAssertTrue(q > 25 || vsMix > 35, "\(core.sources[s]) nel pezzo: \(q) dB")
            Self.checkChannels(core.sources[s], ref: segOut[s], est: res[s], mix: piece)
        }
        XCTAssertTrue(Separator.plausible(piece: piece, result: res))
        Self.note("Pezzo intero: " + parts.joined(separator: " · "))

        // Il risultato di Core ML ha righe «allineate» (passi diversi dalla misura): vanno lette bene
        let probe = try Self.rawPrediction(core, piece: piece, stft: stft)
        Self.note("Passi di wave_out: \(probe.wave.strides) per \(probe.wave.shape)")
    }

    /// Una previsione «a mano», per guardare com'è fatta l'uscita.
    private static func rawPrediction(_ core: CoreMLSeparationCore, piece: [[Float]], stft: Spectrogram) throws -> (spec: MLMultiArray, wave: MLMultiArray) {
        let l = stft.forward(piece[0]), r = stft.forward(piece[1])
        let spec = try CoreMLSeparationCore.array(l.re + l.im + r.re + r.im, shape: [1, 4, core.bins, core.frames])
        let wave = try CoreMLSeparationCore.array(piece[0] + piece[1], shape: [1, 2, core.segment])
        let out = try core.model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["spec": spec, "wave": wave]))
        return (out.featureValue(for: "spec_out")!.multiArrayValue!, out.featureValue(for: "wave_out")!.multiArrayValue!)
    }

    // MARK: Massima qualità (htdemucs_ft)

    func testBestQualityMatchesDemucs() async throws {
        executionTimeAllowance = 600
        let (data, resp) = try await URLSession.shared.data(from: ModelStore.base.appendingPathComponent("HTDemucsFT-prova.f32"))
        guard (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 8 else { throw XCTSkip("prova Massima qualità non ancora pubblicata") }
        let all: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let n = Int(all[0]), S = Int(all[1])
        var p = 2
        func take() -> [Float] { defer { p += n }; return Array(all[p..<(p + n)]) }
        let mix = [take(), take()]
        let expected = (0..<S).map { _ in [take(), take()] }

        // Sul Mac di GitHub quattro modelli non stanno nel tempo: si prova quello della voce (il quarto).
        // Gli altri sono provati uno per uno quando vengono convertiti, e l'unione è provata in AppTests.
        let start = Date()
        let name = Quality.best.models[3]
        let core: CoreMLSeparationCore
        do { core = try await ModelStore.shared.load(name) { _ in } } catch { throw XCTSkip("\(name) non ancora pubblicato") }
        XCTAssertEqual(core.specialty, ["vocals"])
        let out = try Separator(core: core).separate(mix)
        let seconds = Date().timeIntervalSince(start)
        var report: [String] = []
        let mixAll = mix[0] + mix[1]
        for (s, name) in core.sources.enumerated() where core.specialty.contains(name) {
            let ref = expected[s][0] + expected[s][1], est = out[s][0] + out[s][1]
            let q = Self.snr(ref, est)
            let vsMix = Self.snr(mixAll, zip(mixAll, zip(ref, est)).map { $0.0 - ($0.1.0 - $0.1.1) })
            report.append(String(format: "%@ %.1f dB", name, q))
            XCTAssertTrue(q > 25 || vsMix > 35, "\(name): troppo diverso da Demucs (\(q) dB)")
            Self.checkChannels(name, ref: expected[s], est: out[s], mix: mix)
        }
        Self.note("Massima qualità: " + report.joined(separator: " · ") + String(format: " — %.1f s", seconds))
    }
}
