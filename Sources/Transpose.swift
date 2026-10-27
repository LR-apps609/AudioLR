import Foundation
import AVFoundation

// ════════════════════════════════════════════════════════════════════
//  Transpose: la canzone in un'altra tonalità, senza cambiare la velocità.
//  • Nell'ascolto lo fa il mixer (AVAudioUnitTimePitch, MixPlayer.semitones).
//  • Nei file scaricati qui: lo stesso effetto fuori tempo reale, con il suo
//    piccolo ritardo tolto, così le tracce trasposte restano allineate.
//  • La tonalità nuova a parole («Re maggiore»), il capotasto per suonare
//    con le forme facili della chitarra, e di quanto spostare la canzone per
//    la voce di chi canta (dall'estensione della voce separata).
// ════════════════════════════════════════════════════════════════════

enum PitchShift {
    /// Quanto si può spostare: oltre, la voce suona finta.
    static let range = -7...7

    /// La traccia (stereo, 44,1 kHz) spostata di `semitones`, lunga uguale e allineata all'originale.
    static func apply(_ audio: [[Float]], semitones: Int) throws -> [[Float]] {
        guard semitones != 0, let n = audio.first?.count, n > 0 else { return audio }
        let sr = AudioIO.sampleRate
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let e = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let tp = AVAudioUnitTimePitch()
        tp.pitch = Float(semitones * 100)
        tp.overlap = 16                                    // più finestre sovrapposte: meno «metallico»
        e.attach(player)
        e.attach(tp)
        e.connect(player, to: tp, format: fmt)
        e.connect(tp, to: e.mainMixerNode, format: fmt)
        try e.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 8192)
        try e.start()
        // La traccia intera in un buffer; poi silenzio per far uscire la coda dell'effetto
        guard let input = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)), let dst = input.floatChannelData else {
            throw SeparationError("memoria insufficiente per cambiare la tonalità")
        }
        input.frameLength = AVAudioFrameCount(n)
        for c in 0..<2 {
            let src = audio[min(c, audio.count - 1)]
            src.withUnsafeBufferPointer { dst[c].update(from: $0.baseAddress!, count: n) }
        }
        player.scheduleBuffer(input, at: nil)
        player.play()
        let skip = Int((tp.auAudioUnit.latency * sr).rounded())
        let want = AVAudioFramePosition(n + skip)
        let buf = AVAudioPCMBuffer(pcmFormat: e.manualRenderingFormat, frameCapacity: e.manualRenderingMaximumFrameCount)!
        var out: [[Float]] = [[], []]
        out[0].reserveCapacity(Int(want)); out[1].reserveCapacity(Int(want))
        while e.manualRenderingSampleTime < want {
            let k = AVAudioFrameCount(min(AVAudioFramePosition(buf.frameCapacity), want - e.manualRenderingSampleTime))
            let status = try e.renderOffline(k, to: buf)
            guard status == .success, let d = buf.floatChannelData else { break }
            for c in 0..<2 { out[c].append(contentsOf: UnsafeBufferPointer(start: d[c], count: Int(buf.frameLength))) }
        }
        player.stop()
        e.stop()
        return out.map { ch in
            var x = Array(ch.dropFirst(skip).prefix(n))
            if x.count < n { x += [Float](repeating: 0, count: n - x.count) }
            return x
        }
    }

    /// «+2», «−3», «0».
    static func label(_ s: Int) -> String { s > 0 ? "+\(s)" : s < 0 ? "−\(-s)" : "0" }
}

enum Transpose {
    /// «Re maggiore» dalla tonalità della canzone spostata di `shift` semitoni.
    static func keyName(root: Int, minor: Bool, shift: Int) -> String {
        SongAnalysis.names[((root + shift) % 12 + 12) % 12] + (minor ? " minore" : " maggiore")
    }

    /// Le forme aperte che chiunque suoni la chitarra conosce (nomi all'inglese, 0 = Do).
    static let easyShapes: Set<String> = ["0", "2", "4", "7", "9", "2m", "4m", "9m"]   // C D E G A Dm Em Am

    /// Il capotasto che fa suonare più accordi con forme facili (pesati per quanto durano), con le forme da usare.
    /// Nil se senza capotasto va già bene quanto con.
    static func capo(chords: [ChordSpan], shift: Int) -> (capo: Int, shapes: [String])? {
        let played = chords.filter { $0.root != nil }
        guard !played.isEmpty else { return nil }
        func score(_ capo: Int) -> Double {
            played.reduce(0) { s, c in
                let r = ((c.root! + shift - capo) % 12 + 12) % 12
                return s + (easyShapes.contains("\(r)\(c.minor ? "m" : "")") ? c.end - c.start : 0)
            }
        }
        let total = played.reduce(0) { $0 + $1.end - $1.start }
        let best = (0...7).max { score($0) < score($1) } ?? 0
        // Solo se cambia davvero: almeno un quarto della canzone in più con forme facili (Do-Sol-Lam-Fa resta senza capotasto)
        guard best > 0, score(best) > score(0) + 0.25 * total else { return nil }
        var shapes: [String] = []
        for c in played {
            let s = ChordSpan(start: 0, end: 0, root: c.root, minor: c.minor).name(shift: shift - best)
            if !shapes.contains(s) { shapes.append(s) }
            if shapes.count == 4 { break }
        }
        return (best, shapes)
    }

    /// Le note più basse e più alte della voce (MIDI, 10° e 95° percentile dei momenti con una nota chiara).
    static func vocalRange(_ voice: [Float]) -> (low: Double, high: Double)? {
        let x = Compare.decimate(voice)
        let sr = Compare.rate / Double(Compare.down)
        let frames = (x.count - Compare.frame) / Compare.hop
        guard frames > 100 else { return nil }
        // Una colonna ogni 50 ms basta per l'estensione (e la rende cinque volte più veloce)
        let loud = (0..<frames).map { Compare.rms(x, $0 * Compare.hop) }.max() ?? 0
        var notes: [Double] = []
        for t in stride(from: 0, to: frames, by: 5) where Compare.rms(x, t * Compare.hop) > loud * 0.05 {
            if let hz = Compare.yin(x, t * Compare.hop, sr: sr, fmin: 70, fmax: 1100) { notes.append(Compare.midi(hz)) }
        }
        guard notes.count >= 40 else { return nil }
        notes.sort()
        return (notes[notes.count / 10], notes[min(notes.count - 1, notes.count * 95 / 100)])
    }

    /// Di quanto spostare perché la nota più alta della canzone arrivi alla nota più alta comoda di chi canta.
    static func suggest(songHigh: Double, myHigh: Int) -> Int {
        max(PitchShift.range.lowerBound, min(PitchShift.range.upperBound, Int((Double(myHigh) - songHigh).rounded())))
    }

    /// «Sol4» (nomi italiani, Do4 = Do centrale = MIDI 60).
    static func noteName(_ midi: Int) -> String { SongAnalysis.names[((midi % 12) + 12) % 12] + "\(midi / 12 - 1)" }
}
