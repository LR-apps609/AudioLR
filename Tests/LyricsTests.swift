import XCTest

/// Il testo sincronizzato: righe, parola sotto la testina, .lrc/.srt, modifiche (come windows/ui/core/test/lyrics.test.js).
final class LyricsTests: XCTestCase {
    private func w(_ t: String, _ s: Double, _ e: Double) -> LyricWord { LyricWord(text: t, start: s, end: e) }
    private var words: [LyricWord] {
        [w("Questa", 1.0, 1.3), w("è", 1.3, 1.4), w("la", 1.4, 1.5), w("prima.", 1.5, 2.0),
         w("E", 4.0, 4.1), w("questa", 4.1, 4.4), w("la", 4.4, 4.5), w("seconda", 4.5, 5.0)]
    }

    func testLines() {
        let ls = Lyrics.lines(words)
        XCTAssertEqual(ls.map(\.text), ["Questa è la prima.", "E questa la seconda"])
        XCTAssertEqual(ls[1].start, 4.0)
        XCTAssertEqual(ls[1].end, 5.0)
        let many = (0..<12).map { i in w("ok", Double(i) * 0.3, Double(i) * 0.3 + 0.2) }
        XCTAssertEqual(Lyrics.lines(many).map(\.words.count), [8, 4])
    }

    func testCurrent() {
        let ws = words
        let ls = Lyrics.lines(ws)
        XCTAssertNil(Lyrics.current(ls, words: ws, at: 0.5))
        let a = Lyrics.current(ls, words: ws, at: 1.45)
        XCTAssertEqual(a?.line, 0)
        XCTAssertEqual(a?.word, 2)
        let b = Lyrics.current(ls, words: ws, at: 4.6)
        XCTAssertEqual(b?.line, 1)
        XCTAssertEqual(b?.word, 7)
        XCTAssertNil(Lyrics.current(ls, words: ws, at: 9))
    }

    func testExport() {
        let ls = Lyrics.lines(words)
        XCTAssertEqual(Lyrics.lrcTime(62.354), "[01:02.35]")
        XCTAssertEqual(Lyrics.srtTime(3723.5), "01:02:03,500")
        XCTAssertEqual(Lyrics.lrc(ls, title: "Prova"),
                       "[ti:Prova]\n[re:IsoLR]\n[00:01.00]Questa è la prima.\n[00:04.00]E questa la seconda\n")
        XCTAssertTrue(Lyrics.srt(ls).hasPrefix("1\n00:00:01,000 --> 00:00:02,000\nQuesta è la prima.\n\n2\n"))
    }

    func testEdits() {
        let ws = words
        let ls = Lyrics.lines(ws)
        let same = Lyrics.rewrite(ws, line: ls[1], to: "E questa è seconda")
        XCTAssertEqual(same[6].text, "è")
        XCTAssertEqual(same[6].start, 4.4)
        let fewer = Lyrics.rewrite(ws, line: ls[1], to: "Seconda riga")
        XCTAssertEqual(fewer.count, 6)
        XCTAssertEqual(fewer[4].start, 4.0)
        XCTAssertEqual(fewer[5].end, 5.0, accuracy: 1e-9)
        let moved = Lyrics.shift(ws, line: ls[0], by: -0.5)
        XCTAssertEqual(moved[0].start, 0.5)
        XCTAssertEqual(moved[4].start, 4.0)
    }

    func testKaraokeFrame() {
        let ws = words
        let ls = Lyrics.lines(ws)
        // All'inizio il titolo; poco prima della riga la si vede già (in grigio); durante, la parola cantata
        XCTAssertTrue(KaraokeVideo.frame(at: 0.2, lines: ls, words: ws).showTitle)
        let before = KaraokeVideo.frame(at: 3.6, lines: ls, words: ws)
        XCTAssertFalse(before.showTitle)
        XCTAssertEqual(before.line, "E questa la seconda")
        XCTAssertNil(before.sung)
        let during = KaraokeVideo.frame(at: 1.45, lines: ls, words: ws)
        XCTAssertEqual(during.lineWords, ["Questa", "è", "la", "prima."])
        XCTAssertEqual(during.sung, 2)
        XCTAssertEqual(during.next, "E questa la seconda")
    }

    func testCleanAndSave() throws {
        let raw = [w(" ciao ", 1, 0.5), w("", 2, 3)] + (0..<7).map { i in w("la", 3 + Double(i), 3.5 + Double(i)) }
        let c = Lyrics.clean(raw)
        XCTAssertEqual(c[0].text, "ciao")
        XCTAssertEqual(c[0].end, 1)
        XCTAssertEqual(c.filter { $0.text == "la" }.count, 4)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("testo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let lyr = Lyrics(language: "it", words: words, edited: true)
        try lyr.save(in: dir)
        XCTAssertEqual(Lyrics.load(in: dir), lyr)
    }
}
