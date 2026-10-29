import SwiftUI
import AppKit

// ════════════════════════════════════════════════════════════════════
//  Colori di IsoLR: «Studio di notte». Di serie scuro, come una sala di
//  registrazione con le luci basse: fondo inchiostro-prugna con un alone
//  viola caldo, oro per i comandi e un colore al neon per ogni strumento.
//  Di giorno (Impostazioni › Aspetto) carta calda con gli stessi accenti.
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
    static let background = Color(light: 0xF5EFE6, dark: 0x120F1A)
    static let backgroundDeep = Color(light: 0xEAE1D3, dark: 0x0B0A10)
    /// L'alone in alto nella finestra (viola caldo di notte, ambra leggero di giorno).
    static let halo = Color(light: 0xE8C99A, dark: 0x2A2140)
    static let card = Color(light: 0xFFFCF7, dark: 0x1A1524)
    static let cardDeep = Color(light: 0xF8F2E9, dark: 0x141019)
    static let well = Color(light: 0xF1EADF, dark: 0x0E0B14)        // fondo delle onde
    static let ink = Color(light: 0x2B2433, dark: 0xEDE6F2)
    static let brass = Color(light: 0x9A6F2E, dark: 0xD6AA62)
    static let stroke = Color(light: 0x2B2433, dark: 0xFFFFFF, lightOpacity: 0.10, darkOpacity: 0.08)
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

    /// Un colore per strumento: al neon di notte, più carico di giorno (si legge sulla carta).
    static func color(_ stem: String) -> Color {
        switch stem {
        case "vocals": return Color(light: 0xD4553D, dark: 0xFF7A66)        // corallo
        case "drums": return Color(light: 0xB97F12, dark: 0xFFC24B)         // ambra
        case "bass": return Color(light: 0x7F55CC, dark: 0xB48CFF)          // viola
        case "guitar": return Color(light: 0x4A9438, dark: 0x8EE07A)        // verde
        case "piano": return Color(light: 0x4567C8, dark: 0x7FA8FF)         // blu
        case "other": return Color(light: 0x16917F, dark: 0x43E0C2)         // verde acqua
        // Voce solista e cori: sfumature del corallo della voce
        case "lead": return Color(light: 0xC85A44, dark: 0xEC8A70)
        case "backing": return Color(light: 0xD88F7C, dark: 0xF0B3A2)
        case "male": return Color(light: 0xB8553F, dark: 0xE07F66)
        case "female": return Color(light: 0xDB8A6E, dark: 0xF4B49B)
        // Le parti della batteria: sfumature dell'ambra della batteria
        case "kick": return Color(light: 0xB0702A, dark: 0xE09A50)
        case "snare": return Color(light: 0xC9A040, dark: 0xEBC670)
        case "toms": return Color(light: 0xA9603C, dark: 0xD98B63)
        case "hh": return Color(light: 0xB9A35A, dark: 0xDCCB86)
        case "ride": return Color(light: 0x9C8A4A, dark: 0xC9B677)
        case "crash": return Color(light: 0xD08A3A, dark: 0xF0AE66)
        case "instrumental": return Color(light: 0x2F7FC0, dark: 0x6CC3FF)  // azzurro
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
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [Theme.card, Theme.cardDeep], startPoint: .top, endPoint: .bottom))
                .shadow(color: Theme.shadow.opacity(high ? 0 : 0.28), radius: 24, y: 12))
            // Il filo di luce sul bordo alto, come i pannelli di un mixer
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.06), .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
            }
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(high ? Theme.ink.opacity(0.55) : Theme.stroke, lineWidth: high ? 1.5 : 1))
    }
}

extension View {
    func card(radius: CGFloat = 16) -> some View { modifier(CardStyle(radius: radius)) }
}
