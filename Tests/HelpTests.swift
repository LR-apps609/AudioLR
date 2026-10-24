import XCTest

/// FAQ, «Segnala un bug» e Account: la parte che non ha bisogno di finestre.
final class HelpTests: XCTestCase {

    func testEveryFAQHasAKnownTopic() {
        let topics = Set(FAQ.topics.map(\.name))
        for e in FAQ.all {
            XCTAssertTrue(topics.contains(e.topic), e.question)
            XCTAssertFalse(e.answer.isEmpty, e.question)
        }
        XCTAssertEqual(Set(FAQ.all.map(\.id)).count, FAQ.all.count, "due domande uguali")
        for t in topics { XCTAssertTrue(FAQ.all.contains { $0.topic == t }, "argomento vuoto: \(t)") }
    }

    func testFAQSearch() {
        XCTAssertEqual(FAQ.search("").count, FAQ.all.count)
        XCTAssertFalse(FAQ.search("karaoke").isEmpty)
        // Senza accenti e con più parole: tutte devono esserci
        XCTAssertFalse(FAQ.search("qualita massima").isEmpty)
        XCTAssertTrue(FAQ.search("zzzz nessuna").isEmpty)
    }

    func testBugReportURL() throws {
        var r = BugReport()
        r.summary = "La voce & la batteria"
        r.steps = "Massima, 3 minuti"
        let url = r.issueURL(system: "AudioLR 0.7.0\nmacOS 15")
        let c = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(c.host, "github.com")
        XCTAssertEqual(c.path, "/LR-apps609/AudioLR/issues/new")
        let q = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["title"], "[Qualcosa non funziona] La voce & la batteria")
        XCTAssertTrue(q["body"]!.contains("Massima, 3 minuti"))
        XCTAssertTrue(q["body"]!.contains("macOS 15"))
        XCTAssertEqual(q["labels"], "bug")
        r.includeSystem = false
        r.kind = .idea
        XCTAssertFalse(r.body(system: "SEGRETO").contains("SEGRETO"))
        XCTAssertTrue(r.issueURL(system: "").absoluteString.contains("enhancement"))
    }

    @MainActor func testSystemInfoHasTheBasics() {
        let s = BugReport.systemInfo()
        XCTAssertTrue(s.contains("AudioLR"))
        XCTAssertTrue(s.contains("macOS"))
        XCTAssertTrue(s.contains("Memoria"))
    }

    func testInitials() {
        XCTAssertEqual(LRFamily.initials("Mario Rossi"), "MR")
        XCTAssertEqual(LRFamily.initials("ledion"), "L")
        XCTAssertEqual(LRFamily.initials(""), "LR")
    }
}
