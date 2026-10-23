import SwiftUI
import AppKit

// ════════════════════════════════════════════════════════════════════
//  Colori di famiglia LR: la stessa radio d'epoca di OrbitLR (salvia,
//  crema, avorio, ottone), con un colore per ogni strumento.
// ════════════════════════════════════════════════════════════════════

extension Color {
    /// Colore che cambia da solo tra modalità chiara e scura.
    init(light: UInt32, dark: UInt32, lightOpacity: Double = 1, darkOpacity: Double = 1) {
        func ns(_ hex: UInt32, _ a: Double) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: CGFloat(a))
        }
        let l = ns(light, lightOpacity), d = ns(dark, darkOpacity)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l
        })
    }
}

enum Theme {
    static let sage = Color(light: 0xA9C5A0, dark: 0x3C5243)
    static let sageDeep = Color(light: 0x557E5F, dark: 0x8FBE98)
    static let cream = Color(light: 0xF3EDDF, dark: 0x1E221F)
    static let ivory = Color(light: 0xFBF8F0, dark: 0x2C302C)
    static let brass = Color(light: 0xB8925A, dark: 0xD6AA62)
    static let ink = Color(light: 0x3A3126, dark: 0xECE4D2)
    static let stroke = Color(light: 0x3A3126, dark: 0xECE4D2, lightOpacity: 0.11, darkOpacity: 0.12)
    static let shadow = Color(light: 0x3A3126, dark: 0x000000)

    static let accent = sageDeep
    static let background = cream
    static let card = ivory

    /// Un colore per strumento, nelle tinte «vintage» di OrbitLR.
    static func color(_ stem: String) -> Color {
        switch stem {
        case "vocals": return Color(light: 0xC8654F, dark: 0xE08A73)        // terracotta
        case "drums": return Color(light: 0xC99134, dark: 0xE0AE55)         // senape
        case "bass": return Color(light: 0x8A6BA6, dark: 0xAE90C9)          // prugna
        case "guitar": return Color(light: 0x6E9A52, dark: 0x93C174)        // oliva
        case "piano": return Color(light: 0x7B83A8, dark: 0xA0A8CC)         // ardesia
        case "other": return Color(light: 0x4E9A92, dark: 0x72BDB4)         // verde acqua
        case "instrumental": return Color(light: 0x5B7FAA, dark: 0x82A5CF)  // azzurro polvere
        default: return accent
        }
    }
}

struct CardStyle: ViewModifier {
    var radius: CGFloat = 14
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let high = contrast == .increased
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.card)
                .shadow(color: Theme.shadow.opacity(high ? 0 : 0.08), radius: 6, y: 2))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(high ? Theme.ink.opacity(0.55) : Theme.stroke, lineWidth: high ? 1.5 : 1))
    }
}

extension View {
    func card(radius: CGFloat = 14) -> some View { modifier(CardStyle(radius: radius)) }
}
