import Foundation
import WhisperKit

// Il motore del testo sincronizzato (le regole sono in Lyrics.swift): Whisper small con WhisperKit, solo in
// questo file, così i nomi di WhisperKit non si mescolano con quelli dell'app.

// MARK: - Il motore (Whisper con WhisperKit)

enum LyricsEngine {
    static let modelName = "WhisperSmall"
    static var folder: URL { ModelStore.folder.appendingPathComponent(modelName, isDirectory: true) }
    static var isReady: Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("openai_whisper-small/AudioEncoder.mlmodelc").path)
    }

    /// Le lingue nel menu (nil = la riconosce da sola).
    static let languages: [(code: String?, name: String)] = [
        (nil, "Automatica"), ("it", "Italiano"), ("en", "Inglese"), ("es", "Spagnolo"),
        ("fr", "Francese"), ("de", "Tedesco"), ("pt", "Portoghese"),
    ]

    /// Scarica il modello la prima volta (circa 500 MB): release «modelli-1», con il suo codice di controllo.
    static func prepare(progress: @escaping (Double) -> Void) async throws {
        if isReady { progress(1); return }
        let fm = FileManager.default
        try fm.createDirectory(at: ModelStore.folder, withIntermediateDirectories: true)
        let base = ModelStore.base
        do {
            let (shaData, shaResp) = try await URLSession.shared.data(from: base.appendingPathComponent(modelName + ".sha256"))
            guard (shaResp as? HTTPURLResponse)?.statusCode == 200,
                  let expected = String(decoding: shaData, as: UTF8.self).split(separator: " ").first.map(String.init) else {
                throw SeparationError("il modello del testo non è ancora disponibile")
            }
            let delegate = ProgressDelegate { progress(0.9 * $0) }
            let (tmp, resp) = try await URLSession.shared.download(from: base.appendingPathComponent(modelName + ".zip"), delegate: delegate)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw SeparationError("il modello del testo non è ancora disponibile") }
            defer { try? fm.removeItem(at: tmp) }
            guard ModelStore.sha256(of: tmp) == expected else { throw SeparationError("il modello scaricato è rovinato, riprova") }
            let work = ModelStore.folder.appendingPathComponent("scarico-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: work) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", tmp.path, work.path]
            try p.run()
            p.waitUntilExit()
            let unpacked = work.appendingPathComponent(modelName, isDirectory: true)
            guard p.terminationStatus == 0, fm.fileExists(atPath: unpacked.path) else {
                throw SeparationError("non riesco ad aprire il modello del testo")
            }
            try? fm.removeItem(at: folder)
            try fm.moveItem(at: unpacked, to: folder)
            progress(1)
        } catch let e as SeparationError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SeparationError("non riesco a scaricare il modello del testo (serve internet la prima volta)")
        }
    }

    /// La voce (44,1 kHz stereo) come Whisper la vuole: mono a 16 kHz.
    static func mono16k(_ ch: [[Float]], rate: Double = AudioIO.sampleRate) -> [Float] {
        guard let first = ch.first, !first.isEmpty else { return [] }
        let n = first.count
        let ratio = rate / 16_000
        let out = Int(Double(n) / ratio)
        var res = [Float](repeating: 0, count: out)
        for i in 0..<out {
            let x = Double(i) * ratio
            let a = Int(x)
            let b = min(n - 1, a + 1)
            let f = Float(x - Double(a))
            var v: Float = 0
            for c in ch { v += c[a] * (1 - f) + c[b] * f }
            res[i] = v / Float(ch.count)
        }
        return res
    }

    /// Trascrive la voce: parole con i tempi. `language` nil = la riconosce da sola.
    static func transcribe(voice: URL, language: String?, progress: @escaping (String) -> Void) async throws -> Lyrics {
        progress("Leggo la voce…")
        let audio = mono16k(try AudioIO.read(voice))
        progress("Preparo il modello del testo…")
        let tokenizer = folder.appendingPathComponent("tokenizer", isDirectory: true)
        let config = WhisperKitConfig(model: "openai_whisper-small",
                                      modelFolder: folder.appendingPathComponent("openai_whisper-small").path,
                                      tokenizerFolder: tokenizer,
                                      verbose: false, logLevel: .error, prewarm: false, load: true, download: false)
        let kit = try await WhisperKit(config)
        progress("Ascolto la voce…")
        var options = DecodingOptions(task: .transcribe, language: language, temperature: 0,
                                      detectLanguage: language == nil, wordTimestamps: true)
        options.chunkingStrategy = .vad
        let results: [TranscriptionResult] = try await kit.transcribe(audioArray: audio, decodeOptions: options)
        var raw: [LyricWord] = []
        for r in results {
            for s in r.segments {
                for w in s.words ?? [] {
                    raw.append(LyricWord(text: w.word, start: Double(w.start), end: Double(w.end)))
                }
            }
        }
        raw.sort { $0.start < $1.start }
        return Lyrics(language: results.first?.language ?? language, words: clean(raw))
    }

    private final class ProgressDelegate: NSObject, URLSessionTaskDelegate {
        let onProgress: (Double) -> Void
        var obs: NSKeyValueObservation?
        init(_ f: @escaping (Double) -> Void) { onProgress = f }
        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            obs = task.progress.observe(\.fractionCompleted) { [weak self] pr, _ in self?.onProgress(pr.fractionCompleted) }
        }
    }
}
