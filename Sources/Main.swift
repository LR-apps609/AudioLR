import SwiftUI
import AppKit

// Il punto d'ingresso dell'app, da solo in questo file: i test automatici compilano tutto il resto
// senza aprire l'app (niente finestre sul Mac di GitHub).
@main
struct AudioLRApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var job = SeparationJob.shared

    var body: some Scene {
        // Una finestra unica: «Apri con» e il ponte con OrbitLR riportano davanti quella che c'è
        Window("AudioLR", id: "main") {
            ContentView()
                .environmentObject(job)
                .frame(minWidth: 640, minHeight: 520)
        }
        .defaultSize(width: 780, height: 620)
        .commands { AudioLRCommands(job: job) }

        Settings {
            SettingsView()
        }
    }
}

/// I menu: Archivio (apri, nuova, mostra), aggiornamenti, Aiuto.
struct AudioLRCommands: Commands {
    @ObservedObject var job: SeparationJob

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Controlla aggiornamenti…") {
                Task { @MainActor in await UpdateCheck.check(userInitiated: true) }
            }
        }
        CommandGroup(replacing: .newItem) {
            Button("Apri una canzone…") { NotificationCenter.default.post(name: .audiolrOpenSong, object: nil) }
                .keyboardShortcut("o")
                .disabled(job.isBusy)
            Button("Nuova separazione") { job.reset() }
                .keyboardShortcut("n")
                .disabled(job.isBusy || job.phase == .idle)
            Divider()
            Button("Mostra le tracce nel Finder") {
                if let f = job.folder { NSWorkspace.shared.activateFileViewerSelecting([f]) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(job.folder == nil)
            Button("Annulla la separazione") { job.cancel() }
                .keyboardShortcut(".")
                .disabled(!job.isBusy)
        }
        CommandGroup(replacing: .help) {
            Link("Guida di AudioLR", destination: URL(string: "https://github.com/LR-apps609/AudioLR#readme")!)
            Link("Segnala un problema", destination: URL(string: "https://github.com/LR-apps609/AudioLR/issues/new")!)
        }
    }
}

extension Notification.Name {
    static let audiolrOpenSong = Notification.Name("audiolrOpenSong")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UpdateCheck.autoCheckSoon()          // una volta al giorno, in silenzio
    }

    /// Doppio clic su un aggiornamento .audiolr, oppure «Apri con → AudioLR» su una canzone
    /// (e, più avanti, «Apri in AudioLR» da OrbitLR).
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter { $0.isFileURL }
        Task { @MainActor in
            if let update = files.first(where: { $0.pathExtension.lowercased() == "audiolr" }) {
                Updater.shared.open(update)
                return
            }
            guard !files.isEmpty else { return }
            NSApp.activate()
            SeparationJob.shared.enqueue(files)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !Updater.shared.busy }
}
