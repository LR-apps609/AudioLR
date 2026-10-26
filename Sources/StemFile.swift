import Foundation
import AVFoundation

// ════════════════════════════════════════════════════════════════════
//  Il file «Stem» di Native Instruments (.stem.mp4), per i DJ: Traktor,
//  Mixxx, djay e gli altri programmi che leggono le quattro tracce.
//  È un MP4 con cinque tracce AAC: la canzone intera, poi batteria, basso,
//  altri strumenti e voce, più un atomo «stem» con nomi e colori.
//  I lettori normali (Musica, QuickTime) suonano solo la prima traccia.
// ════════════════════════════════════════════════════════════════════

enum StemFile {
    /// Le quattro tracce nell'ordine del formato, con le chiavi di IsoLR che finiscono in ognuna.
    static let layout: [(name: String, color: String, keys: Set<String>)] = [
        ("Drums", "#C48E2C", Set(["drums"] + DrumSplitter.parts)),
        ("Bass", "#8C6AAF", ["bass"]),
        ("Other", "#3C978C", ["guitar", "piano", "other"]),
        ("Vocals", "#CF6F57", ["vocals", "lead", "backing", "male", "female"]),
    ]

    static let bitrate = 320_000

    /// «Canzone.stem.mp4» nella cartella delle tracce, dalle tracce già salvate.
    /// Senza la canzone originale (una separazione riaperta dalla Cronologia), la canzone intera è voce + base.
    static func make(stems: [Stem], song: URL?, folder: URL, title: String) async throws -> URL {
        let url = folder.appendingPathComponent("\(title).stem.mp4")
        let chosen = MixPlayer.mixable(stems)
        let (master, parts) = try await Task.detached(priority: .userInitiated) { () -> ([[Float]], [[[Float]]]) in
            var mix: [[Float]]
            if let song, FileManager.default.fileExists(atPath: song.path) {
                // Le tracce sono state abbassate tutte dello stesso tanto: la canzone intera si abbassa uguale
                let g = Float(pow(10, (stems.first?.gainDB ?? 0) / 20))
                mix = try AudioIO.read(song).map { $0.map { $0 * g } }
            } else if let v = stems.first(where: { $0.key == "vocals" }), let b = stems.first(where: { $0.key == "instrumental" }) {
                let va = try AudioIO.read(v.url), ba = try AudioIO.read(b.url)
                mix = (0..<2).map { c in zip(va[c], ba[c]).map { $0 + $1 } }
            } else {
                mix = []
            }
            var n = mix.first?.count ?? 0
            if n == 0 { n = try chosen.first.map { try AudioIO.read($0.url)[0].count } ?? 0 }
            guard n > 0 else { throw SeparationError("non ci sono tracce per il file DJ") }
            var parts = [[[Float]]](repeating: [[Float]](repeating: [Float](repeating: 0, count: n), count: 2), count: layout.count)
            for s in chosen {
                guard let slot = layout.firstIndex(where: { $0.keys.contains(s.key) }) else { continue }
                let a = try AudioIO.read(s.url)
                for c in 0..<2 {
                    let ch = a[min(c, a.count - 1)]
                    for i in 0..<min(n, ch.count) { parts[slot][c][i] += ch[i] }
                }
            }
            // Senza canzone né base: la canzone intera è la somma delle quattro tracce
            if mix.isEmpty { mix = (0..<2).map { c in (0..<n).map { i in parts.reduce(Float(0)) { (sum: Float, p: [[Float]]) -> Float in sum + p[c][i] } } } }
            return (mix.map { Array($0.prefix(n)) + [Float](repeating: 0, count: max(0, n - $0.count)) }, parts)
        }.value
        try await write(master: master, stems: parts, to: url)
        return url
    }

    /// Scrive il file: prima la canzone intera (traccia attiva), poi le quattro tracce (disattivate per i lettori normali).
    static func write(master: [[Float]], stems: [[[Float]]], to url: URL) async throws {
        precondition(stems.count == layout.count)
        // Un solo guadagno per tutte, così nel programma DJ le tracce sommate ridanno la canzone, senza tagli
        var top: Float = 0
        for t in [master] + stems { for ch in t { for v in ch { top = max(top, abs(v)) } } }
        let gain: Float = top > 0.98 ? 0.98 / top : 1

        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: tmp, fileType: .mp4) } catch {
            throw SeparationError("non riesco a creare il file per DJ")
        }
        // La «moov» in fondo al file: così si può aggiungere l'atomo «stem» senza spostare l'audio
        writer.shouldOptimizeForNetworkUse = false
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: AudioIO.sampleRate,
                                       AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: bitrate]
        let tracks = [master] + stems
        let inputs = tracks.indices.map { i -> AVAssetWriterInput in
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            input.marksOutputTrackAsEnabled = i == 0
            writer.add(input)
            return input
        }
        guard writer.startWriting() else { throw SeparationError("non riesco a scrivere il file per DJ") }
        writer.startSession(atSourceTime: .zero)

        let format = try pcmFormat()
        let n = master[0].count, step = 8192
        guard n > 0, tracks.allSatisfy({ $0.count >= 1 && $0.allSatisfy { $0.count >= n } }) else {
            writer.cancelWriting()
            throw SeparationError("tracce incomplete per il file DJ")
        }
        // Le tracce si scrivono a turno, un pezzo per volta: AVAssetWriter le intreccia nel file e accetta
        // un pezzo di una traccia solo quando le altre sono abbastanza avanti
        var pos = [Int](repeating: 0, count: inputs.count)
        var finished = [Bool](repeating: false, count: inputs.count)
        var idle = Date()
        while finished.contains(false) && writer.status == .writing {
            var progressed = false
            for (i, input) in inputs.enumerated() where !finished[i] {
                var rounds = 0
                while input.isReadyForMoreMediaData && pos[i] < n && rounds < 4 {
                    let count = min(step, n - pos[i])
                    let sb = try sampleBuffer(tracks[i], from: pos[i], count: count, gain: gain, format: format)
                    guard input.append(sb) else { break }
                    pos[i] += count
                    rounds += 1
                    progressed = true
                }
                if pos[i] >= n {
                    input.markAsFinished()
                    finished[i] = true
                    progressed = true
                }
            }
            if progressed {
                idle = Date()
            } else {
                // Niente si muove da troppo: meglio fermarsi con un errore che restare bloccati
                if Date().timeIntervalSince(idle) > 30 { break }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        guard writer.status == .writing, !finished.contains(false) else {
            writer.cancelWriting()
            throw SeparationError("il file per DJ non si è completato (\(writer.error?.localizedDescription ?? "scrittura ferma"))")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw SeparationError("il file per DJ non si è completato (\(writer.error?.localizedDescription ?? "errore sconosciuto"))")
        }
        var data: Data
        do { data = try Data(contentsOf: tmp) } catch {
            throw SeparationError("non riesco a rileggere il file per DJ appena scritto (\(error.localizedDescription))")
        }
        try addStemAtom(to: &data)
        try? FileManager.default.removeItem(at: url)
        do { try data.write(to: url) } catch {
            throw SeparationError("non riesco a salvare \(url.lastPathComponent) (\(error.localizedDescription))")
        }
    }

    // MARK: Audio per AVAssetWriter

    private static func pcmFormat() throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(mSampleRate: AudioIO.sampleRate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var desc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &desc) == noErr, let d = desc else {
            throw SeparationError("non riesco a preparare l'audio per il file DJ")
        }
        return d
    }

    private static func sampleBuffer(_ ch: [[Float]], from start: Int, count: Int, gain: Float,
                                     format: CMAudioFormatDescription) throws -> CMSampleBuffer {
        var interleaved = [Float](repeating: 0, count: count * 2)
        let l = ch[0], r = ch[min(1, ch.count - 1)]
        for i in 0..<count {
            interleaved[2 * i] = min(1, max(-1, l[start + i] * gain))
            interleaved[2 * i + 1] = min(1, max(-1, r[start + i] * gain))
        }
        let bytes = count * 8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let b = block else {
            throw SeparationError("memoria insufficiente per il file DJ")
        }
        let copied = interleaved.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: b, offsetIntoDestination: 0, dataLength: bytes)
        }
        var sb: CMSampleBuffer?
        guard copied == noErr,
              CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: b,
                                                                   formatDescription: format, sampleCount: count,
                                                                   presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(AudioIO.sampleRate)),
                                                                   packetDescriptions: nil, sampleBufferOut: &sb) == noErr,
              let s = sb else {
            throw SeparationError("non riesco a preparare l'audio per il file DJ")
        }
        return s
    }

    // MARK: L'atomo «stem»

    /// I nomi e i colori delle tracce, come li scrive il programma di Native Instruments.
    static var metadata: Data {
        let json: [String: Any] = [
            "version": 1,
            "stems": layout.map { ["name": $0.name, "color": $0.color] },
            "mastering_dsp": [
                "compressor": ["enabled": false, "input_gain": 0.5, "output_gain": 0.5, "threshold": 0, "dry_wet": 50,
                               "attack": 0.003, "release": 0.3, "ratio": 3, "hp_cutoff": 300],
                "limiter": ["enabled": false, "threshold": 0, "ceiling": -0.35, "release": 0.05],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
    }

    /// Mette moov › udta › stem nel file. La «moov» deve essere l'ultimo atomo (così nessun riferimento all'audio cambia).
    static func addStemAtom(to data: inout Data) throws {
        func u32(_ o: Int) -> Int { data[o..<o + 4].reduce(0) { $0 << 8 | Int($1) } }
        func box(_ type: String, _ payload: Data) -> Data {
            var d = Data()
            let size = UInt32(8 + payload.count).bigEndian
            withUnsafeBytes(of: size) { d.append(contentsOf: $0) }
            d.append(type.data(using: .ascii)!)
            d.append(payload)
            return d
        }
        func setU32(_ o: Int, _ v: Int) {
            let b = withUnsafeBytes(of: UInt32(v).bigEndian) { Data($0) }
            data.replaceSubrange(o..<o + 4, with: b)
        }
        // Gli atomi principali (l'audio, «mdat», può avere la dimensione a 64 bit: 1 + 8 byte dopo il tipo)
        var o = 0, moov: Int?
        while o + 8 <= data.count {
            let size = boxSize(data, at: o)
            guard size >= 8, o + size <= data.count else { throw SeparationError("file per DJ non valido") }
            if String(data: data[o + 4..<o + 8], encoding: .ascii) == "moov" { moov = o }
            o += size
        }
        guard let m = moov, m + u32(m) == data.count else { throw SeparationError("file per DJ con una struttura inattesa") }
        let stem = box("stem", metadata)
        // C'è già una «udta» dentro la «moov»? Allora l'atomo va lì dentro
        var c = m + 8, udta: Int?
        while c + 8 <= m + u32(m) {
            if String(data: data[c + 4..<c + 8], encoding: .ascii) == "udta" { udta = c }
            c += max(8, u32(c))
        }
        if let u = udta {
            // Dentro la «udta» che c'è già: tutto quello che segue resta dentro la «moov», che è l'ultimo atomo,
            // quindi i riferimenti all'audio (nella «mdat», prima) non cambiano
            let end = u + u32(u)
            setU32(u, u32(u) + stem.count)
            setU32(m, u32(m) + stem.count)
            data.insert(contentsOf: stem, at: end)
        } else {
            let wrapped = box("udta", stem)
            setU32(m, u32(m) + wrapped.count)
            data.append(wrapped)
        }
    }

    /// La dimensione di un atomo MP4: 32 bit, oppure 1 = 64 bit nei byte dopo il tipo, oppure 0 = fino in fondo.
    static func boxSize(_ data: Data, at o: Int) -> Int {
        let start = data.startIndex + o
        let s32 = data[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
        if s32 == 1, o + 16 <= data.count { return data[start + 8..<start + 16].reduce(0) { $0 << 8 | Int($1) } }
        if s32 == 0 { return data.count - o }
        return s32
    }

    /// L'atomo «stem» di un file, se c'è (per le prove e per riconoscere i file).
    static func readMetadata(_ data: Data) -> Data? {
        func u32(_ o: Int) -> Int { data[o..<o + 4].reduce(0) { $0 << 8 | Int($1) } }
        func type(_ o: Int) -> String { String(data: data[o + 4..<o + 8], encoding: .ascii) ?? "" }
        /// Il primo figlio di tipo `name` tra `from` e `to`.
        func child(_ name: String, from: Int, to: Int) -> Int? {
            var o = from
            while o + 8 <= to {
                let size = boxSize(data, at: o)
                guard size >= 8, o + size <= to else { return nil }
                if type(o) == name { return o }
                o += size
            }
            return nil
        }
        guard let moov = child("moov", from: 0, to: data.count) else { return nil }
        let moovEnd = moov + u32(moov)
        var o = moov + 8
        // Si guarda in ogni «udta» della «moov»
        while let u = child("udta", from: o, to: moovEnd) {
            let uEnd = u + u32(u)
            if let st = child("stem", from: u + 8, to: uEnd) { return data[(st + 8)..<(st + u32(st))] }
            o = uEnd
        }
        return nil
    }
}
