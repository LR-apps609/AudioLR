import XCTest
import CoreML
import Darwin

/// Il banco dei tempi (workflow «Tempi Mac»): separa la stessa canzone con le tre qualità, come l'app,
/// e misura secondi, passi, memoria massima e fluidità della finestra. Scrive /tmp/audiolr-banco.json e copia
/// le tracce in /tmp/audiolr-banco/tracce, per confrontarle con quelle della versione di prima.
/// Gira solo con AUDIOLR_BANCO=1 (xcodebuild: TEST_RUNNER_AUDIOLR_BANCO=1): nei test normali si salta.
/// Nessun dato esce dal Mac: i numeri restano nel file, e il workflow li allega come «artifact».
@MainActor
final class BenchTests: XCTestCase {

    static let output = URL(fileURLWithPath: "/tmp/audiolr-banco.json")
    static let tracks = URL(fileURLWithPath: "/tmp/audiolr-banco/tracce", isDirectory: true)

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["AUDIOLR_BANCO"] == "1" else { throw XCTSkip("solo per il banco dei tempi") }
        executionTimeAllowance = 4 * 3600
    }

    // MARK: Le prove (in ordine di nome: apertura, Rapida, Massima, Studio)

    /// Aprire un modello la prima volta in questo processo e la seconda (dopo averlo liberato).
    func test1Apertura() async throws {
        var out: [String: Any] = [:]
        for name in ["HTDemucs", "StrumentiSW2"] {
            do { try await ModelStore.shared.prepare(name) { _ in } } catch { throw XCTSkip("\(name) non raggiungibile") }
            ModelStore.shared.release(name)
            let t0 = Date()
            _ = try await ModelStore.shared.mlModel(name, units: .all) { _ in }
            let cold = Date().timeIntervalSince(t0)
            ModelStore.shared.release(name)
            let t1 = Date()
            _ = try await ModelStore.shared.mlModel(name, units: .all) { _ in }
            let warm = Date().timeIntervalSince(t1)
            ModelStore.shared.release(name)
            out[name] = ["primaApertura": cold, "secondaApertura": warm]
        }
        Self.record("apertura", out)
    }

    func test2Rapida() async throws {
        try await separate(.fast, seconds: 30, tag: "rapida-1")
        try await separate(.fast, seconds: 30, tag: "rapida-2")
    }

    func test3Massima() async throws {
        try await separate(.best, seconds: 10, tag: "massima-1")
        try await separate(.best, seconds: 10, tag: "massima-2")
    }

    func test4Studio() async throws {
        try await separate(.studio, seconds: 5, tag: "studio-1")
    }

    // MARK: Una separazione misurata

    private func separate(_ q: Quality, seconds: Double, tag: String) async throws {
        for m in q.allModels {
            do { try await ModelStore.shared.prepare(m) { _ in } } catch { throw XCTSkip("\(m) non raggiungibile") }
        }
        let clip = try Self.clip(seconds: seconds)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("banco-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        UserDefaults.standard.set(out.path, forKey: Prefs.folderKey)
        defer { UserDefaults.standard.removeObject(forKey: Prefs.folderKey); try? FileManager.default.removeItem(at: out) }

        let job = SeparationJob.shared
        job.reset()
        let sampler = Sampler()
        sampler.start()
        let start = Date()
        job.start(clip, quality: q)
        while job.isBusy { try await Task.sleep(nanoseconds: 100_000_000) }
        let took = Date().timeIntervalSince(start)
        let s = sampler.stop()
        if case .failed(let msg) = job.phase { return XCTFail("\(tag): separazione non riuscita: \(msg)") }
        XCTAssertEqual(job.phase, .done)

        // Le tracce, per il confronto con la versione di prima
        let dest = Self.tracks.appendingPathComponent(tag, isDirectory: true)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        for stem in job.stems {
            try? FileManager.default.copyItem(at: stem.url, to: dest.appendingPathComponent(stem.key + "." + stem.url.pathExtension))
        }
        let row: [String: Any] = [
            "qualita": q.rawValue, "secondiCanzone": seconds, "secondi": took,
            "passi": job.timings.map { ["nome": $0.name, "secondi": $0.seconds] },
            "motore": job.engineText ?? "",
            "memoriaMassimaMB": Double(s.peakFootprint) / 1_048_576,
            "memoriaPiccoProcessoMB": Double(Self.footprint().peak) / 1_048_576,
            "ritardoMassimoFinestraMs": s.maxLag * 1000,
            "blocchiOltre50ms": s.stalls,
            "tracce": job.stems.map(\.key),
        ]
        Self.record(tag, row)
        print(String(format: "Banco %@: %.1f s · memoria %.0f MB · ritardo massimo %.0f ms · blocchi %d",
                     tag, took, Double(s.peakFootprint) / 1_048_576, s.maxLag * 1000, s.stalls))
    }

    // MARK: Strumenti

    /// I primi `seconds` della canzone di prova (AUDIOLR_BANCO_CANZONE), o una canzone sintetica se manca.
    private static func clip(seconds: Double) throws -> URL {
        let rate = AudioIO.sampleRate, n = Int(seconds * rate)
        var audio: [[Float]]
        if let path = ProcessInfo.processInfo.environment["AUDIOLR_BANCO_CANZONE"], FileManager.default.fileExists(atPath: path) {
            let all = try AudioIO.read(URL(fileURLWithPath: path))
            audio = all.map { Array($0.prefix(n)) }
        } else {
            var l = [Float](repeating: 0, count: n), r = l
            for i in 0..<n {
                let t = Double(i) / rate
                let chord = 0.08 * (sin(2 * .pi * 220 * t) + sin(2 * .pi * 277.2 * t) + sin(2 * .pi * 329.6 * t))
                let beat = (i % 22_050) < 2_500 ? 0.4 * sin(2 * .pi * 60 * t) * exp(-Double(i % 22_050) / 600) : 0
                var voice = 0.0
                for k in 1...12 { voice += sin(2 * .pi * 220 * Double(k) * t) / Double(k) }
                l[i] = Float(chord + 0.18 * sin(2 * .pi * 55 * t) + beat + 0.1 * voice)
                r[i] = Float(0.8 * chord + 0.18 * sin(2 * .pi * 55 * t) + beat + 0.1 * voice)
            }
            audio = [l, r]
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Banco \(Int(seconds)) s.wav")
        try AudioIO.write(audio, to: url, format: .wav24)
        return url
    }

    /// Aggiunge una voce al file del banco (il file resta valido anche se una prova dopo si interrompe).
    private static func record(_ key: String, _ value: Any) {
        var all = (try? Data(contentsOf: output)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if all["macchina"] == nil {
            all["macchina"] = [
                "modello": sysctl("hw.model"), "processore": sysctl("machdep.cpu.brand_string"),
                "memoriaGB": Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
                "neuralEngine": SeparationJob.hasNeuralEngine, "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            ] as [String: Any]
        }
        var runs = all["prove"] as? [String: Any] ?? [:]
        runs[key] = value
        all["prove"] = runs
        if let data = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output) }
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }

    /// La memoria del processo adesso e il massimo da quando è partito (come «Memoria» in Monitoraggio Attività).
    nonisolated static func footprint() -> (now: UInt64, peak: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? (info.phys_footprint, info.ledger_phys_footprint_peak) : (0, 0)
    }

    /// Ogni 10 ms: la memoria (su un thread a parte) e quanto in ritardo arriva il turno della finestra (thread principale).
    final class Sampler: @unchecked Sendable {
        private let lock = NSLock()
        private var peak: UInt64 = 0
        private var maxLag = 0.0
        private var stalls = 0
        private var last = Date()
        private var memTimer: DispatchSourceTimer?
        private var mainTimer: DispatchSourceTimer?

        func start() {
            last = Date()
            let m = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            m.schedule(deadline: .now(), repeating: .milliseconds(10))
            m.setEventHandler { [weak self] in
                let f = BenchTests.footprint().now
                self?.lock.withLock { if f > self!.peak { self!.peak = f } }
            }
            m.resume()
            memTimer = m
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in
                guard let self else { return }
                let now = Date()
                self.lock.withLock {
                    let lag = now.timeIntervalSince(self.last) - 0.010
                    if lag > self.maxLag { self.maxLag = lag }
                    if lag > 0.050 { self.stalls += 1 }
                    self.last = now
                }
            }
            t.resume()
            mainTimer = t
        }

        func stop() -> (peakFootprint: UInt64, maxLag: Double, stalls: Int) {
            memTimer?.cancel(); mainTimer?.cancel()
            return lock.withLock { (peak, max(0, maxLag), stalls) }
        }
    }
}
