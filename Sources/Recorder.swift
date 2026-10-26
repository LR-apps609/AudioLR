import Foundation
import AVFoundation

// ════════════════════════════════════════════════════════════════════
//  Registrati sopra la base: il microfono (o la scheda audio) registra
//  mentre il mixer suona. Alla fine la registrazione si mette «a tempo»
//  con la canzone: si toglie il ritardo di microfono e altoparlanti, e se
//  si suonava più piano o in un altro tono la si riporta alla velocità e
//  al tono originali. Il file finale parte dall'inizio della canzone (con
//  silenzio prima), così si mescola, si confronta e si scarica come le
//  altre tracce.
// ════════════════════════════════════════════════════════════════════

/// Dove e come suonava il mixer quando è partita la registrazione.
struct TakeClock {
    /// Istante (host time, secondi) in cui il lettore ha cominciato: il primo clic del conteggio, o la musica.
    let startHost: Double
    /// Secondo della canzone da cui la musica parte, e quanto conteggio c'era prima (in secondi di canzone).
    let at: Double
    let lead: Double
    let rate: Double
    let semitones: Int
    /// Ritardo dell'uscita (altoparlanti o cuffie), secondi.
    let outputLatency: Double

    /// Il secondo della canzone che si sentiva quando il suono `host` (secondi) è entrato nel microfono.
    func songTime(atHost host: Double) -> Double {
        at - lead + (host - outputLatency - startHost) * rate
    }
}

/// Riceve i pezzi dal microfono (su un thread dell'audio) e li scrive su disco.
private final class TapSink: @unchecked Sendable {
    private let lock = NSLock()
    private let file: AVAudioFile
    private(set) var firstHost: Double?
    private(set) var frames: AVAudioFramePosition = 0
    private(set) var peak: Float = 0
    private(set) var failed = false

    init(file: AVAudioFile) { self.file = file }

    func take(_ buffer: AVAudioPCMBuffer, _ when: AVAudioTime) {
        lock.lock(); defer { lock.unlock() }
        if firstHost == nil, when.isHostTimeValid { firstHost = AVAudioTime.seconds(forHostTime: when.hostTime) }
        do { try file.write(from: buffer) } catch { failed = true }
        frames += AVAudioFramePosition(buffer.frameLength)
        if let d = buffer.floatChannelData {
            var m: Float = 0
            for c in 0..<Int(buffer.format.channelCount) {
                for i in 0..<Int(buffer.frameLength) { m = max(m, abs(d[c][i])) }
            }
            peak = max(peak * 0.85, m)
        }
    }

    func snapshot() -> (firstHost: Double?, frames: AVAudioFramePosition, peak: Float, failed: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (firstHost, frames, peak, failed)
    }
}

@MainActor
final class TakeRecorder: ObservableObject {
    static let shared = TakeRecorder()

    @Published private(set) var recording = false
    /// Volume del microfono (0…1) mentre si registra, per la barretta.
    @Published private(set) var level: Float = 0
    @Published var error: String?

    private var engine: AVAudioEngine?
    private var sink: TapSink?
    private var rawURL: URL?
    private var inputLatency = 0.0
    private var clock: TakeClock?

    enum Problem: LocalizedError {
        case denied, noInput, tooShort
        var errorDescription: String? {
            switch self {
            case .denied: return "IsoLR non può usare il microfono. Aprilo in Impostazioni di Sistema › Privacy e sicurezza › Microfono."
            case .noInput: return "Non trovo un microfono o una scheda audio. Collegane uno e riprova."
            case .tooShort: return "La registrazione è troppo corta."
            }
        }
    }

    /// Chiede il permesso del microfono (la prima volta compare la finestra di macOS).
    static func allowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Accende il microfono e comincia a scrivere. `clock` arriva un attimo dopo, quando il mixer parte.
    func start() throws {
        let e = AVAudioEngine()
        let input = e.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.channelCount > 0, fmt.sampleRate > 0 else { throw Problem.noInput }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("isolr-take-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let sink = TapSink(file: file)
        input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { b, w in sink.take(b, w) }
        e.prepare()
        try e.start()
        engine = e
        self.sink = sink
        rawURL = url
        inputLatency = input.presentationLatency
        clock = nil
        recording = true
        error = nil
        Task { @MainActor [weak self] in
            while let s = self, s.recording {
                s.level = s.sink?.snapshot().peak ?? 0
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    /// Il mixer è partito: da qui si sa a che punto della canzone corrisponde ogni pezzo registrato.
    func started(_ c: TakeClock) { if recording { clock = c } }

    /// Si ferma e prepara il file finale nella cartella `folder` («Registrazioni»), lungo quanto la canzone.
    func stop(into folder: URL, songDuration: Double, extraOffset: Double) async throws -> URL? {
        guard recording, let e = engine, let sink, let raw = rawURL else { return nil }
        e.inputNode.removeTap(onBus: 0)
        e.stop()
        engine = nil
        recording = false
        level = 0
        let snap = sink.snapshot()
        self.sink = nil
        defer { try? FileManager.default.removeItem(at: raw) }
        guard let c = clock, let first = snap.firstHost, snap.frames > 4410, !snap.failed else { throw Problem.tooShort }
        // Il primo pezzo registrato: quale secondo della canzone si sentiva in quel momento
        let start = c.songTime(atHost: first - inputLatency) + extraOffset
        let dir = folder.appendingPathComponent("Registrazioni", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = Self.nextName(in: dir)
        try await Task.detached(priority: .userInitiated) {
            try Self.place(raw: raw, startingAt: start, rate: c.rate, semitones: c.semitones, length: songDuration, to: out)
        }.value
        return out
    }

    /// Annulla senza salvare (per esempio se il mixer si ferma per un errore).
    func cancel() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        sink = nil
        recording = false
        level = 0
        if let r = rawURL { try? FileManager.default.removeItem(at: r) }
        rawURL = nil
    }

    nonisolated static func nextName(in dir: URL) -> URL {
        var n = 1
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent("Registrazione \(n).wav").path) { n += 1 }
        return dir.appendingPathComponent("Registrazione \(n).wav")
    }

    /// Le registrazioni di una canzone, la più recente per prima.
    nonisolated static func takes(in folder: URL) -> [URL] {
        let dir = folder.appendingPathComponent("Registrazioni", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension.lowercased() == "wav" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
    }

    /// Riporta la registrazione a velocità e tono originali (se serve), a 44,1 kHz stereo,
    /// e la scrive a partire dal secondo `start` della canzone, con silenzio prima.
    nonisolated static func place(raw: URL, startingAt start: Double, rate: Double, semitones: Int, length: Double, to url: URL) throws {
        let audio: [[Float]]
        do { audio = try render(raw, rate: rate, semitones: semitones) } catch {
            throw SeparationError("non riesco a mettere a tempo la registrazione (\(error.localizedDescription))")
        }
        let sr = AudioIO.sampleRate
        let total = Int(max(0, length) * sr)
        let shift = Int((start * sr).rounded())
        var out = [[Float]](repeating: [Float](repeating: 0, count: total), count: 2)
        for c in 0..<2 {
            let src = audio[min(c, audio.count - 1)]
            for i in 0..<src.count {
                let j = i + shift
                if j >= 0 && j < total { out[c][j] = src[i] }
            }
        }
        try AudioIO.write(out, to: url, format: .wav24, gain: 1)
    }

    /// Il file del microfono come stereo a 44,1 kHz; con velocità o tono cambiati passa per lo stesso
    /// effetto del mixer, al contrario (`1/rate`, `-semitoni`), fuori tempo reale.
    nonisolated static func render(_ raw: URL, rate: Double, semitones: Int) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: raw)
        let e = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let tp = AVAudioUnitTimePitch()
        tp.rate = Float(1 / max(0.25, rate))
        tp.pitch = Float(-semitones * 100)
        // A velocità e tono normali l'effetto non serve (e non aggiunge il suo piccolo ritardo)
        tp.bypass = abs(rate - 1) < 0.001 && semitones == 0
        let outFmt = AVAudioFormat(standardFormatWithSampleRate: AudioIO.sampleRate, channels: 2)!
        e.attach(player)
        e.attach(tp)
        e.connect(player, to: tp, format: file.processingFormat)
        e.connect(tp, to: e.mainMixerNode, format: outFmt)
        try e.enableManualRenderingMode(.offline, format: outFmt, maximumFrameCount: 4096)
        try e.start()
        player.scheduleFile(file, at: nil)
        player.play()
        let seconds = Double(file.length) / file.processingFormat.sampleRate * rate
        // L'effetto restituisce il suono con un piccolo ritardo: si registra un po' di più e lo si toglie
        let skip = tp.bypass ? 0 : Int((tp.auAudioUnit.latency * AudioIO.sampleRate).rounded())
        let want = AVAudioFramePosition(seconds * AudioIO.sampleRate) + AVAudioFramePosition(skip)
        let buf = AVAudioPCMBuffer(pcmFormat: e.manualRenderingFormat, frameCapacity: e.manualRenderingMaximumFrameCount)!
        var out: [[Float]] = [[], []]
        out[0].reserveCapacity(Int(want)); out[1].reserveCapacity(Int(want))
        while e.manualRenderingSampleTime < want {
            let n = AVAudioFrameCount(min(AVAudioFramePosition(buf.frameCapacity), want - e.manualRenderingSampleTime))
            let status = try e.renderOffline(n, to: buf)
            guard status == .success, let d = buf.floatChannelData else { break }
            for c in 0..<2 { out[c].append(contentsOf: UnsafeBufferPointer(start: d[c], count: Int(buf.frameLength))) }
        }
        player.stop()
        e.stop()
        return skip > 0 ? out.map { Array($0.dropFirst(skip)) } : out
    }
}
