import AppKit
import Metal

// ════════════════════════════════════════════════════════════════════
//  IsoLR si accorge da sola quando qualcosa va storto, anche se nessuno
//  usa «Segnala»: la finestra che non risponde per qualche secondo, un
//  lavoro fermo troppo a lungo, una chiusura brusca (arresto o uscita
//  forzata). Lo scrive nel registro e, al primo avvio dopo, propone un
//  rapporto in un file sulla Scrivania, facile da mandare su WhatsApp o
//  per email. Il rapporto non contiene il nome utente né le canzoni.
// ════════════════════════════════════════════════════════════════════

enum Health {
    /// La cartella dei file di controllo (accanto al registro).
    static var folder: URL { AppLog.url.deletingLastPathComponent() }
    /// Esiste mentre IsoLR è aperta: se all'avvio c'è ancora, l'ultima volta non si è chiusa bene.
    static var marker: URL { folder.appendingPathComponent("aperta.txt") }
    /// I problemi notati e non ancora proposti nel rapporto.
    static var problemsURL: URL { folder.appendingPathComponent("problemi.txt") }

    /// Secondi senza risposta della finestra prima di scriverlo nel registro.
    static let hangSeconds: Double = 5
    /// Minuti senza nessun avanzamento di un lavoro prima di considerarlo fermo (un pezzo su un Mac Intel
    /// lento dura fino a 6 minuti: 15 lasciano margine).
    static let stallMinutes: Double = 15

    private static let lock = NSLock()
    nonisolated(unsafe) static var lastPong = Date()
    nonisolated(unsafe) private static var lastTick = Date()
    nonisolated(unsafe) private static var hangLogged = false
    nonisolated(unsafe) private static var activity: (what: String, since: Date)?
    nonisolated(unsafe) private static var stallLogged = false
    nonisolated(unsafe) private static var started = false

    /// All'avvio: controlla come si era chiusa l'ultima volta e accende la sorveglianza.
    static func start(version: String) {
        guard lock.withLock({ () -> Bool in defer { started = true }; return !started }) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if let last = try? String(contentsOf: marker, encoding: .utf8) {
            problem("L'ultima volta IsoLR non si è chiusa bene (arresto improvviso, o chiusa a forza mentre era bloccata). Era aperta da: \(last.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        try? "\(version) · \(Date())".write(to: marker, atomically: true, encoding: .utf8)
        // La finestra risponde? Un filo a parte bussa ogni secondo; se per 5 s nessuno apre, lo si scrive
        let t = Thread {
            while true {
                Thread.sleep(forTimeInterval: 1)
                DispatchQueue.main.async { lock.withLock { lastPong = Date() } }
                check(now: Date())
            }
        }
        t.name = "IsoLR sorveglianza"
        t.qualityOfService = .utility
        t.start()
    }

    /// Chiusura normale: niente da segnalare la prossima volta.
    static func cleanExit() { try? FileManager.default.removeItem(at: marker) }

    /// Un lavoro lungo che avanza (scaricamento, separazione…): `what` dice cosa sta facendo.
    static func progressed(_ what: String) {
        lock.withLock {
            activity = (what, Date())
            stallLogged = false
        }
    }

    /// Il lavoro è finito (bene, male o annullato).
    static func idle() { lock.withLock { activity = nil } }

    /// Cosa stava facendo IsoLR, per il rapporto.
    static var doing: String { lock.withLock { activity?.what ?? "niente (in attesa)" } }

    /// Il controllo periodico (separato per le prove).
    /// Per le prove: la sorveglianza come appena accesa.
    static func resetForTests(now: Date = Date()) {
        lock.withLock { lastPong = now; lastTick = now; hangLogged = false; stallLogged = false; activity = nil }
    }

    static func check(now: Date) {
        var notes: [String] = []
        lock.withLock {
            // Il Mac è stato in stop (coperchio chiuso): anche la sorveglianza dormiva, non è un blocco
            if now.timeIntervalSince(lastTick) > 3 { lastPong = now }
            lastTick = now
            let silent = now.timeIntervalSince(lastPong)
            if silent >= hangSeconds && !hangLogged {
                hangLogged = true
                notes.append(String(format: "La finestra non risponde da %.0f secondi (stava facendo: %@)", silent, activity?.what ?? "niente"))
            } else if silent < 2 && hangLogged {
                hangLogged = false
                AppLog.write("La finestra risponde di nuovo")
            }
            if let a = activity, !stallLogged, now.timeIntervalSince(a.since) >= stallMinutes * 60 {
                stallLogged = true
                notes.append("Lavoro fermo da \(Int(stallMinutes)) minuti senza avanzare: \(a.what)")
            }
        }
        notes.forEach(problem)
    }

    /// Scrive un problema nel registro e lo tiene da parte per il rapporto del prossimo avvio.
    static func problem(_ text: String) {
        AppLog.write("PROBLEMA: " + text)
        lock.withLock {
            let line = "\(Date()) · \(text)\n"
            if let h = try? FileHandle(forWritingTo: problemsURL) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: problemsURL)
            }
        }
    }

    /// I problemi da proporre (di questa sessione e delle precedenti), poi dimenticati.
    static func takeProblems() -> [String] {
        lock.withLock {
            defer { try? FileManager.default.removeItem(at: problemsURL) }
            guard let text = try? String(contentsOf: problemsURL, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        }
    }

    /// Toglie il nome utente da percorsi e testi: /Users/nome → /Users/***.
    static func redact(_ text: String, home: String = NSHomeDirectory(), user: String = NSUserName()) -> String {
        var t = text.replacingOccurrences(of: home, with: "/Users/***")
        t = t.replacingOccurrences(of: #"/Users/[^/\s"']+"#, with: "/Users/***", options: .regularExpression)
        if user.count >= 3 { t = t.replacingOccurrences(of: user, with: "***") }
        return t
    }

    // MARK: Il rapporto

    /// Il rapporto completo: tutto quello che serve per rifare il problema, senza nome utente.
    @MainActor static func report(problems: [String]) -> String {
        var lines = ["RAPPORTO DI ISOLR (Mac) · \(Date())", ""]
        lines.append("Cosa è andato storto:")
        lines += problems.isEmpty ? ["—"] : problems.map { "• " + $0 }
        lines.append("")
        lines.append("Cosa stava facendo IsoLR: \(doing)")
        let d = UserDefaults.standard
        let previous = d.string(forKey: "health.previousVersion")
        lines.append("Installazione: " + (previous == nil ? "primo avvio" : previous == UpdateCheck.current ? "già usata" : "aggiornata dalla \(previous!)"))
        lines.append("")
        lines.append(BugReport.systemInfo())
        lines.append("Architettura: " + (SeparationJob.hasNeuralEngine ? "Apple Silicon" : "Intel"))
        lines.append("Scheda grafica: \(MTLCreateSystemDefaultDevice()?.name ?? "nessuna (Metal non disponibile)")")
        let screens = NSScreen.screens.enumerated().map { i, s in
            String(format: "schermo %d: %.0f×%.0f punti, scala %.0f×, spazio utile %.0f×%.0f", i + 1,
                   s.frame.width, s.frame.height, s.backingScaleFactor, s.visibleFrame.width, s.visibleFrame.height)
        }
        lines.append("Schermi (\(NSScreen.screens.count)): " + screens.joined(separator: " · "))
        if let w = NSApp?.windows.first(where: { $0.isVisible }) {  // NSApp è nil nei test
            lines.append(String(format: "Finestra: %.0f×%.0f", w.frame.width, w.frame.height))
        }
        lines.append("Lingua: \(Locale.preferredLanguages.prefix(3).joined(separator: ", ")) · formato \(Locale.current.identifier), decimali «\(Locale.current.decimalSeparator ?? "?")»")
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if let free = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
            lines.append(String(format: "Spazio libero: %.1f GB", Double(free) / 1_000_000_000))
        }
        let out = Prefs.folder
        let cloud = (try? out.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
            || out.path.contains("Mobile Documents") || out.path.contains("CloudStorage")
        lines.append("Cartella delle tracce: \(redact(out.path))\(cloud ? " (su iCloud o in un'altra nuvola)" : "")")
        lines.append("Riduci movimento: \(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? "sì" : "no") · contrasto alto: \(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? "sì" : "no")")
        lines.append("")
        lines.append("Registro (ultime 150 righe):")
        lines.append(AppLog.tail(150))
        return redact(lines.joined(separator: "\n"))
    }

    /// Salva il rapporto sulla Scrivania (o, se non si può, nella cartella Download) e lo mostra nel Finder.
    @MainActor @discardableResult
    static func saveReport(problems: [String]) -> URL? {
        let fm = FileManager.default
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        let name = "Rapporto IsoLR \(f.string(from: Date())).txt"
        for dir in [fm.urls(for: .desktopDirectory, in: .userDomainMask).first, fm.urls(for: .downloadsDirectory, in: .userDomainMask).first].compactMap({ $0 }) {
            let url = dir.appendingPathComponent(name)
            if (try? report(problems: problems).write(to: url, atomically: true, encoding: .utf8)) != nil {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return url
            }
        }
        return nil
    }

    /// Al primo avvio dopo un problema: «Vuoi mandarmi il rapporto?».
    /// Durante le prove automatiche (l'app fa da ospite ai test) niente finestre di dialogo.
    static var underTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
    }

    @MainActor static func offerReportIfNeeded() {
        guard !underTests else { return }
        let problems = takeProblems()
        defer { UserDefaults.standard.set(UpdateCheck.current, forKey: "health.previousVersion") }
        guard !problems.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "L'ultima volta qualcosa è andato storto"
        alert.informativeText = "Vuoi mandarmi il rapporto? IsoLR lo salva in un file sulla Scrivania: puoi mandarlo su WhatsApp o per email. Dentro ci sono solo le informazioni del Mac e cosa stava facendo IsoLR: niente nome utente, niente canzoni."
        alert.addButton(withTitle: "Salva il rapporto sulla Scrivania")
        alert.addButton(withTitle: "Non ora")
        if alert.runModal() == .alertFirstButtonReturn { saveReport(problems: problems) }
    }
}
