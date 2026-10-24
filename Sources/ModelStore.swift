import Foundation
import CoreML

// ════════════════════════════════════════════════════════════════════
//  Il modello Demucs (HTDemucs, licenza MIT) si scarica la prima volta
//  dalle «Release» di AudioLR (versione «modelli-1», non è un aggiornamento
//  dell'app) e resta nella cartella di supporto. Poi tutto funziona senza internet.
// ════════════════════════════════════════════════════════════════════

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let support = home.appendingPathComponent("Library/Application Support/AudioLR", isDirectory: true)
    /// Dove finiscono le tracce separate: Musica/AudioLR/<canzone>/ (Musica non chiede permessi).
    static let output = home.appendingPathComponent("Music/AudioLR", isDirectory: true)
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
    func prepare(_ name: String, progress: @escaping (Double) -> Void) async throws {
        if !isReady(name) { try await download(name, progress: progress) }
        progress(1)
    }

    /// Il modello Core ML così com'è (scaricato e preparato se serve).
    func mlModel(_ name: String, units: MLComputeUnits = .all, progress: @escaping (Double) -> Void) async throws -> MLModel {
        let key = "\(name)#\(units.rawValue)"
        if let m = lock.withLock({ models[key] }) { return m }
        if !isReady(name) { try await download(name, progress: progress) }
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
    func voice(_ name: String = Quality.best.voiceModel ?? "VoceRoFormer8", units: MLComputeUnits = .all,
               progress: @escaping (Double) -> Void) async throws -> VoiceRoFormer {
        try await roformer(name, units: units, progress: progress)
    }

    /// Un modello RoFormer qualsiasi (voce o a più strumenti) con la sua descrizione.
    func roformer(_ name: String, units: MLComputeUnits = .all, progress: @escaping (Double) -> Void) async throws -> RoFormer {
        let cfg = try JSONDecoder().decode(RoFormerConfig.self, from: try await config(name))
        return RoFormer(model: try await mlModel(name, units: units, progress: progress), config: cfg)
    }

    /// Modelli di versioni passate, sostituiti da altri: si tolgono dal disco all'avvio (centinaia di MB).
    static let obsolete = ["StrumentiSW", "VoceStudio", "VoceCori"]

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

    private func download(_ name: String, progress: @escaping (Double) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        do {
            // Il codice di controllo, per essere sicuri che il file arrivi intero
            let (shaData, shaResp) = try await URLSession.shared.data(from: Self.base.appendingPathComponent(name + ".sha256"))
            guard (shaResp as? HTTPURLResponse)?.statusCode == 200,
                  let expected = String(decoding: shaData, as: UTF8.self).split(separator: " ").first.map(String.init) else {
                throw SeparationError("il modello di IA non è ancora disponibile")
            }
            let zipURL = Self.base.appendingPathComponent(name + ".mlpackage.zip")
            // Lo scaricamento è l'80% della barra; il resto è verifica, estrazione e installazione (sul Mac, qualche decina di secondi)
            let (tmp, resp) = try await URLSession.shared.download(from: zipURL, delegate: ProgressDelegate { progress(0.8 * $0) })
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw SeparationError("il modello di IA non è ancora disponibile") }
            progress(0.81)
            guard Self.sha256(of: tmp) == expected else { throw SeparationError("il modello scaricato è rovinato, riprova") }
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
        } catch {
            throw SeparationError("non riesco a scaricare il modello di IA (serve internet la prima volta)")
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

    private final class ProgressDelegate: NSObject, URLSessionTaskDelegate {
        let onProgress: (Double) -> Void
        var obs: NSKeyValueObservation?
        init(_ f: @escaping (Double) -> Void) { onProgress = f }
        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            obs = task.progress.observe(\.fractionCompleted) { [weak self] pr, _ in self?.onProgress(pr.fractionCompleted) }
        }
    }
}
