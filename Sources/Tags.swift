import Foundation
import AVFoundation

// ════════════════════════════════════════════════════════════════════
//  Tempo e tonalità dentro i file scaricati, dove li leggono i programmi
//  dei DJ e dei musicisti (Rekordbox, Serato, Traktor, Ableton, Musica):
//  • WAV: un blocco «id3 » (ID3v2.3: TBPM, TKEY, TIT2, TPE1) e LIST/INFO;
//  • FLAC: commenti Vorbis BPM, INITIALKEY, TITLE, ARTIST;
//  • M4A (AAC, Apple Lossless): tmpo, titolo, artista, la chiave nel commento.
//  Titolo e artista vengono dal nome («Artista - Titolo») quando c'è.
// ════════════════════════════════════════════════════════════════════

enum Tags {
    struct Info: Equatable, Sendable {
        var title: String
        var artist: String?
        var bpm: Int?
        /// «Am», «F#», «Bb»: come la scrivono i programmi (ID3 TKEY, solo lettere ASCII).
        var key: String?

        /// Dal nome della canzone e dalla sua analisi; con il tono cambiato (Transpose) anche la tonalità cambia.
        init(song: String, analysis: SongAnalysis?, shift: Int = 0) {
            let (artist, title) = Tags.split(song)
            self.title = title
            self.artist = artist
            if let a = analysis {
                bpm = Int(a.bpm.rounded())
                key = Tags.keyName(root: a.keyRoot + shift, minor: a.minor)
            }
        }

        init(title: String, artist: String? = nil, bpm: Int? = nil, key: String? = nil) {
            self.title = title; self.artist = artist; self.bpm = bpm; self.key = key
        }

        var comment: String { [bpm.map { "\($0) BPM" }, key].compactMap { $0 }.joined(separator: " · ") }
    }

    static let keyNames = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]

    static func keyName(root: Int, minor: Bool) -> String {
        keyNames[((root % 12) + 12) % 12] + (minor ? "m" : "")
    }

    /// «Eminem - Till I Collapse» → («Eminem», «Till I Collapse»); senza trattino solo il titolo.
    static func split(_ name: String) -> (artist: String?, title: String) {
        for sep in [" – ", " - ", " — "] {
            if let r = name.range(of: sep) {
                let a = name[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                let t = name[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if !a.isEmpty && !t.isEmpty { return (a, t) }
            }
        }
        return (nil, name)
    }

    /// Scrive i dati nel file appena salvato, secondo il suo formato. Se non riesce il file resta com'è.
    static func apply(_ info: Info, to url: URL) throws {
        switch url.pathExtension.lowercased() {
        case "wav", "wave":
            let data = try Data(contentsOf: url)
            try wav(data, info).write(to: url, options: .atomic)
        case "flac":
            let data = try Data(contentsOf: url)
            try flac(data, info).write(to: url, options: .atomic)
        case "m4a", "aac", "mp4":
            try m4a(url, info)
        default:
            break
        }
    }

    // MARK: WAV

    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func readLE32(_ d: Data, _ at: Int) -> UInt32 {
        UInt32(d[at]) | UInt32(d[at + 1]) << 8 | UInt32(d[at + 2]) << 16 | UInt32(d[at + 3]) << 24
    }

    private static func chunk(_ id: String, _ body: Data) -> Data {
        var c = Data(id.utf8)
        c += le32(UInt32(body.count))
        c += body
        if body.count % 2 == 1 { c.append(0) }
        return c
    }

    /// ID3v2.3 con i frame di testo (Latin-1 se basta, altrimenti UTF-16 con BOM).
    static func id3(_ info: Info) -> Data {
        func frame(_ id: String, _ text: String) -> Data {
            var body = Data()
            if let latin = text.data(using: .isoLatin1) {
                body.append(0); body += latin
            } else {
                body.append(1); body += Data([0xFF, 0xFE]); body += text.data(using: .utf16LittleEndian) ?? Data()
            }
            var f = Data(id.utf8)
            let n = UInt32(body.count)
            f += Data([UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF), 0, 0])
            return f + body
        }
        var frames = frame("TIT2", info.title)
        if let a = info.artist { frames += frame("TPE1", a) }
        if let b = info.bpm { frames += frame("TBPM", String(b)) }
        if let k = info.key { frames += frame("TKEY", k) }
        // Dimensione «synchsafe»: 7 bit per byte
        let n = frames.count
        var h = Data("ID3".utf8)
        h += Data([3, 0, 0, UInt8(n >> 21 & 0x7F), UInt8(n >> 14 & 0x7F), UInt8(n >> 7 & 0x7F), UInt8(n & 0x7F)])
        return h + frames
    }

    /// Il WAV con i blocchi «id3 » e LIST/INFO nuovi in fondo (quelli vecchi si tolgono), e la misura RIFF giusta.
    static func wav(_ data: Data, _ info: Info) throws -> Data {
        guard data.count >= 12, data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else {
            throw SeparationError("non è un file WAV")
        }
        var out = Data(data.prefix(12))
        var i = 12
        while i + 8 <= data.count {
            let id = String(decoding: data[i..<i + 4], as: UTF8.self)
            let size = Int(readLE32(data, i + 4))
            let end = min(data.count, i + 8 + size + size % 2)
            let isList = id == "LIST" && i + 12 <= data.count && data[i + 8..<i + 12] == Data("INFO".utf8)
            if id != "id3 " && id != "ID3 " && !isList { out += data[i..<end] }
            i = end
        }
        var list = Data("INFO".utf8)
        func zstr(_ s: String) -> Data { var d = s.data(using: .isoLatin1) ?? Data(s.utf8); d.append(0); return d }
        list += chunk("INAM", zstr(info.title))
        if let a = info.artist { list += chunk("IART", zstr(a)) }
        if !info.comment.isEmpty { list += chunk("ICMT", zstr(info.comment)) }
        out += chunk("LIST", list)
        out += chunk("id3 ", id3(info))
        out.replaceSubrange(4..<8, with: le32(UInt32(out.count - 8)))
        return out
    }

    /// I frame di testo nel blocco «id3 » di un WAV (per le prove e per controllare).
    static func readWAV(_ data: Data) -> [String: String] {
        var i = 12
        while i + 8 <= data.count {
            let id = String(decoding: data[i..<i + 4], as: UTF8.self)
            let size = Int(readLE32(data, i + 4))
            if id == "id3 " { return readID3(Data(data[(i + 8)..<min(data.count, i + 8 + size)])) }
            i += 8 + size + size % 2
        }
        return [:]
    }

    static func readID3(_ d: Data) -> [String: String] {
        guard d.count > 10, d.prefix(3) == Data("ID3".utf8) else { return [:] }
        var out: [String: String] = [:]
        var i = 10
        while i + 10 <= d.count {
            let id = String(decoding: d[i..<i + 4], as: UTF8.self)
            let n = Int(d[i + 4]) << 24 | Int(d[i + 5]) << 16 | Int(d[i + 6]) << 8 | Int(d[i + 7])
            guard n > 0, i + 10 + n <= d.count else { break }
            let body = d[(i + 10)..<(i + 10 + n)]
            let enc = body.first ?? 0
            let text = body.dropFirst()
            out[id] = enc == 1 ? String(data: Data(text.dropFirst(2)), encoding: .utf16LittleEndian) : String(data: Data(text), encoding: .isoLatin1)
            i += 10 + n
        }
        return out
    }

    // MARK: FLAC

    /// Il FLAC con un blocco VORBIS_COMMENT nuovo al posto di quello vecchio (gli altri blocchi restano).
    static func flac(_ data: Data, _ info: Info) throws -> Data {
        guard data.count > 8, data.prefix(4) == Data("fLaC".utf8) else { throw SeparationError("non è un file FLAC") }
        var blocks: [(type: UInt8, body: Data)] = []
        var i = 4, last = false
        while !last && i + 4 <= data.count {
            let head = data[i]
            last = head & 0x80 != 0
            let n = Int(data[i + 1]) << 16 | Int(data[i + 2]) << 8 | Int(data[i + 3])
            guard i + 4 + n <= data.count else { throw SeparationError("FLAC rovinato") }
            let type = head & 0x7F
            if type != 4 && type != 1 { blocks.append((type, Data(data[(i + 4)..<(i + 4 + n)]))) }
            i += 4 + n
        }
        var fields = ["TITLE=\(info.title)"]
        if let a = info.artist { fields.append("ARTIST=\(a)") }
        if let b = info.bpm { fields.append("BPM=\(b)") }
        if let k = info.key { fields.append("INITIALKEY=\(k)") }
        if !info.comment.isEmpty { fields.append("COMMENT=\(info.comment)") }
        let vendor = Data("IsoLR".utf8)
        var vc = le32(UInt32(vendor.count)) + vendor + le32(UInt32(fields.count))
        for f in fields { let b = Data(f.utf8); vc += le32(UInt32(b.count)) + b }
        // STREAMINFO resta primo, poi il commento, poi il resto
        let streamIndex = blocks.firstIndex { $0.type == 0 } ?? 0
        blocks.insert((4, vc), at: min(blocks.count, streamIndex + 1))
        var out = Data("fLaC".utf8)
        for (k, b) in blocks.enumerated() {
            let n = b.body.count
            out.append(b.type | (k == blocks.count - 1 ? 0x80 : 0))
            out += Data([UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
            out += b.body
        }
        out += data[i...]
        return out
    }

    /// I commenti Vorbis di un FLAC (per le prove).
    static func readFLAC(_ data: Data) -> [String: String] {
        var i = 4, last = false
        while !last && i + 4 <= data.count {
            last = data[i] & 0x80 != 0
            let type = data[i] & 0x7F
            let n = Int(data[i + 1]) << 16 | Int(data[i + 2]) << 8 | Int(data[i + 3])
            if type == 4 {
                let b = Data(data[(i + 4)..<(i + 4 + n)])
                var j = 4 + Int(readLE32(b, 0))
                let count = Int(readLE32(b, j)); j += 4
                var out: [String: String] = [:]
                for _ in 0..<count {
                    let len = Int(readLE32(b, j)); j += 4
                    let s = String(decoding: b[j..<j + len], as: UTF8.self); j += len
                    if let eq = s.firstIndex(of: "=") { out[String(s[..<eq]).uppercased()] = String(s[s.index(after: eq)...]) }
                }
                return out
            }
            i += 4 + n
        }
        return [:]
    }

    // MARK: M4A

    /// Titolo, artista, tempo e (nel commento) la tonalità, riscrivendo il file senza ricodificarlo.
    static func m4a(_ url: URL, _ info: Info) throws {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw SeparationError("non riesco a scrivere i dati nel file")
        }
        func item(_ id: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value
            return m
        }
        var items = [item(.iTunesMetadataSongName, info.title as NSString)]
        if let a = info.artist { items.append(item(.iTunesMetadataArtist, a as NSString)) }
        if let b = info.bpm { items.append(item(.iTunesMetadataBeatsPerMin, NSNumber(value: Int16(clamping: b)))) }
        if !info.comment.isEmpty { items.append(item(.iTunesMetadataUserComment, info.comment as NSString)) }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".isolr-tag-\(UUID().uuidString).m4a")
        export.outputURL = tmp
        export.outputFileType = .m4a
        export.metadata = items
        let done = DispatchSemaphore(value: 0)
        export.exportAsynchronously { done.signal() }
        done.wait()
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: tmp)
            throw SeparationError("non riesco a scrivere i dati nel file")
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
