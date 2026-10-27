import XCTest
import CoreML

/// Aggiornamenti, novità, salvataggio delle tracce, lettura dei risultati di Core ML, forme d'onda e testi.
final class AppTests: XCTestCase {

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("audiolr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    // MARK: Aggiornamenti

    func testVersionCompare() {
        XCTAssertTrue(News.newer("0.2.0", than: "0.1.9"))
        XCTAssertTrue(News.newer("0.10.0", than: "0.9.3"))
        XCTAssertTrue(News.newer("1.0", than: "0.99.99"))
        XCTAssertFalse(News.newer("0.2.0", than: "0.2.0"))
        XCTAssertFalse(News.newer("0.2", than: "0.2.0"))
        XCTAssertFalse(News.newer("0.1.0", than: "0.2.0"))
    }

    func testParseGitHubRelease() {
        let json = """
        {"tag_name": "v0.3.1", "html_url": "https://github.com/LR-apps609/AudioLR/releases/tag/v0.3.1",
         "assets": [{"name": "AudioLR.0.3.1.zip", "browser_download_url": "https://example.com/a.zip"},
                    {"name": "AudioLR.0.3.1.audiolr", "browser_download_url": "https://example.com/a.audiolr"}]}
        """
        let r = UpdateCheck.parse(Data(json.utf8))
        XCTAssertEqual(r?.version, "0.3.1")
        XCTAssertEqual(r?.asset.absoluteString, "https://example.com/a.audiolr")
        XCTAssertNil(UpdateCheck.parse(Data(#"{"tag_name": "v1", "assets": []}"#.utf8)), "senza .audiolr non è un aggiornamento")
        XCTAssertNil(UpdateCheck.parse(Data("non è json".utf8)))
    }

    func testAutoCheckOncePerDay() {
        let d = UserDefaults(suiteName: "audiolr-test-\(UUID().uuidString)")!
        let now = Date()
        XCTAssertTrue(UpdateCheck.shouldAutoCheck(now: now, defaults: d))
        d.set(now.timeIntervalSince1970 - 3600, forKey: UpdateCheck.lastKey)
        XCTAssertFalse(UpdateCheck.shouldAutoCheck(now: now, defaults: d))
        d.set(now.timeIntervalSince1970 - 21 * 3600, forKey: UpdateCheck.lastKey)
        XCTAssertTrue(UpdateCheck.shouldAutoCheck(now: now, defaults: d))
        d.set(false, forKey: UpdateCheck.autoKey)
        XCTAssertFalse(UpdateCheck.shouldAutoCheck(now: now, defaults: d))
    }

    /// Studio: le medie degli strumenti. «Tutto il resto» somma altro, chitarra e piano; la media è campione per campione.
    func testInstrumentTeamAverages() {
        let one: [[Float]] = [[1, 1], [1, 1]], two: [[Float]] = [[2, 2], [2, 2]], four: [[Float]] = [[4, 4], [4, 4]]
        let t = SeparationJob.instrumentTotals(["vocals", "drums", "bass", "guitar", "piano", "other"], [one, one, two, one, two, four])
        XCTAssertEqual(t["drums"]?[0], [1, 1])
        XCTAssertEqual(t["bass"]?[1], [2, 2])
        XCTAssertEqual(t["rest"]?[0], [7, 7], "altro + chitarra + piano")
        XCTAssertNil(SeparationJob.instrumentTotals(["vocals"], [one])["rest"])
        XCTAssertEqual(SeparationJob.average([one, two, four.map { $0.map { $0 - 1 } }])[0], [2, 2])
        // Una traccia più corta non fa uscire dai limiti
        XCTAssertEqual(SeparationJob.average([[[3, 3, 3], [3, 3, 3]], [[1], [1]]])[0], [2, 1.5, 1.5])
    }

    /// IsoLR: la cartella delle tracce si sposta una volta sola e la cronologia segue.
    func testOutputFolderMigration() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("migra-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent("AudioLR"), new = root.appendingPathComponent("IsoLR")
        let song = old.appendingPathComponent("Canzone")
        try fm.createDirectory(at: song, withIntermediateDirectories: true)
        let d = UserDefaults(suiteName: "audiolr-test-\(UUID().uuidString)")!
        History.add(song: nil, folder: song, quality: .best, defaults: d)
        d.set(old.path, forKey: Prefs.folderKey)
        XCTAssertTrue(Paths.migrateOutput(from: old, to: new, defaults: d))
        XCTAssertTrue(fm.fileExists(atPath: new.appendingPathComponent("Canzone").path))
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertEqual(History.all(defaults: d).first?.folder, new.appendingPathComponent("Canzone").path)
        XCTAssertEqual(d.string(forKey: Prefs.folderKey), new.path)
        // Una seconda volta non fa niente
        XCTAssertFalse(Paths.migrateOutput(from: old, to: new, defaults: d))
    }

    /// Album di notte: la durata nell'avviso.
    func testBatchDurationText() {
        XCTAssertEqual(DockProgress.duration(40), "40 s")
        XCTAssertEqual(DockProgress.duration(8 * 60 + 5), "8 min")
        XCTAssertEqual(DockProgress.duration(72 * 60), "1 h 12 min")
    }

    /// La barra nel Dock: sale con il lavoro e sparisce quando non c'è niente in corso.
    func testDockProgressFraction() {
        XCTAssertNil(DockProgress.fraction(.idle))
        XCTAssertNil(DockProgress.fraction(.done))
        let a = DockProgress.fraction(.reading)!, b = DockProgress.fraction(.separating(0.5))!, c = DockProgress.fraction(.saving)!
        XCTAssertLessThan(a, b); XCTAssertLessThan(b, c); XCTAssertLessThanOrEqual(c, 1)
        XCTAssertEqual(DockProgress.fraction(.separating(2))!, 0.96, accuracy: 1e-9)
    }

    /// Una canzone trascinata non parte da sola: aspetta la qualità e «Separa».
    @MainActor
    func testDroppedSongWaitsForSepara() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pronta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let song = dir.appendingPathComponent("Canzone.wav")
        try Data([0]).write(to: song)
        let job = SeparationJob.shared
        guard !job.isBusy else { throw XCTSkip("una separazione è già in corso") }
        job.prepare([song])
        XCTAssertEqual(job.pending, [song])
        XCTAssertEqual(job.phase, .idle, "non deve partire prima di «Separa»")
        XCTAssertTrue(job.queue.isEmpty)
        job.clearPending()
        XCTAssertTrue(job.pending.isEmpty)
        job.prepare([dir.appendingPathComponent("non-esiste.wav")])
        XCTAssertTrue(job.pending.isEmpty, "niente da preparare se il file non c'è")
    }

    /// Il tasto «Aggiornamento disponibile» compare solo per una versione più nuova.
    func testUpdateButtonOnlyForNewerVersion() {
        let u = URL(string: "https://example.com/a.audiolr")!
        let rel = UpdateCheck.Release(version: "0.19.0", asset: u, page: u)
        XCTAssertEqual(UpdateCheck.worthShowing(rel, current: "0.18.0"), rel)
        XCTAssertNil(UpdateCheck.worthShowing(rel, current: "0.19.0"))
        XCTAssertNil(UpdateCheck.worthShowing(rel, current: "0.20.1"))
        XCTAssertNil(UpdateCheck.worthShowing(nil, current: "0.18.0"))
    }

    func testFindUpdatePackage() throws {
        let d = try tempDir()
        XCTAssertNil(Updater.findPackage(in: d))
        let pkg = d.appendingPathComponent("AudioLR")
        try FileManager.default.createDirectory(at: pkg.appendingPathComponent("Prebuilt/AudioLR.app"), withIntermediateDirectories: true)
        XCTAssertNil(Updater.findPackage(in: d), "manca version.txt")
        try "0.2.0".write(to: pkg.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Updater.findPackage(in: d)?.lastPathComponent, "AudioLR")
    }

    // MARK: Novità

    static let novita = """
    Novità della 0.3.0 «Tre»:
    • terza A
    • terza B

    Novità della 0.2.0 «Due»:
    • seconda

    Novità della 0.1.0 «Uno»:
    • prima
    """

    func testNewsSinceVersion() {
        XCTAssertEqual(News.items(since: "0.1.0", in: Self.novita), ["terza A", "terza B", "seconda"])
        XCTAssertEqual(News.items(since: "0.2.0", in: Self.novita), ["terza A", "terza B"])
        XCTAssertEqual(News.items(since: "", in: Self.novita), ["terza A", "terza B"], "senza versione: solo l'ultima")
        XCTAssertEqual(News.items(since: "0.3.0", in: Self.novita), [])
        XCTAssertEqual(News.version(inHeader: "Novità della 0.2.0 «Studio»:"), "0.2.0")
        XCTAssertNil(News.version(inHeader: "• qualcosa"))
    }

    func testWhatsNewOnlyAfterAnUpdate() {
        let d = UserDefaults(suiteName: "audiolr-test-\(UUID().uuidString)")!
        XCTAssertEqual(WhatsNew.pending(defaults: d, current: "0.2.0", text: Self.novita), [], "primo avvio: niente")
        XCTAssertEqual(WhatsNew.pending(defaults: d, current: "0.2.0", text: Self.novita), [], "stessa versione: niente")
        XCTAssertEqual(WhatsNew.pending(defaults: d, current: "0.3.0", text: Self.novita), ["terza A", "terza B"])
        XCTAssertEqual(WhatsNew.pending(defaults: d, current: "0.3.0", text: Self.novita), [], "una volta sola")
    }

    func testBundledNewsHasCurrentVersion() throws {
        // NOVITA.txt deve cominciare con la versione di version.txt: è il testo che vede chi aggiorna
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let version = try String(contentsOf: root.appendingPathComponent("version.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let news = try String(contentsOf: root.appendingPathComponent("NOVITA.txt"), encoding: .utf8)
        let first = news.split(separator: "\n").first.map(String.init) ?? ""
        XCTAssertEqual(News.version(inHeader: first), version)
        XCTAssertFalse(News.items(since: "", in: news).isEmpty)
    }

    // MARK: Salvataggio

    func testSaveWritesStemsAndKaraoke() throws {
        let d = try tempDir()
        let song = d.appendingPathComponent("La mia canzone.mp3")
        let n = 8_000
        let sources = ["drums", "bass", "other", "vocals"]
        let out: [[[Float]]] = sources.indices.map { s in
            (0..<2).map { c in (0..<n).map { i in Float(sin(Double(i) * 0.01 * Double(s + 1) + Double(c))) * 0.2 } }
        }
        let (dir, stems) = try SeparationJob.save(out, sources: sources, song: song, into: d)
        XCTAssertEqual(dir.lastPathComponent, "La mia canzone")
        XCTAssertEqual(stems.map(\.key), ["vocals", "drums", "bass", "other", "instrumental"], "in ordine: voce per prima")
        XCTAssertEqual(stems.first?.name, "Voce")
        for st in stems {
            XCTAssertTrue(FileManager.default.fileExists(atPath: st.url.path), st.name)
            XCTAssertFalse(st.peaks.isEmpty)
        }
        // La base = tutto tranne la voce
        let base = try AudioIO.read(stems.last!.url)
        for i in stride(from: 0, to: n, by: 997) {
            XCTAssertEqual(base[0][i], out[0][0][i] + out[1][0][i] + out[2][0][i], accuracy: 1e-4)
        }
        // Una seconda volta non sovrascrive: nuova cartella
        let (dir2, _) = try SeparationJob.save(out, sources: sources, song: song, into: d)
        XCTAssertEqual(dir2.lastPathComponent, "La mia canzone 2")
    }

    func testEveryOutputFormatRoundTrips() throws {
        let d = try tempDir()
        let n = 22_050
        let tone = (0..<n).map { Float(sin(2 * Double.pi * 330 * Double($0) / 44_100)) * 0.4 }
        for f in OutputFormat.allCases {
            let url = d.appendingPathComponent("prova.\(f.fileExtension)")
            try AudioIO.write([tone, tone], to: url, format: f)
            let back = try AudioIO.read(url)
            XCTAssertEqual(back[0].count, n, f.title)
            // L'AAC è compresso: il suono resta, i singoli campioni cambiano un poco
            XCTAssertEqual(back[0][5000], tone[5000], accuracy: f == .aac ? 0.02 : f == .wav16 ? 1e-3 : 1e-4, f.title)
        }
    }

    func testSaveRespectsFormatAndKaraokeChoice() throws {
        let d = try tempDir()
        let out: [[[Float]]] = (0..<4).map { _ in [[Float](repeating: 0.1, count: 4000), [Float](repeating: 0.1, count: 4000)] }
        let (_, stems) = try SeparationJob.save(out, sources: ["drums", "bass", "other", "vocals"], song: d.appendingPathComponent("Brano.mp3"),
                                                into: d, format: .flac, instrumental: false)
        XCTAssertEqual(stems.count, 4, "senza base")
        XCTAssertTrue(stems.allSatisfy { $0.url.pathExtension == "flac" })
    }

    // MARK: Mixer

    func testMixerMuteSoloAndVolume() {
        var m = MixState()
        XCTAssertEqual(m.effectiveGain("vocals"), 1)
        m.gain["bass"] = 1.3
        XCTAssertEqual(m.effectiveGain("bass"), 1.3)
        m.muted.insert("drums")
        XCTAssertEqual(m.effectiveGain("drums"), 0)
        m.solo.insert("bass")
        XCTAssertEqual(m.effectiveGain("vocals"), 0, "con un solo attivo, le altre tacciono")
        XCTAssertEqual(m.effectiveGain("bass"), 1.3)
        XCTAssertNil(m.preset)
    }

    func testMixerPresets() {
        var m = MixState()
        XCTAssertEqual(m.preset, .all)
        m.apply(.karaoke)
        XCTAssertEqual(m.effectiveGain("vocals"), 0)
        XCTAssertEqual(m.effectiveGain("drums"), 1)
        XCTAssertEqual(m.preset, .karaoke)
        m.apply(.voice)
        XCTAssertEqual(m.effectiveGain("vocals"), 1)
        XCTAssertEqual(m.effectiveGain("other"), 0)
        XCTAssertEqual(MixPlayer.exportName(state: m, title: "Brano"), "Brano – Solo voce")
        m.apply(.all)
        m.gain["vocals"] = 0.3
        XCTAssertEqual(MixPlayer.exportName(state: m, title: "Brano"), "Brano – Mix")
    }

    /// Il tempo che manca parte dal primo avanzamento: l'apertura lenta dei modelli non gonfia la stima.
    func testPaceIgnoresModelOpening() {
        let p = SeparationJob.Pace()
        let t0 = Date()
        XCTAssertNil(p.remaining(at: 0.01, now: t0.addingTimeInterval(300)), "il primo pezzo arriva dopo 5 minuti di apertura")
        // Poi 10 s per ogni 10%: da 0,01 a 0,21 in 20 s, mancano 0,79 → 79 s (non i 1.500 s di prima)
        let left = p.remaining(at: 0.21, now: t0.addingTimeInterval(320))
        XCTAssertEqual(left ?? 0, 79, accuracy: 0.5)
    }

    /// Versione completa: i modelli inclusi nell'app si copiano una volta sola, senza toccare quelli già presenti.
    func testInstallBundledModels() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Inclusi \(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let src = root.appendingPathComponent("App/Modelli"), dst = root.appendingPathComponent("Supporto/Modelli")
        try fm.createDirectory(at: src.appendingPathComponent("StrumentiSW2.mlmodelc"), withIntermediateDirectories: true)
        try Data("pesi".utf8).write(to: src.appendingPathComponent("StrumentiSW2.mlmodelc/model.mil"))
        try Data("{}".utf8).write(to: src.appendingPathComponent("StrumentiSW2.json"))
        try fm.createDirectory(at: src.appendingPathComponent("HTDemucs.mlmodelc"), withIntermediateDirectories: true)
        try Data("nuovo".utf8).write(to: src.appendingPathComponent("leggimi.txt"))
        // Un modello già presente (scaricato prima) resta com'è
        try fm.createDirectory(at: dst.appendingPathComponent("HTDemucs.mlmodelc"), withIntermediateDirectories: true)
        try Data("già qui".utf8).write(to: dst.appendingPathComponent("HTDemucs.mlmodelc/segno"))

        let copied = ModelStore.installBundled(from: src, to: dst)
        XCTAssertEqual(Set(copied), ["StrumentiSW2"], "solo quello che manca (modello e descrizione)")
        XCTAssertTrue(fm.fileExists(atPath: dst.appendingPathComponent("StrumentiSW2.mlmodelc/model.mil").path))
        XCTAssertTrue(fm.fileExists(atPath: dst.appendingPathComponent("StrumentiSW2.json").path))
        XCTAssertTrue(fm.fileExists(atPath: dst.appendingPathComponent("HTDemucs.mlmodelc/segno").path), "il modello già presente non si tocca")
        XCTAssertFalse(fm.fileExists(atPath: dst.appendingPathComponent("leggimi.txt").path), "solo modelli e descrizioni")
        XCTAssertTrue(ModelStore.installBundled(from: src, to: dst).isEmpty, "la seconda volta non c'è niente da copiare")
        XCTAssertTrue(ModelStore.installBundled(from: nil, to: dst).isEmpty, "nell'app leggera non ci sono modelli")
    }

    /// Una cartella intera: le canzoni anche nelle sottocartelle, in ordine, senza file nascosti, non audio
    /// o già creati da AudioLR.
    func testSongsInFolder() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Cartella \(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("Disco 2"), withIntermediateDirectories: true)
        for name in ["10 Fine.mp3", "2 Inizio.wav", "Disco 2/1 Bonus.flac", "copertina.jpg", ".nascosta.mp3",
                     "Inizio – Voce.wav", "Inizio – Base (senza voce).wav", "Inizio – Karaoke.wav", "Inizio – Mix 2.wav",
                     "Inizio – Senza batteria.wav", "Inizio.stem.mp4", "video.mp4",
                     // Canzoni vere con nomi che somigliano a quelli di AudioLR: restano
                     "Eros – Senza di te.mp3", "Artista – Voce.mp3"] {
            try Data([0]).write(to: root.appendingPathComponent(name))
        }
        let single = root.appendingPathComponent("2 Inizio.wav")
        let base = root.resolvingSymlinksInPath().path + "/"
        let found = SeparationJob.songs(in: [root]).map { $0.resolvingSymlinksInPath().path.replacingOccurrences(of: base, with: "") }
        XCTAssertEqual(found, ["2 Inizio.wav", "10 Fine.mp3", "Artista – Voce.mp3", "Disco 2/1 Bonus.flac", "Eros – Senza di te.mp3"])
        // Un file scelto da solo passa così com'è; un percorso che non esiste no
        XCTAssertEqual(SeparationJob.songs(in: [single, root.appendingPathComponent("non c'è.mp3")]), [single])
    }

    /// «Senza il mio strumento»: la batteria va via anche divisa nei suoi pezzi, il resto suona.
    func testWithoutMyInstrument() {
        var m = MixState()
        m.apply(without: .drums)
        for k in ["drums", "kick", "snare", "toms", "hh", "ride", "crash"] { XCTAssertEqual(m.effectiveGain(k), 0, k) }
        for k in ["vocals", "bass", "guitar", "piano", "other"] { XCTAssertEqual(m.effectiveGain(k), 1, k) }
        XCTAssertEqual(m.without, .drums)
        XCTAssertNil(m.preset)
        XCTAssertEqual(MixPlayer.exportName(state: m, title: "Brano"), "Brano – Senza batteria")
        m.apply(without: .bass)
        XCTAssertEqual(m.effectiveGain("bass"), 0)
        XCTAssertEqual(m.effectiveGain("kick"), 1)
        XCTAssertEqual(MixPlayer.exportName(state: m, title: "Brano"), "Brano – Senza basso")
        // Un muto in più a mano: non è più «senza basso» e basta
        m.muted.insert("vocals")
        XCTAssertNil(m.without)
        m.apply(.all)
        XCTAssertNil(m.without)
        XCTAssertEqual(m.preset, .all)
        // Il mio strumento si ricorda
        let old = MixState.Instrument.mine
        MixState.Instrument.mine = .guitar
        XCTAssertEqual(MixState.Instrument.mine, .guitar)
        MixState.Instrument.mine = old
    }

    func testMixSumsWithGains() {
        var m = MixState()
        m.gain["vocals"] = 0.5
        m.muted = ["bass"]
        let out = MixState.mix([(key: "vocals", audio: [[1, 1], [2, 2]]),
                                (key: "drums", audio: [[0.25, 0.25], [0.25, 0.25]]),
                                (key: "bass", audio: [[9, 9], [9, 9]])], state: m)
        XCTAssertEqual(out[0], [0.75, 0.75])
        XCTAssertEqual(out[1], [1.25, 1.25])
    }

    // MARK: Cronologia

    func testHistoryKeepsExistingFoldersNewestFirst() throws {
        let d = try tempDir()
        let defaults = UserDefaults(suiteName: "audiolr-test-\(UUID().uuidString)")!
        let a = d.appendingPathComponent("A"), b = d.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        History.add(song: URL(fileURLWithPath: "/x/Prima.mp3"), folder: a, quality: .fast, defaults: defaults)
        History.add(song: URL(fileURLWithPath: "/x/Seconda.mp3"), folder: b, quality: .best, defaults: defaults)
        XCTAssertEqual(History.all(defaults: defaults).map(\.title), ["Seconda", "Prima"])
        try FileManager.default.removeItem(at: a)
        XCTAssertEqual(History.all(defaults: defaults).map(\.title), ["Seconda"], "le cartelle cancellate spariscono")
        History.remove(History.all(defaults: defaults)[0], defaults: defaults)
        XCTAssertTrue(History.all(defaults: defaults).isEmpty)
    }

    func testHistoryClear() throws {
        let defaults = UserDefaults(suiteName: "svuota-\(UUID().uuidString)")!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("svuota-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        History.add(song: URL(fileURLWithPath: "/x/Una.mp3"), folder: dir, quality: .best, defaults: defaults)
        XCTAssertEqual(History.all(defaults: defaults).count, 1)
        History.clear(defaults: defaults)
        XCTAssertTrue(History.all(defaults: defaults).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "svuotare la cronologia non cancella le tracce")
    }

    func testHistoryFindsStemsByName() throws {
        let d = try tempDir()
        for name in ["Brano – Voce.wav", "Brano – Batteria.flac", "Brano – Base (senza voce).m4a", "altro.txt"] {
            FileManager.default.createFile(atPath: d.appendingPathComponent(name).path, contents: Data())
        }
        XCTAssertEqual(History.stems(in: d, title: "Brano").map(\.key), ["vocals", "drums", "instrumental"])
    }

    func testLibraryStats() {
        let items = [HistoryItem(title: "A", folder: "/a", date: Date(), quality: "best", duration: 90, seconds: 60),
                     HistoryItem(title: "B", folder: "/b", date: Date(), quality: "fast", duration: 150, seconds: 20),
                     HistoryItem(title: "C", folder: "/c", date: Date(), quality: "fast")]
        let s = History.stats(items)
        XCTAssertEqual(s.songs, 3)
        XCTAssertEqual(s.minutes, 4, accuracy: 1e-9)
        XCTAssertEqual(s.averageSeconds ?? 0, 40, accuracy: 1e-9)
    }

    func testOldHistoryStillReads() throws {
        // Le separazioni salvate dalle versioni precedenti non hanno durata, tempi e motore
        let json = #"[{"id":"\#(UUID().uuidString)","title":"Vecchia","folder":"/x","date":0,"quality":"best"}]"#
        let items = try JSONDecoder().decode([HistoryItem].self, from: Data(json.utf8))
        XCTAssertEqual(items.first?.title, "Vecchia")
        XCTAssertNil(items.first?.duration)
    }

    func testSafeGainKeepsTracksInProportion() {
        XCTAssertEqual(Stem.safeGain(peaks: [0.5, 0.9]), 1, "sotto il massimo: niente da fare")
        XCTAssertEqual(Stem.safeGain(peaks: [0.5, 1.4]), Stem.ceiling / 1.4, accuracy: 1e-6)
    }

    func testSaveNeverClipsAndReportsBalance() throws {
        let d = try tempDir()
        // Una base che supera il massimo (1,5) solo a destra: prima veniva tagliata, suono «fritto»
        let n = 4000
        let loud: [[Float]] = [[Float](repeating: 0.2, count: n), (0..<n).map { Float(sin(Double($0) * 0.05)) * 1.5 }]
        let quiet: [[Float]] = [[Float](repeating: 0.1, count: n), [Float](repeating: 0.1, count: n)]
        let (_, stems) = try SeparationJob.save([quiet, quiet, loud, quiet], sources: ["drums", "bass", "other", "vocals"],
                                                song: d.appendingPathComponent("Forte.wav"), into: d, format: .wav24, instrumental: false)
        let other = try XCTUnwrap(stems.first { $0.key == "other" })
        XCTAssertLessThan(other.gainDB, -3, "volume abbassato di circa 4 dB")
        XCTAssertGreaterThan(other.balance ?? 0, 0.9, "quasi tutta l'energia a destra")
        let back = try AudioIO.read(other.url)
        let peak = back[1].map(abs).max() ?? 0
        XCTAssertLessThan(peak, 0.99)
        XCTAssertGreaterThan(peak, 0.95, "abbassato quanto basta, non di più")
        // Proporzioni tenute: la batteria scende dello stesso tanto
        let drums = try AudioIO.read(try XCTUnwrap(stems.first { $0.key == "drums" }).url)
        XCTAssertEqual(drums[0][100], 0.1 * Stem.ceiling / 1.5, accuracy: 1e-3)
    }

    func testStemMeasure() {
        let m = Stem.measure([[0.5, -0.5], [0, 0]])
        XCTAssertEqual(m.energy, 0.5, accuracy: 1e-9)
        XCTAssertEqual(m.balance, 0, accuracy: 1e-9, "tutto a sinistra")
        XCTAssertEqual(m.peakDB, 20 * log10(0.5), accuracy: 1e-6)
    }

    func testHistoryDates() {
        let now = Date()
        XCTAssertTrue(History.when(now, now: now).hasPrefix("oggi"))
        XCTAssertEqual(History.when(now.addingTimeInterval(-86_400), now: now), "ieri")
    }

    func testFolderNames() {
        XCTAssertEqual(Prefs.displayName(of: Paths.output), "Musica › IsoLR")
        XCTAssertEqual(Prefs.displayName(of: Paths.home.appendingPathComponent("Desktop/Tracce")), "Desktop › Tracce")
    }

    func testStemNames() {
        XCTAssertEqual(Stem.info("vocals").name, "Voce")
        XCTAssertEqual(Stem.info("drums").name, "Batteria")
        XCTAssertEqual(Stem.info("bass").name, "Basso")
        XCTAssertEqual(Stem.info("other").name, "Altri strumenti")
        XCTAssertEqual(Stem.info("sconosciuto").name, "Sconosciuto")
    }

    // MARK: Risultati di Core ML

    func testReadsCoreMLFloat32WithPaddedRows() throws {
        // 2 righe da 3 valori, ma in memoria ogni riga occupa 4 posti (come quando Core ML «allinea»)
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: 8)
        let values: [Float] = [1, 2, 3, -9, 4, 5, 6, -9]
        storage.initialize(from: values, count: 8)
        let a = try MLMultiArray(dataPointer: storage, shape: [1, 2, 3], dataType: .float32, strides: [8, 4, 1]) { $0.deallocate() }
        XCTAssertEqual(CoreMLSeparationCore.floats(a), [1, 2, 3, 4, 5, 6])
    }

    func testReadsCoreMLFloat16() throws {
        let a = try MLMultiArray(shape: [2, 2], dataType: .float16)
        // 1.0, -2.0, 0.5, 3.0 in mezza precisione
        let bits: [UInt16] = [0x3C00, 0xC000, 0x3800, 0x4200]
        let p = a.dataPointer.assumingMemoryBound(to: UInt16.self)
        for i in 0..<4 { p[i] = bits[i] }
        XCTAssertEqual(CoreMLSeparationCore.floats(a), [1, -2, 0.5, 3])
    }

    func testArrayRoundTrip() throws {
        let v: [Float] = (0..<24).map { Float($0) * 0.5 }
        let a = try CoreMLSeparationCore.array(v, shape: [1, 2, 3, 4])
        XCTAssertEqual(CoreMLSeparationCore.floats(a), v)
    }

    // MARK: Spettrogramma, casi limite

    func testReflectPadShortSignal() {
        // Come pad1d di Demucs: segnale più corto del margine → prima silenzio, poi specchio
        let y = Spectrogram.reflectPad([1, 2], left: 3, right: 3)
        XCTAssertEqual(y.count, 8)
        XCTAssertEqual(Array(y[3..<5]), [1, 2])
    }

    func testShortSongFrames() {
        let s = Spectrogram()
        XCTAssertEqual(s.frames(for: 343_980), 336)
        XCTAssertEqual(s.frames(for: 1024), 1)
        XCTAssertEqual(s.frames(for: 1025), 2)
        let z = s.forward([Float](repeating: 0.1, count: 3000))
        XCTAssertEqual(z.re.count, 2048 * 3)
    }

    // MARK: Qualità e motore

    func testQualityModels() {
        XCTAssertEqual(Quality.fast.models, ["HTDemucs"])
        XCTAssertEqual(Quality.best.models, ["HTDemucsFT-0", "HTDemucsFT-1", "HTDemucsFT-2", "HTDemucsFT-3"])
        let d = UserDefaults.standard.string(forKey: Quality.key)
        defer { UserDefaults.standard.set(d, forKey: Quality.key) }
        UserDefaults.standard.removeObject(forKey: Quality.key)
        XCTAssertEqual(Quality.current, .best, "di serie: massima qualità")
    }

    func testObsoleteModelsAreRemoved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("modelli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("StrumentiSW.mlmodelc"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("StrumentiSW2.mlmodelc"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("VoceCori.json").path, contents: Data("{}".utf8))
        defer { try? FileManager.default.removeItem(at: dir) }
        let removed = ModelStore.removeObsolete(in: dir)
        XCTAssertEqual(Set(removed), ["StrumentiSW.mlmodelc", "VoceCori.json"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("StrumentiSW2.mlmodelc").path), "i modelli nuovi restano")
        for m in Quality.allCases.flatMap(\.everyModel) + ExtraSplit.allCases.map(\.modelName) {
            XCTAssertFalse(ModelStore.obsolete.contains(m), "\(m) è in uso: non va tolto")
        }
    }

    func testOldGraphicsChoiceIsReconsideredWithTheNewThreshold() {
        let d = UserDefaults(suiteName: "soglia-\(UUID().uuidString)")!
        // Scelta salvata con la vecchia soglia di 30 dB: 27 dB → grafica. Ora vale il Neural Engine
        EngineChoice.store(EngineChoice.Decision(units: .cpuAndGPU, agreement: 27), for: "VoceRoFormer8", defaults: d)
        XCTAssertEqual(EngineChoice.stored("VoceRoFormer8", defaults: d)?.units, .all)
        // Agreement 0 = il Neural Engine ha dato un risultato sbagliato: si resta sulla grafica
        EngineChoice.store(EngineChoice.Decision(units: .cpuAndGPU, agreement: 0), for: "StrumentiSW", defaults: d)
        XCTAssertEqual(EngineChoice.stored("StrumentiSW", defaults: d)?.units, .cpuAndGPU)
        XCTAssertEqual(EngineChoice.decide(agreement: 15).units, .cpuAndGPU)
    }

    func testNoNeuralEngineChoiceIsKept() {
        // Mac Intel: nessuna prova del motore, il modello resta su grafica e processore anche dopo il riavvio
        let d = UserDefaults(suiteName: "intel-\(UUID().uuidString)")!
        EngineChoice.store(EngineChoice.Decision(units: .all, agreement: EngineChoice.noANE), for: "VoceRevive", defaults: d)
        XCTAssertEqual(EngineChoice.stored("VoceRevive", defaults: d)?.units, .all)
    }

    func testProcessorOnlyChoiceIsRemembered() {
        // Su un Mac dove Neural Engine e grafica non riescono a calcolare si resta sul solo processore
        let d = UserDefaults(suiteName: "processore-\(UUID().uuidString)")!
        let cpu = EngineChoice.Decision(units: .cpuOnly, agreement: 0)
        EngineChoice.store(cpu, for: "VoceRoFormer8", defaults: d)
        XCTAssertEqual(EngineChoice.stored("VoceRoFormer8", defaults: d), cpu)
        XCTAssertTrue(cpu.text.hasPrefix("Solo processore"))
    }

    func testEngineChoiceRememberedPerModel() {
        let d = UserDefaults(suiteName: "audiolr-test-\(UUID().uuidString)")!
        XCTAssertNil(EngineChoice.stored("HTDemucs", defaults: d))
        let good = EngineChoice.decide(agreement: 45)
        XCTAssertEqual(good.units, .all)
        let bad = EngineChoice.decide(agreement: 12)
        XCTAssertEqual(bad.units, .cpuAndGPU)
        XCTAssertTrue(bad.text.hasPrefix("Grafica"))
        EngineChoice.store(bad, for: "HTDemucs", defaults: d)
        XCTAssertEqual(EngineChoice.stored("HTDemucs", defaults: d), bad)
        XCTAssertNil(EngineChoice.stored("HTDemucsFT-0", defaults: d))
        EngineChoice.reset(defaults: d)
        XCTAssertNil(EngineChoice.stored("HTDemucs", defaults: d))
    }

    func testAgreement() {
        let a: [[[Float]]] = [[[1, 2, 3], [3, 2, 1]]]
        XCTAssertGreaterThan(Separator.agreement(a, a), 100)
        let b: [[[Float]]] = [[[1.1, 2, 3], [3, 2, 1]]]
        XCTAssertEqual(Separator.agreement(a, b), 10 * log10(28 / 0.01), accuracy: 0.01)
    }

    func testMergeTakesEachSpecialist() {
        let sources = ["drums", "bass", "other", "vocals"]
        func r(_ v: Float) -> [[[Float]]] { sources.map { _ in [[v], [v]] } }
        var out: [[[Float]]] = []
        for (k, key) in sources.enumerated() {
            Separator.merge(&out, r(Float(k + 1)), sources: sources, specialty: [key])
        }
        XCTAssertEqual(out.map { $0[0][0] }, [1, 2, 3, 4], "ogni strumento dal suo modello")
        // Un modello «per tutto» sostituisce tutto
        var all: [[[Float]]] = []
        Separator.merge(&all, r(7), sources: sources, specialty: sources)
        XCTAssertEqual(all.map { $0[1][0] }, [7, 7, 7, 7])
    }

    func testPieceIsCenteredLikeDemucs() {
        let norm: [[Float]] = [(0..<10).map(Float.init), (0..<10).map { Float($0) * 2 }]
        // Pezzo da 8 che comincia a 6: restano 4 campioni, centrati con 2 prima (4, 5) e 2 di silenzio dopo
        let p = Separator.piece(norm, offset: 6, segment: 8)
        XCTAssertEqual(p[0], [4, 5, 6, 7, 8, 9, 0, 0])
        XCTAssertEqual(Separator.piece(norm, offset: 0, segment: 4)[1], [0, 2, 4, 6])
    }

    // MARK: Forme d'onda e testi

    func testPeaks() {
        let n = 10_000
        let quiet = [Float](repeating: 0.1, count: n)
        var loud = quiet
        loud[7_500] = 0.9
        let p = Peaks.of([quiet, loud], count: 100)
        XCTAssertEqual(p.count, 100)
        XCTAssertEqual(p[10], 0.1, accuracy: 1e-6)
        XCTAssertEqual(p[75], 0.5, accuracy: 1e-6, "media dei due canali")
        XCTAssertEqual(Peaks.of([[Float]](), count: 10), [])
    }

    @MainActor
    func testTexts() {
        XCTAssertEqual(formatTime(222), "3:42")
        XCTAssertEqual(formatTime(5), "0:05")
        XCTAssertEqual(ContentView.sentence("il file è vuoto"), "Il file è vuoto.")
        XCTAssertEqual(ContentView.timeLeft(5), "Quasi fatto")
        XCTAssertEqual(ContentView.timeLeft(42), "Circa 40 secondi")
        XCTAssertEqual(ContentView.timeLeft(61), "Circa 1 minuto")
        XCTAssertEqual(ContentView.timeLeft(200), "Circa 3 minuti")
    }
}
