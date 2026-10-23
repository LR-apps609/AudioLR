import SwiftUI
import AppKit
import CoreML

// ════════════════════════════════════════════════════════════════════
//  Impostazioni (⌘,): Tracce, Motore, Aggiornamenti.
// ════════════════════════════════════════════════════════════════════

struct SettingsView: View {
    var body: some View {
        TabView {
            TracksSettings().tabItem { Label("Tracce", systemImage: "waveform") }
            EngineSettings().tabItem { Label("Motore", systemImage: "cpu") }
            UpdateSettings().tabItem { Label("Aggiornamenti", systemImage: "arrow.down.circle") }
        }
        .frame(width: 520)
        .tint(Theme.brass)
    }
}

/// Qualità, formato, cartella e cosa fare a fine lavoro.
struct TracksSettings: View {
    @AppStorage(Quality.key) private var quality = Quality.best.rawValue
    @AppStorage(Prefs.formatKey) private var format = OutputFormat.wav24.rawValue
    @AppStorage(Prefs.folderKey) private var folder = ""
    @AppStorage(Prefs.instrumentalKey) private var instrumental = true
    @AppStorage(Prefs.revealKey) private var reveal = false
    @AppStorage(Prefs.soundKey) private var sound = true

    var body: some View {
        Form {
            Section {
                Picker("Qualità", selection: $quality) {
                    ForEach(Quality.allCases) { q in Text(q.title).tag(q.rawValue) }
                }
                Text((Quality(rawValue: quality) ?? .best).detail).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Formato", selection: $format) {
                    ForEach(OutputFormat.allCases) { f in Text(f.title).tag(f.rawValue) }
                }
                Text((OutputFormat(rawValue: format) ?? .wav24).detail).font(.caption).foregroundStyle(.secondary)
                LabeledContent("Cartella") {
                    HStack(spacing: 8) {
                        Text(Prefs.displayName(of: folder.isEmpty ? Paths.output : URL(fileURLWithPath: folder)))
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Scegli…") { chooseFolder() }
                        if !folder.isEmpty {
                            Button("Predefinita") { folder = "" }.help("Torna a Musica › AudioLR")
                        }
                    }
                }
                Toggle("Crea anche la base senza voce (karaoke)", isOn: $instrumental)
            }
            Section {
                Toggle("Suono quando ha finito", isOn: $sound)
                Toggle("Apri la cartella nel Finder quando ha finito", isOn: $reveal)
            }
        }
        .formStyle(.grouped)
        .frame(height: 400)
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Usa questa cartella"
        p.message = "Dove salvare le tracce separate"
        if p.runModal() == .OK, let u = p.url { folder = u.path }
    }
}

/// Dove lavora il Mac, e lo spazio dei modelli scaricati.
struct EngineSettings: View {
    @State private var size = ModelFiles.sizeText()
    @State private var decisions: [(String, EngineChoice.Decision?)] = EngineSettings.load()
    @State private var confirmDelete = false

    static func load() -> [(String, EngineChoice.Decision?)] {
        [("Veloce", EngineChoice.stored(ModelStore.name)), ("Massima · Voce RoFormer", EngineChoice.stored("VoceRoFormer"))] +
        Quality.best.models.enumerated().map { (i, m) in
            ("Massima · " + Stem.info(["drums", "bass", "other", "vocals"][i]).name, EngineChoice.stored(m))
        }
    }

    var body: some View {
        Form {
            Section {
                ForEach(decisions.indices, id: \.self) { i in
                    let d = decisions[i].1
                    LabeledContent(decisions[i].0) {
                        Text(d?.text ?? "Da provare al primo uso").foregroundStyle(d == nil ? .tertiary : .secondary)
                    }
                }
                Button("Ricontrolla alla prossima separazione") {
                    EngineChoice.reset()
                    decisions = Self.load()
                }
            } header: {
                Text("Motore")
            } footer: {
                Text("Al primo uso di ogni modello AudioLR confronta Neural Engine e grafica su un pezzo della canzone, e usa il più preciso.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Modelli scaricati", value: size)
                Button("Elimina i modelli scaricati…") { confirmDelete = true }
                    .disabled(SeparationJob.shared.isBusy)
            } footer: {
                Text("Si riscaricano da soli alla prossima separazione.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 400)
        .confirmationDialog("Eliminare i modelli di IA scaricati?", isPresented: $confirmDelete) {
            Button("Elimina", role: .destructive) {
                ModelFiles.remove()
                size = ModelFiles.sizeText()
                decisions = Self.load()
            }
        } message: {
            Text("Liberi \(size). Alla prossima separazione verranno scaricati di nuovo (serve internet).")
        }
        .onAppear {
            size = ModelFiles.sizeText()
            decisions = Self.load()
        }
    }
}

struct UpdateSettings: View {
    @AppStorage(UpdateCheck.autoKey) private var auto = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Versione", value: UpdateCheck.current)
                Toggle("Controlla da sola una volta al giorno", isOn: $auto)
                Button("Controlla adesso") {
                    Task { @MainActor in await UpdateCheck.check(userInitiated: true) }
                }
            } footer: {
                Text("Gli aggiornamenti si installano in pochi secondi e AudioLR si riapre da sola. Puoi anche fare doppio clic su un file .audiolr.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Link("Pagina di AudioLR su GitHub", destination: URL(string: "https://github.com/LR-apps609/AudioLR")!)
                Link("Segnala un problema", destination: URL(string: "https://github.com/LR-apps609/AudioLR/issues/new")!)
            }
        }
        .formStyle(.grouped)
        .frame(height: 400)
    }
}
