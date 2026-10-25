import Foundation
import AppKit
import SwiftUI

// ════════════════════════════════════════════════════════════════════
//  Aggiornamenti con un doppio clic, come in OrbitLR.
//  «IsoLR x.y.z.audiolr» contiene l'app già pronta (cartella Prebuilt):
//  IsoLR controlla che sia integra e adatta a questo Mac, la prepara
//  accanto a quella attuale, si chiude, viene sostituita e si riapre.
//  Se qualcosa va storto, la versione attuale torna al suo posto.
// ════════════════════════════════════════════════════════════════════

final class Updater: ObservableObject, @unchecked Sendable {
    static let shared = Updater()
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    enum Stage: Int {
        case check, prepare, done
        var text: String {
            switch self {
            case .check: return "Controllo la nuova versione…"
            case .prepare: return "Preparo l'installazione…"
            case .done: return "Fatto! Riapro IsoLR…"
            }
        }
    }

    @Published var stage: Stage = .check
    @Published var error: String?
    @Published var busy = false
    @Published var fromVersion = ""
    @Published var toVersion = ""
    private var window: NSWindow?

    private let work = Paths.home.appendingPathComponent("Library/Caches/AudioLR-update")
    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }

    /// La cartella dell'aggiornamento dentro lo zip: quella con version.txt e l'app pronta.
    static func findPackage(in dir: URL) -> URL? {
        let fm = FileManager.default
        func ok(_ u: URL) -> Bool {
            fm.fileExists(atPath: u.appendingPathComponent("version.txt").path) &&
            fm.fileExists(atPath: u.appendingPathComponent("Prebuilt/AudioLR.app").path)
        }
        if ok(dir) { return dir }
        let subs = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return subs.first(where: ok)
    }

    /// Doppio clic su un .audiolr (o «Scarica e installa»). `confirmed`: l'utente ha già detto sì.
    @MainActor
    func open(_ file: URL, confirmed: Bool = false) {
        guard !busy else { window?.makeKeyAndOrderFront(nil); return }
        if SeparationJob.shared.isWorking {
            alert("Aspetta che finisca la separazione", "Poi apri di nuovo l'aggiornamento: ci vogliono pochi secondi.")
            return
        }
        busy = true
        let fm = FileManager.default
        try? fm.removeItem(at: work)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        guard sh("/usr/bin/ditto", ["-x", "-k", file.path, work.path]) == 0, let pkg = Self.findPackage(in: work) else {
            busy = false
            alert("Questo file non è un aggiornamento di IsoLR valido.", "")
            return
        }
        let version = (try? String(contentsOf: pkg.appendingPathComponent("version.txt"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "nuova"
        let news = (try? String(contentsOf: pkg.appendingPathComponent("NOVITA.txt"), encoding: .utf8)) ?? ""

        // Dal tasto o dal controllo automatico si installa solo una versione più nuova: mai un ritorno indietro
        if confirmed, version != "nuova", !News.newer(version, than: currentVersion) {
            busy = false
            alert("Hai già l'ultima versione", "Il file scaricato è la \(version), uguale o più vecchia della \(currentVersion) che hai.")
            return
        }
        if !confirmed {
            let a = NSAlert()
            a.messageText = "Installare IsoLR \(version)?"
            a.informativeText = "Versione attuale: \(currentVersion).\n\nIsoLR si chiude e si riapre da sola, già aggiornata, in pochi secondi."
            let items = News.items(since: currentVersion, in: news, maxVersions: 8)
            if !items.isEmpty { a.accessoryView = Self.scrollingText(items.map { "• " + $0 }.joined(separator: "\n\n")) }
            a.addButton(withTitle: "Installa")
            a.addButton(withTitle: "Annulla")
            NSApp.activate()
            guard a.runModal() == .alertFirstButtonReturn else { busy = false; return }
        }
        fromVersion = currentVersion
        toVersion = version
        error = nil
        stage = .check
        showWindow()
        let app = pkg.appendingPathComponent("Prebuilt/AudioLR.app")
        DispatchQueue.global(qos: .userInitiated).async { [self] in install(app, package: pkg) }
    }

    private func set(_ s: Stage) { DispatchQueue.main.async { self.stage = s } }

    private func install(_ app: URL, package: URL) {
        _ = sh("/usr/bin/xattr", ["-cr", package.path])
        let exe = app.appendingPathComponent("Contents/MacOS/AudioLR").path
        let arch = shOut("/usr/bin/uname", ["-m"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard shOut("/usr/bin/lipo", ["-archs", exe]).contains(arch) else { return fail("Questa versione non è fatta per questo Mac.") }
        guard sh("/usr/bin/codesign", ["--verify", "--deep", app.path]) == 0 else { return fail("L'aggiornamento è rovinato: scaricalo di nuovo.") }
        Thread.sleep(forTimeInterval: 0.6)

        set(.prepare)
        // L'app nuova si prepara accanto: quella attuale resta intatta finché non è tutto pronto
        let staged = work.appendingPathComponent("AudioLR-nuova.app")
        try? FileManager.default.removeItem(at: staged)
        guard sh("/bin/cp", ["-R", app.path, staged.path]) == 0 else { return fail("Non riesco a preparare l'installazione.") }
        _ = sh(Self.lsregister, ["-u", app.path])
        Thread.sleep(forTimeInterval: 0.6)

        set(.done)
        Thread.sleep(forTimeInterval: 1.2)
        let pid = ProcessInfo.processInfo.processIdentifier
        let target = Bundle.main.bundleURL.deletingLastPathComponent().path == "/Applications"
            ? Bundle.main.bundlePath : "/Applications/AudioLR.app"
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        # La versione attuale si mette da parte: se la nuova non si copia, torna al suo posto (mai senza app)
        OLD="$HOME/Library/Caches/AudioLR-precedente.app"
        rm -rf "$OLD"; mv \(q(target)) "$OLD" 2>/dev/null
        if mv \(q(staged.path)) \(q(target)); then
          rm -rf "$OLD"
        else
          rm -rf \(q(target)); mv "$OLD" \(q(target)); open \(q(target)); exit 1
        fi
        xattr -dr com.apple.quarantine \(q(target)) 2>/dev/null
        \(Self.lsregister) -f \(q(target)) >/dev/null 2>&1
        rm -rf \(q(work.path))
        open \(q(target))
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", script]
        try? p.run()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    // MARK: - Finestra

    @MainActor
    private func showWindow() {
        let size = NSSize(width: 420, height: 330)
        let host = NSHostingView(rootView: UpdateView(updater: self))
        host.frame.size = size
        let w = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.level = .floating
        w.contentView = host
        w.isReleasedWhenClosed = false
        w.center()
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    @MainActor
    func closeAfterError() {
        window?.orderOut(nil)
        window = nil
        error = nil
        busy = false
    }

    /// Un testo lungo in un riquadro che scorre: la finestra resta piccola e i pulsanti sempre visibili.
    static func scrollingText(_ text: String, width: CGFloat = 380, height: CGFloat = 200) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width - 4, height: height))
        tv.isEditable = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.font = .systemFont(ofSize: 12)
        tv.string = text
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        scroll.documentView = tv
        return scroll
    }

    // MARK: - Utilità

    private func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func fail(_ s: String) {
        DispatchQueue.main.async { self.error = s }
    }

    @MainActor
    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate()
        a.runModal()
    }

    private func shOut(_ exe: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }

    @discardableResult
    private func sh(_ exe: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

// MARK: - Controllo automatico

/// Il tasto in alto a destra: c'è una versione nuova da installare.
@MainActor
final class UpdateNotice: ObservableObject {
    static let shared = UpdateNotice()
    @Published var available: UpdateCheck.Release?
    @Published var downloading = false
    /// Il numero dell'ultimo controllo partito: le risposte dei controlli precedenti si ignorano.
    var generation = 0
}

enum UpdateCheck {
    struct Release: Equatable {
        let version: String
        let asset: URL
        let page: URL
    }

    /// Le ultime versioni pubblicate: si prende la più alta (non l'ultima creata, che può essere più vecchia).
    static let api = URL(string: "https://api.github.com/repos/LR-apps609/AudioLR/releases?per_page=30")!
    static let lastKey = "updateLastCheck"
    static let autoKey = "updateAutoCheck"
    static let skipKey = "updateSkipVersion"

    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// Dalla risposta di GitHub: versione («v0.2.0» → «0.2.0») e file .audiolr da scaricare.
    static func parse(_ data: Data) -> Release? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String,
              let assets = j["assets"] as? [[String: Any]],
              // Le versioni di prova e le bozze non si propongono a tutti
              j["prerelease"] as? Bool != true, j["draft"] as? Bool != true else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard let a = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".audiolr") == true }),
              let s = a["browser_download_url"] as? String, let u = URL(string: s) else { return nil }
        let page = (j["html_url"] as? String).flatMap(URL.init(string:)) ?? URL(string: "https://github.com/LR-apps609/AudioLR/releases")!
        return Release(version: version, asset: u, page: page)
    }

    /// Dall'elenco delle versioni di GitHub: la più alta che ha il file .audiolr.
    static func parseList(_ data: Data) -> Release? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return parse(data) }
        let releases = list.compactMap { (try? JSONSerialization.data(withJSONObject: $0)).flatMap(parse) }
        return releases.max { News.newer($1.version, than: $0.version) }
    }

    /// Controllo automatico: al massimo una volta ogni 20 ore, se non è stato spento.
    static func shouldAutoCheck(now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: autoKey) as? Bool == false { return false }
        let last = defaults.double(forKey: lastKey)
        return last == 0 || now.timeIntervalSince1970 - last > 20 * 3600
    }

    static func latest() async throws -> Release? {
        var req = URLRequest(url: api, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("AudioLR/\(current)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parseList(data)
    }

    /// All'avvio (dopo qualche secondo) e poi ogni 3 ore, in silenzio: se c'è una versione nuova compare
    /// il tasto «Aggiornamento disponibile» in alto a destra, senza finestre che interrompono.
    static func autoCheckSoon() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if autoEnabled { await quietCheck() }
            // Passi brevi misurati sull'orologio vero: dopo che il Mac ha dormito la notte il controllo arriva
            // al risveglio, non dopo altre 3 ore di Mac acceso. Spegnendo il controllo nelle Impostazioni si ferma subito
            while true {
                try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
                checkIfStale(after: 3 * 3600)
            }
        }
    }

    /// Il controllo automatico è acceso (di serie sì).
    static var autoEnabled: Bool { UserDefaults.standard.object(forKey: autoKey) as? Bool != false }

    /// Controllo silenzioso: aggiorna solo il tasto in alto a destra.
    @MainActor
    static func quietCheck() async {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastKey)
        // Se nel frattempo parte un controllo più recente, vale quello: una risposta lenta non riporta indietro il tasto
        UpdateNotice.shared.generation += 1
        let mine = UpdateNotice.shared.generation
        // Senza risposta (niente internet) il tasto resta com'era; con una risposta si aggiorna sempre,
        // così dopo ore di app aperta mostra l'ultima versione uscita e non una vecchia
        guard let found = try? await latest(), mine == UpdateNotice.shared.generation else { return }
        let skipped = UserDefaults.standard.string(forKey: skipKey)
        UpdateNotice.shared.available = worthShowing(found, current: current).flatMap { $0.version == skipped ? nil : $0 }
    }

    /// Quando si torna su IsoLR: se l'ultimo controllo è di più di 30 minuti fa, se ne fa uno nuovo.
    @MainActor
    static func checkIfStale(now: Date = Date(), after seconds: Double = 30 * 60) {
        guard autoEnabled else { return }
        let last = UserDefaults.standard.double(forKey: lastKey)
        guard now.timeIntervalSince1970 - last > seconds else { return }
        Task { await quietCheck() }
    }

    /// Il tasto compare solo per una versione davvero più nuova di quella installata.
    static func worthShowing(_ rel: Release?, current: String) -> Release? {
        guard let rel, News.newer(rel.version, than: current) else { return nil }
        return rel
    }

    /// Dal tasto «Aggiornamento disponibile»: scarica e installa (IsoLR si riapre da sola).
    @MainActor
    static func installNow(_ rel: Release) async {
        guard !Updater.shared.busy else { return }
        if SeparationJob.shared.isWorking {
            info("Prima finisce la separazione", "IsoLR si aggiorna appena la canzone in corso è pronta: premi di nuovo il tasto dopo.")
            return
        }
        UpdateNotice.shared.downloading = true
        defer { UpdateNotice.shared.downloading = false }
        // Si installa sempre l'ultima versione uscita, anche se il tasto è comparso ore fa per un'altra.
        // Se GitHub risponde, vale la sua risposta; solo senza internet si usa quella del tasto
        UpdateNotice.shared.generation += 1
        var target = rel
        if let found = try? await latest() {
            guard let fresh = worthShowing(found, current: current) else {
                UpdateNotice.shared.available = nil
                info("Hai già l'ultima versione", "IsoLR \(current) è la più recente.")
                return
            }
            target = fresh
            UpdateNotice.shared.available = fresh
        }
        await download(target)
    }

    @MainActor
    static func check(userInitiated: Bool) async {
        guard !Updater.shared.busy else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastKey)
        let rel: Release?
        do { rel = try await latest() } catch {
            if userInitiated { info("Non riesco a controllare gli aggiornamenti", "Controlla di essere connesso a internet e riprova.") }
            return
        }
        guard let rel else {
            if userInitiated { info("Non riesco a controllare gli aggiornamenti", "GitHub non ha risposto come previsto. Riprova più tardi.") }
            return
        }
        guard News.newer(rel.version, than: current) else {
            if userInitiated { info("Hai già l'ultima versione", "IsoLR \(current) è la più recente.") }
            return
        }
        UpdateNotice.shared.available = rel
        // Una versione saltata non si ripropone da sola (ma «Controlla aggiornamenti» sì)
        if !userInitiated, UserDefaults.standard.string(forKey: skipKey) == rel.version { return }
        // Durante una separazione non si interrompe: ci si riprova al prossimo avvio
        if !userInitiated, SeparationJob.shared.isWorking { UserDefaults.standard.set(0.0, forKey: lastKey); return }
        let a = NSAlert()
        a.messageText = "È disponibile IsoLR \(rel.version)"
        a.informativeText = "Hai la \(current). La scarico e la installo? Ci vogliono pochi secondi e IsoLR si riapre da sola."
        a.addButton(withTitle: "Scarica e installa")
        a.addButton(withTitle: "Più tardi")
        a.addButton(withTitle: "Salta questa versione")
        NSApp.activate()
        switch a.runModal() {
        case .alertFirstButtonReturn: await download(rel)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(rel.version, forKey: skipKey)
            UpdateNotice.shared.available = nil
        default: break
        }
    }

    @MainActor
    private static func download(_ rel: Release) async {
        let dir = Paths.home.appendingPathComponent("Library/Caches/AudioLR-download")
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("AudioLR \(rel.version).audiolr")
        do {
            let (tmp, resp) = try await URLSession.shared.download(from: rel.asset)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            try fm.moveItem(at: tmp, to: dest)
        } catch {
            let a = NSAlert()
            a.messageText = "Il download non è riuscito"
            a.informativeText = "Riprova, oppure scarica l'aggiornamento dalla pagina di GitHub e aprilo con un doppio clic."
            a.addButton(withTitle: "Apri la pagina")
            a.addButton(withTitle: "Chiudi")
            if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(rel.page) }
            return
        }
        Updater.shared.open(dest, confirmed: true)
    }

    @MainActor
    private static func info(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "OK")
        NSApp.activate()
        a.runModal()
    }
}

// MARK: - Novità

enum News {
    static let text: String = {
        guard let url = Bundle.main.url(forResource: "NOVITA", withExtension: "txt"),
              let t = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return t
    }()

    /// Solo le novità arrivate dopo la versione che avevi (al massimo `maxVersions` versioni).
    static func items(since from: String, in text: String = text, maxVersions: Int = 3) -> [String] {
        var out: [String] = []
        var versions = 0
        var take = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let v = version(inHeader: line) {
                take = versions < maxVersions && (from.isEmpty ? versions == 0 : newer(v, than: from))
                if take { versions += 1 }
                if !take && versions > 0 { break }       // le sezioni sono in ordine, dalla più nuova
                continue
            }
            if take, line.hasPrefix("•") { out.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)) }
        }
        return out
    }

    /// «Novità della 0.2.0 «Studio»:» → «0.2.0»
    static func version(inHeader line: String) -> String? {
        guard line.hasPrefix("Novità della ") else { return nil }
        let v = line.dropFirst("Novità della ".count).prefix { $0.isNumber || $0 == "." }
        return v.isEmpty ? nil : String(v)
    }

    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}

// MARK: - Schedina dell'aggiornamento

struct UpdateView: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(spacing: 16) {
            LogoMark(size: 92, animated: updater.error == nil)
                .padding(.top, 30)
            VStack(spacing: 4) {
                Text(updater.error == nil ? "Aggiorno IsoLR" : "Aggiornamento non riuscito")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Text("\(updater.fromVersion)  →  \(updater.toVersion)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Theme.brass)
            }
            if let e = updater.error {
                Text(e).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Chiudi") { updater.closeAfterError() }.keyboardShortcut(.defaultAction)
            } else {
                VStack(spacing: 8) {
                    ProgressView(value: Double(updater.stage.rawValue + 1) / 3).tint(Theme.accent)
                    Text(updater.stage.text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 40)
                .animation(.easeInOut(duration: 0.4), value: updater.stage)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 420, height: 330)
        .background(StudioBackground())
        .foregroundStyle(Theme.ink)
    }
}
