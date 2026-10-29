import SwiftUI

// ════════════════════════════════════════════════════════════════════
//  I pezzi dello stile «Studio di notte» per la schermata di lavoro:
//  la canzone con la parte separata in oro e una testina luminosa, un
//  equalizzatore per ogni traccia che nasce, la luce REC. Tutto con
//  TimelineView + Canvas (niente ridisegni della vista a ogni avanzamento)
//  e fermo quando il Mac chiede di ridurre il movimento.
// ════════════════════════════════════════════════════════════════════

/// La canzone mentre viene separata: barre in oro fino a `progress`, il resto in penombra, e la testina che brilla.
struct GlowWaveform: View {
    let peaks: [Float]
    var progress: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Sui Mac virtuali (Drawing.flat) niente Canvas: la stessa onda disegnata con forme semplici
        if Drawing.flat {
            WaveformView(peaks: peaks, color: Theme.brass, dim: Theme.ink.opacity(0.14), progress: progress,
                         playhead: progress > 0 && progress < 1 ? progress : nil, barWidth: 2.5, spacing: 1.5)
        } else { live }
    }

    private var live: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: reduceMotion)) { tl in
            let t = reduceMotion ? 0 : tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                guard !peaks.isEmpty else { return }
                let bw: CGFloat = 2.5, gap: CGFloat = 1.5
                let slots = max(1, Int(size.width / (bw + gap)))
                let mid = size.height / 2
                let done = Int(Double(slots) * min(max(progress, 0), 1))
                for s in 0..<slots {
                    let a = s * peaks.count / slots, b = max(a + 1, (s + 1) * peaks.count / slots)
                    var p: Float = 0
                    for i in a..<min(b, peaks.count) { p = max(p, peaks[i]) }
                    var h = max(1.5, CGFloat(Double(p).squareRoot()) * size.height * 0.9)
                    // Le barre appena separate «respirano» un attimo vicino alla testina
                    if s < done && done - s < 24 { h *= CGFloat(1 + 0.06 * sin(t * 6 + Double(s) * 0.7)) }
                    let r = CGRect(x: CGFloat(s) * (bw + gap), y: mid - h / 2, width: bw, height: h)
                    let shade: GraphicsContext.Shading = s < done
                        ? .linearGradient(Gradient(colors: [Color(hex: 0xF2C478), Color(hex: 0xC98A3A)]),
                                          startPoint: CGPoint(x: r.midX, y: r.minY), endPoint: CGPoint(x: r.midX, y: r.maxY))
                        : .color(Theme.ink.opacity(0.14))
                    ctx.fill(Path(roundedRect: r, cornerRadius: bw / 2), with: shade)
                }
                // La testina: una linea d'oro con il suo bagliore
                if progress > 0 && progress < 1 {
                    let x = CGFloat(done) * (bw + gap)
                    var glow = ctx
                    glow.addFilter(.shadow(color: Theme.brass.opacity(0.9), radius: 8))
                    glow.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(Theme.brass))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Un equalizzatore che salta a tempo nel colore della traccia. `level` (0…1) alza le barre man mano.
struct Equalizer: View {
    let color: Color
    var bars = 7
    var seed = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if Drawing.flat { flat } else { live }
    }

    /// Fermo, con forme semplici (Mac virtuali senza Canvas).
    private var flat: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<bars, id: \.self) { k in
                RoundedRectangle(cornerRadius: 2).fill(LinearGradient(colors: [color, color.opacity(0.35)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 6, height: CGFloat(18 + ((k * 23 + seed * 11) % 34)))
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .accessibilityHidden(true)
    }

    private var live: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { tl in
            let t = reduceMotion ? 0 : tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let bw: CGFloat = 6, gap: CGFloat = 3
                let total = CGFloat(bars) * bw + CGFloat(bars - 1) * gap
                let x0 = (size.width - total) / 2
                var glow = ctx
                glow.addFilter(.shadow(color: color.opacity(0.55), radius: 5))
                for k in 0..<bars {
                    let speed = 2.2 + Double((k + seed) % 5) * 0.55
                    let phase = Double(k * 23 + seed * 11) * 0.37
                    let v = reduceMotion ? 0.55 : 0.2 + 0.8 * abs(sin(t * speed + phase))
                    let h = max(4, size.height * CGFloat(v))
                    let r = CGRect(x: x0 + CGFloat(k) * (bw + gap), y: size.height - h, width: bw, height: h)
                    glow.fill(Path(roundedRect: r, cornerRadius: 2),
                              with: .linearGradient(Gradient(colors: [color, color.opacity(0.35)]),
                                                    startPoint: CGPoint(x: r.midX, y: r.minY), endPoint: CGPoint(x: r.midX, y: r.maxY)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Una traccia che sta nascendo: equalizzatore, nome e la sua barra luminosa.
struct StemForming: View {
    let key: String
    let progress: Double
    let index: Int

    var body: some View {
        let info = Stem.info(key), color = Theme.color(key)
        VStack(spacing: 8) {
            Equalizer(color: color, seed: index).frame(height: 56)
            HStack(spacing: 5) {
                Image(systemName: info.symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
                Text(info.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.ink.opacity(0.08))
                    if progress == 0 { Shimmer(color: color).clipShape(Capsule()) }
                    Capsule().fill(color)
                        .frame(width: max(0, g.size.width * progress))
                        .shadow(color: color.opacity(0.8), radius: 5)
                }
            }
            .frame(height: 4)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.well))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(info.name): \(Int(progress * 100))%")
    }
}

/// Un indicatore di livello verticale nel colore della traccia, con il suo bagliore.
struct LevelMeter: View {
    let level: Double
    let color: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .bottom) {
                Capsule().fill(Theme.ink.opacity(0.08))
                Capsule().fill(LinearGradient(colors: [color, color.opacity(0.45)], startPoint: .top, endPoint: .bottom))
                    .frame(height: g.size.height * min(max(level, 0), 1))
                    .shadow(color: color.opacity(level > 0 ? 0.7 : 0), radius: 4)
            }
        }
        .accessibilityHidden(true)
    }
}

/// La luce rossa «REC» che lampeggia mentre IsoLR lavora.
struct RecLight: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: reduceMotion)) { tl in
            let t = reduceMotion ? 0 : tl.date.timeIntervalSinceReferenceDate
            let on = reduceMotion ? 1 : 0.35 + 0.65 * (0.5 + 0.5 * cos(t * 2 * .pi / 1.2))
            HStack(spacing: 5) {
                Circle().fill(Color(hex: 0xFF5D5D)).frame(width: 7, height: 7)
                    .opacity(on).shadow(color: Color(hex: 0xFF5D5D).opacity(on), radius: 4)
                Text("REC").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Color(hex: 0xFF5D5D))
            }
        }
        .accessibilityHidden(true)
    }
}

extension View {
    /// Il bagliore d'oro dello stile «Studio di notte» (numeri, scelta attiva).
    func goldGlow(_ on: Bool = true, radius: CGFloat = 10) -> some View {
        shadow(color: Theme.brass.opacity(on ? 0.45 : 0), radius: radius)
    }
}
