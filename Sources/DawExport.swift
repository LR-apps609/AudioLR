import Foundation
import Compression

// ════════════════════════════════════════════════════════════════════
//  «Progetto per…»: le tracce separate pronte da aprire in un programma
//  musicale. Copia di windows/ui/core/daw.js: se qui cambia qualcosa, va
//  cambiato anche lì.
//  • Ableton Live: un set .als (XML compresso con gzip) con una traccia
//    audio per strumento, il tempo della canzone, i locatori sulle parti
//    e, se ci sono i battiti, i segnaposto di warp sul primo battito di
//    ogni battuta (la griglia di Live segue la canzone).
//  • REAPER: un .rpp (testo) con tracce, colori, tempo e marcatori.
//  • Tutti gli altri (Logic, GarageBand, FL Studio, Cubase, Studio One):
//    le tracce numerate e allineate, un MIDI con la mappa del tempo e i
//    marcatori delle parti, e un LEGGIMI.
//  • DJ: un foglio .cue con le parti (formato CUE, documentato e letto da
//    molti programmi) e lo stesso elenco in testo semplice.
// ════════════════════════════════════════════════════════════════════

enum DawExport {
    enum Kind: String, CaseIterable, Identifiable {
        case ableton, reaper, daw
        var id: String { rawValue }
        var title: String {
            switch self {
            case .ableton: return "Ableton Live"
            case .reaper: return "REAPER"
            case .daw: return "Logic, GarageBand, FL Studio, altri"
            }
        }
    }

    struct Track: Equatable {
        let key: String
        let name: String
        /// Percorso relativo nella cartella del progetto.
        let file: String
        let seconds: Double
    }

    struct Section: Equatable {
        let start: Double
        let label: String
    }

    struct Project: Equatable {
        var title: String
        var bpm: Double
        var key: String?
        var seconds: Double
        var tracks: [Track]
        var beats: [Double] = []
        var firstDownbeat = 0
        var beatsPerBar = 4
        var sections: [Section] = []
        /// Senza analisi (canzone cortissima) 120 BPM è solo di serie: non si scrive nei nomi come se fosse misurato
        var measured = true
    }

    /// «120 BPM · La minore» con solo quello che si sa davvero.
    static func heading(_ p: Project, _ sep: String) -> String {
        [p.measured ? "\(Int(p.bpm.rounded())) BPM" : nil, p.key].compactMap { $0 }.joined(separator: sep)
    }

    /// Colori delle tracce (gli stessi del tema scuro) e il colore più vicino della tavolozza di Ableton (0…69).
    static func color(_ key: String) -> (rgb: Int, live: Int) {
        switch key {
        case "vocals", "lead", "male": return (key == "vocals" ? 0xFF7A66 : key == "lead" ? 0xEC8A70 : 0xE07F66, 14)
        case "clean": return (0xFF8F7D, 14)
        case "backing": return (0xF0B3A2, 2)
        case "female": return (0xF4B49B, 2)
        case "drums": return (0xFFC24B, 4)
        case "bass": return (0xB48CFF, 24)
        case "guitar": return (0x8EE07A, 6)
        case "piano": return (0x7FA8FF, 21)
        case "other": return (0x43E0C2, 8)
        case "instrumental": return (0x6CC3FF, 21)
        default: return (0xC9C2D2, 13)
        }
    }

    /// Il progetto: le parti comuni a tutti i formati.
    static func project(title: String, bpm: Double?, key: String?, seconds: Double, tracks: [Track], structure: SongStructure?) -> Project {
        var p = Project(title: title, bpm: max(20, min(300, bpm ?? 120)), key: key, seconds: seconds, tracks: tracks)
        p.measured = (bpm ?? 0) > 0
        if let s = structure {
            p.beats = s.beats.filter { $0 >= 0 && $0 <= seconds }
            p.firstDownbeat = s.firstDownbeat
            p.beatsPerBar = s.beatsPerBar
            p.sections = s.sections.filter { $0.start < seconds }.map { Section(start: max(0, $0.start), label: $0.label) }
        }
        return p
    }

    static func downbeats(_ p: Project) -> [Double] {
        stride(from: p.firstDownbeat, to: p.beats.count, by: max(1, p.beatsPerBar)).map { p.beats[$0] }
    }

    /// I segnaposto di warp: (secondi, battito di Live). Vuoto senza battiti (la clip resta senza warp).
    static func warpMarkers(_ p: Project) -> [(sec: Double, beat: Double)] {
        let d = downbeats(p)
        guard d.count >= 2 else { return [] }
        let bar = Double(p.beatsPerBar)
        let start = d[0] * p.bpm / 60
        let first = (start / bar).rounded() * bar
        return d.enumerated().map { (i, s) in (s, first + Double(i) * bar) }
    }

    /// Da secondi a battiti di Live: lungo i segnaposto (se ci sono), altrimenti al tempo della canzone.
    static func beat(_ p: Project, at sec: Double, markers: [(sec: Double, beat: Double)]) -> Double {
        guard markers.count >= 2 else { return sec * p.bpm / 60 }
        var i = 0
        while i < markers.count - 2 && sec > markers[i + 1].sec { i += 1 }
        let a = markers[i], b = markers[i + 1]
        return a.beat + (sec - a.sec) * (b.beat - a.beat) / (b.sec - a.sec)
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Un numero senza zeri inutili (come Number.toString in JavaScript, arrotondato al milionesimo).
    static func num(_ x: Double) -> String {
        let r = (x * 1e6).rounded() / 1e6
        if r == r.rounded(), abs(r) < 1e15 { return String(Int(r)) }
        var s = String(format: "%.6f", r)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }

    // MARK: Ableton Live

    /// Il set di Live come XML (schema di Live 11, che apre anche Live 12).
    static func abletonXML(_ p: Project) -> String {
        let markers = warpMarkers(p)
        let warped = markers.count >= 2
        let end = num(beat(p, at: p.seconds, markers: markers))
        var id = 100
        func nid() -> Int { id += 1; return id }
        var tracks: [String] = []
        for (i, t) in p.tracks.enumerated() {
            let col = color(t.key).live
            var warp = ""
            if warped {
                for m in markers { warp += "<WarpMarker Id=\"\(nid())\" SecTime=\"\(num(m.sec))\" BeatTime=\"\(num(m.beat))\" />" }
            } else {
                warp = "<WarpMarker Id=\"\(nid())\" SecTime=\"0\" BeatTime=\"0\" />"
                warp += "<WarpMarker Id=\"\(nid())\" SecTime=\"\(num(p.seconds))\" BeatTime=\"\(end)\" />"
            }
            let name = esc(t.name), file = esc(t.file)
            let samples = Int((p.seconds * 44100).rounded())
            var x = "<AudioTrack Id=\"\(i + 10)\">\n"
            x += "<LomId Value=\"0\" /><LomIdView Value=\"0\" /><IsContentSelectedInDocument Value=\"false\" /><PreferredContentViewMode Value=\"0\" />\n"
            x += "<TrackDelay><Value Value=\"0\" /><IsValueSampleBased Value=\"false\" /></TrackDelay>\n"
            x += "<Name><EffectiveName Value=\"\(name)\" /><UserName Value=\"\(name)\" /><Annotation Value=\"\" /><MemorizedFirstClipName Value=\"\" /></Name>\n"
            x += "<Color Value=\"\(col)\" /><TrackGroupId Value=\"-1\" /><TrackUnfolded Value=\"true\" />\n"
            x += "<DeviceChain>\n"
            x += "<Mixer><Volume><Manual Value=\"1\" /></Volume><Pan><Manual Value=\"0\" /></Pan><Speaker><Manual Value=\"true\" /></Speaker></Mixer>\n"
            x += "<MainSequencer><Sample><ArrangerAutomation><Events>\n"
            x += "<AudioClip Id=\"\(nid())\" Time=\"0\">\n"
            x += "<LomId Value=\"0\" /><CurrentStart Value=\"0\" /><CurrentEnd Value=\"\(end)\" />\n"
            x += "<Loop><LoopStart Value=\"0\" /><LoopEnd Value=\"\(end)\" /><StartRelative Value=\"0\" /><LoopOn Value=\"false\" /><OutMarker Value=\"\(end)\" /><HiddenLoopStart Value=\"0\" /><HiddenLoopEnd Value=\"\(end)\" /></Loop>\n"
            x += "<Name Value=\"\(name)\" /><Annotation Value=\"\" /><Color Value=\"\(col)\" /><Disabled Value=\"false\" />\n"
            x += "<SampleRef><FileRef><RelativePathType Value=\"3\" /><RelativePath Value=\"\(file)\" /><Path Value=\"\(file)\" /><Type Value=\"1\" /><LivePackName Value=\"\" /><LivePackId Value=\"\" /><OriginalFileSize Value=\"0\" /><OriginalCrc Value=\"0\" /></FileRef><LastModDate Value=\"0\" /><DefaultDuration Value=\"\(samples)\" /><DefaultSampleRate Value=\"44100\" /></SampleRef>\n"
            x += "<WarpMarkers>\(warp)</WarpMarkers>\n"
            x += "<MarkersGenerated Value=\"true\" /><IsWarped Value=\"\(warped)\" /><WarpMode Value=\"4\" /><GranularityTones Value=\"30\" /><GranularityTexture Value=\"65\" /><FluctuationTexture Value=\"25\" /><ComplexProFormants Value=\"100\" /><ComplexProEnvelope Value=\"128\" />\n"
            x += "<Fades><FadeInLength Value=\"0\" /><FadeOutLength Value=\"0\" /><ClipFadesAreInitialized Value=\"true\" /><IsDefaultFadeIn Value=\"true\" /><IsDefaultFadeOut Value=\"true\" /></Fades>\n"
            x += "<PitchCoarse Value=\"0\" /><PitchFine Value=\"0\" /><SampleVolume Value=\"1\" />\n"
            x += "</AudioClip>\n"
            x += "</Events></ArrangerAutomation></Sample></MainSequencer>\n"
            x += "</DeviceChain>\n"
            x += "</AudioTrack>"
            tracks.append(x)
        }
        var locators: [String] = []
        for (i, s) in p.sections.enumerated() {
            let t = num(beat(p, at: s.start, markers: markers))
            locators.append("<Locator Id=\"\(i)\"><LomId Value=\"0\" /><Time Value=\"\(t)\" /><Name Value=\"\(esc(s.label))\" /><Annotation Value=\"\" /><IsSongStart Value=\"false\" /></Locator>")
        }
        let signature = p.beatsPerBar == 3 ? 202 : 201
        let note = esc(p.title) + (p.key.map { " · " + esc($0) } ?? "") + " · separata con IsoLR"
        var x = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        x += "<Ableton MajorVersion=\"5\" MinorVersion=\"11.0_433\" SchemaChangeCount=\"3\" Creator=\"IsoLR\" Revision=\"\">\n"
        x += "<LiveSet>\n"
        x += "<NextPointeeId Value=\"\(id + 10)\" /><OverwriteProtectionNumber Value=\"2816\" /><LomId Value=\"0\" /><LomIdView Value=\"0\" />\n"
        x += "<Tracks>\n" + tracks.joined(separator: "\n") + "\n</Tracks>\n"
        x += "<MasterTrack>\n"
        x += "<Name><EffectiveName Value=\"Master\" /><UserName Value=\"\" /><Annotation Value=\"\" /></Name>\n"
        x += "<DeviceChain><Mixer>\n"
        x += "<Tempo><LomId Value=\"0\" /><Manual Value=\"\(num(p.bpm))\" /><MidiControllerRange><Min Value=\"60\" /><Max Value=\"200\" /></MidiControllerRange><AutomationTarget Id=\"8\"><LockEnvelope Value=\"0\" /></AutomationTarget></Tempo>\n"
        x += "<TimeSignature><LomId Value=\"0\" /><Manual Value=\"\(signature)\" /></TimeSignature>\n"
        x += "</Mixer></DeviceChain>\n"
        x += "</MasterTrack>\n"
        x += "<Locators><Locators>\n" + locators.joined(separator: "\n") + "\n</Locators></Locators>\n"
        x += "<Annotation Value=\"\(note)\" />\n"
        x += "</LiveSet>\n</Ableton>\n"
        return x
    }

    static func als(_ p: Project) -> Data { gzip(Data(abletonXML(p).utf8)) }

    // MARK: gzip (il formato di un .als)

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    /// DEFLATE con la libreria di sistema (Compression, zlib senza intestazione), dentro la busta gzip.
    static func gzip(_ data: Data) -> Data {
        var out = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF])
        let capacity = data.count + data.count / 10 + 1024
        var body = [UInt8](repeating: 0, count: capacity)
        let n = data.withUnsafeBytes { src in
            compression_encode_buffer(&body, capacity, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        out.append(contentsOf: body.prefix(n))
        var crc = crc32(data).littleEndian, size = UInt32(truncatingIfNeeded: data.count).littleEndian
        out.append(Data(bytes: &crc, count: 4))
        out.append(Data(bytes: &size, count: 4))
        return out
    }

    /// Il contrario di `gzip` (solo per le buste scritte qui: intestazione di 10 byte, senza campi extra).
    static func gunzip(_ data: Data) -> Data? {
        guard data.count > 18, data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B else { return nil }
        let bytes = [UInt8](data)
        let size = Int(UInt32(bytes[bytes.count - 4]) | UInt32(bytes[bytes.count - 3]) << 8 | UInt32(bytes[bytes.count - 2]) << 16 | UInt32(bytes[bytes.count - 1]) << 24)
        var out = [UInt8](repeating: 0, count: max(1, size))
        let body = Array(bytes[10..<(bytes.count - 8)])
        let n = compression_decode_buffer(&out, out.count, body, body.count, nil, COMPRESSION_ZLIB)
        return n == size ? Data(out.prefix(n)) : nil
    }

    // MARK: REAPER

    static func reaper(_ p: Project) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "'") + "\"" }
        var lines = ["<REAPER_PROJECT 0.1 \"6.0\" 0", "  SAMPLERATE 44100 0 0", "  TEMPO \(num(p.bpm)) \(p.beatsPerBar) 4"]
        for (i, s) in p.sections.enumerated() { lines.append("  MARKER \(i + 1) \(num(s.start)) \(q(s.label)) 0") }
        for t in p.tracks {
            let rgb = color(t.key).rgb
            // REAPER: rosso nei bit bassi, verde, blu; più il bit che dice «colore scelto»
            let r = (rgb >> 16) & 255, g = (rgb >> 8) & 255, b = rgb & 255
            let peak = r | (g << 8) | (b << 16) | 0x100_0000
            lines += ["  <TRACK", "    NAME \(q(t.name))", "    PEAKCOL \(peak)",
                      "    <ITEM", "      POSITION 0", "      LENGTH \(num(t.seconds))", "      NAME \(q(t.name))",
                      "      <SOURCE WAVE", "        FILE \(q(t.file))", "      >", "    >", "  >"]
        }
        lines.append(">")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: MIDI: mappa del tempo e marcatori

    static let ppq = 480

    private static func vlq(_ value: Int) -> [UInt8] {
        var v = max(0, value)
        var b = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 { b.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
        return b
    }

    private static func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 255), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)] }
    private static func text(_ s: String) -> [UInt8] { Array(Array(s.utf8).prefix(120)) }

    /// Da secondi a tick: lungo i battiti (un battito = 480 tick), al tempo della canzone fuori dai battiti.
    static func tick(_ p: Project, at sec: Double) -> Int {
        let b = p.beats, q = Double(ppq)
        guard b.count >= 2 else { return Int((sec * p.bpm * q / 60).rounded()) }
        let lead = b[0] * p.bpm * q / 60
        if sec <= b[0] {
            let first = (b[0] - sec) * (q / (b[1] - b[0]))
            return max(0, Int((lead - first).rounded()))
        }
        var i = 0
        while i < b.count - 2 && sec > b[i + 1] { i += 1 }
        let within = (sec - b[i]) / (b[i + 1] - b[i])
        return Int((lead.rounded() + (Double(i) + within) * q).rounded())
    }

    /// Un MIDI (formato 0): tempo che segue i battiti veri, metro, tonalità nel nome, marcatori delle parti.
    static func tempoMidi(_ p: Project) -> Data {
        var ev: [(tick: Int, order: Int, bytes: [UInt8])] = []
        func tempo(_ t: Int, _ secPerBeat: Double) {
            let us = max(200_000, min(3_000_000, Int((secPerBeat * 1e6).rounded())))
            ev.append((t, 0, [0xFF, 0x51, 0x03, UInt8((us >> 16) & 255), UInt8((us >> 8) & 255), UInt8(us & 255)]))
        }
        let name = text([p.title, heading(p, " · ")].filter { !$0.isEmpty }.joined(separator: " · "))
        ev.append((0, -2, [0xFF, 0x03] + vlq(name.count) + name))
        ev.append((0, -1, [0xFF, 0x58, 0x04, UInt8(p.beatsPerBar), 2, 24, 8]))
        tempo(0, 60 / p.bpm)
        let b = p.beats
        if b.count >= 2 {
            let lead = Int((b[0] * p.bpm * Double(ppq) / 60).rounded())
            for i in 0..<(b.count - 1) { tempo(lead + i * ppq, b[i + 1] - b[i]) }
        }
        for s in p.sections {
            let t = text(s.label)
            ev.append((tick(p, at: s.start), 1, [0xFF, 0x06] + vlq(t.count) + t))
        }
        ev.sort { ($0.tick, $0.order) < ($1.tick, $1.order) }
        var track: [UInt8] = []
        var last = 0
        for e in ev {
            track += vlq(e.tick - last) + e.bytes
            last = e.tick
        }
        track += [0x00, 0xFF, 0x2F, 0x00]
        var out: [UInt8] = text("MThd") + be32(6) + [0, 0, 0, 1, UInt8(ppq >> 8), UInt8(ppq & 255)]
        out += text("MTrk") + be32(track.count) + track
        return Data(out)
    }

    // MARK: DJ: foglio CUE e testo

    static func cueTime(_ sec: Double) -> String {
        let f = Int((sec * 75).rounded())
        return String(format: "%02d:%02d:%02d", f / 4500, (f % 4500) / 75, f % 75)
    }

    static func cueSheet(_ p: Project, file: String) -> String {
        let parts = p.sections.isEmpty ? [Section(start: 0, label: p.title)] : p.sections
        func clean(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "'") }
        var lines = ["TITLE \"\(clean(p.title))\""]
        if p.measured { lines.append("REM BPM \(num(p.bpm))") }
        if let k = p.key { lines.append("REM KEY \"\(k)\"") }
        lines.append("FILE \"\(clean(file))\" \(file.lowercased().hasSuffix(".wav") ? "WAVE" : "MP3")")
        for (i, s) in parts.enumerated() {
            lines += [String(format: "  TRACK %02d AUDIO", i + 1), "    TITLE \"\(clean(s.label))\"", "    INDEX 01 \(cueTime(s.start))"]
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// «0:02.4»: in decimi interi, arrotondati. Con `Int((s - s.rounded(.down)) * 10)` 2,4 s diventava «0:02.3»
    /// (0,3999…), come su Windows (dal tester t4 del giro 2).
    static func partsClock(_ s: Double) -> String {
        let d = Int((max(0, s) * 10).rounded())
        return String(format: "%d:%02d.%d", d / 600, (d / 10) % 60, d % 10)
    }

    static func partsText(_ p: Project) -> String {
        func clock(_ s: Double) -> String { partsClock(s) }
        let head = [p.title, heading(p, " · ")].filter { !$0.isEmpty }.joined(separator: " · ")
        return ([head, ""] + p.sections.map { "\(clock($0.start))  \($0.label)" }).joined(separator: "\r\n") + "\r\n"
    }

    /// Un nome che va bene come nome di file su Windows e sul Mac.
    static func safe(_ s: String) -> String {
        var out = ""
        for c in s { out.append("\\/:*?\"<>|".contains(c) ? "-" : c) }
        while out.last?.isWhitespace == true { out.removeLast() }
        return out
    }

    static func folderName(_ p: Project, kind: Kind) -> String {
        let tail = heading(p, ", ")
        switch kind {
        case .ableton: return safe("\(p.title) – Ableton Project")
        case .reaper: return safe("\(p.title) – REAPER")
        case .daw: return safe("\(p.title) – Tracce per DAW" + (tail.isEmpty ? "" : " (\(tail))"))
        }
    }

    /// «Samples/Imported/01 Voce.wav» per Live, «Media/…» per REAPER, «01 Voce.wav» per gli altri.
    static func trackFile(_ kind: Kind, index: Int, name: String) -> String {
        let dir = kind == .ableton ? "Samples/Imported/" : kind == .reaper ? "Media/" : ""
        return dir + String(format: "%02d ", index + 1) + safe(name) + ".wav"
    }

    static func readme(_ p: Project) -> String {
        let bpm = Int(p.bpm.rounded())
        return [
            "\(p.title) – tracce separate con IsoLR",
            (p.measured ? "Tempo: \(bpm) BPM" : "Tempo: non misurato (canzone troppo corta per l'analisi): il progetto usa \(bpm) BPM, da cambiare a mano") + (p.key.map { " · Tonalità: " + $0 } ?? ""),
            "",
            "Tutte le tracce iniziano a 0 e sono lunghe uguali: messe una sotto l'altra dall'inizio, sono allineate.",
            "«Tempo e marcatori.mid» contiene il tempo che segue i battiti veri della canzone e le parti (Intro, Strofa…). Trascinalo per primo.",
            "",
            "LOGIC PRO: trascina «Tempo e marcatori.mid» nella finestra principale e, se lo chiede, importa il tempo. Poi seleziona tutti i .wav e trascinali sotto, all'inizio (battuta 1).",
            "GARAGEBAND: imposta il tempo del progetto a \(bpm) BPM, disattiva «Regola tempo» per le regioni audio, poi trascina i .wav all'inizio, uno per traccia.",
            "FL STUDIO: File › Import › MIDI file per «Tempo e marcatori.mid» (spunta «Import tempo»); poi trascina i .wav nella Playlist a battuta 1.",
            "CUBASE: File › Importa › File MIDI (tempo e marcatori), poi File › Importa › File audio, «Posiziona ogni file su una traccia diversa», dall'inizio del progetto.",
            "STUDIO ONE: trascina il .mid nella traccia tempo/marcatori e i .wav all'inizio della canzone.",
            "",
            "Le parti sono anche in «Parti.cue» (foglio CUE, per programmi da DJ e lettori) e in «Parti.txt».",
        ].joined(separator: "\r\n") + "\r\n"
    }

    // MARK: Scrittura

    /// Scrive il progetto dentro `folder`: tracce allineate in WAV 24 bit, il file del programma, il MIDI del tempo.
    nonisolated static func write(kind: Kind, stems: [Stem], title: String, analysis: SongAnalysis?, shift: Int, into folder: URL) throws -> URL {
        // Come il mixer: la voce pulita o le parti divise prendono il posto della traccia d'origine (prima c'erano
        // tutte e due, attive, e la voce suonava doppia; come su Windows, dal tester t4 del giro 2)
        let list = MixPlayer.mixable(stems)
        var audio: [[[Float]]] = []
        var length = 0
        for s in list {
            let a = try PitchShift.apply(AudioIO.read(s.url), semitones: shift)
            audio.append(a)
            length = max(length, a.first?.count ?? 0)
        }
        let seconds = Double(length) / AudioIO.sampleRate
        let tracks = list.enumerated().map { (i, s) in Track(key: s.key, name: s.name, file: trackFile(kind, index: i, name: s.name), seconds: seconds) }
        let key = analysis.map { Transpose.keyName(root: $0.keyRoot, minor: $0.minor, shift: shift) }
        let p = project(title: title + Downloads.suffix(shift), bpm: analysis?.bpm, key: key, seconds: seconds, tracks: tracks, structure: analysis?.structure)
        let fm = FileManager.default
        let base = folderName(p, kind: kind)
        var dir = folder.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: dir.path) {
            dir = folder.appendingPathComponent("\(base) \(n)", isDirectory: true)
            n += 1
        }
        for (i, t) in tracks.enumerated() {
            let url = dir.appendingPathComponent(t.file)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Tutte lunghe uguali: messe una sotto l'altra sono allineate
            let padded = audio[i].map { c in c.count >= length ? c : c + [Float](repeating: 0, count: length - c.count) }
            try AudioIO.write(padded, to: url, format: .wav24)
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = safe(p.title)
        switch kind {
        case .ableton: try als(p).write(to: dir.appendingPathComponent("\(name).als"))
        case .reaper: try Data(reaper(p).utf8).write(to: dir.appendingPathComponent("\(name).rpp"))
        case .daw:
            try Data(cueSheet(p, file: tracks.first?.file ?? "\(name).wav").utf8).write(to: dir.appendingPathComponent("Parti.cue"))
            try Data(partsText(p).utf8).write(to: dir.appendingPathComponent("Parti.txt"))
            try Data(readme(p).utf8).write(to: dir.appendingPathComponent("LEGGIMI.txt"))
        }
        try tempoMidi(p).write(to: dir.appendingPathComponent("Tempo e marcatori.mid"))
        return dir
    }
}
