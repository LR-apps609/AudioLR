import Foundation
import SwiftUI

// ════════════════════════════════════════════════════════════════════
//  Filtri della libreria (e della Cronologia): testo, tonalità (anche le
//  «compatibili» per mixare: stessa casella Camelot, ±1, relativa), BPM
//  (anche a metà o al doppio), strumento presente, qualità; e l'ordine.
//  Le canzoni senza analisi (separate prima della 0.10) restano visibili
//  solo finché non si filtra per tonalità o BPM.
// ════════════════════════════════════════════════════════════════════

struct LibraryFilter: Equatable {
    enum Sort: String, CaseIterable, Identifiable {
        case recent, title, bpm, key
        var id: String { rawValue }
        var title: String {
            switch self {
            case .recent: return "Più recenti"
            case .title: return "Titolo"
            case .bpm: return "BPM"
            case .key: return "Tonalità (Camelot)"
            }
        }
    }

    var text = ""
    /// La tonalità cercata (0 = Do … 11 = Si) e se è minore.
    var keyRoot: Int?
    var minor = false
    /// Anche le tonalità che si mixano bene con questa.
    var compatible = false
    var bpmMin: Double?
    var bpmMax: Double?
    /// Conta anche le canzoni a metà o al doppio del tempo (80 BPM vale come 160).
    var halfDouble = false
    /// Una traccia che deve esserci («piano», «guitar»…).
    var instrument: String?
    var quality: String?
    var sort: Sort = .recent

    /// Qualche filtro oltre al testo è acceso.
    var active: Bool { keyRoot != nil || bpmMin != nil || bpmMax != nil || instrument != nil || quality != nil }

    /// Numero e lettera Camelot («8A» → 8, minore).
    static func camelot(root: Int, minor: Bool) -> (number: Int, minor: Bool) {
        let major = minor ? (root + 3) % 12 : root
        return (((major * 7) % 12 + 7) % 12 + 1, minor)
    }

    /// Due tonalità si mixano bene: stessa casella, una casella accanto (stessa lettera), o la relativa.
    static func compatible(_ a: (Int, Bool), _ b: (Int, Bool)) -> Bool {
        let x = camelot(root: a.0, minor: a.1), y = camelot(root: b.0, minor: b.1)
        if x.minor == y.minor {
            let d = abs(x.number - y.number)
            return d == 0 || d == 1 || d == 11
        }
        return x.number == y.number
    }

    func matchesKey(_ a: SongAnalysis?) -> Bool {
        guard let root = keyRoot else { return true }
        guard let a else { return false }
        if compatible { return Self.compatible((root, minor), (a.keyRoot, a.minor)) }
        return a.keyRoot == ((root % 12) + 12) % 12 && a.minor == minor
    }

    func matchesBPM(_ a: SongAnalysis?) -> Bool {
        guard bpmMin != nil || bpmMax != nil else { return true }
        guard let bpm = a?.bpm else { return false }
        let lo = bpmMin ?? 0, hi = bpmMax ?? .infinity
        let candidates = halfDouble ? [bpm, bpm / 2, bpm * 2] : [bpm]
        return candidates.contains { $0 >= lo - 0.5 && $0 <= hi + 0.5 }
    }

    /// Le canzoni che passano i filtri, nell'ordine scelto. `stems` dice quali tracce ha una canzone.
    func apply(_ items: [HistoryItem], stems: (HistoryItem) -> Set<String> = { _ in [] }) -> [HistoryItem] {
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        let kept = items.filter { item in
            (q.isEmpty || item.title.lowercased().contains(q))
                && matchesKey(item.analysis)
                && matchesBPM(item.analysis)
                && (quality == nil || item.quality == quality)
                && (instrument == nil || stems(item).contains(instrument!))
        }
        switch sort {
        case .recent:
            return kept.sorted { $0.date > $1.date }
        case .title:
            return kept.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .bpm:
            // Le canzoni senza BPM vanno in fondo
            return kept.sorted { ($0.analysis?.bpm ?? .infinity) < ($1.analysis?.bpm ?? .infinity) }
        case .key:
            func code(_ i: HistoryItem) -> Int {
                guard let a = i.analysis else { return Int.max }
                let c = Self.camelot(root: a.keyRoot, minor: a.minor)
                return c.number * 2 + (c.minor ? 0 : 1)
            }
            return kept.sorted { code($0) < code($1) }
        }
    }

    /// Le parole dei filtri accesi, per i chip («La minore e compatibili», «120–128 BPM»…).
    struct Chip: Identifiable, Equatable { let id: String; let text: String }

    var chips: [Chip] {
        var out: [Chip] = []
        if let r = keyRoot {
            let name = SongAnalysis.names[((r % 12) + 12) % 12] + (minor ? " minore" : " maggiore")
            out.append(Chip(id: "key", text: compatible ? "\(name) e compatibili" : name))
        }
        if bpmMin != nil || bpmMax != nil {
            let lo = bpmMin.map { String(Int($0)) } ?? "…", hi = bpmMax.map { String(Int($0)) } ?? "…"
            out.append(Chip(id: "bpm", text: "\(lo)–\(hi) BPM" + (halfDouble ? " (anche ½ e ×2)" : "")))
        }
        if let i = instrument { out.append(Chip(id: "instrument", text: "con " + Stem.info(i).name.lowercased())) }
        if let q = quality, let qq = Quality(rawValue: q) { out.append(Chip(id: "quality", text: qq.title)) }
        return out
    }

    mutating func clear(_ id: String) {
        switch id {
        case "key": keyRoot = nil; compatible = false
        case "bpm": bpmMin = nil; bpmMax = nil; halfDouble = false
        case "instrument": instrument = nil
        case "quality": quality = nil
        default: break
        }
    }
}

/// Lo stesso filtro per la libreria a sinistra e per la Cronologia.
final class LibraryFilterState: ObservableObject {
    static let shared = LibraryFilterState()
    @Published var filter = LibraryFilter()
    /// Quali tracce ha ogni cartella (si legge il disco una volta sola per cartella).
    private var cache: [String: Set<String>] = [:]

    func stems(_ item: HistoryItem) -> Set<String> {
        if let s = cache[item.folder] { return s }
        let s = Set(History.stems(in: item.folderURL, title: item.title).map(\.key))
        cache[item.folder] = s
        return s
    }

    func forgetCache() { cache = [:] }
}

/// I filtri in poco spazio: un menu «Filtri», un menu per l'ordine, il numero di canzoni e i chip dei filtri accesi.
struct LibraryFilterBar: View {
    @ObservedObject var state = LibraryFilterState.shared
    /// La canzone aperta (per «Come questa canzone»).
    var current: SongAnalysis?
    let count: Int

    private static let bpmRanges: [(String, Double?, Double?)] = [
        ("Meno di 90", nil, 90), ("90–110", 90, 110), ("110–125", 110, 125), ("125–140", 125, 140), ("Più di 140", 140, nil),
    ]
    private static let instruments = ["guitar", "piano", "lead", "male", "kick"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                filterMenu
                sortMenu
                Spacer(minLength: 0)
                Text(count == 1 ? "1 canzone" : "\(count) canzoni")
                    .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
            }
            ForEach(state.filter.chips) { chip in
                HStack(spacing: 4) {
                    Text(chip.text).lineLimit(1).truncationMode(.tail)
                    Button { state.filter.clear(chip.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Togli il filtro \(chip.text)")
                }
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Theme.brass.opacity(0.16)))
                .overlay(Capsule().strokeBorder(Theme.brass.opacity(0.45)))
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            if let a = current {
                Button("Come la canzone aperta (\(a.keyShort), \(a.bpmText))") {
                    state.filter.keyRoot = a.keyRoot; state.filter.minor = a.minor; state.filter.compatible = true
                    state.filter.bpmMin = (a.bpm * 0.94).rounded(); state.filter.bpmMax = (a.bpm * 1.06).rounded()
                    state.filter.halfDouble = true
                }
                Divider()
            }
            Menu("Tonalità") {
                Toggle("Anche le compatibili (Camelot)", isOn: $state.filter.compatible)
                Divider()
                ForEach(0..<12, id: \.self) { r in
                    Button(SongAnalysis.names[r] + " maggiore") { state.filter.keyRoot = r; state.filter.minor = false }
                }
                Divider()
                ForEach(0..<12, id: \.self) { r in
                    Button(SongAnalysis.names[r] + " minore") { state.filter.keyRoot = r; state.filter.minor = true }
                }
            }
            Menu("BPM") {
                Toggle("Anche a metà e al doppio", isOn: $state.filter.halfDouble)
                Divider()
                ForEach(Self.bpmRanges.indices, id: \.self) { i in
                    let r = Self.bpmRanges[i]
                    Button(r.0) { state.filter.bpmMin = r.1; state.filter.bpmMax = r.2 }
                }
            }
            Menu("Strumento") {
                ForEach(Self.instruments, id: \.self) { k in
                    Button("Con " + Stem.info(k).name.lowercased()) { state.filter.instrument = k }
                }
            }
            Menu("Qualità") {
                ForEach(Quality.allCases) { q in Button(q.title) { state.filter.quality = q.rawValue } }
            }
            if state.filter.active {
                Divider()
                Button("Togli tutti i filtri") { state.filter = LibraryFilter(text: state.filter.text, sort: state.filter.sort) }
            }
        } label: {
            Label("Filtri", systemImage: state.filter.active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.system(size: 11))
        .help("Filtra per tonalità (anche quelle che si mixano bene), BPM, strumento o qualità")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Ordina", selection: $state.filter.sort) {
                ForEach(LibraryFilter.Sort.allCases) { s in Text(s.title).tag(s) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Ordine: \(state.filter.sort.title)")
        .accessibilityLabel("Ordina le canzoni")
    }
}
