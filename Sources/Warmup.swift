import Foundation
import CoreML

// ════════════════════════════════════════════════════════════════════
//  Il primo avvio: i modelli inclusi nell'app (versione completa) si
//  installano, poi il Neural Engine adatta il modello della qualità scelta,
//  in sottofondo. Così la prima canzone parte subito, senza attese.
// ════════════════════════════════════════════════════════════════════

@MainActor
final class Warmup: ObservableObject {
    static let shared = Warmup()
    /// Cosa si sta preparando (nil = niente, l'app è pronta).
    @Published private(set) var text: String?
    private var started = false

    /// Ricordato per ogni modello: adattato al Neural Engine di questo Mac (il sistema lo tiene da parte).
    nonisolated static func preparedKey(_ name: String) -> String { "prepared.\(name)" }

    func start() {
        guard !started else { return }
        started = true
        let needsInstall = (try? FileManager.default.contentsOfDirectory(atPath: ModelStore.bundled?.path ?? ""))?
            .contains { !FileManager.default.fileExists(atPath: ModelStore.folder.appendingPathComponent($0).path) } ?? false
        if needsInstall { text = "Installo i modelli di IA (solo la prima volta)…" }
        Task.detached(priority: .utility) { [weak self] in
            ModelStore.installBundled()
            // Il Neural Engine adatta i modelli della qualità scelta (la prima volta può volerci qualche minuto)
            let q = await MainActor.run { Quality.current }
            let names = [q.voiceModel, q.instrumentModel].compactMap { $0 }
                .filter { ModelStore.shared.isReady($0) && !UserDefaults.standard.bool(forKey: Warmup.preparedKey($0)) }
                // Solo i modelli che useranno davvero il Neural Engine (con 8 GB i grandi vanno sulla grafica)
                .filter { EngineChoice.current($0)?.units != .cpuAndGPU }
            if SeparationJob.hasNeuralEngine && !Prefs.gpuOnly {
                for name in names {
                    await self?.set("Preparo AudioLR per il Neural Engine di questo Mac (solo la prima volta, qualche minuto)…")
                    let units: MLComputeUnits = SeparationJob.useDual ? .cpuAndNeuralEngine : .all
                    let ok = (try? await withTimeout(SeparationJob.aneLimit, { try await ModelStore.shared.mlModel(name, units: units) { _ in } })) ?? nil
                    if ok != nil {
                        UserDefaults.standard.set(true, forKey: Warmup.preparedKey(name))
                        AppLog.write("Preparazione al primo avvio: \(name) pronto sul Neural Engine")
                    } else {
                        ModelStore.shared.abandon(name, units: units)
                        AppLog.write("Preparazione al primo avvio: \(name) troppo lento sul Neural Engine")
                    }
                    if Prefs.lowMemory { ModelStore.shared.release(name) }
                }
            }
            await self?.set(nil)
        }
    }

    private func set(_ t: String?) { text = t }
}
