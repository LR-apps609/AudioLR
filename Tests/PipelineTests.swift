import XCTest

/// La separazione vera, dall'inizio alla fine, come la fa l'app: una canzone di prova in Massima.
/// Controlla le tracce, i file e che base + voce ridiano la canzone. Se il modello non è raggiungibile, si salta.
@MainActor
final class PipelineTests: XCTestCase {

    private func song(seconds: Double = 12) throws -> URL {
        let rate = 44_100.0, n = Int(seconds * rate)
        var l = [Float](repeating: 0, count: n), r = l
        for i in 0..<n {
            let t = Double(i) / rate
            let chord = 0.08 * (sin(2 * .pi * 220 * t) + sin(2 * .pi * 277.2 * t) + sin(2 * .pi * 329.6 * t))
            let bass = 0.18 * sin(2 * .pi * 55 * t)
            let beat = (i % 22_050) < 2_500 ? 0.4 * sin(2 * .pi * 60 * t) * exp(-Double(i % 22_050) / 600) : 0
            let f0 = 220 * (1 + 0.03 * sin(2 * .pi * 5.5 * t))
            var voice = 0.0
            for k in 1...12 { voice += sin(2 * .pi * f0 * Double(k) * t) / Double(k) }
            voice *= 0.1 * (0.5 + 0.5 * sin(2 * .pi * 0.25 * t))
            l[i] = Float(chord + bass + beat + voice)
            r[i] = Float(0.8 * chord + bass + beat + voice)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Prova completa.wav")
        try AudioIO.write([l, r], to: url, format: .wav16)
        return url
    }

    /// Studio dall'inizio alla fine: voce viperx, SW sugli strumenti e il basso dal Demucs specializzato.
    func testStudioFromStartToFinish() async throws {
        executionTimeAllowance = 3000
        let q = Quality.studio
        for m in q.allModels {
            do { _ = try await ModelStore.shared.mlModel(m) { _ in } } catch { throw XCTSkip("\(m) non raggiungibile") }
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("uscita-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        UserDefaults.standard.set(out.path, forKey: Prefs.folderKey)
        defer { UserDefaults.standard.removeObject(forKey: Prefs.folderKey); try? FileManager.default.removeItem(at: out) }

        let job = SeparationJob.shared
        job.reset()
        // 5 secondi: sul Mac di GitHub (senza Neural Engine) tre modelli pesanti sono lenti
        let url = try song(seconds: 5)
        let start = Date()
        job.start(url, quality: q)
        while job.isBusy { try await Task.sleep(nanoseconds: 500_000_000) }
        if case .failed(let msg) = job.phase { return XCTFail("separazione non riuscita: \(msg)") }
        XCTAssertEqual(job.phase, .done)
        XCTAssertEqual(Set(job.stems.map(\.key)), ["vocals", "drums", "bass", "guitar", "piano", "other", "instrumental"])
        XCTAssertTrue(job.timings.contains { $0.name == "Basso (Demucs)" }, "il basso deve venire da Demucs")
        // Il basso c'è davvero: la canzone di prova ha un basso a 55 Hz
        let bass = try AudioIO.read(job.stems.first { $0.key == "bass" }!.url)
        let energy = bass[0].reduce(0) { $0 + $1 * $1 } / Float(bass[0].count)
        XCTAssertGreaterThan(energy, 1e-4, "basso vuoto")
        let line = String(format: "Studio completa: 5 s in %.0f s · %@ · %@", Date().timeIntervalSince(start),
                          job.timings.map { "\($0.name) \(Int($0.seconds.rounded())) s" }.joined(separator: ", "), job.engineText ?? "")
        print(line)
        let path = "/tmp/audiolr-passi.txt"
        let old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? (old + line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        job.reset()
    }

    func testMassimaFromStartToFinish() async throws {
        executionTimeAllowance = 2400
        guard let sw = Quality.best.instrumentModel else { return XCTFail("Massima senza modello strumenti") }
        do { _ = try await ModelStore.shared.mlModel(sw) { _ in } } catch { throw XCTSkip("\(sw) non raggiungibile") }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("uscita-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        UserDefaults.standard.set(out.path, forKey: Prefs.folderKey)
        defer { UserDefaults.standard.removeObject(forKey: Prefs.folderKey); try? FileManager.default.removeItem(at: out) }

        let job = SeparationJob.shared
        job.reset()
        let url = try song()
        let start = Date()
        job.start(url, quality: .best)
        while job.isBusy { try await Task.sleep(nanoseconds: 500_000_000) }
        if case .failed(let msg) = job.phase { return XCTFail("separazione non riuscita: \(msg)") }
        XCTAssertEqual(job.phase, .done)
        let keys = job.stems.map(\.key)
        XCTAssertEqual(Set(keys), ["vocals", "drums", "bass", "guitar", "piano", "other", "instrumental"])
        for s in job.stems { XCTAssertTrue(FileManager.default.fileExists(atPath: s.url.path), s.name) }
        XCTAssertNotNil(job.analysis, "tempo e tonalità")
        // Base + voce = canzone (a meno del volume comune)
        let mix = try AudioIO.read(url)
        let base = try AudioIO.read(job.stems.first { $0.key == "instrumental" }!.url)
        let voice = try AudioIO.read(job.stems.first { $0.key == "vocals" }!.url)
        let g = Float(pow(10, (job.stems.first?.gainDB ?? 0) / 20))
        var sum = [Float](repeating: 0, count: mix[0].count)
        for i in sum.indices { sum[i] = (base[0][i] + voice[0][i]) / g }
        let q = EndToEndTests.snr(mix[0], sum)
        let line = String(format: "Massima completa: 12 s in %.0f s · base + voce / canzone %.1f dB · %@",
                          Date().timeIntervalSince(start), q, job.engineText ?? "")
        print(line)
        let path = "/tmp/audiolr-passi.txt"
        let old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? (old + line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertGreaterThan(q, 30, "base e voce devono ridare la canzone")
        job.reset()
    }
}
