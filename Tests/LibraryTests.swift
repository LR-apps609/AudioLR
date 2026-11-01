import XCTest
import AVFoundation

/// Filtri della libreria, anteprima di 20 s e tempo/tonalità nei file scaricati.
final class LibraryTests: XCTestCase {
    private func item(_ title: String, bpm: Double? = nil, root: Int = 0, minor: Bool = false, quality: String = "best", ago: Double = 0) -> HistoryItem {
        var i = HistoryItem(title: title, folder: "/tmp/\(title)", date: Date(timeIntervalSinceNow: -ago), quality: quality)
        if let b = bpm { i.analysis = SongAnalysis(bpm: b, keyRoot: root, minor: minor, keyConfidence: 0.8) }
        return i
    }

    func testCamelotCompatible() {
        // La minore (8A): compatibili 7A, 9A e Do maggiore (8B); non Fa♯ minore (11A)
        XCTAssertTrue(LibraryFilter.compatible((9, true), (9, true)))
        XCTAssertTrue(LibraryFilter.compatible((9, true), (2, true)))   // Re minore = 7A
        XCTAssertTrue(LibraryFilter.compatible((9, true), (4, true)))   // Mi minore = 9A
        XCTAssertTrue(LibraryFilter.compatible((9, true), (0, false)))  // Do maggiore = 8B
        XCTAssertFalse(LibraryFilter.compatible((9, true), (6, true)))
        // 12 e 1 sono vicini
        XCTAssertEqual(LibraryFilter.camelot(root: 1, minor: false).number, 3)
        XCTAssertTrue(LibraryFilter.compatible((4, false), (11, false)))  // Mi (12B) e Si (1B)
    }

    func testFiltersAndSort() {
        let items = [
            item("Uno", bpm: 120, root: 9, minor: true, ago: 30),
            item("Due", bpm: 64, root: 0, minor: false, quality: "studio", ago: 20),
            item("Tre", bpm: 140, root: 6, minor: true, ago: 10),
            item("Vecchia", ago: 5),
        ]
        var f = LibraryFilter()
        XCTAssertEqual(f.apply(items).map(\.title), ["Vecchia", "Tre", "Due", "Uno"])
        f.keyRoot = 9; f.minor = true
        XCTAssertEqual(f.apply(items).map(\.title), ["Uno"], "le canzoni senza analisi spariscono solo con filtri di tonalità")
        f.compatible = true
        XCTAssertEqual(Set(f.apply(items).map(\.title)), ["Uno", "Due"], "Do maggiore è la relativa di La minore")
        f = LibraryFilter(bpmMin: 118, bpmMax: 130)
        XCTAssertEqual(f.apply(items).map(\.title), ["Uno"])
        f.halfDouble = true
        XCTAssertEqual(Set(f.apply(items).map(\.title)), ["Uno", "Due"], "64 BPM al doppio fa 128")
        f = LibraryFilter(quality: "studio")
        XCTAssertEqual(f.apply(items).map(\.title), ["Due"])
        f = LibraryFilter(instrument: "piano")
        XCTAssertEqual(f.apply(items, stems: { $0.title == "Tre" ? ["piano", "vocals"] : ["vocals"] }).map(\.title), ["Tre"])
        f = LibraryFilter(text: "u")
        XCTAssertEqual(Set(f.apply(items).map(\.title)), ["Uno", "Due"])
        f = LibraryFilter(sort: .bpm)
        XCTAssertEqual(f.apply(items).map(\.title), ["Due", "Uno", "Tre", "Vecchia"])
        f = LibraryFilter(sort: .title)
        XCTAssertEqual(f.apply(items).first?.title, "Due")
        f = LibraryFilter(keyRoot: 9, minor: true, compatible: true, bpmMin: 120)
        XCTAssertEqual(f.chips.map(\.id), ["key", "bpm"])
        f.clear("key")
        XCTAssertNil(f.keyRoot)
    }

    func testPreviewRange() {
        let r = SeparationJob.previewRange(duration: 200, at: 0.5)
        XCTAssertEqual(r.start, 90, accuracy: 1e-9)
        XCTAssertEqual(r.end, 110, accuracy: 1e-9)
        XCTAssertEqual(SeparationJob.previewRange(duration: 200, at: 0).start, 0)
        XCTAssertEqual(SeparationJob.previewRange(duration: 200, at: 1).end, 200, accuracy: 1e-9)
        let short = SeparationJob.previewRange(duration: 12, at: 0.5)
        XCTAssertEqual(short.start, 0); XCTAssertEqual(short.end, 12)
    }

    func testTagInfoFromName() {
        let a = SongAnalysis(bpm: 119.6, keyRoot: 9, minor: true, keyConfidence: 0.9)
        let t = Tags.Info(song: "Eminem - Till I Collapse [HD]", analysis: a, shift: 2)
        XCTAssertEqual(t.artist, "Eminem")
        XCTAssertEqual(t.title, "Till I Collapse [HD]")
        XCTAssertEqual(t.bpm, 120)
        XCTAssertEqual(t.key, "Bm", "con il tono +2 La minore diventa Si minore")
        XCTAssertNil(Tags.Info(song: "Senza trattino", analysis: nil).artist)
    }

    private func tone(_ seconds: Double = 0.5) -> [[Float]] {
        let n = Int(seconds * AudioIO.sampleRate)
        let x = (0..<n).map { Float(sin(Double($0) * 0.05) * 0.3) }
        return [x, x]
    }

    func testWAVTagsReadBackAndAudioStays() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tag-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try AudioIO.write(tone(), to: url, format: .wav24)
        let info = Tags.Info(title: "Canzone", artist: "Artista", bpm: 128, key: "F#m")
        try Tags.apply(info, to: url)
        // Due volte: i blocchi vecchi si sostituiscono, non si accumulano
        try Tags.apply(info, to: url)
        let data = try Data(contentsOf: url)
        let tags = Tags.readWAV(data)
        XCTAssertEqual(tags["TBPM"], "128")
        XCTAssertEqual(tags["TKEY"], "F#m")
        XCTAssertEqual(tags["TIT2"], "Canzone")
        XCTAssertEqual(tags["TPE1"], "Artista")
        XCTAssertEqual(data.count - 8, Int(data[4]) | Int(data[5]) << 8 | Int(data[6]) << 16 | Int(data[7]) << 24, "misura RIFF giusta")
        XCTAssertEqual(data.components(separatedBy: "id3 "), 1)
        let back = try AudioIO.read(url)
        XCTAssertEqual(back[0].count, tone()[0].count, "l'audio resta intero")
    }

    func testFLACTagsReadBack() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tag-\(UUID().uuidString).flac")
        defer { try? FileManager.default.removeItem(at: url) }
        try AudioIO.write(tone(), to: url, format: .flac)
        try Tags.apply(Tags.Info(title: "Canzone", bpm: 96, key: "Eb"), to: url)
        let tags = Tags.readFLAC(try Data(contentsOf: url))
        XCTAssertEqual(tags["BPM"], "96")
        XCTAssertEqual(tags["INITIALKEY"], "Eb")
        XCTAssertEqual(tags["TITLE"], "Canzone")
        XCTAssertEqual(try AudioIO.read(url)[0].count, tone()[0].count)
    }

    func testM4ATagsReadBack() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tag-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try AudioIO.write(tone(1), to: url, format: .aac)
        try Tags.apply(Tags.Info(title: "Canzone", artist: "Artista", bpm: 100, key: "C"), to: url)
        let items = try await AVURLAsset(url: url).load(.metadata)
        var found: [String: String] = [:]
        for i in items {
            guard let id = i.identifier else { continue }
            if let v = try? await i.load(.stringValue) { found[id.rawValue] = v }
            if found[id.rawValue] == nil, let n = try? await i.load(.numberValue) { found[id.rawValue] = n.stringValue }
        }
        XCTAssertEqual(found[AVMetadataIdentifier.iTunesMetadataBeatsPerMin.rawValue], "100")
        XCTAssertEqual(found[AVMetadataIdentifier.iTunesMetadataSongName.rawValue], "Canzone")
    }
}

private extension Data {
    /// Quante volte compare una sequenza di caratteri (per contare i blocchi).
    func components(separatedBy s: String) -> Int {
        let p = Data(s.utf8)
        var n = 0, i = startIndex
        while let r = range(of: p, in: i..<endIndex) { n += 1; i = r.upperBound }
        return n
    }
}
