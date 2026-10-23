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
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Controlla aggiornamenti…") {
                    Task { @MainActor in await UpdateCheck.check(userInitiated: true) }
                }
                Button("Ricontrolla il motore alla prossima separazione") { EngineChoice.reset() }
            }
        }
    }
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
            guard let song = files.first else { return }
            NSApp.activate()
            SeparationJob.shared.start(song)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !Updater.shared.busy }
}
