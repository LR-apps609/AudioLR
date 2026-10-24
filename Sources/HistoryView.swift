import SwiftUI
import AppKit

// ════════════════════════════════════════════════════════════════════
//  Cronologia (⌘Y): tutte le separazioni fatte, con data, qualità,
//  durata, tempo impiegato, tempo e tonalità. Si riaprono, si mostrano
//  nel Finder, si tolgono. La libreria a sinistra resta la via rapida.
// ════════════════════════════════════════════════════════════════════

struct HistoryView: View {
    @EnvironmentObject private var job: SeparationJob
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""
    @State private var selection: HistoryItem.ID?
    @State private var confirmClear = false

    private var items: [HistoryItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? job.history : job.history.filter { $0.title.lowercased().contains(q) }
    }

    private var selected: HistoryItem? { job.history.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if job.history.isEmpty {
                empty
            } else {
                table
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 420, idealHeight: 560)
        .background(Theme.background)
        .tint(Theme.brass)
    }

    private var header: some View {
        let s = History.stats(job.history)
        let spent = job.history.compactMap(\.seconds).reduce(0, +)
        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.brass.gradient))
            VStack(alignment: .leading, spacing: 1) {
                Text("Cronologia").font(.system(size: 18, weight: .bold, design: .rounded))
                Text(s.songs == 1 ? "1 canzone" : "\(s.songs) canzoni")
                    + Text(String(format: " · %.0f minuti di musica", s.minutes))
                    + Text(spent > 0 ? " · \(formatTime(spent)) di lavoro del Mac" : "")
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            TextField("Cerca una canzone", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
        }
        .padding(18)
    }

    private var table: some View {
        Table(items, selection: $selection) {
            TableColumn("Canzone") { item in
                Text(item.title).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    .help(item.title)
            }
            .width(min: 180, ideal: 260)
            TableColumn("Quando") { item in
                Text(History.when(item.date)).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 80, ideal: 100)
            TableColumn("Qualità") { item in
                let q = Quality(rawValue: item.quality) ?? .best
                Label(q.title, systemImage: q.symbol).labelStyle(.titleAndIcon).lineLimit(1)
            }
            .width(min: 90, ideal: 130)
            TableColumn("Durata") { item in
                Text(item.duration.map(formatTime) ?? "—").monospacedDigit()
            }
            .width(min: 50, ideal: 60)
            TableColumn("Lavoro") { item in
                Text(item.seconds.map(formatTime) ?? "—").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 60)
            TableColumn("Tempo e tonalità") { item in
                Text(item.analysis.map { "\($0.bpmText) · \($0.keyShort)" } ?? "—").monospacedDigit().lineLimit(1)
                    .help(item.analysis.map { "\($0.keyName) · Camelot \($0.camelot)" } ?? "Non misurati (separazione delle prime versioni)")
            }
            .width(min: 100, ideal: 130)
        }
        .contextMenu(forSelectionType: HistoryItem.ID.self) { ids in
            if let id = ids.first, let item = job.history.first(where: { $0.id == id }) {
                Button("Riapri") { reopen(item) }
                Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.folderURL]) }
                Divider()
                Button("Togli dalla cronologia") { job.forget(item) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let item = job.history.first(where: { $0.id == id }) { reopen(item) }
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock").font(.system(size: 30)).foregroundStyle(.tertiary)
            Text("Le canzoni che separi compaiono qui").font(.system(size: 14, weight: .semibold))
            Text("Con data, qualità, durata, tempo impiegato, BPM e tonalità.").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Riapri") { if let s = selected { reopen(s) } }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil || job.isBusy)
            Button("Mostra nel Finder") { if let s = selected { NSWorkspace.shared.activateFileViewerSelecting([s.folderURL]) } }
                .disabled(selected == nil)
            Button("Togli") { if let s = selected { job.forget(s); selection = nil } }
                .disabled(selected == nil)
                .help("Toglie la canzone dalla cronologia; i file restano nella cartella")
            Spacer()
            if confirmClear {
                Text("Togliere tutte le canzoni? I file restano.").font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Annulla") { confirmClear = false }
                Button("Svuota", role: .destructive) { job.clearHistory(); confirmClear = false; selection = nil }
            } else {
                Button("Svuota la cronologia…") { confirmClear = true }
                    .disabled(job.history.isEmpty)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func reopen(_ item: HistoryItem) {
        guard !job.isBusy else { return }
        job.open(item)
        openWindow(id: "main")
        NSApp.activate()
    }
}
