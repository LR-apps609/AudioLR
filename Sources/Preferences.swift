import Foundation
import AVFoundation
import AppKit

// ════════════════════════════════════════════════════════════════════
//  Le scelte dell'utente (finestra Impostazioni, ⌘,): formato e cartella
//  delle tracce, base senza voce, cosa fare a fine lavoro.
// ════════════════════════════════════════════════════════════════════

/// Il formato dei file delle tracce separate.
enum OutputFormat: String, CaseIterable, Identifiable {
    case wav24, wav16, flac, alac, aac
    var id: String { rawValue }

    var title: String {
        switch self {
        case .wav24: return "WAV 24 bit"
        case .wav16: return "WAV 16 bit"
        case .flac: return "FLAC"
        case .alac: return "Apple Lossless (M4A)"
        case .aac: return "AAC 256 kbps (M4A, leggero)"
        }
    }

    var detail: String {
        switch self {
        case .wav24: return "Qualità da studio, per GarageBand, Logic e ogni programma musicale"
        case .wav16: return "Qualità CD, file un po' più piccoli"
        case .flac: return "Senza perdita, circa metà dello spazio"
        case .alac: return "Senza perdita, per Musica e iPhone"
        case .aac: return "Compresso, circa un decimo dello spazio: per ascoltare e condividere"
        }
    }

    var fileExtension: String {
        switch self {
        case .wav24, .wav16: return "wav"
        case .flac: return "flac"
        case .alac, .aac: return "m4a"
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
        case .aac:
            return [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: 256_000]
        }
    }
}

enum Prefs {
    static let formatKey = "outputFormat"
    static let folderKey = "outputFolder"
    static let instrumentalKey = "makeInstrumental"
    static let revealKey = "revealWhenDone"
    static let soundKey = "soundWhenDone"

    static let recordOffsetKey = "recordOffsetMs"
    /// Correzione a mano del ritardo delle registrazioni, in secondi (positiva = la registrazione si sposta più tardi).
    static var recordOffset: Double { UserDefaults.standard.double(forKey: recordOffsetKey) / 1000 }

    static var format: OutputFormat {
        OutputFormat(rawValue: UserDefaults.standard.string(forKey: formatKey) ?? "") ?? .wav24
    }

    /// La cartella delle tracce: Musica › IsoLR, se non ne è stata scelta un'altra (che esista ancora).
    static var folder: URL {
        if let p = UserDefaults.standard.string(forKey: folderKey), !p.isEmpty {
            var dir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &dir), dir.boolValue { return URL(fileURLWithPath: p, isDirectory: true) }
        }
        return Paths.output
    }

    static let appearanceKey = "appearance"

    /// Aspetto: automatico (come il Mac), chiaro o scuro.
    static func applyAppearance(_ value: String? = nil) {
        // Di serie scuro: lo «studio di notte» è l'aspetto di IsoLR
        switch value ?? UserDefaults.standard.string(forKey: appearanceKey) ?? "dark" {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    /// Neural Engine e grafica al lavoro insieme sui pezzi della canzone (di serie sì).
    /// Un Mac con poca memoria (8 GB o meno): i modelli si liberano appena hanno finito il loro passaggio,
    /// altrimenti macOS usa il disco come memoria e tutto rallenta molto.
    static let lowMemory = ProcessInfo.processInfo.physicalMemory <= 9 * 1024 * 1024 * 1024


    /// «Solo grafica»: niente Neural Engine (se su un Mac apre i modelli troppo lentamente o dà problemi).
    static let engineModeKey = "engineMode"
    static var gpuOnly: Bool { UserDefaults.standard.string(forKey: engineModeKey) == "grafica" }

    static let dualKey = "dualEngine"
    static var dualEngine: Bool { UserDefaults.standard.object(forKey: dualKey) as? Bool ?? true }

    /// Un modello in memoria alla volta (si libera appena finito): sui Mac con poca memoria e su quelli senza
    /// Neural Engine. Cambia solo la memoria usata, non il risultato.
    static var oneModelAtATime: Bool { lowMemory || !SeparationJob.hasNeuralEngine }

    /// Quante volte ogni punto della canzone passa nei RoFormer (voce e strumenti): 2 su tutti i Mac,
    /// come nel banco di prova sulle 50 canzoni. Fisso: Studio è la stessa ovunque.
    static let voiceOverlapValue = 2.0
    static let instrumentOverlap = 2.0

    /// Massima qualità: chitarra e pianoforte in tracce proprie (altrimenti restano in «Altri strumenti»).
    static let splitKey = "splitGuitarPiano"
    static var splitGuitarPiano: Bool { UserDefaults.standard.object(forKey: splitKey) as? Bool ?? true }
    /// Anche il file .stem.mp4 per i DJ (Traktor, Mixxx) a ogni separazione.
    static let stemFileKey = "makeStemFile"
    static var makeStemFile: Bool { UserDefaults.standard.bool(forKey: stemFileKey) }
    static var makeInstrumental: Bool { UserDefaults.standard.object(forKey: instrumentalKey) as? Bool ?? true }
    static var revealWhenDone: Bool { UserDefaults.standard.bool(forKey: revealKey) }
    /// Album di notte: a fine coda il Mac va in stop (scelta per il giro di lavoro in corso, si ricorda).
    static let sleepAfterBatchKey = "sleepAfterBatch"
    static var sleepAfterBatch: Bool { UserDefaults.standard.bool(forKey: sleepAfterBatchKey) }

    static var soundWhenDone: Bool { UserDefaults.standard.object(forKey: soundKey) as? Bool ?? true }

    /// «Musica › IsoLR» oppure il percorso abbreviato della cartella scelta.
    static func displayName(of url: URL) -> String {
        if url.standardizedFileURL == Paths.output.standardizedFileURL { return "Musica › IsoLR" }
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
