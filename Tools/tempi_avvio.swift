// Il tempo di avvio di IsoLR: dal lancio alla prima finestra sullo schermo, tre volte.
//   swift Tools/tempi_avvio.swift <percorso di AudioLR.app> <uscita.json>
// Guarda le finestre con CGWindowList (non serve nessun permesso): conta la prima finestra normale dell'app.
import Foundation
import CoreGraphics

let app = CommandLine.arguments[1]
let out = CommandLine.arguments[2]
let info = NSDictionary(contentsOfFile: app + "/Contents/Info.plist")
let exe = app + "/Contents/MacOS/" + ((info?["CFBundleExecutable"] as? String) ?? "AudioLR")

func hasWindow(_ pid: Int32) -> Bool {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.contains {
        ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
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
    print(String(format: "Avvio %d: %@", i + 1, t.map { String(format: "%.2f s", $0) } ?? "nessuna finestra in 90 s"))
    if let t { times.append(t) }
    p.terminate()
    p.waitUntilExit()
    sleep(3)
}
let json: [String: Any] = ["avvii": times, "primo": times.first ?? -1, "mediana": times.sorted().dropFirst(times.count / 2).first ?? -1]
try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted).write(to: URL(fileURLWithPath: out))
