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
    /// Le quattro tracce nell'ordine del formato, con le chiavi di AudioLR che finiscono in ognuna.
    static let layout: [(name: String, color: String, keys: Set<String>)] = [
        ("Drums", "#C48E2C", Set(["drums"] + DrumSplitter.parts)),
        ("Bass", "#8C6AAF", ["bass"]),
        ("Other", "#3C978C", ["guitar", "piano", "other"]),
        ("Vocals", "#CF6F57", ["vocals", "lead", "backing"]),
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
            if mix.isEmpty { mix = (0..<2).map { c in (0..<n).map { i in parts.reduce(0) { $0 + $1[c][i] } } } }
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
        // Ogni traccia si scrive dalla sua coda quando il file è pronto a riceverla: AVAssetWriter le intreccia
        await withTaskGroup(of: Void.self) { group in
            for (i, input) in inputs.enumerated() {
                group.addTask {
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        var pos = 0
                        let queue = DispatchQueue(label: "audiolr.stem.\(i)")
                        input.requestMediaDataWhenReady(on: queue) {
                            while input.isReadyForMoreMediaData {
                                if pos >= n || writer.status != .writing {
                                    input.markAsFinished()
                                    done.resume()
                                    return
                                }
                                let count = min(step, n - pos)
                                if let sb = try? sampleBuffer(tracks[i], from: pos, count: count, gain: gain, format: format) {
                                    input.append(sb)
                                }
                                pos += count
                            }
                        }
                    }
                }
            }
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw SeparationError("il file per DJ non si è completato (\(writer.error?.localizedDescription ?? "errore sconosciuto"))")
        }
        var data = try Data(contentsOf: tmp)
        try addStemAtom(to: &data)
        try? FileManager.default.removeItem(at: url)
        try data.write(to: url, options: .atomic)
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
        // Gli atomi principali
        var o = 0, moov: Int?
        while o + 8 <= data.count {
            let size = u32(o)
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
        if let u = udta, u + u32(u) == data.count {
            setU32(u, u32(u) + stem.count)
            setU32(m, u32(m) + stem.count)
            data.append(stem)
        } else {
            let wrapped = box("udta", stem)
            setU32(m, u32(m) + wrapped.count)
            data.append(wrapped)
        }
    }

    /// L'atomo «stem» di un file, se c'è (per le prove e per riconoscere i file).
    static func readMetadata(_ data: Data) -> Data? {
        guard let r = data.range(of: Data("stem".utf8), options: .backwards), r.lowerBound >= 4 else { return nil }
        let start = r.lowerBound - 4
        let size = data[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
        guard size > 8, start + size <= data.count else { return nil }
        return data[(start + 8)..<(start + size)]
    }
}
