import Foundation
import AVFoundation

// ════════════════════════════════════════════════════════════════════
//  L'audio degli editor Warp e Rimonta: il mix ai volumi del mixer, il clic
//  del metronomo sopra, un piccolo lettore con la testina, e la scrittura
//  della versione nuova (tutte le tracce trasformate, in una cartella accanto).
// ════════════════════════════════════════════════════════════════════

enum EditAudio {
    /// La somma delle tracce da mescolare, ai volumi del mixer (tutte, se nel mixer sono mute).
    static func mix(_ stems: [Stem], state: MixState) -> [[Float]] {
        let list = MixPlayer.mixable(stems)
        let anyOn = list.contains { state.effectiveGain($0.key) > 0 }
        var out: [[Float]] = []
        for s in list {
            let g = Float(anyOn ? state.effectiveGain(s.key) : 1)
            guard g > 0, let a = try? AudioIO.read(s.url), let n = a.first?.count else { continue }
            if out.isEmpty { out = [[Float]](repeating: [Float](repeating: 0, count: n), count: 2) }
            for c in 0..<2 {
                let ch = a[min(c, a.count - 1)]
                for i in 0..<min(ch.count, out[c].count) { out[c][i] += ch[i] * g }
            }
        }
        return out
    }

    /// Forma d'onda con `perSecond` barre al secondo (per gli editor, che si ingrandiscono).
    static func peaks(_ audio: [[Float]], perSecond: Double = 50) -> [Float] {
        let n = audio.first?.count ?? 0
        return Peaks.of(audio, count: max(1, Int(Double(n) / AudioIO.sampleRate * perSecond)))
    }

    /// Un clic breve (25 ms): più acuto e più forte sul primo battito della battuta.
    static func click(strong: Bool, sampleRate: Double = AudioIO.sampleRate) -> [Float] {
        let n = Int(0.025 * sampleRate), f = strong ? 1600.0 : 1000.0, amp: Float = strong ? 0.6 : 0.4
        return (0..<n).map { i in
            let t = Double(i) / sampleRate
            return amp * Float(sin(2 * .pi * f * t) * exp(-t * 160))
        }
    }

    /// La versione nuova di una canzone: ogni traccia trasformata, in una cartella «`title`» accanto all'originale
    /// (con «2», «3»… se c'è già). Restituisce la cartella e la durata.
    static func writeVersion(_ stems: [Stem], title: String, into root: URL, format: OutputFormat,
                                         progress: (Double) -> Void,
                                         transform: ([[Float]]) throws -> [[Float]]) throws -> (URL, Double) {
        let fm = FileManager.default
        var dir = root.appendingPathComponent(title, isDirectory: true)
        var k = 2
        while fm.fileExists(atPath: dir.path) {
            dir = root.appendingPathComponent("\(title) \(k)", isDirectory: true)
            k += 1
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Le tracce si riconoscono dal nome: «<cartella> – Voce.wav»
        let name = dir.lastPathComponent
        var seconds = 0.0
        do {
            for (i, s) in stems.enumerated() {
                let audio = try AudioIO.read(s.url)
                let out = try transform(audio)
                seconds = max(seconds, Double(out.first?.count ?? 0) / AudioIO.sampleRate)
                try AudioIO.write(out, to: dir.appendingPathComponent("\(name) – \(Stem.info(s.key).name).\(format.fileExtension)"), format: format)
                progress(Double(i + 1) / Double(max(1, stems.count)))
            }
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
        return (dir, seconds)
    }
}

/// Un lettore per gli editor: suona un tratto del mix (con i clic, se servono) e sa dov'è la testina.
@MainActor
final class PreviewPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: AudioIO.sampleRate, channels: 2)!
    private var offset = 0.0
    private var session = 0

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    /// Suona `audio` da `start` secondi per al massimo `seconds`; `clicks` (istanti e «forte») si sentono sopra.
    func play(_ audio: [[Float]], from start: Double, seconds: Double = 60, clicks: [(time: Double, strong: Bool)] = []) {
        stop()
        let sr = AudioIO.sampleRate
        guard let n = audio.first?.count else { return }
        let a = max(0, min(n, Int(start * sr))), b = min(n, a + Int(seconds * sr))
        guard b > a, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(b - a)),
              let d = buf.floatChannelData else { return }
        buf.frameLength = AVAudioFrameCount(b - a)
        for c in 0..<2 {
            let ch = audio[min(c, audio.count - 1)]
            for i in 0..<(b - a) { d[c][i] = ch[a + i] }
        }
        let strong = EditAudio.click(strong: true), weak = EditAudio.click(strong: false)
        for k in clicks {
            let at = Int(k.time * sr) - a
            guard at >= 0, at < b - a else { continue }
            let snd = k.strong ? strong : weak
            for i in 0..<min(snd.count, b - a - at) { for c in 0..<2 { d[c][at + i] += snd[i] } }
        }
        offset = Double(a) / sr
        session += 1
        let s = session
        do { if !engine.isRunning { try engine.start() } } catch {
            AppLog.write("Anteprima dell'editor non riuscita: \(error.localizedDescription)")
            return
        }
        node.scheduleBuffer(buf, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in if self?.session == s { self?.isPlaying = false } }
        }
        node.play()
        isPlaying = true
    }

    func stop() {
        session += 1
        node.stop()
        isPlaying = false
    }

    /// Dove suona adesso, in secondi del tratto suonato.
    var position: Double {
        guard isPlaying, let t = node.lastRenderTime, let p = node.playerTime(forNodeTime: t) else { return offset }
        return offset + Double(p.sampleTime) / p.sampleRate
    }
}
