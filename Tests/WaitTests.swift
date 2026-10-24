import XCTest

/// Le attese con un limite (l'apertura dei modelli sul Neural Engine) e il registro dei passi.
final class WaitTests: XCTestCase {

    func testTimeoutGivesUpOnSlowWork() async throws {
        let start = Date()
        // Un lavoro bloccante che il sistema non sa interrompere, come MLModel(contentsOf:)
        let r: Int? = try await withTimeout(0.3) {
            await withCheckedContinuation { c in
                DispatchQueue.global().async { Thread.sleep(forTimeInterval: 2); c.resume(returning: 1) }
            }
        }
        XCTAssertNil(r, "dopo il limite non si aspetta più")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5, "si smette di aspettare al limite, non a lavoro finito")
    }

    func testTimeoutReturnsFastWork() async throws {
        let r: Int? = try await withTimeout(5) { 42 }
        XCTAssertEqual(r, 42)
    }

    func testTimeoutPassesErrors() async {
        struct Boom: Error {}
        do {
            let _: Int? = try await withTimeout(5) { throw Boom() }
            XCTFail("doveva arrivare l'errore")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }

    func testLogKeepsSteps() {
        let mark = "Prova del registro \(UUID().uuidString)"
        AppLog.write(mark)
        XCTAssertTrue(AppLog.tail(5).contains(mark))
    }

    func testEngineTexts() {
        XCTAssertEqual(EngineChoice.Decision(units: .cpuAndGPU, agreement: EngineChoice.slowANE).text,
                       "Grafica (il Neural Engine era troppo lento ad aprire il modello)")
        XCTAssertEqual(EngineChoice.Decision(units: .cpuAndGPU, agreement: EngineChoice.chosenGPU).text,
                       "Grafica (scelta nelle Impostazioni)")
        // «Solo grafica» nelle Impostazioni vale per tutti i modelli
        let old = UserDefaults.standard.object(forKey: Prefs.engineModeKey)
        UserDefaults.standard.set("grafica", forKey: Prefs.engineModeKey)
        XCTAssertEqual(EngineChoice.current("StrumentiSW2")?.units, .cpuAndGPU)
        UserDefaults.standard.set(old, forKey: Prefs.engineModeKey)
    }
}
