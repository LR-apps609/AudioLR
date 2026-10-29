import SwiftUI

// ════════════════════════════════════════════════════════════════════
//  Un disegno fatto di forme (rettangoli, tratti, scritte) per gli editor
//  delle note e delle fette: di serie con Canvas (veloce); con Drawing.flat
//  (le prove sui Mac di GitHub, dove Canvas può chiudere l'app) come viste
//  semplici, una per forma.
// ════════════════════════════════════════════════════════════════════

struct Sketch {
    enum Item {
        case fill(Path, Color)
        case stroke(Path, Color, StrokeStyle)
        case text(String, CGPoint, CGFloat, Color, leading: Bool)
    }
    private(set) var items: [Item] = []

    mutating func fill(_ p: Path, _ c: Color) { items.append(.fill(p, c)) }
    mutating func fill(_ r: CGRect, _ c: Color) { items.append(.fill(Path(r), c)) }
    mutating func stroke(_ p: Path, _ c: Color, _ s: StrokeStyle) { items.append(.stroke(p, c, s)) }
    /// Una scritta piccola: centrata sul punto, o che parte dal punto (`leading`).
    mutating func text(_ s: String, at p: CGPoint, size: CGFloat, color: Color, leading: Bool = false) {
        items.append(.text(s, p, size, color, leading: leading))
    }
}

struct SketchView: View {
    let make: (CGSize) -> Sketch

    var body: some View {
        GeometryReader { g in
            if Drawing.flat {
                let items = Self.merged(make(g.size).items)
                ZStack(alignment: .topLeading) {
                    ForEach(items.indices, id: \.self) { i in view(items[i]) }
                }
                .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            } else {
                Canvas { ctx, size in
                    for item in make(size).items {
                        switch item {
                        case .fill(let p, let c): ctx.fill(p, with: .color(c))
                        case .stroke(let p, let c, let s): ctx.stroke(p, with: .color(c), style: s)
                        case .text(let s, let pt, let size, let c, let leading):
                            ctx.draw(Text(s).font(.system(size: size, weight: .semibold)).foregroundColor(c), at: pt, anchor: leading ? .leading : .center)
                        }
                    }
                }
            }
        }
    }

    /// Riempimenti vicini dello stesso colore in un'unica forma: molte meno viste da disegnare.
    static func merged(_ items: [Sketch.Item]) -> [Sketch.Item] {
        var out: [Sketch.Item] = []
        for item in items {
            if case .fill(let p, let c) = item, case .fill(var q, let c0)? = out.last, c0 == c {
                q.addPath(p)
                out[out.count - 1] = .fill(q, c)
            } else {
                out.append(item)
            }
        }
        return out
    }

    @ViewBuilder private func view(_ item: Sketch.Item) -> some View {
        switch item {
        case .fill(let p, let c): p.fill(c)
        case .stroke(let p, let c, let s): p.stroke(c, style: s)
        case .text(let s, let pt, let size, let c, let leading):
            Text(s).font(.system(size: size, weight: .semibold)).foregroundColor(c).fixedSize()
                .alignmentGuide(.leading) { d in leading ? -pt.x : -(pt.x - d.width / 2) }
                .alignmentGuide(.top) { d in -(pt.y - d.height / 2) }
        }
    }
}
