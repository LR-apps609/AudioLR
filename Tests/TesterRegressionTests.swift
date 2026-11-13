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

    func testIntelEngineTextsDoNotNameTheNeuralEngine() {
        // Giro 2, t16: su un Mac Intel nessun testo del motore parla del Neural Engine, e non si consiglia
        // «Solo grafica» (selettore disattivato lì; inutile a chi l'ha già scelto)
        let intel: [EngineChoice.Decision] = [
            .init(units: .cpuAndGPU, agreement: 0), .init(units: .cpuOnly, agreement: 0), .init(units: .all, agreement: EngineChoice.intelDemucs),
            EngineChoice.decideSpeed(cpu: 48, gpu: nil), EngineChoice.decideSpeed(cpu: 48, gpu: 20)]
        for d in intel { XCTAssertFalse(d.text(neuralEngine: false).contains("Neural Engine"), d.text(neuralEngine: false)) }
        XCTAssertEqual(EngineChoice.Decision(units: .cpuAndGPU, agreement: 0).text(neuralEngine: false),
                       "Grafica (il primo calcolo qui ha dato un risultato sbagliato)")
        XCTAssertEqual(EngineChoice.Decision(units: .cpuAndGPU, agreement: 0).text(neuralEngine: true),
                       "Grafica (il Neural Engine qui ha dato un risultato sbagliato)")
        XCTAssertTrue(EngineChoice.Decision(units: .cpuOnly, agreement: 0).text(neuralEngine: true).contains("Neural Engine"))
        XCTAssertFalse(EngineChoice.howItChooses(neuralEngine: false).contains("Neural Engine"))
        XCTAssertTrue(EngineChoice.howItChooses(neuralEngine: false).contains("il più veloce"))
        XCTAssertTrue(EngineChoice.howItChooses(neuralEngine: true).contains("il più preciso"))
        for u: MLComputeUnits in [.all, .cpuAndGPU] {
            let m = EngineChoice.openFailedMessage(units: u, neuralEngine: false)
            XCTAssertFalse(m.contains("Solo grafica") || m.contains("Neural Engine") || m.contains("tutto"), m)
        }
        XCTAssertFalse(EngineChoice.openFailedMessage(units: .cpuAndGPU, neuralEngine: true).contains("Solo grafica"))
        XCTAssertTrue(EngineChoice.openFailedMessage(units: .all, neuralEngine: true).contains("Solo grafica"))
        let help = try? source("Help.swift"), settings = try? source("SettingsView.swift"), store = try? source("ModelStore.swift")
        XCTAssertEqual(help?.contains("EngineChoice.howItChooses(neuralEngine: SeparationJob.hasNeuralEngine)"), true)
        XCTAssertEqual(settings?.contains("EngineChoice.howItChooses(neuralEngine: SeparationJob.hasNeuralEngine)"), true)
        XCTAssertEqual(store?.contains("EngineChoice.openFailedMessage(units: units, neuralEngine: SeparationJob.hasNeuralEngine)"), true)
    }

    @MainActor
    func testModelsAreNotDeletedWhileWorking() throws {
        // Giro 2, t16: «Elimina i modelli scaricati…» restava attivo se la separazione partiva con le Impostazioni aperte
        let settings = try source("SettingsView.swift"), prefs = try source("Preferences.swift")
        XCTAssertTrue(settings.contains("@ObservedObject private var job = SeparationJob.shared"))
        XCTAssertTrue(settings.contains(".disabled(job.isWorking)"))
        XCTAssertFalse(settings.contains(".disabled(SeparationJob.shared.isWorking)"))
        XCTAssertTrue(prefs.contains("if SeparationJob.shared.isWorking { return false }"))
    }

    func testDiskFullIsSaidAndTheHalfFolderIsRemoved() throws {
        // Giro 2, t16: disco pieno al salvataggio: messaggio sullo spazio e niente cartella a metà
        XCTAssertTrue(AudioIO.isDiskFull(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)), free: nil, needed: 1))
        XCTAssertTrue(AudioIO.isDiskFull(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError), free: nil, needed: 1))
        XCTAssertTrue(AudioIO.isDiskFull(NSError(domain: NSOSStatusErrorDomain, code: -50), free: 1000, needed: 5000))
        XCTAssertFalse(AudioIO.isDiskFull(NSError(domain: NSOSStatusErrorDomain, code: -50), free: 10_000_000, needed: 5000))
        XCTAssertTrue(AudioIO.diskFullMessage(needed: 300_000_000).contains("spazio sul disco"))
        XCTAssertTrue(AudioIO.diskFullMessage(needed: 300_000_000).contains("«Riprova»"))
        let job = try source("SeparationJob.swift")
        XCTAssertTrue(job.contains("try? fm.removeItem(at: dir)"))
        XCTAssertTrue(job.contains("if error is AudioIO.DiskFullError {"))
        // Una scrittura non riuscita (cartella che non esiste) non lascia niente e dice il nome del file
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("non-esiste-\(UUID().uuidString)/Prova – Voce.wav")
        XCTAssertThrowsError(try AudioIO.write([[0, 0], [0, 0]], to: missing, format: .wav24)) { e in
            XCTAssertTrue(((e as? LocalizedError)?.errorDescription ?? "").contains("Prova – Voce.wav"))
        }
    }

    @MainActor
    func testErrorSentenceHasOneFullStop() {
        // Giro 2, t16: i testi di macOS finiscono già con il punto: niente «..»
        XCTAssertEqual(ContentView.sentence("il file è vuoto"), "Il file è vuoto.")
        XCTAssertEqual(ContentView.sentence("Non hai l'autorizzazione per salvare il file."), "Non hai l'autorizzazione per salvare il file.")
        XCTAssertEqual(ContentView.sentence("Impossibile completare l'operazione. (errore -50.)"), "Impossibile completare l'operazione. (errore -50.)")
        XCTAssertEqual(ContentView.sentence("ok "), "Ok.")
    }

    func testQualityTextsAgree() throws {
        // Giro 2, t16: «Qualità Massima qualità» nel menu, Rapida 20 s contro 30 s, dimensioni dei modelli diverse
        let main = try source("Main.swift"), help = try source("Help.swift"), library = try source("Library.swift")
        XCTAssertFalse(main.contains("Toggle(\"Qualità \\(Quality.best.title)\""))
        XCTAssertTrue(main.contains("Toggle(\"Qualità Massima\""))
        XCTAssertTrue(library.contains("\"Massima / Rapida / Studio\""))
        XCTAssertTrue(Quality.fast.detail(appleChip: true).contains("circa 30 s"))
        XCTAssertTrue(Quality.fast.cardTime.contains("circa 30 secondi"))
        XCTAssertFalse(Quality.fast.detail(appleChip: false).contains(" s a canzone"))
        // Le dimensioni vere dei file della release «modelli-1» (HTDemucs 79 MB, StrumentiSW2 328 MB, VoceRevive 298 MB)
        XCTAssertEqual(Quality.fast.downloadSize, "circa 80 MB")
        XCTAssertEqual(Quality.best.downloadSize, "circa 330 MB")
        XCTAssertEqual(Quality.studio.downloadSize, "circa 630 MB")
        XCTAssertTrue(help.contains("circa 330 MB per Massima, 630 MB per Studio, 80 MB per Rapida"))
        XCTAssertFalse(help.contains("310 MB"))
    }

    func testSongFolderDoesNotStartWithADot() {
        // Giro 2, parità con Windows (t4): «...And Justice for All» finiva in una cartella nascosta dal Finder
        XCTAssertEqual(SeparationJob.folderName("...And Justice for All"), "And Justice for All")
        XCTAssertEqual(SeparationJob.folderName(" . . Canzone"), "Canzone")
        XCTAssertEqual(SeparationJob.folderName("..."), "Canzone")
        XCTAssertEqual(SeparationJob.folderName("Canzone. Fine."), "Canzone. Fine.")
    }

    func testDawProjectHasTheMixerTracks() throws {
        // Giro 2, parità con Windows (t4): dopo «Pulisci la voce» il progetto aveva Voce e Voce pulita, tutte e due attive
        let daw = try source("DawExport.swift")
        XCTAssertTrue(daw.contains("let list = MixPlayer.mixable(stems)"))
        XCTAssertFalse(daw.contains("let list = stems.filter { $0.key != \"instrumental\" }"))
    }

    func testPartsTextTenthsAreRounded() {
        // Giro 2, parità con Windows (t4): 2,4 s diventava «0:02.3»
        XCTAssertEqual(DawExport.partsClock(2.4), "0:02.4")
        XCTAssertEqual(DawExport.partsClock(0), "0:00.0")
        XCTAssertEqual(DawExport.partsClock(59.96), "1:00.0")
        XCTAssertEqual(DawExport.partsClock(125.26), "2:05.3")
    }

    func testOneUpdateDownloadAtATime() throws {
        // Giro 2, parità con Windows (t8): scaricando l'aggiornamento dall'avviso, il tasto «Aggiornamento disponibile»
        // restava attivo e un secondo clic avviava un secondo scaricamento, che cancellava la cartella del primo
        let up = try source("Updater.swift")
        XCTAssertTrue(up.contains("guard !Updater.shared.busy, !UpdateNotice.shared.downloading else { return }"))
        let check = up.components(separatedBy: "static func check(userInitiated: Bool) async {")[1].components(separatedBy: "private static func download(")[0]
        XCTAssertTrue(check.contains("if UpdateNotice.shared.downloading {"))
        XCTAssertTrue(check.contains("UpdateNotice.shared.downloading = true\n            await download(rel)\n            UpdateNotice.shared.downloading = false"))
        // Il file dell'aggiornamento ha la versione nel nome e si scarica da capo (niente ripresa che unisca due versioni)
        XCTAssertTrue(up.contains("appendingPathComponent(\"AudioLR \\(rel.version).audiolr\")"))
        XCTAssertFalse(up.contains("Range"))
    }

    func testQueueAfterPreviewAndCancelInThePause() throws {
        // Giro 2, t14 (rilettura del commit di anteprima e coda): ⌘. nella pausa tra due canzoni ferma la prossima;
        // un'anteprima non riuscita rimette pronta la canzone vera; dopo un'anteprima «Nuova separazione» non lascia una coda nascosta
        let job = try source("SeparationJob.swift")
        XCTAssertTrue(job.contains("guard let self, self.startingNext else { return }"))
        let cancel = job.components(separatedBy: "    func cancel() {")[1].components(separatedBy: "    private func startNextInQueue()")[0]
        XCTAssertTrue(cancel.contains("startingNext = false"))
        let failure = job.components(separatedBy: "private func afterFailure(")[1].components(separatedBy: "private func loaded(")[0]
        XCTAssertTrue(failure.contains("pending.insert(p.source, at: 0)"))
        let reset = job.components(separatedBy: "    func reset() {")[1].components(separatedBy: "\n    }\n")[0]
        XCTAssertTrue(reset.contains("pending += queue.filter"))
    }

    func testBugReportHidesSongTitles() {
        // Giro 2, t18: «Segnala» (issue pubblica su GitHub) e il rapporto promettono «nessuna canzone»
        let song = "Lettera a Giulia (demo privata)"
        let text = """
        Ultimo errore: non riesco a scrivere Lettera a Giulia (demo privata) – Voce.wav
        Registro: Separazione non riuscita: Impossibile aprire il file “Lettera a Giulia (demo privata).mp3”.
        La finestra non risponde da 7 secondi (stava facendo: legge «Lettera a Giulia (demo privata).mp3»)
        Qualità: Massima qualità · formato: WAV 24 bit
        """
        let hidden = Health.hideSongs(text, titles: [song])
        XCTAssertFalse(hidden.contains("Giulia"), hidden)
        XCTAssertTrue(hidden.contains("non riesco a scrivere canzone – Voce.wav"))
        XCTAssertTrue(hidden.contains("Qualità: Massima qualità · formato: WAV 24 bit"), "il resto resta")
        // Anche senza sapere il titolo: i nomi di file tra «…» e tra “…” degli errori di macOS
        let unknown = Health.hideSongs(text, titles: [])
        XCTAssertTrue(unknown.contains("«canzone»") && unknown.contains("“canzone”"))
        XCTAssertFalse(unknown.contains("demo privata).mp3"))
        // Parole intere: un titolo corto non rovina le altre parole
        XCTAssertEqual(Health.hideSongs("Fortemente Forte", titles: ["Forte"]), "Fortemente canzone")
        // Il titolo e il testo della issue, anche se l'utente ci ha scritto il titolo
        var r = BugReport()
        r.summary = "Si è fermata con " + song
        let url = r.issueURL(system: "Registro: legge «\(song).mp3»", titles: [song]).absoluteString.removingPercentEncoding ?? ""
        XCTAssertFalse(url.contains("Giulia"), url)
    }

    @MainActor
    func testHealthReportHasNoSongTitles() throws {
        // Giro 2, t18: il rapporto dopo un blocco conteneva il titolo (dalla sorveglianza e dal registro)
        AppLog.write("Separazione non riuscita: non riesco a leggere «Lettera a Giulia (demo privata).mp3»")
        let r = Health.report(problems: ["La finestra non risponde da 7 secondi (stava facendo: legge «Lettera a Giulia (demo privata).flac»)"])
        XCTAssertFalse(r.contains("Giulia"))
        XCTAssertTrue(r.contains("Registro"))
        let job = try source("SeparationJob.swift"), help = try source("Help.swift")
        XCTAssertFalse(job.contains("Health.progressed(\"separa «\\(title)»"))
        XCTAssertTrue(job.contains("Health.progressed(\"separa la canzone in"))
        XCTAssertTrue(help.contains("Health.hideSongs(Health.redact("))
        XCTAssertTrue(help.contains("report.issueURL(system: system, titles: Health.knownTitles)"))
    }
}
