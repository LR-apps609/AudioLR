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
                .frame(minWidth: 560, minHeight: 440)
        }
        .defaultSize(width: 720, height: 560)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// «Apri con → AudioLR» dal Finder (e, più avanti, «Apri in AudioLR» da OrbitLR).
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.isFileURL }) else { return }
        Task { @MainActor in
            NSApp.activate()
            SeparationJob.shared.start(url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
