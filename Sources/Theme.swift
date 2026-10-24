import SwiftUI
import AppKit

// ════════════════════════════════════════════════════════════════════
//  Colori di AudioLR: uno studio di registrazione. Di giorno carta crema,
//  di notte inchiostro-prugna come l'icona; ottone per i comandi e un
//  colore per ogni strumento (gli stessi delle barre dell'icona).
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

    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

enum Theme {
    static let background = Color(light: 0xF4EFE6, dark: 0x17141E)
    static let backgroundDeep = Color(light: 0xE9E1D3, dark: 0x0F0D14)
    static let card = Color(light: 0xFFFCF6, dark: 0x221E2B)
    static let well = Color(light: 0xF1EBE0, dark: 0x1A1721)        // fondo delle onde
    static let ink = Color(light: 0x2B2433, dark: 0xEDE6F2)
    static let brass = Color(light: 0xA97E3F, dark: 0xD6AA62)
    static let stroke = Color(light: 0x2B2433, dark: 0xEDE6F2, lightOpacity: 0.10, darkOpacity: 0.10)
    static let shadow = Color(light: 0x2B2433, dark: 0x000000)
    static let green = Color(light: 0x4E9A6A, dark: 0x7CC796)

    static let accent = brass
    /// Il rosso del tasto «muto» del mixer.
    static let voiceMute = Color(light: 0xB8463A, dark: 0xE0705F)

    /// I quattro strumenti nell'ordine dell'icona, dall'alto: voce, batteria, basso, altri strumenti.
    static let stemOrder = ["vocals", "drums", "bass", "other"]

    /// Le tracce che darà una separazione: in Massima anche chitarra e pianoforte (se non sono stati riuniti).
    static func stems(for q: Quality, split: Bool = Prefs.splitGuitarPiano) -> [String] {
        q.instrumentModel != nil && split ? ["vocals", "drums", "bass", "guitar", "piano", "other"] : stemOrder
    }

    /// Un colore per strumento: più carico di giorno, più luminoso di notte.
    static func color(_ stem: String) -> Color {
        switch stem {
        case "vocals": return Color(light: 0xCF6F57, dark: 0xE5917A)        // corallo
        case "drums": return Color(light: 0xC48E2C, dark: 0xE6B45C)         // ambra
        case "bass": return Color(light: 0x8C6AAF, dark: 0xB497D0)          // lilla
        case "guitar": return Color(light: 0x6E9A52, dark: 0x93C174)        // oliva
        case "piano": return Color(light: 0x6F78A3, dark: 0xA0A8CC)         // ardesia
        case "other": return Color(light: 0x3C978C, dark: 0x76C3B9)         // verde acqua
        // Le parti della batteria: sfumature dell'ambra della batteria
        case "kick": return Color(light: 0xB0702A, dark: 0xE09A50)
        case "snare": return Color(light: 0xC9A040, dark: 0xEBC670)
        case "toms": return Color(light: 0xA9603C, dark: 0xD98B63)
        case "hh": return Color(light: 0xB9A35A, dark: 0xDCCB86)
        case "ride": return Color(light: 0x9C8A4A, dark: 0xC9B677)
        case "crash": return Color(light: 0xD08A3A, dark: 0xF0AE66)
        case "instrumental": return Color(light: 0x5B7FAA, dark: 0x82A5CF)  // azzurro
        case "mix": return Color(light: 0x8A8194, dark: 0x8D859A)           // la canzone intera
        default: return accent
        }
    }
}

struct CardStyle: ViewModifier {
    var radius: CGFloat = 16
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let high = contrast == .increased
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.card)
                .shadow(color: Theme.shadow.opacity(high ? 0 : 0.10), radius: 14, y: 6))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(high ? Theme.ink.opacity(0.55) : Theme.stroke, lineWidth: high ? 1.5 : 1))
    }
}

extension View {
    func card(radius: CGFloat = 16) -> some View { modifier(CardStyle(radius: radius)) }
}
