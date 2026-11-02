import Foundation
import Darwin

// ════════════════════════════════════════════════════════════════════
//  I tempi delle separazioni, sul Mac: una riga per ogni separazione
//  (qualità, durata, secondi, passi, motore, memoria massima, Mac) in
//  Supporto Applicazioni › AudioLR › Tempi.txt. Non si manda niente a
//  nessuno: le ultime righe finiscono in «Segnala» solo se lo mandi tu.
// ════════════════════════════════════════════════════════════════════

enum TimingLog {
    static var url: URL { Paths.support.appendingPathComponent("Tempi.txt") }
    private static let lock = NSLock()

    /// Una riga: «2026-11-02 14:03 · Massima · canzone 3:42 · 2:10 · Voce 50 s, Strumenti 60 s · Neural Engine · memoria max 2,1 GB · Mac…»
    static func line(date: Date = Date(), quality: String, songSeconds: Double, seconds: Double, steps: [(String, Double)],
                     engine: String, peakBytes: UInt64, machine: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "it_IT")
        let parts = steps.map { "\($0.0) \(Int($0.1.rounded())) s" }.joined(separator: ", ")
        let memory = String(format: "%.1f GB", Double(peakBytes) / 1_073_741_824).replacingOccurrences(of: ".", with: ",")
        return [f.string(from: date), quality, "canzone \(formatTime(songSeconds))", formatTime(seconds),
                parts, engine, "memoria max \(memory)", machine].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Aggiunge una riga. Si tengono le ultime 500 (qualche decina di KB).
    static func add(_ line: String, to url: URL = TimingLog.url) {
        lock.withLock {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            lines.append(line)
            try? (lines.suffix(500).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Le ultime righe, per una segnalazione.
    static func tail(_ n: Int = 20, from url: URL = TimingLog.url) -> [String] {
        lock.withLock {
            ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").suffix(n).map(String.init)
        }
    }

    /// Il Mac in breve: modello, chip, memoria.
    static let machine: String = {
        func sysctl(_ name: String) -> String {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
            var buf = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "" }
            return String(cString: buf)
        }
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        return "\(sysctl("hw.model")) \(sysctl("machdep.cpu.brand_string")) \(Int(gb.rounded())) GB"
    }()
}

/// La memoria usata da IsoLR (quella di «Memoria» in Monitoraggio Attività), misurata ogni mezzo secondo
/// mentre si separa: alla fine dice il massimo. Costa pochissimo (una chiamata al sistema ogni 0,5 s).
final class MemoryMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var timer: DispatchSourceTimer?

    static func now() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in
            let m = MemoryMeter.now()
            self?.lock.withLock { if m > self!.peak { self!.peak = m } }
        }
        t.resume()
        timer = t
    }

    /// Si ferma e dice il massimo (in byte).
    func stop() -> UInt64 {
        timer?.cancel()
        timer = nil
        let m = MemoryMeter.now()
        return lock.withLock { max(peak, m) }
    }
}
