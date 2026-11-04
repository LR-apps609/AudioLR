import XCTest

/// La sorveglianza (Health): blocchi della finestra, lavori fermi e rapporto senza nome utente.
final class HealthTests: XCTestCase {
    func testRedactsUserName() {
        let t = Health.redact("Apro /Users/Nicolò De Santis/Music/IsoLR/canzone.wav e /Users/altro/Desktop",
                              home: "/Users/Nicolò De Santis", user: "Nicolò De Santis")
        XCTAssertFalse(t.contains("Nicolò"), t)
        XCTAssertTrue(t.contains("/Users/***/Music/IsoLR/canzone.wav"), t)
        XCTAssertFalse(t.contains("/Users/altro"), t)
    }

    func testWindowNotRespondingIsWritten() {
        _ = Health.takeProblems()
        let t0 = Date()
        Health.resetForTests(now: t0)
        Health.check(now: t0.addingTimeInterval(1))
        Health.lastPong = t0.addingTimeInterval(-10)
        Health.check(now: t0.addingTimeInterval(2))
        XCTAssertTrue(Health.takeProblems().contains { $0.contains("non risponde") })
    }

    func testSleepIsNotAHang() {
        // Il Mac in stop: la sorveglianza stessa ha dormito, il silenzio della finestra non conta
        _ = Health.takeProblems()
        let t0 = Date()
        Health.resetForTests(now: t0)
        Health.lastPong = t0.addingTimeInterval(-600)
        Health.check(now: t0.addingTimeInterval(600))
        XCTAssertFalse(Health.takeProblems().contains { $0.contains("non risponde") })
    }

    func testStalledJobIsWritten() {
        _ = Health.takeProblems()
        Health.resetForTests()
        Health.progressed("separa «Prova» in Massima (12%)")
        Health.check(now: Date().addingTimeInterval(Health.stallMinutes * 60 + 5))
        Health.idle()
        XCTAssertTrue(Health.takeProblems().contains { $0.contains("fermo") && $0.contains("Massima") })
    }

    @MainActor func testReportHasWhatIsNeeded() {
        let r = Health.report(problems: ["La finestra non risponde da 7 secondi"])
        for part in ["macOS", "Mac:", "Memoria", "Architettura", "Schermi", "Lingua", "Spazio libero", "Cartella delle tracce", "Registro"] {
            XCTAssertTrue(r.contains(part), "manca «\(part)» nel rapporto")
        }
        XCTAssertFalse(r.contains(NSHomeDirectory()), "il rapporto contiene il nome utente")
    }
}
