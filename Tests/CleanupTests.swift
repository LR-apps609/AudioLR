import Accelerate
import AppKit
import XCTest
@testable import AudioLR

/// «Pulisci la voce»: Togli riverbero (calcolo di IsoLR) e Togli rumore (DeepFilterNet3).
final class CleanupTests: XCTestCase {
    private func db(_ x: [Float], _ mask: [Bool]) -> Double {
        var s = 0.0, c = 0
        for i in 0..<x.count where mask[i] { s += Double(x[i] * x[i]); c += 1 }
        return 10 * log10(s / Double(max(c, 1)) + 1e-20)
    }

    /// Una «voce» sintetica: armoniche con vibrato, frasi di 1,25 s e pause di 1,25 s.
    private func phrases(seconds: Double = 8) -> (dry: [Float], env: [Float]) {
        let sr = 44_100.0, n = Int(seconds * sr)
        var ph = 0.0, dry = [Float](repeating: 0, count: n), env = [Float](repeating: 0, count: n)
        var raw = [Float](repeating: 0, count: n)
        for i in 0..<n { raw[i] = sin(2 * Double.pi * 0.4 * Double(i) / sr) > 0 ? 1 : 0 }
        // Bordi morbidi (400 campioni)
        var acc: Float = 0
        for i in 0..<n {
            acc += raw[i] - (i >= 400 ? raw[i - 400] : 0)
            env[max(0, i - 200)] = acc / 400
        }
        for i in 0..<n {
            let t = Double(i) / sr
            let f0 = 220 * pow(2, floor(t * 1.5).truncatingRemainder(dividingBy: 5) / 12) * (1 + 0.01 * sin(2 * Double.pi * 5.5 * t))
            ph += 2 * Double.pi * f0 / sr
            var v = 0.0
            for k in 1..<15 { v += sin(Double(k) * ph) / Double(k) * exp(-Double(k) / 8) }
            dry[i] = Float(0.2 * v) * env[i]
        }
        return (dry, env)
    }

    /// Riverbero sintetico (Schroeder: sei filtri a pettine e due passa-tutto) con il T60 dato.
    private func reverb(_ x: [Float], t60: Double, offset: Int) -> [Float] {
        let sr = 44_100.0, n = x.count
        var wet = [Double](repeating: 0, count: n)
        for d0 in [1116, 1188, 1277, 1356, 1422, 1491] {
            let d = d0 + offset, g = pow(10, -3 * Double(d) / (t60 * sr))
            var y = [Double](repeating: 0, count: n)
            for i in 0..<n { y[i] = Double(x[i]) + (i >= d ? g * y[i - d] : 0) }
            for i in 0..<n { wet[i] += y[i] }
        }
        for (d0, g) in [(556, 0.5), (441, 0.5)] {
            let d = d0 + offset
            var y = [Double](repeating: 0, count: n)
            for i in 0..<n { y[i] = -g * wet[i] + (i >= d ? wet[i - d] + g * y[i - d] : 0) }
            wet = y
        }
        let ex = x.reduce(0.0) { $0 + Double($1 * $1) }, ew = wet.reduce(0.0) { $0 + $1 * $1 }
        let k = (ex / max(ew, 1e-20)).squareRoot()
        return (0..<n).map { x[$0] + Float(0.7 * k * wet[$0]) }
    }

    func testFFTRoundTrip() {
        for n in [960, 2048] {
            let fft = RealFFT(n)
            let x = (0..<n).map { Float(sin(Double($0) * 0.37) + 0.3 * cos(Double($0) * 1.9)) }
            var re = [Float](repeating: 0, count: n / 2 + 1), im = re, y = [Float](repeating: 0, count: n)
            x.withUnsafeBufferPointer { fft.forward($0.baseAddress!, re: &re, im: &im) }
            fft.inverse(re: re, im: im, out: &y)
            let err = zip(x, y).map { abs($0 - $1 / Float(n)) }.max() ?? 1
            XCTAssertLessThan(err, 1e-4, "FFT \(n) non torna indietro")
        }
    }

    func testDereverbKeepsDryVoice() throws {
        let (dry, env) = phrases()
        let out = try Dereverb.process([dry, dry])
        let note = env.map { $0 > 0.99 }
        XCTAssertEqual(out[0].count, dry.count)
        XCTAssertGreaterThan(db(out[0], note) - db(dry, note), -0.5, "Togli riverbero abbassa una voce senza riverbero")
        XCTAssertGreaterThan(EndToEndTests.snr(dry, out[0]), 20)
    }

    func testDereverbCutsTails() throws {
        let (dry, env) = phrases()
        // I buchi lontani dai bordi delle frasi (100 ms)
        var gap = [Bool](repeating: false, count: dry.count)
        for i in 2205..<(dry.count - 2205) where env[(i - 2205)...(i + 2205)].allSatisfy({ $0 < 0.01 }) { gap[i] = true }
        let note = env.map { $0 > 0.99 }
        for t60 in [0.6, 1.2] {
            let l = reverb(dry, t60: t60, offset: 0), r = reverb(dry, t60: t60, offset: 23)
            let out = try Dereverb.process([l, r])
            let cut = db(l, gap) - db(out[0], gap), notes = db(out[0], note) - db(l, note)
            print(String(format: "Togli riverbero, T60 %.1f s: coda nelle pause %.1f dB in meno, note %+.1f dB", t60, cut, notes))
            XCTAssertGreaterThan(cut, 8, "la coda del riverbero resta")
            XCTAssertGreaterThan(notes, -2, "le note si abbassano troppo")
        }
    }

    func testSampleRateRoundTrip() throws {
        let x = (0..<44_100).map { Float(sin(2 * Double.pi * 440 * Double($0) / 44_100)) * 0.5 }
        let up = try AudioIO.convert([x, x], from: 44_100, to: 48_000)
        XCTAssertEqual(Double(up[0].count), 48_000, accuracy: 64)
        let back = try AudioIO.convert(up, from: 48_000, to: 44_100)
        let n = min(back[0].count, x.count)
        // Allineate (senza ritardo), lontano dai bordi
        XCTAssertGreaterThan(EndToEndTests.snr(Array(x[2000..<(n - 2000)]), Array(back[0][2000..<(n - 2000)])), 30)
    }

    func testDenoiserMatchesDeepFilterNet() async throws {
        executionTimeAllowance = 600
        let (data, resp) = try await EndToEndTests.fixture("DeepFilter-prova.f32")
        guard (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 8 else { throw XCTSkip("modello del rumore non ancora pubblicato") }
        let all: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let n = Int(all[0])
        let input = Array(all[1..<(1 + n)]), want = Array(all[(1 + n)..<(1 + 2 * n)])
        let model: Denoiser
        do { model = try await ModelStore.shared.denoiser { _ in } } catch { throw XCTSkip("modello del rumore non disponibile: \(error)") }
        let start = Date()
        let got = try model.process(input)
        XCTAssertEqual(got.count, n)
        let q = EndToEndTests.snr(want, got)
        let line = String(format: "Togli rumore (DeepFilterNet3): %.1f dB dal calcolo originale, 3 s in %.2f s", q, Date().timeIntervalSince(start))
        print(line)
        let path = "/tmp/audiolr-passi.txt"
        let old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? (old + line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertGreaterThan(q, 30, "Togli rumore dell'app è diverso da DeepFilterNet3")
    }

    // MARK: Gli stessi numeri di Windows e del riferimento numpy (windows/ui/core/test/fixtures)

    private func fixture(_ name: String) throws -> [Float] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("windows/ui/core/test/fixtures/\(name)"))
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Lo stesso ingresso di Tools/make_cleanup_fixtures.py.
    private func signal(_ n: Int, _ sr: Double, _ seed: UInt32) -> [Float] {
        var s = seed
        return (0..<n).map { i in
            s = (s &* 1_103_515_245 &+ 12345) & 0x7fff_ffff
            let noise = Double(s) / 2_147_483_648 * 2 - 1, t = Double(i) / sr
            let gate: Double = t.truncatingRemainder(dividingBy: 0.25) < 0.12 ? 1 : 0
            return Float(0.3 * sin(2 * Double.pi * 220 * t) + 0.2 * sin(2 * Double.pi * 1330 * t) * gate + 0.05 * noise)
        }
    }

    func testDenoiseMathMatchesReference() throws {
        let widths = [2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 5, 5, 7, 7, 8, 10, 12, 13, 15, 18, 20, 24, 28, 31, 37, 42, 50, 56, 67]
        let cfg = DeepFilterConfig(sr: 48000, fft: 960, hop: 480, nb_erb: 32, nb_df: 96, order: 5, lookahead: 2, alpha: 0.99,
                                   frames: 30, ctx: 5, widths: widths)
        let F = 30, E = 32, D = 96, O = 5
        // La rete finta del riferimento: dipende solo dal fotogramma
        let den = Denoiser(net: { fe, fs in
            let m = fe.map { 1 / (1 + exp(-3 * $0)) }
            var c = [Float](repeating: 0, count: F * D * O * 2)
            for t in 0..<F { for f in 0..<D { for o in 0..<O {
                c[(t * D + f) * O * 2 + 2 * o] = 0.1 * Float(o + 1) * fs[t * D + f]
                c[(t * D + f) * O * 2 + 2 * o + 1] = 0.05 * fs[F * D + t * D + f]
            } } }
            return (m, c)
        }, config: cfg)
        let y = try den.process(signal(19200, 48000, 7))
        let want = try fixture("denoise-finta.f32")
        XCTAssertEqual(y.count, want.count)
        XCTAssertGreaterThan(EndToEndTests.snr(want, y), 60, "il calcolo di Togli rumore è diverso da deepfilter_ref")
    }

    func testDereverbMatchesReference() throws {
        let out = try Dereverb.process([signal(22050, 44100, 11), signal(22050, 44100, 13)])
        let want = try fixture("dereverb.f32")
        XCTAssertGreaterThan(EndToEndTests.snr(Array(want[0..<22050]), out[0]), 60)
        XCTAssertGreaterThan(EndToEndTests.snr(Array(want[22050...]), out[1]), 60)
    }
}

/// Clic destro nel Finder › «Separa con IsoLR».
final class FinderServiceTests: XCTestCase {
    func testServiceIsDeclaredAndHandled() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Sources/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let services = try XCTUnwrap(plist["NSServices"] as? [[String: Any]])
        let s = try XCTUnwrap(services.first)
        XCTAssertEqual(s["NSMessage"] as? String, "separateWithIsoLR")
        XCTAssertEqual((s["NSMenuItem"] as? [String: String])?["default"], "Separa con IsoLR")
        XCTAssertEqual(s["NSSendFileTypes"] as? [String], ["public.audio"])
        XCTAssertTrue(AppDelegate().responds(to: Selector(("separateWithIsoLR:userData:error:"))))
    }

    func testServiceRefusesEmptyPasteboard() {
        let pb = NSPasteboard(name: NSPasteboard.Name("prova-isolr-\(UUID().uuidString)"))
        pb.clearContents()
        var msg: NSString = ""
        AppDelegate().separateWithIsoLR(pb, userData: "", error: &msg)
        XCTAssertEqual(msg, "Nessun file audio scelto")
    }
}
