import AppKit
import Combine
import UserNotifications

/// Nel Dock: una barra sotto l'icona mentre IsoLR separa, e alla fine la finestra torna in primo piano.
@MainActor
final class DockProgress {
    static let shared = DockProgress()
    private var bag: Set<AnyCancellable> = []
    private let view = DockProgressView()
    private var shown: Int?
    private var wasWorking = false
    /// Album di notte: finché si separa il Mac non va in stop da solo
    private var activity: NSObjectProtocol?
    /// Canzoni finite in questo giro di lavoro (una o una coda intera) e quando è cominciato
    private var finished = 0
    private var batchStart: Date?

    func start() {
        let job = SeparationJob.shared
        job.$phase
            // Senza ritardo: il valore arriva prima che parta la canzone successiva della coda,
            // così «la coda è vuota» è vero solo alla fine dell'ultima
            .sink { [weak self] phase in self?.update(phase, queueEmpty: job.queue.isEmpty) }
            .store(in: &bag)
    }

    /// 0…1 per la barra, nil quando non c'è un lavoro in corso.
    nonisolated static func fraction(_ phase: SeparationJob.Phase) -> Double? {
        switch phase {
        case .downloading(let p): return 0.02 + 0.08 * min(max(p, 0), 1)
        // Dopo lo scaricamento la barra non torna indietro
        case .reading, .tuning: return 0.10
        case .separating(let p): return 0.1 + 0.86 * min(max(p, 0), 1)
        case .saving: return 0.97
        case .idle, .done, .failed: return nil
        }
    }

    private func update(_ phase: SeparationJob.Phase, queueEmpty: Bool) {
        let tile = NSApp.dockTile
        if let f = Self.fraction(phase) {
            wasWorking = true
            beginBatch()
            let pct = Int(f * 100)
            guard pct != shown else { return }
            shown = pct
            view.fraction = f
            if tile.contentView !== view { tile.contentView = view }
            tile.display()
            return
        }
        if shown != nil {
            shown = nil
            tile.contentView = nil
            tile.display()
        }
        if wasWorking, phase == .done { finished += 1 }
        // Fine del giro di lavoro: finita l'ultima della coda, oppure annullata o non riuscita senza altro in coda
        var failed = false
        if case .failed = phase { failed = true }
        if wasWorking, queueEmpty, phase == .done || phase == .idle || failed {
            endBatch(cancelled: phase == .idle)
        }
        // Finita (anche l'ultima della coda): IsoLR torna davanti, con la finestra dei risultati
        if wasWorking, phase == .done, queueEmpty {
            NSApp.activate()
            if let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
                w.orderFrontRegardless()
                w.makeKeyAndOrderFront(nil)
            }
            // Se macOS non lascia passare davanti (stai scrivendo in un'altra app), l'icona saltella una volta
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        }
        if phase != .done || queueEmpty { wasWorking = false }
    }

    // MARK: Album di notte

    private func beginBatch() {
        guard activity == nil else { return }
        finished = 0
        batchStart = Date()
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "IsoLR sta separando le canzoni")
        // Il permesso per l'avviso si chiede la prima volta che serve
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func endBatch(cancelled: Bool) {
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
        activity = nil
        let count = finished, took = batchStart.map { Date().timeIntervalSince($0) } ?? 0
        finished = 0
        batchStart = nil
        guard !cancelled, count > 0 else { return }
        // L'avviso arriva anche con l'app davanti solo per una coda: per una canzone sola basta la finestra
        if !NSApp.isActive || count > 1 {
            let c = UNMutableNotificationContent()
            c.title = count == 1 ? "IsoLR ha finito" : "IsoLR ha finito le \(count) canzoni"
            c.body = (count == 1 ? "La canzone è separata" : "Tutte separate") + " in " + Self.duration(took) + "."
            c.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
        // A fine coda, se scelto: il Mac va in stop dopo un minuto (se nel frattempo non riparte un lavoro)
        if Prefs.sleepAfterBatch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                guard !SeparationJob.shared.isWorking, Prefs.sleepAfterBatch else { return }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
                p.arguments = ["sleepnow"]
                try? p.run()
            }
        }
    }

    /// «1 h 12 min», «8 min», «40 s».
    nonisolated static func duration(_ s: Double) -> String {
        let m = Int((s / 60).rounded(.down))
        if m >= 60 { return "\(m / 60) h \(m % 60) min" }
        if m >= 1 { return "\(m) min" }
        return "\(max(1, Int(s.rounded()))) s"
    }
}

/// L'icona dell'app con sotto una barra arrotondata che si riempie.
final class DockProgressView: NSView {
    var fraction: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let h = bounds.height * 0.11
        let track = NSRect(x: bounds.width * 0.12, y: bounds.height * 0.09, width: bounds.width * 0.76, height: h)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: track, xRadius: h / 2, yRadius: h / 2).fill()
        let inner = track.insetBy(dx: h * 0.18, dy: h * 0.18)
        let fill = NSRect(x: inner.minX, y: inner.minY, width: max(inner.height, inner.width * fraction), height: inner.height)
        NSColor(calibratedRed: 0.84, green: 0.67, blue: 0.38, alpha: 1).setFill()
        NSBezierPath(roundedRect: fill, xRadius: inner.height / 2, yRadius: inner.height / 2).fill()
    }
}
