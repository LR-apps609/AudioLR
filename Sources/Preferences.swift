import Foundation
import AVFoundation
import AppKit

// ════════════════════════════════════════════════════════════════════
//  Le scelte dell'utente (finestra Impostazioni, ⌘,): formato e cartella
//  delle tracce, base senza voce, cosa fare a fine lavoro.
// ════════════════════════════════════════════════════════════════════

/// Il formato dei file delle tracce separate.
enum OutputFormat: String, CaseIterable, Identifiable {
    case wav24, wav16, flac, alac
    var id: String { rawValue }

    var title: String {
        switch self {
        case .wav24: return "WAV 24 bit"
        case .wav16: return "WAV 16 bit"
        case .flac: return "FLAC"
        case .alac: return "Apple Lossless (M4A)"
        }
    }

    var detail: String {
        switch self {
        case .wav24: return "Qualità da studio, per GarageBand, Logic e ogni programma musicale"
        case .wav16: return "Qualità CD, file un po' più piccoli"
        case .flac: return "Senza perdita, circa metà dello spazio"
        case .alac: return "Senza perdita, per Musica e iPhone"
        }
    }

    var fileExtension: String {
        switch self {
        case .wav24, .wav16: return "wav"
        case .flac: return "flac"
        case .alac: return "m4a"
        }
    }

    /// Impostazioni del file per AVAudioFile.
    func settings(channels: Int, sampleRate: Double) -> [String: Any] {
        switch self {
        case .wav24, .wav16:
            return [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
                    AVLinearPCMBitDepthKey: self == .wav24 ? 24 : 16, AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        case .flac:
            return [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
                    AVEncoderBitDepthHintKey: 24]
        case .alac:
            return [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
                    AVEncoderBitDepthHintKey: 24]
        }
    }
}

enum Prefs {
    static let formatKey = "outputFormat"
    static let folderKey = "outputFolder"
    static let instrumentalKey = "makeInstrumental"
    static let revealKey = "revealWhenDone"
    static let soundKey = "soundWhenDone"

    static var format: OutputFormat {
        OutputFormat(rawValue: UserDefaults.standard.string(forKey: formatKey) ?? "") ?? .wav24
    }

    /// La cartella delle tracce: Musica › AudioLR, se non ne è stata scelta un'altra (che esista ancora).
    static var folder: URL {
        if let p = UserDefaults.standard.string(forKey: folderKey), !p.isEmpty {
            var dir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &dir), dir.boolValue { return URL(fileURLWithPath: p, isDirectory: true) }
        }
        return Paths.output
    }

    static let appearanceKey = "appearance"
    static let voiceOverlapKey = "voiceOverlap"

    /// Aspetto: automatico (come il Mac), chiaro o scuro.
    static func applyAppearance(_ value: String? = nil) {
        switch value ?? UserDefaults.standard.string(forKey: appearanceKey) ?? "auto" {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    /// Velocità della separazione: «equilibrio» (di serie) o «rapida» (pezzi meno sovrapposti, circa un quarto più veloce).
    static let speedKey = "speedMode"
    static var fast: Bool { UserDefaults.standard.string(forKey: speedKey) == "rapida" }
    /// Neural Engine e grafica al lavoro insieme sui pezzi della canzone (di serie sì).
    static let dualKey = "dualEngine"
    static var dualEngine: Bool { UserDefaults.standard.object(forKey: dualKey) as? Bool ?? true }

    /// Sovrapposizione dei pezzi per il modello voce e per quello degli strumenti.
    static var voiceOverlapValue: Double { fast ? 1.5 : Double(voiceOverlap) }
    static var instrumentOverlap: Double { fast ? 1.5 : 2 }

    /// Quante volte ogni punto della canzone passa nel modello voce: 2 equilibrio, 4 più preciso e più lento.
    static var voiceOverlap: Int {
        let v = UserDefaults.standard.integer(forKey: voiceOverlapKey)
        return v == 0 ? 2 : v
    }

    /// Massima qualità: chitarra e pianoforte in tracce proprie (altrimenti restano in «Altri strumenti»).
    static let splitKey = "splitGuitarPiano"
    static var splitGuitarPiano: Bool { UserDefaults.standard.object(forKey: splitKey) as? Bool ?? true }
    static var makeInstrumental: Bool { UserDefaults.standard.object(forKey: instrumentalKey) as? Bool ?? true }
    static var revealWhenDone: Bool { UserDefaults.standard.bool(forKey: revealKey) }
    static var soundWhenDone: Bool { UserDefaults.standard.object(forKey: soundKey) as? Bool ?? true }

    /// «Musica › AudioLR» oppure il percorso abbreviato della cartella scelta.
    static func displayName(of url: URL) -> String {
        if url.standardizedFileURL == Paths.output.standardizedFileURL { return "Musica › AudioLR" }
        let home = Paths.home.path
        let p = url.path
        let short = p.hasPrefix(home) ? String(p.dropFirst(home.count + 1)) : p
        return short.split(separator: "/").joined(separator: " › ")
    }
}

/// Spazio occupato dai modelli scaricati, e la possibilità di liberarlo.
enum ModelFiles {
    static func size() -> Int64 {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: ModelStore.folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static func sizeText() -> String {
        ByteCountFormatter.string(fromByteCount: size(), countStyle: .file)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: ModelStore.folder)
        ModelStore.shared.forget()
        EngineChoice.reset()
    }
}
