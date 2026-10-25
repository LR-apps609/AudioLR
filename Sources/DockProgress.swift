import AppKit
import Combine

/// Nel Dock: una barra sotto l'icona mentre AudioLR separa, e alla fine la finestra torna in primo piano.
@MainActor
final class DockProgress {
    static let shared = DockProgress()
    private var bag: Set<AnyCancellable> = []
    private let view = DockProgressView()
    private var shown: Int?
    private var wasWorking = false

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
        // Finita (anche l'ultima della coda): AudioLR torna davanti, con la finestra dei risultati
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
