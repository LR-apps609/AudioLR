import Foundation
import CoreML

// ════════════════════════════════════════════════════════════════════
//  Il modello Demucs (HTDemucs, licenza MIT) si scarica la prima volta
//  dalle «Release» di IsoLR (versione «modelli-1», non è un aggiornamento
//  dell'app) e resta nella cartella di supporto. Poi tutto funziona senza internet.
// ════════════════════════════════════════════════════════════════════

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let support = home.appendingPathComponent("Library/Application Support/AudioLR", isDirectory: true)
    /// Dove finiscono le tracce separate: Musica/IsoLR/<canzone>/ (Musica non chiede permessi).
    static let output = home.appendingPathComponent("Music/IsoLR", isDirectory: true)
    /// La cartella delle tracce delle versioni chiamate ancora AudioLR (fino alla 0.23).
    static let legacyOutput = home.appendingPathComponent("Music/AudioLR", isDirectory: true)

    /// IsoLR (0.24): Musica › AudioLR diventa Musica › IsoLR, una volta sola, con la cronologia che punta
    /// ai nuovi percorsi. Se la cartella nuova c'è già, o lo spostamento non riesce, non si tocca niente.
    @discardableResult
    static func migrateOutput(from old: URL = legacyOutput, to new: URL = output, defaults: UserDefaults = .standard) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return false }
        do { try fm.moveItem(at: old, to: new) } catch { return false }
        History.rebase(from: old.path, to: new.path, defaults: defaults)
        // Chi aveva scelto proprio quella cartella nelle Impostazioni passa a quella nuova
        if defaults.string(forKey: Prefs.folderKey) == old.path { defaults.set(new.path, forKey: Prefs.folderKey) }
        return true
    }
}

final class ModelStore: @unchecked Sendable {
    static let shared = ModelStore()

    static let name = "HTDemucs"
    static let base = URL(string: "https://github.com/LR-apps609/AudioLR/releases/download/modelli-1/")!
    static var folder: URL { Paths.support.appendingPathComponent("Modelli", isDirectory: true) }
    static func compiled(_ name: String) -> URL { folder.appendingPathComponent(name + ".mlmodelc", isDirectory: true) }
    static var compiled: URL { compiled(name) }

    func isReady(_ name: String) -> Bool { FileManager.default.fileExists(atPath: Self.compiled(name).path) }
    var isReady: Bool { isReady(Self.name) }

    /// Un modello pronto per ogni nome e scelta di unità di calcolo.
    private var cores: [String: CoreMLSeparationCore] = [:]
    private var models: [String: MLModel] = [:]
    /// Aperture che si è smesso di aspettare: quando finiscono, il modello non si tiene.
    private var abandoned: Set<String> = []
    /// Le aperture in corso, per non aprire due volte lo stesso modello.
    private var inflight: [String: Task<MLModel, Error>] = [:]
    private let lock = NSLock()

    /// Il modello pronto all'uso: lo scarica e lo prepara se serve. `progress` riceve 0…1 durante lo scaricamento.
    /// `units`: dove fare i calcoli (di solito tutto: Neural Engine, grafica e processore).
    func load(_ name: String = ModelStore.name, units: MLComputeUnits = .all,
              progress: @escaping (Double) -> Void) async throws -> CoreMLSeparationCore {
        let key = "\(name)#\(units.rawValue)"
        let cached = lock.withLock { cores[key] }
        if let c = cached { return c }
        let c = try CoreMLSeparationCore(model: try await mlModel(name, units: units, progress: progress))
        lock.withLock { cores[key] = c }
        return c
    }

    /// Scarica e installa il modello se manca, senza aprirlo: aprirlo (e adattarlo al Neural Engine) si fa dopo,
    /// una volta sola e con le unità di calcolo giuste. `progress`: 0…0,8 scaricamento, poi verifica e installazione.
    /// `status`: le frasi per chi aspetta («Ripreso da 120 MB», «Connessione interrotta: riprovo tra 4 s…»).
    func prepare(_ name: String, status: @escaping (String) -> Void = { _ in },
                 progress: @escaping (Double) -> Void) async throws {
        if !isReady(name) { try await downloadOnce(name, status: status, progress: progress) }
        progress(1)
    }

    /// Gli scaricamenti in corso: lo stesso modello non si scarica due volte insieme (es. preparazione e separazione).
    private var downloading: [String: Task<Void, Error>] = [:]

    private func downloadOnce(_ name: String, status: @escaping (String) -> Void = { _ in },
                              progress: @escaping (Double) -> Void) async throws {
        let task: Task<Void, Error> = lock.withLock {
            if let t = downloading[name] { return t }
            let t = Task { try await self.download(name, status: status, progress: progress) }
            downloading[name] = t
            return t
        }
        defer { lock.withLock { if downloading[name] == task { downloading[name] = nil } } }
        // «Annulla» ferma anche lo scaricamento (la parte già arrivata resta: la prossima volta si riprende da lì)
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Il modello Core ML così com'è (scaricato e preparato se serve).
    func mlModel(_ name: String, units: MLComputeUnits = .all, progress: @escaping (Double) -> Void) async throws -> MLModel {
        let key = "\(name)#\(units.rawValue)"
        if let m = lock.withLock({ models[key] }) { return m }
        // Se lo stesso modello si sta già aprendo (es. la preparazione al primo avvio), si aspetta quello:
        // due aperture insieme raddoppierebbero memoria e tempo
        let task: Task<MLModel, Error> = lock.withLock {
            if let t = inflight[key] { return t }
            let t = Task { () throws -> MLModel in
                if !self.isReady(name) { try await self.downloadOnce(name, progress: progress) }
                return try await self.open(name, units: units, key: key)
            }
            inflight[key] = t
            return t
        }
        defer { lock.withLock { if inflight[key] == task { inflight[key] = nil } } }
        return try await task.value
    }

    private func open(_ name: String, units: MLComputeUnits, key: String) async throws -> MLModel {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = units
        let url = Self.compiled(name)
        let began = Date()
        AppLog.write("Apro \(name) (\(Self.unitsName(units)))")
        // L'apertura può durare minuti (la prima volta il Neural Engine adatta il modello): fuori dai thread di Swift
        let model: MLModel = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try MLModel(contentsOf: url, configuration: cfg)) } catch {
                    AppLog.write("Non si apre \(name) (\(Self.unitsName(units))): \(error.localizedDescription)")
                    // Il file è sano se si apre almeno sul processore: allora il problema è un altro (es. memoria)
                    // e il modello non si cancella, così non si riscaricano centinaia di MB per niente
                    let cpu = MLModelConfiguration()
                    cpu.computeUnits = .cpuOnly
                    if units != .cpuOnly, (try? MLModel(contentsOf: url, configuration: cpu)) != nil {
                        cont.resume(throwing: SeparationError("il modello non si apre su \(Self.unitsName(units)) (memoria quasi piena?): chiudi le altre app e riprova, oppure scegli «Solo grafica» in Impostazioni › Motore"))
                    } else {
                        // Modello rovinato (scaricamento interrotto, macOS diverso…): la prossima volta si riscarica
                        try? FileManager.default.removeItem(at: url)
                        cont.resume(throwing: SeparationError("il modello di IA era rovinato: riprova, verrà scaricato di nuovo"))
                    }
                }
            }
        }
        AppLog.write(String(format: "Aperto %@ (%@) in %.1f s", name, Self.unitsName(units), Date().timeIntervalSince(began)))
        // Se nel frattempo si è smesso di aspettarlo (troppo lento), non si tiene in memoria
        let keep = lock.withLock { () -> Bool in
            if abandoned.remove(key) != nil { return false }
            models[key] = model
            return true
        }
        if !keep { AppLog.write("\(name) (\(Self.unitsName(units))) arrivato tardi: non si tiene") }
        return model
    }

    /// La descrizione che accompagna alcuni modelli (es. VoceRoFormer.json): scaricata una volta e tenuta accanto.
    func config(_ name: String) async throws -> Data {
        let url = Self.folder.appendingPathComponent(name + ".json")
        if let d = try? Data(contentsOf: url) { return d }
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let (data, resp) = try await URLSession.shared.data(from: Self.base.appendingPathComponent(name + ".json"))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw SeparationError("la descrizione del modello non è disponibile") }
        try data.write(to: url)
        return data
    }

    /// Il modello voce RoFormer, pronto (scaricato e preparato se serve).
    func voice(_ name: String = Quality.best.voiceModel ?? "VoceRoFormer9", units: MLComputeUnits = .all,
               progress: @escaping (Double) -> Void) async throws -> VoiceRoFormer {
        try await roformer(name, units: units, progress: progress)
    }

    /// Un modello RoFormer qualsiasi (voce o a più strumenti) con la sua descrizione.
    func roformer(_ name: String, units: MLComputeUnits = .all, progress: @escaping (Double) -> Void) async throws -> RoFormer {
        let cfg = try JSONDecoder().decode(RoFormerConfig.self, from: try await config(name))
        return RoFormer(model: try await mlModel(name, units: units, progress: progress), config: cfg)
    }

    /// I modelli inclusi nell'app (versione completa, file .dmg): stanno in Contents/Resources/Modelli.
    static var bundled: URL? { Bundle.main.resourceURL?.appendingPathComponent("Modelli", isDirectory: true) }

    /// Al primo avvio i modelli inclusi nell'app si copiano nella cartella dei modelli: così gli aggiornamenti
    /// (che portano solo l'app, pochi MB) li trovano già lì. Restituisce i nomi dei modelli copiati.
    @discardableResult
    static func installBundled(from source: URL? = bundled, to folder: URL = ModelStore.folder) -> [String] {
        let fm = FileManager.default
        guard let source, let items = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else { return [] }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var copied: [String] = []
        for item in items where ["mlmodelc", "json"].contains(item.pathExtension) {
            let target = folder.appendingPathComponent(item.lastPathComponent)
            guard !fm.fileExists(atPath: target.path) else { continue }
            // Prima in una cartella provvisoria, poi al suo posto: un avvio interrotto non lascia un modello a metà
            let tmp = folder.appendingPathComponent(".copia-\(UUID().uuidString)-" + item.lastPathComponent)
            do {
                try fm.copyItem(at: item, to: tmp)
                try fm.moveItem(at: tmp, to: target)
                copied.append(item.deletingPathExtension().lastPathComponent)
            } catch {
                try? fm.removeItem(at: tmp)
                AppLog.write("Modello incluso non copiato \(item.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !copied.isEmpty { AppLog.write("Modelli inclusi installati: " + copied.joined(separator: ", ")) }
        return copied
    }

    /// Modelli di versioni passate, sostituiti da altri: si tolgono dal disco all'avvio (centinaia di MB).
    static let obsolete = ["StrumentiSW", "VoceStudio", "VoceStudio3", "VoceCori",
                                   // Le voci con i pesi compressi a 8 bit: molto lente sulla grafica (0.18)
                                   "VoceStudio2", "VoceCori2", "VoceRoFormer8"]

    /// Toglie dal disco i modelli che nessuna versione attuale usa più.
    @discardableResult
    static func removeObsolete(in folder: URL = ModelStore.folder) -> [String] {
        let fm = FileManager.default
        var removed: [String] = []
        for name in obsolete {
            for ext in ["mlmodelc", "json"] {
                let url = folder.appendingPathComponent("\(name).\(ext)")
                if fm.fileExists(atPath: url.path), (try? fm.removeItem(at: url)) != nil { removed.append(url.lastPathComponent) }
            }
        }
        return removed
    }

    /// Libera la memoria di un modello (tutte le sue copie: Neural Engine, grafica…). Si riapre dal disco quando serve.
    func release(_ name: String) {
        lock.withLock {
            cores = cores.filter { !$0.key.hasPrefix(name + "#") }
            models = models.filter { !$0.key.hasPrefix(name + "#") }
        }
    }

    /// Libera una sola copia di un modello (es. quella che ha perso la gara del motore sui Mac Intel).
    func release(_ name: String, units: MLComputeUnits) {
        let key = "\(name)#\(units.rawValue)"
        lock.withLock {
            cores[key] = nil
            models[key] = nil
        }
    }

    /// Si smette di aspettare l'apertura di un modello su queste unità.
    func abandon(_ name: String, units: MLComputeUnits) {
        _ = lock.withLock { abandoned.insert("\(name)#\(units.rawValue)") }
    }

    static func unitsName(_ u: MLComputeUnits) -> String {
        switch u {
        case .cpuOnly: return "processore"
        case .cpuAndGPU: return "grafica"
        case .cpuAndNeuralEngine: return "Neural Engine"
        case .all: return "tutto"
        @unknown default: return "altro"
        }
    }

    /// Quante copie di modelli sono aperte (per le prove).
    var openCount: Int { lock.withLock { models.count } }

    /// Dimentica i modelli già aperti (dopo averli eliminati dal disco).
    func forget() { lock.withLock { cores.removeAll(); models.removeAll() } }

    private func download(_ name: String, status: @escaping (String) -> Void = { _ in },
                          progress: @escaping (Double) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        do {
            // Il codice di controllo, per essere sicuri che il file arrivi intero
            let (shaData, shaResp) = try await Self.session.data(from: Self.base.appendingPathComponent(name + ".sha256"))
            guard (shaResp as? HTTPURLResponse)?.statusCode == 200,
                  let expected = String(decoding: shaData, as: UTF8.self).split(separator: " ").first.map(String.init) else {
                throw SeparationError("il modello di IA non è ancora disponibile")
            }
            let zipURL = Self.base.appendingPathComponent(name + ".mlpackage.zip")
            // Il file arriva in «.parziale» accanto ai modelli: se si interrompe (rete, Annulla, Mac spento)
            // la volta dopo si riprende da dove si era fermato
            let tmp = Self.folder.appendingPathComponent(name + ".mlpackage.zip.parziale")
            // Lo scaricamento è l'80% della barra; il resto è verifica, estrazione e installazione (sul Mac, qualche decina di secondi)
            try await Self.fetch(zipURL, to: tmp, status: status) { progress(0.8 * $0) }
            progress(0.81)
            if Self.sha256(of: tmp) != expected {
                // Un pezzo rovinato (o un «.parziale» di una versione vecchia del modello): si ricomincia da zero, una volta
                try? fm.removeItem(at: tmp)
                status("Il modello scaricato non supera il controllo (è arrivato incompleto): lo scarico di nuovo da capo…")
                try await Self.fetch(zipURL, to: tmp, status: status) { progress(0.8 * $0) }
                guard Self.sha256(of: tmp) == expected else {
                    try? fm.removeItem(at: tmp)
                    throw SeparationError("il modello scaricato non supera il controllo per due volte di fila: la connessione lo rovina per strada. Prova un'altra rete e premi di nuovo «Separa»")
                }
            }
            progress(0.84)
            let work = Self.folder.appendingPathComponent("scarico-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: work); try? fm.removeItem(at: tmp) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", tmp.path, work.path]
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0,
                  let pkg = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "mlpackage" }) else {
                throw SeparationError("non riesco ad aprire il modello scaricato")
            }
            progress(0.88)
            let built = try await MLModel.compileModel(at: pkg)
            progress(0.99)
            try? fm.removeItem(at: Self.compiled(name))
            try fm.moveItem(at: built, to: Self.compiled(name))
        } catch let e as SeparationError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            // Annullato dall'utente: non è un problema di rete
            throw CancellationError()
        } catch let e as URLError {
            AppLog.write("Scaricamento di \(name) non riuscito: \(e.localizedDescription)")
            throw SeparationError("non riesco a scaricare il modello di IA: la connessione a internet si è interrotta per \(Self.attempts) volte. Controlla la rete e premi di nuovo «Separa»: lo scaricamento riprende da dove si era fermato")
        } catch {
            // Non è la rete: di solito il disco (spazio finito, cartella non scrivibile)
            AppLog.write("Scaricamento di \(name) non riuscito: \(error.localizedDescription)")
            throw SeparationError("non riesco a salvare il modello di IA sul Mac (\(error.localizedDescription)): controlla che ci sia spazio libero sul disco e riprova")
        }
    }

    /// La sessione per i modelli: se per 30 s non arriva niente la connessione si considera ferma e si riprova.
    /// La parte già arrivata resta, quindi riprovare non ricomincia da zero.
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 6 * 3600
        return URLSession(configuration: c)
    }()

    /// Quante volte si prova uno scaricamento che si interrompe, con attese crescenti (2, 4, 8, 16 s).
    static let attempts = 5

    /// Scarica `url` in `dest`, riprendendo dalla parte già scaricata (richiesta «Range»). Se la connessione cade o
    /// si ferma, riprova fino a `attempts` volte. `progress`: 0…1 sul file intero, al massimo 10 volte al secondo
    /// (prima arrivava a ogni pacchetto: centinaia di aggiornamenti della finestra al secondo).
    static func fetch(_ url: URL, to dest: URL, session: URLSession = ModelStore.session, status: @escaping (String) -> Void,
                      progress: @escaping (Double) -> Void) async throws {
        var attempt = 1
        while true {
            try Task.checkCancellation()
            let have = ((try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber)?.int64Value ?? 0
            if have > 0 { status("Riprendo a scaricare da \(megabytes(have)), dove si era fermato…") }
            do {
                try await Chunked.run(url, to: dest, from: have, session: session, progress: progress)
                return
            } catch let e as URLError where e.code != .cancelled && attempt < attempts && !Task.isCancelled {
                let wait = 1 << attempt          // 2, 4, 8, 16 s
                let what = e.code == .timedOut ? "Da 30 secondi non arrivano dati" : "La connessione si è interrotta"
                status("\(what): riprovo a scaricare tra \(wait) s (tentativo \(attempt + 1) di \(attempts)). Quello già scaricato resta.")
                AppLog.write("Scaricamento \(url.lastPathComponent): \(e.localizedDescription), riprovo tra \(wait) s")
                try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
                attempt += 1
            }
        }
    }

    static func megabytes(_ bytes: Int64) -> String { "\(bytes / 1_048_576) MB" }

    /// Uno scaricamento scritto man mano su disco, in coda a quello che c'è già.
    private final class Chunked: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let file: FileHandle
        private var done: Int64
        private var total: Int64 = 0
        private var last = Date.distantPast
        private let progress: (Double) -> Void
        private var cont: CheckedContinuation<Void, Error>?
        private var failure: Error?

        private init(file: FileHandle, from: Int64, progress: @escaping (Double) -> Void) {
            self.file = file; self.done = from; self.progress = progress
        }

        static func run(_ url: URL, to dest: URL, from: Int64, session: URLSession, progress: @escaping (Double) -> Void) async throws {
            let fm = FileManager.default
            if !fm.fileExists(atPath: dest.path) { fm.createFile(atPath: dest.path, contents: nil) }
            let file = try FileHandle(forWritingTo: dest)
            defer { try? file.close() }
            var req = URLRequest(url: url)
            if from > 0 { req.setValue("bytes=\(from)-", forHTTPHeaderField: "Range") }
            let me = Chunked(file: file, from: from, progress: progress)
            // Una sessione per scaricamento, con le stesse regole (timeout) e questo oggetto a ricevere i dati
            let own = URLSession(configuration: session.configuration, delegate: me, delegateQueue: nil)
            defer { own.finishTasksAndInvalidate() }
            let task = own.dataTask(with: req)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    me.cont = c
                    task.resume()
                }
            } onCancel: { task.cancel() }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            do {
                switch code {
                case 206:
                    try file.seekToEnd()
                case 200:
                    // Il server non riprende da metà: si ricomincia da zero
                    try file.truncate(atOffset: 0)
                    done = 0
                case 416 where done > 0:
                    // Era già tutto arrivato: resta solo da verificarlo
                    total = done
                    completionHandler(.cancel)
                    return
                default:
                    failure = SeparationError("il modello di IA non è disponibile sul server di IsoLR (risposta \(code)): riprova più tardi, oppure aggiorna IsoLR dal menu IsoLR › Controlla aggiornamenti…")
                    completionHandler(.cancel)
                    return
                }
            } catch {
                failure = error
                completionHandler(.cancel)
                return
            }
            if response.expectedContentLength > 0 { total = done + response.expectedContentLength }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            do { try file.write(contentsOf: data) } catch {
                failure = error
                dataTask.cancel()
                return
            }
            done += Int64(data.count)
            let now = Date()
            if total > 0, now.timeIntervalSince(last) >= 0.1 {
                last = now
                progress(min(1, Double(done) / Double(total)))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let c = cont
            cont = nil
            if let f = failure { c?.resume(throwing: f); return }
            if total > 0 && done >= total { progress(1); c?.resume(); return }
            if let error { c?.resume(throwing: error); return }
            // Finito senza errori ma più corto del previsto: la connessione si è chiusa a metà
            if total > 0 && done < total { c?.resume(throwing: URLError(.networkConnectionLost)); return }
            progress(1)
            c?.resume()
        }
    }

    static func sha256(of url: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        p.arguments = ["-a", "256", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: " ").first.map(String.init)
    }
}
