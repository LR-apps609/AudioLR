import SwiftUI
import AppKit

// ════════════════════════════════════════════════════════════════════
//  Elementi grafici a tema musica: il marchio (le barre dell'icona),
//  lo sfondo da studio, le forme d'onda con la testina di lettura.
// ════════════════════════════════════════════════════════════════════

/// Il marchio di AudioLR, come l'icona: barre di un'onda divise nei colori dei quattro strumenti.
/// Animato, le barre «suonano» piano.
struct LogoMark: View {
    var size: CGFloat = 32
    var animated = false
    var tile = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let heights: [Double] = [0.16, 0.30, 0.48, 0.66, 0.84, 0.96, 1.0, 0.90, 0.74, 0.56, 0.40, 0.26, 0.14]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animated || reduceMotion)) { tl in
            let t = animated && !reduceMotion ? tl.date.timeIntervalSinceReferenceDate : 0
            Canvas { ctx, sz in
                let side = min(sz.width, sz.height)
                if tile {
                    let r = CGRect(x: 0, y: 0, width: side, height: side)
                    let path = Path(roundedRect: r, cornerRadius: side * 0.225, style: .continuous)
                    ctx.fill(path, with: .linearGradient(Gradient(colors: [Color(hex: 0x2E2540), Color(hex: 0x120F18)]),
                                                         startPoint: .zero, endPoint: CGPoint(x: 0, y: side)))
                    ctx.stroke(path, with: .color(Color(hex: 0xD6AA62).opacity(0.35)), lineWidth: max(0.5, side * 0.006))
                }
                let inner = tile ? side * 0.80 : side
                let n = Self.heights.count
                let bw = inner * 0.048, gap = inner * 0.029
                let total = Double(n) * bw + Double(n - 1) * gap
                let x0 = (side - total) / 2
                let hmax = inner * (tile ? 0.80 : 0.95)
                // Sempre i colori «di notte»: il marchio ha il suo fondo scuro
                let colors: [Color] = [0xE5917A, 0xE6B45C, 0xB497D0, 0x76C3B9].map { Color(hex: $0) }
                for (i, h0) in Self.heights.enumerated() {
                    let wobble = animated ? 0.82 + 0.18 * sin(t * 3.1 + Double(i) * 0.9) : 1
                    let h = hmax * h0 * wobble
                    let x = x0 + Double(i) * (bw + gap)
                    let top = side / 2 - h / 2
                    let cap = Path(roundedRect: CGRect(x: x, y: top, width: bw, height: h), cornerRadius: bw / 2)
                    ctx.drawLayer { layer in
                        layer.clip(to: cap)
                        for (k, c) in colors.enumerated() {
                            layer.fill(Path(CGRect(x: x, y: top + h * Double(k) / 4, width: bw, height: h / 4 + 0.5)), with: .color(c))
                        }
                    }
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
