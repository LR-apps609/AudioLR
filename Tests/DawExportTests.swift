import XCTest

/// «Progetto per…»: set di Ableton, progetto REAPER, MIDI con tempo e marcatori, foglio CUE (come windows/ui/core/test/daw.test.js).
final class DawExportTests: XCTestCase {
    /// 96 BPM con un battito un po' in ritardo a metà: 20 s, battute da 4, due parti.
    private func sample() -> DawExport.Project {
        var beats: [Double] = []
        var t = 0.5
        while t < 20 { beats.append(t); t += 0.625 }
        beats[10] += 0.03
        let structure = SongStructure(beats: beats, firstDownbeat: 0, beatsPerBar: 4,
                                      sections: [SongSection(start: 0.5, end: 8, label: "Intro", group: 0),
                                                 SongSection(start: 8, end: 20, label: "Strofa", group: 1)])
        let tracks = [DawExport.Track(key: "vocals", name: "Voce", file: "Samples/Imported/01 Voce.wav", seconds: 20),
                      DawExport.Track(key: "drums", name: "Batteria", file: "Samples/Imported/02 Batteria.wav", seconds: 20)]
        return DawExport.project(title: "Prova & co", bpm: 96, key: "La minore", seconds: 20, tracks: tracks, structure: structure)
    }

    func testWarpMarkersOnDownbeats() {
        let p = sample()
        let m = DawExport.warpMarkers(p)
        XCTAssertGreaterThanOrEqual(m.count, 7)
        for i in 1..<m.count { XCTAssertEqual(m[i].beat - m[i - 1].beat, 4) }
        XCTAssertEqual(m[0].beat.truncatingRemainder(dividingBy: 4), 0)
        XCTAssertEqual(DawExport.beat(p, at: m[3].sec, markers: m), m[3].beat, accuracy: 1e-9)
    }

    func testAbletonSetIsGzippedXML() throws {
        let p = sample()
        let data = DawExport.als(p)
        XCTAssertEqual(Array(data.prefix(2)), [0x1F, 0x8B], "firma di gzip")
        let raw = try XCTUnwrap(DawExport.gunzip(data))
        let xml = String(decoding: raw, as: UTF8.self)
        XCTAssertTrue(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Ableton MajorVersion=\"5\""))
        XCTAssertEqual(xml.components(separatedBy: "<AudioTrack ").count - 1, 2)
        XCTAssertTrue(xml.contains("<RelativePath Value=\"Samples/Imported/01 Voce.wav\" />"))
        XCTAssertTrue(xml.contains("<Tempo><LomId Value=\"0\" /><Manual Value=\"96\" />"))
        XCTAssertTrue(xml.contains("<Name Value=\"Intro\" />"))
        XCTAssertTrue(xml.contains("<IsWarped Value=\"true\" />"))
        XCTAssertTrue(xml.contains("Prova &amp; co"))
        // Ben formato secondo il lettore XML di sistema
        let doc = try XMLDocument(data: raw)
        XCTAssertEqual(try doc.nodes(forXPath: "//AudioTrack").count, 2)
        XCTAssertEqual(try doc.nodes(forXPath: "//Locator").count, 2)
    }

    func testAbletonWithoutBeatsIsNotWarped() {
        let p = DawExport.project(title: "X", bpm: 120, key: nil, seconds: 10,
                                  tracks: [DawExport.Track(key: "bass", name: "Basso", file: "a.wav", seconds: 10)], structure: nil)
        XCTAssertTrue(DawExport.warpMarkers(p).isEmpty)
        XCTAssertEqual(DawExport.beat(p, at: 10, markers: []), 20)
        XCTAssertTrue(DawExport.abletonXML(p).contains("<IsWarped Value=\"false\" />"))
    }

    func testReaperProject() {
        let r = DawExport.reaper(sample())
        XCTAssertTrue(r.hasPrefix("<REAPER_PROJECT 0.1 \"6.0\" 0\n"))
        XCTAssertTrue(r.contains("\n  TEMPO 96 4 4\n"))
        XCTAssertTrue(r.contains("\n  MARKER 1 0.5 \"Intro\" 0\n"))
        XCTAssertTrue(r.contains("FILE \"Samples/Imported/01 Voce.wav\""))
        // Corallo #FF7A66: rosso nei bit bassi, più il bit del colore scelto
        XCTAssertTrue(r.contains("PEAKCOL \(0xFF | (0x7A << 8) | (0x66 << 16) | 0x100_0000)"))
        let lines = r.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(lines.filter { $0.hasPrefix("<") }.count, lines.filter { $0 == ">" }.count)
    }

    func testTempoMidiFollowsBeats() {
        let p = sample()
        let m = [UInt8](DawExport.tempoMidi(p))
        XCTAssertEqual(Array(m.prefix(4)), Array("MThd".utf8))
        var tempos = 0
        for i in 0..<(m.count - 2) where m[i] == 0xFF && m[i + 1] == 0x51 && m[i + 2] == 0x03 { tempos += 1 }
        XCTAssertEqual(tempos, p.beats.count)
        let s = String(decoding: m, as: UTF8.self)
        XCTAssertTrue(s.contains("Intro") && s.contains("Strofa"))
        XCTAssertEqual(DawExport.tick(p, at: p.beats[4]) - DawExport.tick(p, at: p.beats[0]), 4 * 480)
    }

    func testCueSheetAndNames() {
        let p = sample()
        let c = DawExport.cueSheet(p, file: "Prova.wav")
        XCTAssertTrue(c.contains("FILE \"Prova.wav\" WAVE"))
        XCTAssertTrue(c.contains("TRACK 01 AUDIO\r\n    TITLE \"Intro\"\r\n    INDEX 01 00:00:38"))
        XCTAssertTrue(c.contains("TRACK 02 AUDIO\r\n    TITLE \"Strofa\"\r\n    INDEX 01 00:08:00"))
        XCTAssertTrue(DawExport.folderName(p, kind: .daw).hasSuffix("Tracce per DAW (96 BPM, La minore)"))
        XCTAssertEqual(DawExport.trackFile(.ableton, index: 0, name: "Voce/Cori"), "Samples/Imported/01 Voce-Cori.wav")
    }
}
