import AppKit

/// Clic destro su un file audio nel Finder › Azioni rapide (o Servizi) › «Separa con IsoLR» (NSServices in
/// project.yml): i file si aprono in IsoLR come con «Apri con», pronti da separare.
final class FinderService: NSObject {
    static let shared = FinderService()

    /// Cosa fare con i file (nelle prove si sostituisce).
    var open: ([URL]) -> Void = { urls in
        Task { @MainActor in
            NSApp.activate()
            SeparationJob.shared.prepare(urls)
        }
    }

    @objc func separateWithIsoLR(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else {
            error.pointee = "Nessun file audio scelto"
            return
        }
        open(urls)
    }
}
