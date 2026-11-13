import XCTest
import CoreML

/// I bug trovati l'08/11 dai tester (t14, t15, t19) che valgono anche sul Mac: ognuno con la sua prova.
final class TesterRegressionTests: XCTestCase {

    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/\(name)"), encoding: .utf8)
    }

    func testResetCanBeUndone() {
        // t14: dopo «Ripristina» con «Annulla» tornano le correzioni di prima (prima la storia si cancellava)
        var e = NoteEditor(detected: [Note(start: 0.5, end: 1, pitch: 60, velocity: 80), Note(start: 1, end: 2, pitch: 64, velocity: 80)])
        e.remove([e.notes[0].id])
        XCTAssertEqual(e.notes.count, 1)
        e.reset()
        XCTAssertFalse(e.edited, "dopo Ripristina non sono modificate")
        XCTAssertEqual(e.notes.count, 2)
        e.undo()
        XCTAssertEqual(e.notes.count, 1, "Annulla riporta la correzione di prima")
        XCTAssertTrue(e.edited)
    }

    func testSliceMidiStopsAtTheLastNote() {
        // t14: oltre 92 fette le altre finivano tutte sulla nota 127
        let l = (0..<100).map { AudioSlice(start: $0 * 441, end: ($0 + 1) * 441) }
        let mid = [UInt8](Slicer.midi(l, rate: 44_100, bpm: 120))
        var on127 = 0
        for i in 0..<(mid.count - 2) where mid[i] == 0x90 && mid[i + 1] == 127 && mid[i + 2] > 0 { on127 += 1 }
        XCTAssertLessThanOrEqual(on127, 1)
        XCTAssertEqual(Slicer.midiMax, 92)
        XCTAssertTrue(Slicer.readme(title: "C", stem: "Batteria", count: 100, bpm: 120).contains("prime 92 fette"))
        XCTAssertFalse(Slicer.readme(title: "C", stem: "Batteria", count: 50, bpm: 120).contains("prime 92"))
    }

    func testDawProjectWithoutMeasuredTempo() {
        // t15: una canzone troppo corta per l'analisi non dichiara «120 BPM» come misurato
        let p = DawExport.project(title: "Cortissima", bpm: nil, key: nil, seconds: 2, tracks: [], structure: nil)
        XCTAssertEqual(p.bpm, 120)
        XCTAssertEqual(DawExport.folderName(p, kind: .daw), "Cortissima – Tracce per DAW")
        XCTAssertFalse(DawExport.cueSheet(p, file: "a.wav").contains("REM BPM"))
        XCTAssertTrue(DawExport.readme(p).contains("non misurato"))
        let q = DawExport.project(title: "Vera", bpm: 98, key: "La minore", seconds: 200, tracks: [], structure: nil)
        XCTAssertEqual(DawExport.folderName(q, kind: .daw), "Vera – Tracce per DAW (98 BPM, La minore)")
        XCTAssertTrue(DawExport.cueSheet(q, file: "a.wav").contains("REM BPM 98"))
    }

    func testPassageNameHasTenths() {
        // t15: il nome del passaggio A–B con i decimi e senza «:»
        XCTAssertEqual(Downloads.passageLabel(0.3, 0.9), "0m00,3s–0m00,9s")
        XCTAssertEqual(Downloads.passageLabel(5, 12.5), "0m05,0s–0m12,5s")
        XCTAssertEqual(Downloads.passageLabel(65, 600), "1m05,0s–10m00,0s")
    }

    func testSilentSongHasNoTempoOrKey() {
        // t11/t15: 10 s di silenzio davano «182 BPM · Do maggiore»
        let n = 44_100 * 10
        let silent = [[Float]](repeating: [Float](repeating: 0, count: n), count: 2)
        XCTAssertNil(Analysis.analyze([silent, silent, silent, silent], sources: ["vocals", "drums", "bass", "other"]))
    }

    func testEngineRaceStopsOnCancel() async {
        // t19: «Annulla» durante la gara del motore (Mac Intel) la ferma invece di aspettare la grafica per minuti
        let flag = SeparationJob.Cancel()
        let t0 = Date()
        // «Annulla» mentre la grafica apre il modello (che qui durerebbe 20 s)
        Task { try? await Task.sleep(nanoseconds: 300_000_000); flag.set() }
        do {
            _ = try await SeparationJob.race("prova", what: "il modello", say: { _ in }, cancelled: { flag.isSet },
                                             open: { u in if u == .cpuAndGPU { try await Task.sleep(nanoseconds: 20_000_000_000) } },
                                             run: { _ in })
            XCTFail("doveva fermarsi con l'annullamento")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3, "si ferma subito, non dopo l'apertura sulla grafica")
    }

    func testTimeoutEndsOnCancel() async throws {
        let flag = SeparationJob.Cancel()
        let t0 = Date()
        Task { try? await Task.sleep(nanoseconds: 300_000_000); flag.set() }
        do {
            _ = try await withTimeout(30, cancelled: { flag.isSet }) { try await Task.sleep(nanoseconds: 20_000_000_000) }
            XCTFail("doveva finire con l'annullamento")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3)
    }

    func testLyricsStopWhenTheWindowCloses() throws {
        // t19: chiudere la finestra del testo ferma Whisper; con la trascrizione in corso Esc è solo «Annulla»;
        // le frasi di una trascrizione annullata non tornano a schermo; il motore controlla l'annullamento
        let view = try source("LyricsView.swift"), engine = try source("LyricsEngine.swift")
        XCTAssertTrue(view.contains(".onDisappear { if working { cancelTranscription() } }"))
        XCTAssertTrue(view.contains("keyboardShortcut(working ? nil : KeyboardShortcut.cancelAction)"))
        XCTAssertTrue(view.contains("if run == mine { status = s }"))
        XCTAssertGreaterThanOrEqual(engine.components(separatedBy: "try Task.checkCancellation()").count - 1, 4)
    }

    func testWaitingForThePreviousJobIsShownWhileWaiting() throws {
        // t19: «Fermo il lavoro di prima…» compare mentre si aspetta; sul Mac Intel niente frase sul Neural Engine
        let job = try source("SeparationJob.swift"), view = try source("ContentView.swift")
        XCTAssertFalse(job.contains("if await SeparationJob.settle(before) {"))
        XCTAssertTrue(job.contains("let waiting = Task {"))
        XCTAssertFalse(job.contains("al massimo \\(Int(2 * cpu + 0.5)) secondi"))
        XCTAssertTrue(view.contains("provo il processore e la grafica di questo Mac"))
    }

    func testPreviewAndQueueDoNotOverlap() throws {
        // Giro 2, t16: «Separa» durante il taglio dell'anteprima, canzoni trascinate durante l'anteprima,
        // pausa di 1,5 s tra le canzoni della coda
        let job = try source("SeparationJob.swift"), view = try source("ContentView.swift")
        XCTAssertTrue(job.contains("if cuttingPreview || startingNext { return true }"))
        XCTAssertTrue(job.contains("@Published private(set) var cuttingPreview = false"))
        XCTAssertTrue(job.contains("guard !cuttingPreview else { return }"))
        XCTAssertTrue(job.contains("guard pending.contains(source) else"))
        XCTAssertTrue(job.contains("pending = [p.source] + queue.filter { $0 != p.source }"))
        XCTAssertTrue(job.contains("startingNext = true"))
        XCTAssertFalse(job.contains("defer { cuttingPreview = false }"))
        XCTAssertEqual(view.components(separatedBy: ".disabled(job.cuttingPreview)").count - 1, 2)
        // Un'anteprima non riuscita si chiude prima di passare alla coda
        let failure = job.components(separatedBy: "private func afterFailure(")[1].components(separatedBy: "private func loaded(")[0]
        XCTAssertTrue(failure.contains("endPreview()"))
    }
}
