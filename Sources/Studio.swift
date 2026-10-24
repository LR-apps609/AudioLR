import SwiftUI
import AppKit

// ════════════════════════════════════════════════════════════════════
//  Elementi grafici a tema musica: il marchio (le barre dell'icona),
//  lo sfondo da studio, le forme d'onda con la testina di lettura.
// ════════════════════════════════════════════════════════════════════

/// Come disegnare onde, barre e marchio: con Canvas (di serie, veloce) oppure con forme semplici.
/// Le forme servono alle schermate di prova: sulle macchine virtuali di GitHub il disegno con Metal si chiude.
enum Drawing {
    static var flat = false
}

/// Il marchio di AudioLR, come l'icona: sette barre arrotondate a forma d'onda, dal corallo al verde acqua,
/// su un riquadro prugna scuro. Animato, le barre «suonano» piano.
struct LogoMark: View {
    var size: CGFloat = 32
    var animated = false
    var tile = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Altezza (frazione del riquadro) e sfumatura dall'alto al basso di ogni barra, come in Tools/make_icon.py.
    static let bars: [(height: Double, colors: [UInt32])] = [
        (0.14, [0xEF9882, 0xE88874]),
        (0.29, [0xEDA489, 0xE89174]),
        (0.47, [0xF1CA93, 0xDEA484]),
        (0.65, [0xE8D4F6, 0xC2ABEB, 0x86BFC6]),
        (0.47, [0xA8C4EE, 0x80ADE4, 0x71B4BA]),
        (0.29, [0x6FA2E0, 0x65AFAE]),
        (0.14, [0x77C3AB, 0x6CB8A0]),
    ]
    static let spacing = 0.1147, width = 0.067

    var body: some View {
        if Drawing.flat { flatBody } else { canvasBody }
    }

    private var background: LinearGradient {
        LinearGradient(colors: [Color(hex: 0x3E3550), Color(hex: 0x252134), Color(hex: 0x0E0E16)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Lo stesso marchio con forme semplici, fermo (per le schermate di prova).
    private var flatBody: some View {
        let side = size, scale = tile ? 1.0 : 1.25
        return ZStack {
            if tile {
                RoundedRectangle(cornerRadius: side * 0.225, style: .continuous).fill(background)
            }
            HStack(spacing: side * (Self.spacing - Self.width) * scale) {
                ForEach(Self.bars.indices, id: \.self) { i in
                    Capsule()
                        .fill(LinearGradient(colors: Self.bars[i].colors.map { Color(hex: $0) }, startPoint: .top, endPoint: .bottom))
                        .frame(width: side * Self.width * scale, height: side * Self.bars[i].height * scale)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var canvasBody: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animated || reduceMotion)) { tl in
            let t = animated && !reduceMotion ? tl.date.timeIntervalSinceReferenceDate : 0
            Canvas { ctx, sz in
                let side = min(sz.width, sz.height)
                if tile {
                    let r = CGRect(x: 0, y: 0, width: side, height: side)
                    let path = Path(roundedRect: r, cornerRadius: side * 0.225, style: .continuous)
                    ctx.fill(path, with: .linearGradient(Gradient(colors: [Color(hex: 0x3E3550), Color(hex: 0x252134), Color(hex: 0x0E0E16)]),
                                                         startPoint: .zero, endPoint: CGPoint(x: side, y: side)))
                    ctx.stroke(path, with: .color(.white.opacity(0.12)), lineWidth: max(0.5, side * 0.006))
                }
                // Senza riquadro le barre occupano un po' più spazio
                let scale = tile ? 1.0 : 1.25
                let n = Self.bars.count
                let w = side * Self.width * scale
                for (i, bar) in Self.bars.enumerated() {
                    let wobble = animated ? 0.80 + 0.20 * sin(t * 3.1 + Double(i) * 0.9) : 1
                    let h = side * bar.height * scale * wobble
                    let cx = side / 2 + (Double(i) - Double(n - 1) / 2) * Self.spacing * side * scale
                    let rect = CGRect(x: cx - w / 2, y: side / 2 - h / 2, width: w, height: h)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: w / 2),
                             with: .linearGradient(Gradient(colors: bar.colors.map { Color(hex: $0) }),
                                                   startPoint: CGPoint(x: cx, y: rect.minY), endPoint: CGPoint(x: cx, y: rect.maxY)))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Sfondo della finestra: carta crema di giorno, studio buio di notte, con un alone caldo in alto.
struct StudioBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.background, Theme.backgroundDeep], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.brass.opacity(0.14), .clear], center: UnitPoint(x: 0.5, y: 0.0),
                           startRadius: 10, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}

/// Riduce un audio a `count` picchi (0…1) per disegnarne la forma d'onda.
enum Peaks {
    static func of(_ channels: [[Float]], count: Int = 480) -> [Float] {
        guard let n = channels.first?.count, n > 0, count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        let per = max(1, n / count)
        for b in 0..<count {
            let lo = b * n / count, hi = min(n, max(lo + 1, (b + 1) * n / count))
            var m: Float = 0
            // Un campione ogni tanto basta per il disegno: veloce anche su canzoni lunghe
            let step = max(1, per / 256)
            var i = lo
            while i < hi {
                var v: Float = 0
                for ch in channels { v += ch[i] }
                m = max(m, abs(v / Float(channels.count)))
                i += step
            }
            out[b] = min(1, m)
        }
        return out
    }
}

/// Forma d'onda a barre simmetriche. `progress` colora la parte già fatta (o già ascoltata).
struct WaveformView: View {
    let peaks: [Float]
    var color: Color
    var dim: Color = Theme.ink.opacity(0.16)
    /// 0…1: fin dove colorare. nil: tutta colorata.
    var progress: Double? = nil
    /// Testina di lettura (0…1), se sta suonando.
    var playhead: Double? = nil
    var barWidth: CGFloat = 2
    var spacing: CGFloat = 1

    var body: some View {
        if Drawing.flat { flatBody } else { canvasBody }
    }

    private var flatBody: some View {
        GeometryReader { g in
            let slots = max(1, min(240, Int(g.size.width / (barWidth + spacing))))
            let w = g.size.width / CGFloat(slots)
            ZStack(alignment: .leading) {
                HStack(alignment: .center, spacing: max(0, w - barWidth)) {
                    ForEach(0..<slots, id: \.self) { s in
                        let a = s * max(peaks.count, 1) / slots, b = max(a + 1, (s + 1) * peaks.count / slots)
                        let p = peaks.isEmpty ? 0 : (a..<min(b, peaks.count)).map { peaks[$0] }.max() ?? 0
                        let done = progress.map { Double(s) / Double(slots) < $0 } ?? true
                        Capsule().fill(done ? color : dim)
                            .frame(width: barWidth, height: max(1.5, CGFloat(Double(p).squareRoot()) * g.size.height * 0.92))
                    }
                }
                .frame(height: g.size.height)
                if let ph = playhead {
                    Rectangle().fill(Theme.ink.opacity(0.85)).frame(width: 2).offset(x: g.size.width * ph - 1)
                }
            }
        }
    }

    private var canvasBody: some View {
        Canvas { ctx, size in
            guard !peaks.isEmpty else { return }
            let slots = max(1, Int(size.width / (barWidth + spacing)))
            let mid = size.height / 2
            for s in 0..<slots {
                let a = s * peaks.count / slots, b = max(a + 1, (s + 1) * peaks.count / slots)
                var p: Float = 0
                for i in a..<min(b, peaks.count) { p = max(p, peaks[i]) }
                // Radice: anche le parti piano si vedono
                let h = max(1.5, CGFloat(Double(p).squareRoot()) * size.height * 0.92)
                let x = CGFloat(s) * (barWidth + spacing)
                let r = CGRect(x: x, y: mid - h / 2, width: barWidth, height: h)
                let done = progress.map { Double(s) / Double(slots) < $0 } ?? true
                ctx.fill(Path(roundedRect: r, cornerRadius: barWidth / 2), with: .color(done ? color : dim))
            }
            if let ph = playhead {
                let x = size.width * ph
                ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(Theme.ink.opacity(0.85)))
            }
        }
    }
}

/// Barre che si muovono da sole: la musica «in attesa» nella schermata iniziale.
struct IdleBars: View {
    var count = 28
    var height: CGFloat = 70
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if Drawing.flat { flatBody } else { canvasBody }
    }

    private var flatBody: some View {
        GeometryReader { g in
            let gap = (g.size.width - CGFloat(count) * 5) / CGFloat(max(count - 1, 1))
            HStack(spacing: gap) {
                ForEach(0..<count, id: \.self) { i in
                    let env = sin(Double(i) / Double(count - 1) * .pi)
                    Capsule().fill(Theme.color(Theme.stemOrder[i * 4 / count]))
                        .frame(width: 5, height: max(6, g.size.height * CGFloat(0.25 + 0.6 * env)))
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private var canvasBody: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { tl in
            let t = reduceMotion ? 0 : tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let bw: CGFloat = 5, gap = (size.width - CGFloat(count) * 5) / CGFloat(max(count - 1, 1))
                for i in 0..<count {
                    let x = CGFloat(i) * (bw + gap)
                    let env = sin(Double(i) / Double(count - 1) * .pi)                 // più alte al centro
                    let beat = 0.55 + 0.45 * sin(t * 2.4 + Double(i) * 0.55) * sin(t * 1.3 + Double(i) * 0.21)
                    let h = max(6, size.height * CGFloat(0.25 + 0.75 * env * beat))
                    let stem = Theme.stemOrder[i * 4 / count]
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: (size.height - h) / 2, width: bw, height: h), cornerRadius: bw / 2),
                             with: .color(Theme.color(stem)))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Riquadro colorato con il simbolo dello strumento.
struct StemBadge: View {
    let key: String
    let symbol: String
    var size: CGFloat = 36
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Theme.color(key).gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.44, weight: .semibold)).foregroundStyle(.white))
            .shadow(color: Theme.color(key).opacity(0.35), radius: 5, y: 2)
    }
}

/// Piccola etichetta arrotondata (es. «Sul tuo Mac»).
struct Chip: View {
    let text: String
    var symbol: String? = nil
    var tint: Color = Theme.brass
    var body: some View {
        HStack(spacing: 5) {
            if let s = symbol { Image(systemName: s).font(.system(size: 10, weight: .bold)) }
            Text(text).font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        // Un'etichetta non si spezza mai a metà parola: se non c'è posto, va a capo intera (FlowLayout)
        .fixedSize()
        .foregroundStyle(tint)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.12)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 1))
    }
}

/// Mette gli elementi uno dopo l'altro e va a capo quando non c'è più posto, centrando ogni riga.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8
    /// Righe centrate (di serie) o allineate a sinistra.
    var centered = true

    private func lines(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, s) in subviews.enumerated() {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append((i, size))
            x += size.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = lines(subviews, width: width)
        let widest = rows.map { r in r.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max(0, r.count - 1)) }.max() ?? 0
        let height = rows.map { r in r.map(\.size.height).max() ?? 0 }.reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: min(widest, width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in lines(subviews, width: bounds.width) {
            let rowWidth = row.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max(0, row.count - 1))
            let rowHeight = row.map(\.size.height).max() ?? 0
            var x = bounds.minX + (centered ? (bounds.width - rowWidth) / 2 : 0)
            for item in row {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (rowHeight - item.size.height) / 2),
                                           proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += rowHeight + lineSpacing
        }
    }
}

/// «3:42»
func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let s = Int(seconds.rounded())
    return "\(s / 60):" + String(format: "%02d", s % 60)
}
