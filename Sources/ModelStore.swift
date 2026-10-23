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
    private let lock = NSLock()

    /// Il modello pronto all'uso: lo scarica e lo prepara se serve. `progress` riceve 0…1 durante lo scaricamento.
    /// `units`: dove fare i calcoli (di solito tutto: Neural Engine, grafica e processore).
    func load(_ name: String = ModelStore.name, units: MLComputeUnits = .all,
              progress: @escaping (Double) -> Void) async throws -> CoreMLSeparationCore {
        let key = "\(name)#\(units.rawValue)"
        let cached = lock.withLock { cores[key] }
        if let c = cached { return c }
        if !isReady(name) { try await download(name, progress: progress) }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = units
        let model: MLModel
        do { model = try MLModel(contentsOf: Self.compiled(name), configuration: cfg) } catch {
            // Modello rovinato (scaricamento interrotto, macOS diverso…): la prossima volta si riscarica
            try? FileManager.default.removeItem(at: Self.compiled(name))
            throw SeparationError("il modello di IA non si apre: riprova, verrà scaricato di nuovo")
        }
        let c = try CoreMLSeparationCore(model: model)
        lock.withLock { cores[key] = c }
        return c
    }

    /// Dimentica i modelli già aperti (dopo averli eliminati dal disco).
    func forget() { lock.withLock { cores.removeAll() } }

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
            let (tmp, resp) = try await URLSession.shared.download(from: zipURL, delegate: ProgressDelegate(progress))
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw SeparationError("il modello di IA non è ancora disponibile") }
            guard Self.sha256(of: tmp) == expected else { throw SeparationError("il modello scaricato è rovinato, riprova") }
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
            let built = try await MLModel.compileModel(at: pkg)
            try? fm.removeItem(at: Self.compiled(name))
            try fm.moveItem(at: built, to: Self.compiled(name))
        } catch let e as SeparationError {
            throw e
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
