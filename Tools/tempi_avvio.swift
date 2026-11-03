// Il tempo di avvio di IsoLR: dal lancio alla prima finestra sullo schermo, tre volte.
//   swift Tools/tempi_avvio.swift <percorso di AudioLR.app> <uscita.json>
// Guarda le finestre con CGWindowList (non serve nessun permesso): conta la prima finestra normale dell'app,
// riconosciuta dal processo lanciato o dal suo nome (IsoLR, AudioLR).
import Foundation
import CoreGraphics

let app = CommandLine.arguments[1]
let out = CommandLine.arguments[2]
let info = NSDictionary(contentsOfFile: app + "/Contents/Info.plist")
let exe = app + "/Contents/MacOS/" + ((info?["CFBundleExecutable"] as? String) ?? "AudioLR")
let names: Set<String> = ["IsoLR", "AudioLR"]

func windows() -> [[String: Any]] {
    CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
}

func hasWindow(_ pid: Int32) -> Bool {
    windows().contains {
        let owner = ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        let name = $0[kCGWindowOwnerName as String] as? String ?? ""
        return (owner == pid || names.contains(name)) && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
    }
}

var times: [Double] = []
for i in 0..<3 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    let t0 = Date()
    try p.run()
    var t: Double?
    while Date().timeIntervalSince(t0) < 90 {
        if hasWindow(p.processIdentifier) { t = Date().timeIntervalSince(t0); break }
        usleep(5_000)
    }
    print("Avvio \(i + 1): " + (t.map { String(format: "%.2f s", $0) } ?? "nessuna finestra in 90 s"))
    if t == nil {
        // Per capire perché: di chi sono le finestre che si vedono, e se l'app è ancora aperta
        let owners = Set(windows().compactMap { $0[kCGWindowOwnerName as String] as? String })
        print("Finestre di: \(owners.sorted().joined(separator: ", ")) · app ancora aperta: \(p.isRunning)")
    }
    if let t { times.append(t) }
    p.terminate()
    p.waitUntilExit()
    sleep(3)
}
let sorted = times.sorted()
let median = sorted.isEmpty ? -1.0 : sorted[sorted.count / 2]
let list = times.map { String(format: "%.3f", $0) }.joined(separator: ", ")
let json = "{\"avvii\": [\(list)], \"primo\": \(String(format: "%.3f", times.first ?? -1.0)), \"mediana\": \(String(format: "%.3f", median))}\n"
try json.write(toFile: out, atomically: true, encoding: .utf8)
print(json)
