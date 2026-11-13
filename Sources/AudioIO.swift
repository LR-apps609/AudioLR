import Foundation
import AVFoundation

// ════════════════════════════════════════════════════════════════════
//  Lettura e scrittura dell'audio. Il modello lavora in stereo a 44,1 kHz:
//  qualsiasi canzone che macOS sa aprire (MP3, M4A/AAC, ALAC, WAV, AIFF,
//  FLAC, CAF) viene portata lì; un audio mono diventa stereo, uno con più
//  di due canali tiene i primi due (come Demucs).
// ════════════════════════════════════════════════════════════════════

enum AudioIO {
    static let sampleRate = 44_100.0

    /// «MP3 · 44,1 kHz · stereo · 8,2 MB», per le informazioni sulla canzone.
    static func describe(_ url: URL) -> String? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        let fmt = f.fileFormat
        let khz = fmt.sampleRate / 1000
        let rate = khz == khz.rounded() ? String(format: "%.0f kHz", khz) : String(format: "%.1f kHz", khz).replacingOccurrences(of: ".", with: ",")
        let ch = fmt.channelCount == 1 ? "mono" : fmt.channelCount == 2 ? "stereo" : "\(fmt.channelCount) canali"
        var parts = [url.pathExtension.uppercased(), rate, ch]
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    /// Due canali a 44,1 kHz, valori tra −1 e 1.
    static func read(_ url: URL) throws -> [[Float]] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch {
            throw SeparationError("non riesco ad aprire questo file come audio")
        }
        let inFormat = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else {
            throw SeparationError("il file audio è vuoto")
        }
        try file.read(into: inBuf)

        var channels: [[Float]]
        if inFormat.sampleRate == sampleRate {
            channels = Self.channels(of: inBuf)
        } else if inFormat.channelCount > 2 {
            // 5.1 e simili a un'altra frequenza: si tengono i primi due canali, poi si cambia la frequenza
            let all = Self.channels(of: inBuf)
            guard let two = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inFormat.sampleRate, channels: 2, interleaved: false),
                  let buf = AVAudioPCMBuffer(pcmFormat: two, frameCapacity: inBuf.frameLength), let dst = buf.floatChannelData else {
                throw SeparationError("non riesco a convertire questo audio")
            }
            buf.frameLength = inBuf.frameLength
            for c in 0..<2 { all[c].withUnsafeBufferPointer { dst[c].update(from: $0.baseAddress!, count: all[c].count) } }
            channels = try resample(buf)
        } else {
            channels = try resample(inBuf)
        }
        if channels.count == 1 { channels.append(channels[0]) }
        return Array(channels.prefix(2))
    }

    private static func channels(of buf: AVAudioPCMBuffer) -> [[Float]] {
        guard let data = buf.floatChannelData else { return [] }
        let n = Int(buf.frameLength)
        return (0..<Int(buf.format.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: n)) }
    }

    /// Cambia la frequenza di campionamento tenendo lo stesso numero di canali.
    private static func resample(_ inBuf: AVAudioPCMBuffer) throws -> [[Float]] {
        let inFormat = inBuf.format
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                            channels: inFormat.channelCount, interleaved: false),
              let conv = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw SeparationError("non riesco a convertire questo audio")
        }
        conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        conv.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering

        var result = [[Float]](repeating: [], count: Int(inFormat.channelCount))
        let block: AVAudioFrameCount = 1 << 16
        var given = false
        while true {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: block) else { break }
            var err: NSError?
            let status = conv.convert(to: outBuf, error: &err) { _, inStatus in
                if given { inStatus.pointee = .endOfStream; return nil }
                given = true
                inStatus.pointee = .haveData
                return inBuf
            }
            if status == .error { throw SeparationError("non riesco a convertire questo audio") }
            let part = channels(of: outBuf)
            for c in 0..<result.count { result[c] += part[c] }
            if status == .endOfStream || outBuf.frameLength == 0 { break }
        }
        return result
    }

    /// WAV a 24 bit, stereo, 44,1 kHz.
    static func writeWAV(_ channels: [[Float]], to url: URL) throws {
        try write(channels, to: url, format: .wav24)
    }

    /// Scrive le tracce nel formato scelto (WAV, FLAC, Apple Lossless), a 44,1 kHz.
    static func write(_ channels: [[Float]], to url: URL, format: OutputFormat, gain: Float = 1) throws {
        let n = channels.first?.count ?? 0
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                      channels: AVAudioChannelCount(channels.count), interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(max(n, 1))),
              let data = buf.floatChannelData else {
            throw SeparationError("non riesco a preparare il file audio")
        }
        buf.frameLength = AVAudioFrameCount(n)
        for (c, ch) in channels.enumerated() {
            for i in 0..<n { data[c][i] = min(1, max(-1, ch[i] * gain)) }
        }
        try? FileManager.default.removeItem(at: url)
        do {
            // Il file si chiude (e si completa) quando `file` esce da qui
            let file = try AVAudioFile(forWriting: url, settings: format.settings(channels: channels.count, sampleRate: sampleRate),
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buf)
        } catch {
            // Disco pieno: lo si dice (prima solo «non riesco a scrivere…»), e il file a metà si toglie (dal tester t16)
            let needed = Int64(max(n, 1)) * Int64(max(channels.count, 1)) * 4
            if isDiskFull(error, free: freeSpace(at: url.deletingLastPathComponent()), needed: needed) {
                try? FileManager.default.removeItem(at: url)
                throw DiskFullError(file: url.lastPathComponent)
            }
            throw SeparationError("non riesco a scrivere \(url.lastPathComponent)")
        }
    }

    /// Lo spazio sul disco è finito mentre si scriveva un file.
    struct DiskFullError: LocalizedError {
        let file: String
        var errorDescription: String? { "lo spazio sul disco è finito mentre salvavo \(file): libera spazio e riprova" }
    }

    /// Un errore di scrittura è il disco pieno: lo dice l'errore stesso (ENOSPC, «spazio esaurito»), oppure
    /// lo spazio libero rimasto (`free`) non basta per il file (`needed`).
    static func isDiskFull(_ error: Error, free: Int64?, needed: Int64) -> Bool {
        let ns = error as NSError
        if (ns.domain == NSPOSIXErrorDomain || ns.domain == NSOSStatusErrorDomain) && ns.code == Int(ENOSPC) { return true }
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return true }
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? Error, isDiskFull(under, free: nil, needed: 0) { return true }
        if let f = free, f < needed { return true }
        return false
    }

    /// Lo spazio libero sul disco di una cartella, in byte (nil se non si sa).
    static func freeSpace(at dir: URL) -> Int64? {
        (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    /// Il messaggio quando il disco si riempie salvando le tracce: quanto spazio serve, e che la separazione va rifatta.
    static func diskFullMessage(needed: Int64) -> String {
        let size = ByteCountFormatter.string(fromByteCount: max(needed, 1), countStyle: .file)
        return "lo spazio sul disco è finito mentre salvavo le tracce: libera almeno \(size) e premi «Riprova»"
    }
}
