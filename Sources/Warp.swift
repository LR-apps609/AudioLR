import Foundation
import AVFoundation

// ════════════════════════════════════════════════════════════════════
//  Warp, come in Ableton: un segnaposto sul primo battito di ogni battuta.
//  • I segnaposto si spostano a mano dove IsoLR ha sbagliato: i battiti
//    (metronomo, parti, passaggio A–B) si ricalcolano da lì.
//  • «Metti a tempo»: ogni battuta dura uguale (al BPM scelto); il tratto
//    tra due segnaposto si stira o si stringe, il tono non cambia. Ne
//    nasce una canzone nuova, l'originale resta com'è.
//  La mappa (WarpMap) dice dove finisce ogni istante; il suono si stira con
//  AVAudioUnitTimePitch fuori tempo reale, cambiando la velocità a piccoli
//  blocchi secondo il tratto in cui si trova.
// ════════════════════════════════════════════════════════════════════

/// Da dove a dove va ogni istante della canzone: ancore (sorgente → destinazione), lineare in mezzo.
struct WarpMap: Equatable {
    struct Anchor: Equatable {
        let src: Double
        let dst: Double
    }
    /// Crescenti sia nella sorgente sia nella destinazione.
    let anchors: [Anchor]

    /// Prima della prima ancora vale la pendenza del primo tratto, dopo l'ultima quella dell'ultimo.
    private func slope(_ i: Int) -> Double {
        guard anchors.count >= 2 else { return 1 }
        let k = max(0, min(anchors.count - 2, i))
        let a = anchors[k], b = anchors[k + 1]
        return (b.dst - a.dst) / max(1e-9, b.src - a.src)
    }

    /// L'istante della canzone nuova che corrisponde a `s` secondi dell'originale.
    func map(_ s: Double) -> Double {
        guard let first = anchors.first else { return s }
        if s <= first.src { return first.dst - (first.src - s) * slope(0) }
        for i in 0..<(anchors.count - 1) where s < anchors[i + 1].src {
            return anchors[i].dst + (s - anchors[i].src) * slope(i)
        }
        let last = anchors[anchors.count - 1]
        return last.dst + (s - last.src) * slope(anchors.count - 2)
    }

    /// Al contrario: l'istante dell'originale che finisce a `d` secondi della canzone nuova.
    func inverse(_ d: Double) -> Double {
        guard let first = anchors.first else { return d }
        if d <= first.dst { return first.src - (first.dst - d) / slope(0) }
        for i in 0..<(anchors.count - 1) where d < anchors[i + 1].dst {
            return anchors[i].src + (d - anchors[i].dst) / slope(i)
        }
        let last = anchors[anchors.count - 1]
        return last.src + (d - last.dst) / slope(anchors.count - 2)
    }

    /// Velocità di lettura dell'originale nel tratto che contiene `s` (1 = invariata, 2 = due volte più veloce).
    func rate(atSource s: Double) -> Double {
        guard anchors.count >= 2 else { return 1 }
        var i = 0
        while i < anchors.count - 2 && s >= anchors[i + 1].src { i += 1 }
        return 1 / slope(i)
    }

    /// Ogni battuta lunga `beatsPerBar * 60 / bpm` secondi; prima del primo segnaposto vale la prima battuta,
    /// dopo l'ultimo l'ultima. Con meno di due segnaposto: tutta la canzone alla stessa velocità (`natural` → `bpm`).
    static func toTempo(downbeats: [Double], beatsPerBar: Int, bpm: Double, natural: Double) -> WarpMap {
        let marks = downbeats.sorted()
        guard marks.count >= 2, bpm > 0 else {
            let k = natural > 0 && bpm > 0 ? natural / bpm : 1
            return WarpMap(anchors: [Anchor(src: 0, dst: 0), Anchor(src: 1, dst: k)])
        }
        let bar = Double(beatsPerBar) * 60 / bpm
        // La prima battuta parte dove la porta la sua velocità, così l'inizio della canzone resta a 0
        let d0 = marks[0] * bar / max(1e-9, marks[1] - marks[0])
        return WarpMap(anchors: marks.enumerated().map { Anchor(src: $0.element, dst: d0 + Double($0.offset) * bar) })
    }

    /// Il tratto più stirato o più stretto: oltre 4 volte la voce suona finta.
    var extremeRate: Double {
        guard anchors.count >= 2 else { return 1 }
        return (0..<(anchors.count - 1)).map { 1 / slope($0) }.map { max($0, 1 / $0) }.max() ?? 1
    }
}

enum Warp {
    /// I battiti dai segnaposto: `beatsPerBar` battiti equidistanti in ogni battuta; prima del primo segnaposto
    /// e dopo l'ultimo si continua con la battuta vicina, dentro la canzone (0…`duration`).
    static func beats(downbeats: [Double], beatsPerBar: Int, duration: Double) -> (beats: [Double], firstDownbeat: Int) {
        let marks = downbeats.sorted()
        let per = max(1, beatsPerBar)
        guard marks.count >= 2 else { return (marks, 0) }
        var before: [Double] = []
        let firstBeat = (marks[1] - marks[0]) / Double(per)
        var t = marks[0] - firstBeat
        while t >= -0.001 && firstBeat > 0.05 { before.insert(max(0, t), at: 0); t -= firstBeat }
        var out = before
        for i in 0..<(marks.count - 1) {
            let step = (marks[i + 1] - marks[i]) / Double(per)
            for k in 0..<per { out.append(marks[i] + Double(k) * step) }
        }
        let lastBeat = (marks[marks.count - 1] - marks[marks.count - 2]) / Double(per)
        t = marks[marks.count - 1]
        while t < duration + 0.001 && lastBeat > 0.05 { out.append(t); t += lastBeat }
        return (out, before.count)
    }

    /// La griglia corretta dai segnaposto, con le parti di prima.
    static func structure(downbeats: [Double], old: SongStructure, duration: Double) -> SongStructure {
        let b = beats(downbeats: downbeats, beatsPerBar: old.beatsPerBar, duration: duration)
        return SongStructure(beats: b.beats, firstDownbeat: b.firstDownbeat, beatsPerBar: old.beatsPerBar, sections: old.sections)
    }

    /// Il BPM medio della griglia (dalla durata delle battute).
    static func bpm(downbeats: [Double], beatsPerBar: Int) -> Double? {
        let m = downbeats.sorted()
        guard m.count >= 2, m[m.count - 1] > m[0] else { return nil }
        return Double(beatsPerBar) * Double(m.count - 1) * 60 / (m[m.count - 1] - m[0])
    }

    /// Tempo, battiti, parti e accordi della canzone messa a tempo: tutto spostato con la mappa, BPM esatto.
    static func analysis(_ a: SongAnalysis, map: WarpMap, bpm: Double, duration: Double) -> SongAnalysis {
        var out = SongAnalysis(bpm: bpm, keyRoot: a.keyRoot, minor: a.minor, keyConfidence: a.keyConfidence)
        let newDuration = map.map(duration)
        if let s = a.structure {
            out.structure = SongStructure(beats: s.beats.map(map.map).filter { $0 >= 0 && $0 <= newDuration + 0.001 },
                                          firstDownbeat: s.firstDownbeat, beatsPerBar: s.beatsPerBar,
                                          sections: s.sections.map { SongSection(start: map.map($0.start), end: map.map($0.end), label: $0.label, group: $0.group) })
            // I battiti nuovi: regolari, dalla mappa dei primi battiti delle battute
            let down = s.downbeats.map(map.map)
            if down.count >= 2 {
                let b = beats(downbeats: down, beatsPerBar: s.beatsPerBar, duration: newDuration)
                out.structure = SongStructure(beats: b.beats, firstDownbeat: b.firstDownbeat, beatsPerBar: s.beatsPerBar, sections: out.structure!.sections)
            }
        }
        out.chords = a.chords?.map { ChordSpan(start: map.map($0.start), end: map.map($0.end), root: $0.root, minor: $0.minor) }
        return out
    }

    /// La traccia (stereo, 44,1 kHz) stirata secondo `map`, con il tono di prima.
    /// La velocità si aggiorna ogni `block` campioni, secondo il tratto dell'originale che si sta leggendo.
    static func render(_ audio: [[Float]], map: WarpMap, block: Int = 512) throws -> [[Float]] {
        guard let n = audio.first?.count, n > 0 else { return audio }
        let sr = AudioIO.sampleRate
        let total = Int((map.map(Double(n) / sr) * sr).rounded())
        guard total > 0 else { return [[], []] }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let e = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let tp = AVAudioUnitTimePitch()
        tp.overlap = 16
        e.attach(player)
        e.attach(tp)
        e.connect(player, to: tp, format: fmt)
        e.connect(tp, to: e.mainMixerNode, format: fmt)
        try e.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: AVAudioFrameCount(block))
        try e.start()
        guard let input = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)), let dst = input.floatChannelData else {
            throw SeparationError("memoria insufficiente per mettere a tempo")
        }
        input.frameLength = AVAudioFrameCount(n)
        for c in 0..<2 {
            let src = audio[min(c, audio.count - 1)]
            src.withUnsafeBufferPointer { dst[c].update(from: $0.baseAddress!, count: n) }
        }
        player.scheduleBuffer(input, at: nil)
        player.play()
        // Il ritardo dell'effetto, in campioni d'uscita: quello che entra adesso esce tanto dopo
        let skip = Int((tp.auAudioUnit.latency * sr).rounded())
        let want = AVAudioFramePosition(total + skip)
        let buf = AVAudioPCMBuffer(pcmFormat: e.manualRenderingFormat, frameCapacity: AVAudioFrameCount(block))!
        var out: [[Float]] = [[], []]
        out[0].reserveCapacity(Int(want)); out[1].reserveCapacity(Int(want))
        while e.manualRenderingSampleTime < want {
            // Quello che si legge adesso finirà, tolto il ritardo, a questo istante della canzone nuova
            let now = Double(e.manualRenderingSampleTime) / sr
            tp.rate = Float(max(1.0 / 32, min(32, map.rate(atSource: map.inverse(now)))))
            let k = AVAudioFrameCount(min(AVAudioFramePosition(block), want - e.manualRenderingSampleTime))
            let status = try e.renderOffline(k, to: buf)
            guard status == .success, let d = buf.floatChannelData else { break }
            for c in 0..<2 { out[c].append(contentsOf: UnsafeBufferPointer(start: d[c], count: Int(buf.frameLength))) }
        }
        player.stop()
        e.stop()
        return out.map { ch in
            var x = Array(ch.dropFirst(skip).prefix(total))
            if x.count < total { x += [Float](repeating: 0, count: total - x.count) }
            return x
        }
    }
}
