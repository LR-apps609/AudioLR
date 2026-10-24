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
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1020, height: 680)
        .commands { AudioLRCommands(job: job) }

        Settings {
            SettingsView()
        }

        Window("Account", id: "account") {
            AccountView().environmentObject(job)
        }
        .windowResizability(.contentSize)

        Window("Cronologia", id: "history") {
            HistoryView().environmentObject(job)
        }
        .defaultSize(width: 860, height: 560)

        Window("Domande frequenti", id: "faq") {
            FAQView()
        }
        .defaultSize(width: 620, height: 620)

        Window("Segnala un bug", id: "bug") {
            BugReportView()
        }
        .windowResizability(.contentSize)
    }
}

/// I menu: Archivio (apri, nuova, mostra), Vista, Mix, aggiornamenti, Account, Aiuto.
struct AudioLRCommands: Commands {
    @ObservedObject var job: SeparationJob
    @Environment(\.openWindow) private var openWindow
    @AppStorage("showLibrary") private var showLibrary = true
    @AppStorage("showPractice") private var showPractice = false
    @AppStorage(Quality.key) private var quality = Quality.best.rawValue

    private func post(_ name: Notification.Name, _ object: Any? = nil) {
        NotificationCenter.default.post(name: name, object: object)
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Controlla aggiornamenti…") {
                Task { @MainActor in await UpdateCheck.check(userInitiated: true) }
            }
            Button("Account…") { openWindow(id: "account") }
                .keyboardShortcut("a", modifiers: [.command, .shift])
        }
        CommandGroup(before: .toolbar) {
            Button(showLibrary ? "Nascondi la libreria" : "Mostra la libreria") { showLibrary.toggle() }
                .keyboardShortcut("l")
            Button("Cronologia") { openWindow(id: "history") }
                .keyboardShortcut("y")
            Button("Dettagli della separazione") { post(.audiolrDetails) }
                .keyboardShortcut("i")
                .disabled(job.phase != .done)
            Divider()
            Toggle("Qualità \(Quality.best.title)", isOn: Binding(get: { quality == Quality.best.rawValue },
                                                               set: { if $0 { quality = Quality.best.rawValue } }))
                .keyboardShortcut("1", modifiers: [.command, .option])
            Toggle("Qualità \(Quality.fast.title)", isOn: Binding(get: { quality == Quality.fast.rawValue },
                                                               set: { if $0 { quality = Quality.fast.rawValue } }))
                .keyboardShortcut("2", modifiers: [.command, .option])
            Toggle("Qualità \(Quality.studio.title)", isOn: Binding(get: { quality == Quality.studio.rawValue },
                                                                 set: { if $0 { quality = Quality.studio.rawValue } }))
                .keyboardShortcut("3", modifiers: [.command, .option])
            Divider()
        }
        CommandMenu("Mix") {
            Button("Suona / pausa") { post(.audiolrPlay) }
                .disabled(job.phase != .done)
            Divider()
            Button("Tutte le tracce") { post(.audiolrPreset, MixState.Preset.all.rawValue) }
                .keyboardShortcut("0")
                .disabled(job.phase != .done)
            Button("Karaoke (senza voce)") { post(.audiolrPreset, MixState.Preset.karaoke.rawValue) }
                .keyboardShortcut("k")
                .disabled(job.phase != .done)
            Button("Solo voce") { post(.audiolrPreset, MixState.Preset.voice.rawValue) }
                .keyboardShortcut("j")
                .disabled(job.phase != .done)
            Menu("Senza il mio strumento") {
                ForEach(MixState.Instrument.allCases) { i in
                    Button(i.without) { post(.audiolrWithout, i.rawValue) }
                        .disabled(!job.stems.contains { i.keys.contains($0.key) })
                }
            }
            .disabled(job.phase != .done)
            Button("Senza il mio strumento (l'ultimo scelto)") { post(.audiolrWithout) }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(job.phase != .done)
            Divider()
            Divider()
            Toggle("Sala prove", isOn: $showPractice)
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Inizio del passaggio da ripetere") { post(.audiolrLoop, "A") }
                .keyboardShortcut("[")
                .disabled(job.phase != .done)
            Button("Fine del passaggio da ripetere") { post(.audiolrLoop, "B") }
                .keyboardShortcut("]")
                .disabled(job.phase != .done)
            Divider()
            Button("Esporta il mix") { post(.audiolrExport) }
                .keyboardShortcut("e")
                .disabled(job.phase != .done)
            Button("Esporta per DJ (.stem.mp4)") { post(.audiolrStemFile) }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(job.phase != .done)
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
            Button("Domande frequenti") { openWindow(id: "faq") }
                .keyboardShortcut("?", modifiers: .command)
            Button("Segnala un bug…") { openWindow(id: "bug") }
                .keyboardShortcut("b", modifiers: [.command, .option])
            Divider()
            Link("AudioLR su GitHub", destination: BugReport.repo)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UpdateCheck.autoCheckSoon()          // una volta al giorno, in silenzio
        Prefs.applyAppearance()
        // I modelli sostituiti da versioni nuove non servono più: spazio libero sul disco
        DispatchQueue.global(qos: .utility).async { ModelStore.removeObsolete() }
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
