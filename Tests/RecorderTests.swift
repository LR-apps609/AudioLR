import XCTest
import AVFoundation

final class RecorderTests: XCTestCase {
    func testSongTimeRemovesLatencyAndCountIn() {
        // Musica da 10 s, una battuta di conteggio da 2 s, uscita con 20 ms di ritardo
        let c = TakeClock(startHost: 100, at: 10, lead: 2, rate: 1, semitones: 0, outputLatency: 0.02)
        XCTAssertEqual(c.songTime(atHost: 102.02), 10, accuracy: 1e-6)
        XCTAssertEqual(c.songTime(atHost: 103.02), 11, accuracy: 1e-6)
        // A metà velocità un secondo vero è mezzo secondo di canzone
        let slow = TakeClock(startHost: 100, at: 10, lead: 2, rate: 0.5, semitones: 0, outputLatency: 0)
        // Il conteggio (2 s di canzone) a metà velocità dura 4 s veri: la musica parte a 104
        XCTAssertEqual(slow.songTime(atHost: 104), 10, accuracy: 1e-9)
        XCTAssertEqual(slow.songTime(atHost: 106), 11, accuracy: 1e-9)
    }

    /// Un «tic» registrato a 48 kHz mono finisce nel punto giusto della canzone, a 44,1 kHz stereo.
    private func rawClick(at seconds: Double, length: Double) throws -> URL {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prova-\(UUID().uuidString).caf")
        let f = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = AVAudioFrameCount(length * 48_000)
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
        b.frameLength = n
        let at = Int(seconds * 48_000)
        for i in 0..<480 { b.floatChannelData![0][at + i] = Float(0.8 * sin(Double(i) * 0.3)) }
        try f.write(from: b)
        return url
    }

    private func loudest(_ url: URL) throws -> Double {
        let a = try AudioIO.read(url)
        var best = 0, m: Float = 0
        for (i, v) in a[0].enumerated() where abs(v) > m { m = abs(v); best = i }
        XCTAssertEqual(a.count, 2)
        return Double(best) / AudioIO.sampleRate
    }

    func testPlaceAtSongTime() throws {
        let raw = try rawClick(at: 0.5, length: 1.5)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("take-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: raw); try? FileManager.default.removeItem(at: out) }
        try TakeRecorder.place(raw: raw, startingAt: 2, rate: 1, semitones: 0, length: 6, to: out)
        XCTAssertEqual(try loudest(out), 2.5, accuracy: 0.02)
        XCTAssertEqual(Double(try AudioIO.read(out)[0].count) / AudioIO.sampleRate, 6, accuracy: 0.01)
    }

    func testSlowTakeBackToSongSpeed() throws {
        // Registrata a metà velocità: il tic a 1 s veri è a 0,5 s di canzone
        let raw = try rawClick(at: 1, length: 2)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("take-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: raw); try? FileManager.default.removeItem(at: out) }
        try TakeRecorder.place(raw: raw, startingAt: 1, rate: 0.5, semitones: 0, length: 4, to: out)
        XCTAssertEqual(try loudest(out), 1.5, accuracy: 0.06)
    }
}
