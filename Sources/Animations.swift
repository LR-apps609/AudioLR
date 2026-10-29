import SwiftUI

// ════════════════════════════════════════════════════════════════════
//  Le tre animazioni dello «Studio di notte» (uguali su Windows, in
//  windows/ui/core/anim.js e ui.css):
//  • il logo che pulsa sui battiti veri della canzone mentre suona;
//  • le bobine di un registratore mentre un modello si scarica o si prepara;
//  • la festa di fine separazione: spunta d'oro, anello, coriandoli.
//  Leggere (TimelineView + Canvas), ferme con «riduci movimento», e con
//  forme semplici sui Mac virtuali (Drawing.flat).
// ════════════════════════════════════════════════════════════════════

/// Quanto «batte» la musica adesso: 1 sul battito, poi scende a 0 prima del successivo.
enum BeatPulse {
    /// Durata della discesa dopo ogni battito (secondi di canzone).
    static let decay = 0.22

    /// `t`: secondi dall'inizio della canzone. Con i battiti veri si usa il più vicino prima di `t`;
    /// senza, una griglia regolare dal BPM. Né battiti né BPM: 0 (fermo).
    static func pulse(at t: Double, beats: [Double], bpm: Double?) -> Double {
        let since: Double
        if !beats.isEmpty {
            // Ricerca binaria dell'ultimo battito non dopo t
            var lo = 0, hi = beats.count - 1
            guard t >= beats[0] else { return 0 }
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if beats[mid] <= t { lo = mid } else { hi = mid - 1 }
            }
            since = t - beats[lo]
            // Dopo l'ultimo battito della canzone (oltre un battito e mezzo) si ferma
            if lo == beats.count - 1, beats.count > 1, since > 1.5 * (beats[lo] - beats[lo - 1]) { return 0 }
        } else if let b = bpm, b > 20 {
            let period = 60 / b
            since = t.truncatingRemainder(dividingBy: period)
        } else {
            return 0
        }
        guard since >= 0, since < decay else { return 0 }
        // Sale di colpo e scende morbida
        let x = since / decay
        return (1 - x) * (1 - x)
    }
}

/// Il logo dell'intestazione: pulsa sui battiti quando la canzone suona, con un alone d'oro che si allarga.
struct BeatLogo: View {
    var size: CGFloat = 38
    var busy: Bool
    @ObservedObject var mixer: MixPlayer
    var bpm: Double?
    /// Per le schermate di prova: il colpo fermo a questo valore.
    var frozen: Double? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let playing = mixer.isPlaying && !reduceMotion
        if frozen == nil && !playing {
            LogoMark(size: size, animated: busy)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: frozen != nil)) { _ in
                let p: Double = frozen ?? BeatPulse.pulse(at: mixer.position, beats: mixer.structure?.beats ?? [], bpm: bpm)
                pulsing(p)
            }
        }
    }
}

extension BeatLogo {
    fileprivate func pulsing(_ p: Double) -> some View {
        let halo = CGFloat(1.6 - 0.6 * p), grow = CGFloat(1 + 0.09 * p), glow = CGFloat(10 * p)
        return ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .strokeBorder(Theme.brass.opacity(0.75 * p), lineWidth: 2)
                .frame(width: size, height: size)
                .scaleEffect(halo)
                .opacity(p > 0.02 ? 1 : 0)
            LogoMark(size: size, animated: true)
                .scaleEffect(grow)
                .shadow(color: Theme.brass.opacity(0.55 * p), radius: glow)
        }
        .frame(width: size, height: size)
    }
}

/// Le bobine di un registratore che girano, con il nastro colorato che scorre: «sto preparando il modello».
/// `progress` (0…1) se si sa quanto manca (scaricamento), altrimenti una barra d'oro che va e viene.
struct TapeReels: View {
    var progress: Double?
    var label: String = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 12) {
            if Drawing.flat { flatDeck } else { liveDeck }
            bar.frame(width: 220, height: 6)
            if !label.isEmpty {
                Text(label).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.isEmpty ? "Preparo il modello" : label)
    }

    private var bar: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || progress != nil || Drawing.flat)) { tl in
            GeometryReader { g in
                let t = tl.date.timeIntervalSinceReferenceDate
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.ink.opacity(0.10))
                    if let p = progress {
                        let w: CGFloat = g.size.width * CGFloat(max(0.02, min(1, p)))
                        Capsule().fill(Theme.brass).frame(width: w).goldGlow(radius: 6)
                    } else {
                        // Indeterminata: un tratto d'oro che va e viene
                        let k: Double = reduceMotion || Drawing.flat ? 0.3 : (sin(t * 1.6) + 1) / 2 * 0.7
                        let w: CGFloat = g.size.width * 0.3, x: CGFloat = g.size.width * CGFloat(k)
                        Capsule().fill(Theme.brass).frame(width: w).offset(x: x).goldGlow(radius: 6)
                    }
                }
            }
        }
    }

    /// Fermo, con forme semplici (Mac virtuali senza Canvas).
    private var flatDeck: some View {
        HStack(spacing: 40) {
            ForEach(0..<2, id: \.self) { _ in
                ZStack {
                    Circle().strokeBorder(Theme.brass, lineWidth: 3).frame(width: 56, height: 56)
                    Circle().fill(Theme.brass).frame(width: 16, height: 16)
                }
            }
        }
        .frame(width: 220, height: 96)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.well))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
    }

    private var liveDeck: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { tl in
            let t = reduceMotion ? 0 : tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let deck = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
                let deckPath = Path(roundedRect: deck, cornerRadius: 12)
                ctx.fill(deckPath, with: .color(Theme.well))
                ctx.stroke(deckPath, with: .color(Theme.stroke), lineWidth: 1)
                let r: CGFloat = 26, cy = size.height / 2 - 4
                let centers = [CGPoint(x: size.width * 0.28, y: cy), CGPoint(x: size.width * 0.72, y: cy)]
                // Il nastro, sotto, che scorre nei colori delle tracce
                let tapeY = cy + r + 1
                let colors: [Color] = ["vocals", "drums", "bass", "guitar", "piano", "other"].map(Theme.color)
                let dash: CGFloat = 8, offset = CGFloat((t * 40).truncatingRemainder(dividingBy: Double(dash) * 6))
                var x = centers[0].x - offset
                var k = 0
                while x < centers[1].x {
                    let x0 = max(centers[0].x, x), x1 = min(centers[1].x, x + dash)
                    if x1 > x0 {
                        ctx.fill(Path(CGRect(x: x0, y: tapeY - 1.5, width: x1 - x0, height: 3)), with: .color(colors[k % colors.count]))
                    }
                    x += dash; k += 1
                }
                for c in centers {
                    let angle = Angle.radians(t * 2.6)
                    var reel = ctx
                    reel.translateBy(x: c.x, y: c.y)
                    reel.rotate(by: angle)
                    var glow = reel
                    glow.addFilter(.shadow(color: Theme.brass.opacity(0.5), radius: 6))
                    glow.stroke(Path(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)), with: .color(Theme.brass), lineWidth: 3)
                    reel.fill(Path(ellipseIn: CGRect(x: -7, y: -7, width: 14, height: 14)), with: .color(Theme.brass))
                    for s in 0..<3 {
                        var spoke = Path()
                        let a = Double(s) * 2 * .pi / 3
                        let ca = CGFloat(cos(a)), sa = CGFloat(sin(a))
                        spoke.move(to: CGPoint(x: ca * 9, y: sa * 9))
                        spoke.addLine(to: CGPoint(x: ca * (r - 5), y: sa * (r - 5)))
                        reel.stroke(spoke, with: .color(Theme.brass), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    }
                }
            }
            .frame(width: 220, height: 96)
        }
    }
}

/// La festa di fine separazione: dura `duration` secondi, una volta sola per canzone.
enum Celebration {
    static let duration = 2.5

    /// I coriandoli: direzione, distanza e colore (indice nei colori delle tracce), sempre uguali.
    static func confetti(count: Int = 24) -> [(angle: Double, distance: Double, color: Int, spin: Double)] {
        var out: [(angle: Double, distance: Double, color: Int, spin: Double)] = []
        for i in 0..<count {
            let row = Double(i % 3)
            let angle: Double = Double(i) / Double(count) * 2 * Double.pi + row * 0.13
            let distance: Double = 110 + row * 32
            out.append((angle: angle, distance: distance, color: i % 6, spin: Double((i * 37) % 360)))
        }
        return out
    }

    /// Avanzamento (0…1) a `elapsed` secondi; nil quando è finita.
    static func progress(elapsed: Double) -> Double? {
        elapsed >= 0 && elapsed < duration ? elapsed / duration : nil
    }

    /// Facilità d'uscita: veloce all'inizio, morbida alla fine.
    static func easeOut(_ x: Double) -> Double { 1 - pow(1 - min(max(x, 0), 1), 3) }
}

/// Sopra il riquadro principale: la festa quando una separazione è appena finita (non riaprendo dalla libreria).
struct CelebrationOverlay: ViewModifier {
    @ObservedObject var job: SeparationJob
    @State private var celebrating = false

    func body(content: Content) -> some View {
        content
            .overlay { overlay }
            .onChange(of: job.finishedAt) { _, new in
                guard new != nil else { celebrating = false; return }
                celebrating = true
                DispatchQueue.main.asyncAfter(deadline: .now() + Celebration.duration) { celebrating = false }
            }
    }

    @ViewBuilder private var overlay: some View {
        if job.phase == .done, let started = job.finishedAt, celebrating || job.celebrationFrozen != nil {
            let tracks = job.stems.filter { $0.key != "instrumental" }.count
            CelebrationView(tracks: tracks, started: started, frozen: job.celebrationFrozen)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .transition(.opacity)
        }
    }
}

/// Spunta d'oro che si disegna, anello che si allarga, coriandoli nei colori delle tracce, «N tracce pronte».
struct CelebrationView: View {
    let tracks: Int
    let started: Date
    /// Per le schermate di prova: fermo a questo punto (0…1).
    var frozen: Double? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: frozen != nil)) { tl in
            let p = frozen ?? Celebration.progress(elapsed: tl.date.timeIntervalSince(started)) ?? 1
            scene(p)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Separazione finita: \(tracks) tracce pronte")
    }

    private func scene(_ p: Double) -> some View {
        let rise: CGFloat = 78 + 14 * CGFloat(1 - Celebration.easeOut((p - 0.35) / 0.25))
        let shown: Double = min(1, max(0, (p - 0.35) / 0.2)) * fadeOut(p)
        let dim: Double = 0.78 * fadeOut(p)
        return ZStack {
            if !reduceMotion { confetti(p) }
            ring(p)
            check(p)
            Text("\(tracks) tracce pronte")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.ink)
                .offset(y: rise)
                .opacity(shown)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.opacity(dim))
    }

    private func fadeOut(_ p: Double) -> Double { p < 0.85 ? 1 : max(0, (1 - p) / 0.15) }

    private func confetti(_ p: Double) -> some View {
        let colors: [Color] = ["vocals", "drums", "bass", "guitar", "piano", "other"].map(Theme.color)
        let e = Celebration.easeOut(p / 0.8)
        let fade: Double = 1 - min(1, p / 0.9)
        let pieces = Celebration.confetti()
        return ZStack {
            ForEach(pieces.indices, id: \.self) { i in
                piece(pieces[i], color: colors[pieces[i].color], p: p, e: e).opacity(fade)
            }
        }
    }

    private func piece(_ c: (angle: Double, distance: Double, color: Int, spin: Double), color: Color, p: Double, e: Double) -> some View {
        let dx = CGFloat(cos(c.angle) * c.distance * e)
        let dy = CGFloat(sin(c.angle) * c.distance * e + 40 * p * p)
        let turn: Double = c.spin + 360 * p
        return RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 9, height: 9)
            .rotationEffect(.degrees(turn))
            .offset(x: dx, y: dy)
    }

    private func ring(_ p: Double) -> some View {
        let x: Double = min(1, max(0, (p - 0.1) / 0.7))
        let scale = CGFloat(0.6 + Celebration.easeOut(x))
        let alpha: Double = x > 0 ? 1 - x : 0
        return Circle().strokeBorder(Theme.brass, lineWidth: 2)
            .frame(width: 110, height: 110)
            .scaleEffect(scale)
            .opacity(alpha)
    }

    private func check(_ p: Double) -> some View {
        let draw = CGFloat(Celebration.easeOut(min(1, p / 0.35)))
        let grow = CGFloat(0.7 + 0.3 * Celebration.easeOut(min(1, p / 0.2)))
        return ZStack {
            Circle().fill(Theme.brass).frame(width: 84, height: 84).goldGlow(radius: 16)
            CheckShape().trim(from: 0, to: draw)
                .stroke(Theme.background, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                .frame(width: 84, height: 84)
        }
        .scaleEffect(grow)
        .opacity(fadeOut(p))
    }
}

/// La spunta, nel riquadro 84×84 come nel disegno di riferimento.
private struct CheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let s = r.width / 84
        p.move(to: CGPoint(x: r.minX + 26 * s, y: r.minY + 43 * s))
        p.addLine(to: CGPoint(x: r.minX + 37 * s, y: r.minY + 54 * s))
        p.addLine(to: CGPoint(x: r.minX + 58 * s, y: r.minY + 31 * s))
        return p
    }
}
