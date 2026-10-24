import SwiftUI
import AppKit

// ════════════════════════════════════════════════════════════════════
//  Account: chi usa AudioLR, il piano, i numeri della libreria e le
//  altre app della famiglia LR. Le Impostazioni restano per le scelte
//  su come lavora l'app; qui c'è tutto quello che riguarda te.
// ════════════════════════════════════════════════════════════════════

/// Le app della famiglia LR e come riconoscerle sul Mac.
enum LRFamily {
    struct App: Identifiable {
        let name: String
        let bundleID: String
        let symbol: String
        let detail: String
        var id: String { bundleID }
    }

    static let apps: [App] = [
        App(name: "AudioLR", bundleID: "it.ledion.AudioLR", symbol: "waveform", detail: "Separa voce e strumenti"),
        App(name: "OrbitLR", bundleID: "it.ledion.OrbitLR", symbol: "circle.circle", detail: "La sorella di AudioLR"),
    ]

    static func installed(_ app: App) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)
    }

    /// Iniziali per l'avatar: «Mario Rossi» → «MR».
    static func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let s = parts.compactMap(\.first).map { String($0).uppercased() }.joined()
        return s.isEmpty ? "LR" : s
    }
}

struct AccountView: View {
    static let nameKey = "accountName"
    @AppStorage(AccountView.nameKey) private var name = NSFullUserName()
    @EnvironmentObject private var job: SeparationJob
    @Environment(\.openWindow) private var openWindow
    @State private var editing = false

    var body: some View {
        let s = History.stats(job.history)
        Form {
            Section {
                HStack(spacing: 14) {
                    Text(LRFamily.initials(name))
                        .font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Theme.brass.gradient))
                    VStack(alignment: .leading, spacing: 3) {
                        if editing {
                            TextField("Nome", text: $name).textFieldStyle(.roundedBorder)
                                .onSubmit { editing = false }
                        } else {
                            Text(name.isEmpty ? "Utente LR" : name).font(.system(size: 17, weight: .semibold))
                        }
                        Text("Account locale · \(NSUserName())@\(Host.current().localizedName ?? "Mac")")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button(editing ? "Fine" : "Modifica") { editing.toggle() }
                }
                .padding(.vertical, 4)
            }
            Section("Piano") {
                LabeledContent("Piano") {
                    Label("Personale · tutto incluso", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.green)
                }
                LabeledContent("Versione", value: UpdateCheck.current)
                LabeledContent("Dove lavora", value: "Solo su questo Mac, senza cloud")
            }
            Section("I tuoi numeri") {
                LabeledContent("Canzoni separate", value: "\(s.songs)")
                LabeledContent("Musica separata", value: String(format: "%.0f minuti", s.minutes))
                if let a = s.averageSeconds { LabeledContent("Tempo medio a canzone", value: formatTime(a)) }
                LabeledContent("Modelli di IA scaricati", value: ModelFiles.sizeText())
            }
            Section("Famiglia LR Apps") {
                ForEach(LRFamily.apps) { app in
                    let url = LRFamily.installed(app)
                    LabeledContent {
                        if app.bundleID == Bundle.main.bundleIdentifier {
                            Text("Questa app").foregroundStyle(.secondary)
                        } else if let url {
                            Button("Apri") { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
                        } else {
                            Text("Non installata").foregroundStyle(.tertiary)
                        }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name)
                                Text(app.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: app.symbol).foregroundStyle(Theme.brass)
                        }
                    }
                }
            }
            Section {
                Button("Domande frequenti…") { openWindow(id: "faq") }
                Button("Segnala un bug…") { openWindow(id: "bug") }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 600)
        .tint(Theme.brass)
    }
}
