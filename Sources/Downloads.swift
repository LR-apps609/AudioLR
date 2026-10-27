import AppKit
import UniformTypeIdentifiers

// ════════════════════════════════════════════════════════════════════
//  Download mirati: una traccia, alcune, tutte, nel formato scelto al
//  momento e dove si vuole. Le tracce di IsoLR restano comunque nella
//  loro cartella; qui se ne fa una copia (convertita se serve).
// ════════════════════════════════════════════════════════════════════

enum Downloads {
    /// «Canzone – Voce.wav», «Canzone – Voce (+2).wav» se è trasposta.
    static func fileName(title: String, stem: Stem, format: OutputFormat, shift: Int = 0) -> String {
        "\(title) – \(stem.name)\(suffix(shift)).\(format.fileExtension)"
    }

    /// « (+2)» per i file trasposti, niente per quelli nella tonalità originale.
    static func suffix(_ shift: Int) -> String { shift == 0 ? "" : " (\(PitchShift.label(shift)))" }

    /// Una traccia, letta e riscritta nel formato scelto (e nella tonalità scelta).
    nonisolated static func write(_ stem: Stem, to url: URL, format: OutputFormat, shift: Int = 0) throws {
        let audio = try PitchShift.apply(AudioIO.read(stem.url), semitones: shift)
        try AudioIO.write(audio, to: url, format: format)
    }

    /// Più tracce in una cartella nuova «Canzone (IsoLR)» dentro `folder` (se c'è già: «Canzone (IsoLR 2)»…).
    nonisolated static func writeAll(_ stems: [Stem], title: String, into folder: URL, format: OutputFormat, shift: Int = 0) throws -> URL {
        let fm = FileManager.default
        var dir = folder.appendingPathComponent("\(title) (IsoLR\(shift == 0 ? "" : " " + PitchShift.label(shift)))", isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: dir.path) {
            dir = folder.appendingPathComponent("\(title) (IsoLR \(n))", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for s in stems { try write(s, to: dir.appendingPathComponent(fileName(title: title, stem: s, format: format, shift: shift)), format: format, shift: shift) }
        return dir
    }

    /// Dove salvare un file: la finestra di macOS, con il nome proposto. Nil se si annulla.
    @MainActor
    static func askFile(name: String, format: OutputFormat) -> URL? {
        let p = NSSavePanel()
        p.nameFieldStringValue = name
        p.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .audio]
        p.canCreateDirectories = true
        p.message = "Dove vuoi salvare il file?"
        return p.runModal() == .OK ? p.url : nil
    }

    /// In quale cartella salvare più tracce. Nil se si annulla.
    @MainActor
    static func askFolder() -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Salva qui"
        p.message = "In quale cartella? IsoLR crea dentro una cartella con il nome della canzone."
        return p.runModal() == .OK ? p.url : nil
    }
}
