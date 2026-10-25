import SwiftUI
import AppKit

// ════════════════════════════════════════════════════════════════════
//  La libreria (a sinistra): tutte le separazioni, con ricerca e numeri;
//  la guida (tasto «?»); i dettagli di una separazione (tempi di ogni fase,
//  file di partenza, motore, peso di ogni strumento nella canzone).
// ════════════════════════════════════════════════════════════════════

/// Si sta scrivendo nella ricerca della libreria: lo spazio deve scrivere uno spazio, non far partire il mix.
final class TypingFocus: ObservableObject {
    static let shared = TypingFocus()
    @Published var typing = false
}

struct LibraryView: View {
    @EnvironmentObject private var job: SeparationJob
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private var items: [HistoryItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? job.history : job.history.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("LIBRERIA").font(.system(size: 10, weight: .bold)).tracking(1.2).foregroundStyle(.tertiary)
                Spacer()
                Button { NSWorkspace.shared.open(Prefs.folder) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless)
                    .help("Apri la cartella delle tracce")
                    .accessibilityLabel("Apri la cartella delle tracce")
            }
            TextField("Cerca", text: $search)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($searchFocused)
                .onChange(of: searchFocused) { _, f in TypingFocus.shared.typing = f }
                // Nascondendo la libreria mentre si scrive, la barra spaziatrice torna a far suonare
                .onDisappear { TypingFocus.shared.typing = false }
                .onExitCommand { searchFocused = false }
                // All'apertura la ricerca non deve prendersi il cursore (e il riquadro acceso)
                .onAppear { DispatchQueue.main.async { searchFocused = false; NSApp.keyWindow?.makeFirstResponder(nil) } }
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text(job.history.isEmpty ? "Le canzoni che separi compaiono qui" : "Nessuna canzone trovata")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(items) { item in LibraryRow(item: item) }
                    }
                }
            }
            Divider()
            stats
        }
        .padding(14)
        .frame(width: 236)
        .background(Theme.card.opacity(0.55))
    }

    private var stats: some View {
        let s = History.stats(job.history)
        return VStack(alignment: .leading, spacing: 4) {
            statLine("music.note", s.songs == 1 ? "1 canzone separata" : "\(s.songs) canzoni separate")
            if s.minutes > 0 { statLine("clock", String(format: "%.0f minuti di musica", s.minutes)) }
            if let a = s.averageSeconds { statLine("timer", "in media " + formatTime(a) + " a canzone") }
            statLine("lock.fill", "Niente caricato su internet")
        }
    }

    private func statLine(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(Theme.brass).frame(width: 14)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct LibraryRow: View {
    let item: HistoryItem
    @EnvironmentObject private var job: SeparationJob
    @State private var hover = false

    var body: some View {
        let open = job.folder?.standardizedFileURL == item.folderURL.standardizedFileURL && job.phase == .done
        Button { job.open(item) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 12.5, weight: open ? .semibold : .medium)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    Image(systemName: (Quality(rawValue: item.quality) ?? .best).symbol).font(.system(size: 9))
                    Text([History.when(item.date), item.duration.map(formatTime)].compactMap { $0 }.joined(separator: " · "))
                }
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(open ? Theme.brass.opacity(0.16) : (hover ? Theme.ink.opacity(0.06) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(job.isBusy)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.folderURL]) }
            Button("Togli dalla libreria") { job.forget(item) }
        }
    }
}

// MARK: - Guida

struct GuideView: View {
    var openFAQ: () -> Void = {}
    private let tips: [(String, String, String)] = [
        ("square.and.arrow.down", "Trascina una o più canzoni", "Anche un album intero: IsoLR le separa una dopo l'altra."),
        ("sparkles", "Veloce, Massima o Studio", "Massima separa anche chitarra e piano; Studio ha la voce più pulita; Veloce è la più rapida."),
        ("slider.horizontal.3", "Il mixer", "Muto (M), solo (S) e volume per ogni traccia; Karaoke e Solo voce in un clic."),
        ("square.and.arrow.up", "Esporta il mix", "Salva quello che senti, accanto alle tracce."),
        ("hand.draw", "Trascina le tracce", "Direttamente in GarageBand, Logic o nel Finder."),
    ]
    private let keys: [(String, String)] = [
        ("⌘O", "Apri una canzone"), ("Spazio", "Suona o ferma il mix"), ("⌘N", "Nuova separazione"),
        ("⌘K", "Karaoke"), ("⌘J", "Solo voce"), ("⌘0", "Tutte le tracce"), ("⌘E", "Esporta il mix"),
        ("⌘I", "Dettagli"), ("⇧⌘D", "Dividi la batteria"), ("⇧⌘V", "Separa voce e cori"), ("⌥⌘P", "Sala prove"), ("⌘[ / ⌘]", "Inizio e fine della ripetizione"), ("⌘L", "Libreria"), ("⌘Y", "Cronologia"), ("⌥⌘1 / 2 / 3", "Massima / Veloce / Studio"),
        ("⇧⌘R", "Mostra le tracce nel Finder"), ("⌘.", "Annulla la separazione"), ("⌘,", "Impostazioni"),
        ("⇧⌘A", "Account"), ("⌘?", "Domande frequenti"), ("⌥⌘B", "Segnala un bug"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                LogoMark(size: 30)
                Text("Come si usa").font(.system(size: 16, weight: .bold, design: .rounded))
            }
            ForEach(tips.indices, id: \.self) { i in
                let t = tips[i]
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: t.0).font(.system(size: 13)).foregroundStyle(Theme.brass).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.1).font(.system(size: 12.5, weight: .semibold))
                        Text(t.2).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Divider()
            Text("TASTI RAPIDI").font(.system(size: 10, weight: .bold)).tracking(1.2).foregroundStyle(.tertiary)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                ForEach(keys.indices, id: \.self) { i in
                    let k = keys[i]
                    GridRow {
                        Text(k.0).font(.system(size: 11.5, weight: .semibold, design: .rounded)).monospacedDigit()
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.ink.opacity(0.07)))
                        Text(k.1).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            Button { openFAQ() } label: { Label("Tutte le domande frequenti", systemImage: "book") }
                .buttonStyle(.link)
        }
        .padding(18)
        .frame(width: 330)
    }
}

// MARK: - Dettagli di una separazione

struct DetailsView: View {
    @EnvironmentObject private var job: SeparationJob

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(job.title).font(.system(size: 15, weight: .bold, design: .rounded)).lineLimit(2)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                if job.duration > 0 { row("Durata", formatTime(job.duration)) }
                if let s = job.sourceInfo { row("File di partenza", s) }
                row("Qualità", job.quality.title)
                if let a = job.analysis {
                    row("Tempo", a.bpmText)
                    row("Tonalità", "\(a.keyName) (\(a.keyShort) · \(a.camelot))")
                }
                if let e = job.engineText { row("Motore", e) }
                row("Formato tracce", Prefs.format.title)
                if let f = job.folder { row("Cartella", Prefs.displayName(of: f)) }
            }
            if !job.timings.isEmpty {
                Divider()
                Text("DOVE È ANDATO IL TEMPO").font(.system(size: 10, weight: .bold)).tracking(1.2).foregroundStyle(.tertiary)
                let total = max(job.timings.reduce(0) { $0 + $1.seconds }, 0.001)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(job.timings) { t in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(t.name).font(.system(size: 11.5))
                                Spacer()
                                Text(formatTime(t.seconds)).font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                            }
                            GeometryReader { g in
                                Capsule().fill(Theme.brass.opacity(0.75)).frame(width: max(2, g.size.width * t.seconds / total))
                            }
                            .frame(height: 4)
                        }
                    }
                    HStack {
                        Text("Totale").font(.system(size: 11.5, weight: .semibold))
                        Spacer()
                        Text(formatTime(total)).font(.system(size: 11.5, weight: .bold)).monospacedDigit()
                    }
                    if job.duration > 0 {
                        Text(String(format: "%.1f secondi di lavoro per ogni secondo di musica", total / job.duration).replacingOccurrences(of: ".", with: ","))
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
            }
            let parts = job.stems.filter { $0.key != "instrumental" && $0.share != nil }
            if !parts.isEmpty {
                Divider()
                Text("DI COSA È FATTA LA CANZONE").font(.system(size: 10, weight: .bold)).tracking(1.2).foregroundStyle(.tertiary)
                GeometryReader { g in
                    HStack(spacing: 1) {
                        ForEach(parts) { s in
                            Rectangle().fill(Theme.color(s.key)).frame(width: max(1, g.size.width * (s.share ?? 0)))
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 10)
                ForEach(parts) { s in
                    HStack(spacing: 6) {
                        Circle().fill(Theme.color(s.key)).frame(width: 7, height: 7)
                        Text(s.name).font(.system(size: 11.5))
                        Spacer()
                        Text(String(format: "%.0f%%", (s.share ?? 0) * 100)).font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                    }
                }
                Text("Quota dell'energia sonora di ogni traccia.").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            let checked = job.stems.filter { $0.balance != nil }
            if !checked.isEmpty {
                Divider()
                Text("CONTROLLO DEL SUONO").font(.system(size: 10, weight: .bold)).tracking(1.2).foregroundStyle(.tertiary)
                ForEach(checked) { s in
                    HStack(spacing: 6) {
                        Text(s.name).font(.system(size: 11.5)).frame(width: 110, alignment: .leading)
                        BalanceBar(value: s.balance ?? 0.5).frame(width: 70, height: 8)
                        Spacer()
                        Text(s.peakDB.map { String(format: "picco %.1f dB", $0) } ?? "").font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if let g = job.stems.first?.gainDB, g < -0.05 {
                    Label(String(format: "Volume di tutte le tracce abbassato di %.1f dB per non distorcere", -g), systemImage: "waveform.badge.minus")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                } else {
                    Label("Nessuna traccia supera il massimo: niente distorsione", systemImage: "checkmark.circle")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .frame(width: 320)
    }

    @ViewBuilder
    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).font(.system(size: 11.5)).foregroundStyle(.secondary)
            Text(v).font(.system(size: 11.5, weight: .medium)).lineLimit(2).textSelection(.enabled)
        }
    }
}

/// Sinistra ↔ destra: il pallino al centro vuol dire traccia bilanciata.
struct BalanceBar: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.ink.opacity(0.08))
                Rectangle().fill(Theme.ink.opacity(0.25)).frame(width: 1).offset(x: g.size.width / 2)
                Circle().fill(abs(value - 0.5) > 0.15 ? Theme.voiceMute : Theme.brass)
                    .frame(width: g.size.height, height: g.size.height)
                    .offset(x: (g.size.width - g.size.height) * value)
            }
        }
        .help(String(format: "Sinistra %.0f%% · destra %.0f%%", (1 - value) * 100, value * 100))
    }
}
