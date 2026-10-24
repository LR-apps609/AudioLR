import XCTest
import SwiftUI
import AppKit

/// Schermate delle finestre principali, chiare e scure, prese durante i test sul Mac di GitHub
/// e pubblicate nella versione «schermate»: servono a controllare la grafica senza un Mac davanti.
@MainActor
final class ScreenshotTests: XCTestCase {
    let out = URL(fileURLWithPath: "/tmp/audiolr-schermate", isDirectory: true)

    private func shot<V: View>(_ view: V, _ name: String, width: CGFloat, height: CGFloat) throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for dark in [false, true] {
            let host = NSHostingView(rootView: view.frame(width: width, height: height))
            host.frame = CGRect(x: 0, y: 0, width: width, height: height)
            let win = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            win.contentView = host
            win.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw XCTSkip("niente schermo") }
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: out.appendingPathComponent("\(name)-\(dark ? "scuro" : "chiaro").png"))
            win.orderOut(nil)
        }
    }

    /// Tracce finte (toni) per mostrare il mixer pieno.
    private func fakeStems() throws -> (URL, [Stem]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("schermate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var stems: [Stem] = []
        let keys = ["vocals", "drums", "bass", "guitar", "piano", "other", "instrumental"]
        let shares: [Double] = [0.28, 0.22, 0.16, 0.12, 0.09, 0.13, 0]
        for (i, k) in keys.enumerated() {
            let n = 44_100 * 6
            let f = 110.0 * Double(i + 1)
            let x = (0..<n).map { j -> Float in
                let t = Double(j) / 44_100
                return Float(0.3 * sin(2 * .pi * f * t) * (0.5 + 0.5 * sin(2 * .pi * (0.7 + Double(i) * 0.3) * t)))
            }
            let info = Stem.info(k)
            let url = dir.appendingPathComponent("Canzone di prova – \(info.name).wav")
            try AudioIO.write([x, x], to: url, format: .wav16)
            stems.append(Stem(key: k, name: info.name, symbol: info.symbol, url: url, peaks: Peaks.of([x, x]),
                              share: k == "instrumental" ? nil : shares[i], peakDB: -3.2, balance: 0.5))
        }
        return (dir, stems)
    }

    func testScreenshots() throws {
        executionTimeAllowance = 300
        let job = SeparationJob.shared
        try shot(ContentView().environmentObject(job), "1-inizio", width: 1020, height: 680)
        let (dir, stems) = try fakeStems()
        defer { try? FileManager.default.removeItem(at: dir); job.reset() }
        job.showcase(title: "Canzone di prova", stems: stems, folder: dir, quality: .best, duration: 214,
                     analysis: SongAnalysis(bpm: 124, keyRoot: 9, minor: true, keyConfidence: 0.8), elapsed: 312,
                     engine: "Neural Engine (verificato: 48 dB)",
                     timings: [.init(name: "Voce (RoFormer)", seconds: 96), .init(name: "Strumenti (BS-RoFormer SW)", seconds: 190)])
        try shot(ContentView().environmentObject(job), "2-risultati", width: 1020, height: 760)
        try shot(DetailsView().environmentObject(job), "3-dettagli", width: 320, height: 620)
        try shot(SettingsView(), "4-impostazioni", width: 520, height: 470)
        try shot(AccountView().environmentObject(job), "5-account", width: 480, height: 600)
        try shot(FAQView(), "6-domande", width: 620, height: 620)
        try shot(BugReportView(), "7-segnala", width: 520, height: 600)
        try shot(GuideView(), "8-guida", width: 330, height: 640)
    }
}
