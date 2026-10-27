import Foundation

// ════════════════════════════════════════════════════════════════════
//  Rimonta («taglia e sposta»): la canzone in blocchi, uno per parte
//  (intro, strofa, ritornello…). I blocchi si dividono sul primo battito
//  di una battuta, si spostano, si duplicano o si tolgono; poi ogni traccia
//  si rimonta nello stesso ordine, con una dissolvenza di 10 ms a ogni
//  giunzione (niente «clic»). Ne nasce una canzone nuova: l'originale resta.
// ════════════════════════════════════════════════════════════════════

struct ArrangeBlock: Equatable, Identifiable {
    var id = UUID()
    /// Secondi dell'originale.
    var srcStart: Double
    var srcEnd: Double
    var label: String
    /// I blocchi dello stesso gruppo si somigliano (stesso colore).
    var group: Int

    var length: Double { max(0, srcEnd - srcStart) }
}

struct Arrangement: Equatable {
    var blocks: [ArrangeBlock]
    /// I primi battiti delle battute dell'originale: i tagli si agganciano lì.
    var downbeats: [Double] = []

    var duration: Double { blocks.reduce(0) { $0 + $1.length } }

    /// Un blocco per parte della canzone; senza parti, un blocco solo.
    static func from(_ structure: SongStructure?, duration: Double) -> Arrangement {
        let parts = (structure?.sections ?? []).filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var blocks: [ArrangeBlock] = []
        var t = 0.0
        for p in parts {
            let start = max(t, p.start), end = min(duration, p.end)
            guard end > start + 0.05 else { continue }
            // Un vuoto prima della parte (l'attacco della canzone) si attacca al blocco
            blocks.append(ArrangeBlock(srcStart: blocks.isEmpty ? 0 : start, srcEnd: end, label: p.label, group: p.group))
            t = end
        }
        if blocks.isEmpty { blocks = [ArrangeBlock(srcStart: 0, srcEnd: duration, label: "Canzone", group: 0)] }
        else if duration - t > 0.05 { blocks[blocks.count - 1].srcEnd = duration }
        return Arrangement(blocks: blocks, downbeats: structure?.downbeats ?? [])
    }

    /// Dove comincia il blocco `i` nella canzone rimontata.
    func start(of i: Int) -> Double { blocks.prefix(i).reduce(0) { $0 + $1.length } }

    /// Il blocco che suona a `t` secondi della canzone rimontata, e quanto dentro.
    func locate(_ t: Double) -> (index: Int, offset: Double)? {
        var o = 0.0
        for (i, b) in blocks.enumerated() {
            if t < o + b.length { return (i, max(0, t - o)) }
            o += b.length
        }
        return blocks.isEmpty ? nil : (blocks.count - 1, blocks[blocks.count - 1].length)
    }

    /// Divide il blocco `i` a `offset` secondi dal suo inizio, sul primo battito di battuta più vicino.
    /// Falso se il taglio cadrebbe troppo vicino a un bordo.
    @discardableResult
    mutating func split(_ i: Int, at offset: Double) -> Bool {
        guard blocks.indices.contains(i) else { return false }
        let b = blocks[i]
        var cut = b.srcStart + offset
        let inside = downbeats.filter { $0 > b.srcStart + 0.3 && $0 < b.srcEnd - 0.3 }
        if let near = inside.min(by: { abs($0 - cut) < abs($1 - cut) }) { cut = near }
        guard cut > b.srcStart + 0.3, cut < b.srcEnd - 0.3 else { return false }
        var first = b, second = b
        first.srcEnd = cut
        second.srcStart = cut
        second.id = UUID()
        blocks[i] = first
        blocks.insert(second, at: i + 1)
        return true
    }

    mutating func duplicate(_ i: Int) {
        guard blocks.indices.contains(i) else { return }
        var copy = blocks[i]
        copy.id = UUID()
        blocks.insert(copy, at: i + 1)
    }

    mutating func remove(_ i: Int) {
        guard blocks.indices.contains(i), blocks.count > 1 else { return }
        blocks.remove(at: i)
    }

    /// Sposta il blocco `from` in posizione `to` (come nella lista finale).
    mutating func move(_ from: Int, to: Int) {
        guard blocks.indices.contains(from) else { return }
        let b = blocks.remove(at: from)
        blocks.insert(b, at: max(0, min(blocks.count, to)))
    }

    /// Come l'originale: tutti i blocchi in ordine, senza buchi.
    var isOriginal: Bool {
        zip(blocks, blocks.dropFirst()).allSatisfy { abs($0.srcEnd - $1.srcStart) < 0.001 } && (blocks.first?.srcStart ?? 0) < 0.001
    }

    /// Lunghezza della dissolvenza a ogni giunzione.
    static let fade = 0.010

    /// La traccia rimontata: i blocchi uno dopo l'altro. Dove due blocchi non erano vicini nell'originale,
    /// negli ultimi 10 ms del primo entra (a potenza costante) quello che nell'originale precede il secondo.
    func render(_ audio: [[Float]], sampleRate: Double = AudioIO.sampleRate) -> [[Float]] {
        guard let n = audio.first?.count else { return audio }
        let fadeN = Int(Self.fade * sampleRate)
        let spans = blocks.map { b -> (Int, Int) in
            let a = max(0, min(n, Int((b.srcStart * sampleRate).rounded())))
            return (a, max(a, min(n, Int((b.srcEnd * sampleRate).rounded()))))
        }
        let total = spans.reduce(0) { $0 + $1.1 - $1.0 }
        return (0..<2).map { c in
            let ch = audio[min(c, audio.count - 1)]
            var out = [Float](repeating: 0, count: total)
            var o = 0
            for (k, (a, b)) in spans.enumerated() {
                out.withUnsafeMutableBufferPointer { dst in
                    ch.withUnsafeBufferPointer { src in
                        for i in 0..<(b - a) { dst[o + i] = src[a + i] }
                    }
                }
                o += b - a
                // Giunzione con il blocco dopo, se nell'originale non era lì
                guard k + 1 < spans.count, spans[k + 1].0 != b else { continue }
                let next = spans[k + 1].0
                let f = min(fadeN, b - a)
                for i in 0..<f {
                    let x = (Double(i) + 0.5) / Double(f)
                    let out1 = Float(cos(x * .pi / 2)), in1 = Float(sin(x * .pi / 2))
                    let pre = next - f + i
                    let incoming: Float = pre >= 0 && pre < n ? ch[pre] : 0
                    out[o - f + i] = out[o - f + i] * out1 + incoming * in1
                }
            }
            return out
        }
    }

    /// Battiti, parti e accordi della canzone rimontata: blocco per blocco; le parti sono i blocchi.
    func analysis(_ a: SongAnalysis) -> SongAnalysis {
        var out = SongAnalysis(bpm: a.bpm, keyRoot: a.keyRoot, minor: a.minor, keyConfidence: a.keyConfidence)
        var o = 0.0
        var beats: [Double] = [], isDown: [Bool] = [], sections: [SongSection] = [], chords: [ChordSpan] = []
        let down = Set((a.structure?.downbeats ?? []).map { Int(($0 * 1000).rounded()) })
        for b in blocks {
            for t in a.structure?.beats ?? [] where t >= b.srcStart - 0.001 && t < b.srcEnd - 0.001 {
                beats.append(o + t - b.srcStart)
                isDown.append(down.contains(Int((t * 1000).rounded())))
            }
            sections.append(SongSection(start: o, end: o + b.length, label: b.label, group: b.group))
            for c in a.chords ?? [] where c.end > b.srcStart && c.start < b.srcEnd {
                chords.append(ChordSpan(start: o + max(c.start, b.srcStart) - b.srcStart, end: o + min(c.end, b.srcEnd) - b.srcStart,
                                        root: c.root, minor: c.minor))
            }
            o += b.length
        }
        if let s = a.structure {
            let first = isDown.firstIndex(of: true) ?? 0
            out.structure = SongStructure(beats: beats, firstDownbeat: first, beatsPerBar: s.beatsPerBar, sections: sections)
        }
        if a.chords != nil { out.chords = chords }
        return out
    }
}
