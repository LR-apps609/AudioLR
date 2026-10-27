import XCTest
import SwiftUI
import AppKit

/// Schermate delle finestre principali, chiare e scure, prese durante i test sul Mac di GitHub
/// e pubblicate nella versione «schermate»: servono a controllare la grafica senza un Mac davanti.
@MainActor
final class ScreenshotTests: XCTestCase {
    let out = URL(fileURLWithPath: "/tmp/audiolr-schermate", isDirectory: true)

    /// Le finestre con logo e onde animate (disegnate con la grafica) fanno chiudere i test sulle macchine
    /// virtuali di GitHub, dentro Metal: lì si saltano finché non c'è un disegno alternativo.
    private func skipOnVirtualMac() throws {
        // Con le forme semplici al posto di Canvas non serve più saltare (vedi Drawing)
    }

    override func setUp() async throws {
        // I test girano senza l'app: le finestre hanno bisogno di un'applicazione attiva
        _ = NSApplication.shared
        Drawing.flat = true
        NSApp.setActivationPolicy(.accessory)
        executionTimeAllowance = 300
    }

    private func shot<V: View>(_ view: V, _ name: String, width: CGFloat, height: CGFloat) throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for dark in [false, true] {
            let host = NSHostingView(rootView: view.frame(width: width, height: height))
            host.frame = CGRect(x: 0, y: 0, width: width, height: height)
            let win = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            win.contentView = host
            win.setFrameOrigin(NSPoint(x: 40, y: 40))
            win.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            // La finestra così come la mostra macOS (anche le parti disegnate con la grafica, come onde e logo):
            // le finestre della propria app si fotografano senza permessi
            guard let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(win.windowNumber),
                                                   [.boundsIgnoreFraming, .bestResolution]) else {
                win.orderOut(nil)
                throw XCTSkip("niente schermo su questo Mac")
            }
            let rep = NSBitmapImageRep(cgImage: cg)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: out.appendingPathComponent("\(name)-\(dark ? "scuro" : "chiaro").png"))
            win.orderOut(nil)
        }
    }

    /// Tracce finte (toni) per mostrare il mixer pieno.
    /// Parti finte sui 6 secondi delle tracce di prova.
    static let parts = SongStructure(beats: stride(from: 0.0, to: 6, by: 0.25).map { $0 }, firstDownbeat: 0, beatsPerBar: 4, sections: [
        SongSection(start: 0, end: 0.6, label: "Intro", group: 0), SongSection(start: 0.6, end: 1.8, label: "Strofa", group: 1),
        SongSection(start: 1.8, end: 2.8, label: "Ritornello", group: 2), SongSection(start: 2.8, end: 4, label: "Strofa", group: 1),
        SongSection(start: 4, end: 5.4, label: "Ritornello", group: 2), SongSection(start: 5.4, end: 6, label: "Finale", group: 3)])

    private func fakeStems() throws -> (URL, [Stem]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("schermate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var stems: [Stem] = []
        let keys = ["vocals", "drums", "bass", "guitar", "piano", "other", "instrumental"]
        let shares: [Double] = [0.28, 0.22, 0.16, 0.12, 0.09, 0.13, 0]
        for (i, k) in keys.enumerated() {
            let n = 44_100 * 6
            let f = 110.0 * Double(i + 1)
            let wobble = 0.7 + Double(i) * 0.3
            var x = [Float](repeating: 0, count: n)
            for j in 0..<n {
                let t = Double(j) / 44_100
                let tone: Double = sin(2 * Double.pi * f * t)
                let level: Double = 0.5 + 0.5 * sin(2 * Double.pi * wobble * t)
                x[j] = Float(0.3 * tone * level)
            }
            let info = Stem.info(k)
            let url = dir.appendingPathComponent("Canzone di prova – \(info.name).wav")
            try AudioIO.write([x, x], to: url, format: .wav16)
            stems.append(Stem(key: k, name: info.name, symbol: info.symbol, url: url, peaks: Peaks.of([x, x]),
                              share: k == "instrumental" ? nil : shares[i], peakDB: -3.2, balance: 0.5))
        }
        return (dir, stems)
    }

    func testShotStart() throws {
        try skipOnVirtualMac()
        try shot(ContentView().environmentObject(SeparationJob.shared), "1-inizio", width: 1280, height: 820)
    }

    func testShotResults() throws {
        try skipOnVirtualMac()
        let job = SeparationJob.shared
        let (dir, stems) = try fakeStems()
        defer { try? FileManager.default.removeItem(at: dir); job.reset() }
        job.showcase(title: "Canzone di prova", stems: stems, folder: dir, quality: .best, duration: 214,
                     analysis: SongAnalysis(bpm: 124, keyRoot: 9, minor: true, keyConfidence: 0.8), elapsed: 312,
                     engine: "Neural Engine (verificato: 48 dB)",
                     timings: [.init(name: "Voce (RoFormer)", seconds: 96), .init(name: "Strumenti (BS-RoFormer SW)", seconds: 190)])
        try shot(ContentView().environmentObject(job), "2-risultati", width: 1280, height: 820)
        try shot(DetailsView().environmentObject(job), "3-dettagli", width: 320, height: 620)
    }

    func testShotSettings() throws { try shot(SettingsView(), "4-impostazioni", width: 660, height: 470) }
    /// La scheda Motore, con «Carico sul computer»
    func testShotEngineSettings() throws { try shot(EngineSettings(), "4b-motore", width: 660, height: 560) }
    func testShotAccount() throws { try shot(AccountView().environmentObject(SeparationJob.shared), "5-account", width: 480, height: 600) }
    func testShotFAQ() throws { try skipOnVirtualMac(); try shot(FAQView(), "6-domande", width: 620, height: 620) }
    func testShotBugReport() throws { try skipOnVirtualMac(); try shot(BugReportView(), "7-segnala", width: 520, height: 600) }
    func testShotGuide() throws { try skipOnVirtualMac(); try shot(GuideView(), "8-guida", width: 330, height: 640) }
    func testShotHistory() throws { try shot(HistoryView().environmentObject(SeparationJob.shared), "9-cronologia", width: 860, height: 520) }
    /// La finestra alla misura minima, con la libreria aperta: niente parole spezzate
    func testShotStartNarrow() throws {
        try skipOnVirtualMac()
        try shot(ContentView().environmentObject(SeparationJob.shared), "1-inizio-stretta", width: 1180, height: 720)
    }

    /// Il tasto «Aggiornamento disponibile» nella testata: alla misura minima e a quella di partenza,
    /// all'inizio e con i risultati. Niente deve uscire dalla finestra.
    func testShotUpdateButton() throws {
        let u = URL(string: "https://example.com/a.audiolr")!
        UpdateNotice.shared.available = UpdateCheck.Release(version: "0.23.1", asset: u, page: u)
        defer { UpdateNotice.shared.available = nil }
        try shot(ContentView().environmentObject(SeparationJob.shared), "10-aggiornamento-stretta", width: 1180, height: 720)
        let job = SeparationJob.shared
        let (dir, stems) = try fakeStems()
        defer { try? FileManager.default.removeItem(at: dir); job.reset() }
        job.showcase(title: "TENDER_WIP_2 versione lunga del titolo", stems: stems, folder: dir, quality: .studio, duration: 280,
                     analysis: SongAnalysis(bpm: 115, keyRoot: 0, minor: false, keyConfidence: 0.8, structure: Self.parts,
                                            chords: [ChordSpan(start: 0, end: 1.5, root: 9, minor: true), ChordSpan(start: 1.5, end: 3, root: 5, minor: false),
                                                     ChordSpan(start: 3, end: 4.5, root: 0, minor: false), ChordSpan(start: 4.5, end: 6, root: 7, minor: false)]),
                     elapsed: 536,
                     engine: "Grafica (scelta nelle Impostazioni)", timings: [])
        // Con la Sala prove aperta: la barra più lunga
        let practice = UserDefaults.standard.object(forKey: "showPractice")
        UserDefaults.standard.set(true, forKey: "showPractice")
        try shot(ContentView().environmentObject(job), "11-aggiornamento-risultati-stretta", width: 1180, height: 760)
        UserDefaults.standard.set(practice, forKey: "showPractice")
        try shot(ContentView().environmentObject(job), "12-aggiornamento-risultati", width: 1280, height: 820)
    }

    /// Gli editor Warp e Rimonta su una canzone con battiti e parti.
    func testShotWarpAndArrange() throws {
        let job = SeparationJob.shared
        let (dir, stems) = try fakeStems()
        defer { try? FileManager.default.removeItem(at: dir); job.reset() }
        job.showcase(title: "Canzone di prova", stems: stems, folder: dir, quality: .best, duration: 6,
                     analysis: SongAnalysis(bpm: 120, keyRoot: 9, minor: true, keyConfidence: 0.8, structure: Self.parts),
                     elapsed: 312, engine: "Neural Engine", timings: [])
        let mixer = MixPlayer()
        let mix = EditAudio.mix(stems, state: MixState())
        try shot(WarpView(mixer: mixer, preloaded: mix) {}.environmentObject(job), "15-warp", width: 960, height: 520)
        try shot(ArrangeView(mixer: mixer, preloaded: mix, preselect: 1) {}.environmentObject(job), "16-rimonta", width: 960, height: 520)
    }

    /// Una canzone trascinata in attesa di «Separa».
    func testShotPending() throws {
        let job = SeparationJob.shared
        let (dir, stems) = try fakeStems()
        defer { try? FileManager.default.removeItem(at: dir); job.clearPending() }
        job.prepare([stems[0].url])
        try shot(ContentView().environmentObject(job), "13-canzone-pronta", width: 1180, height: 760)
    }
}
