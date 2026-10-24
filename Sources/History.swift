import Foundation

// ════════════════════════════════════════════════════════════════════
//  Le ultime separazioni, per riaprirle dalla schermata iniziale
//  (si ascoltano e si trascinano di nuovo, senza rifare il lavoro).
// ════════════════════════════════════════════════════════════════════

struct HistoryItem: Codable, Identifiable, Equatable {
    var id = UUID()
    let title: String
    let folder: String
    let date: Date
    let quality: String
    /// Durata della canzone, tempo impiegato e motore usato (assenti nelle separazioni delle prime versioni).
    var duration: Double? = nil
    var seconds: Double? = nil
    var engine: String? = nil
    /// Tempo e tonalità (dalla 0.10).
    var analysis: SongAnalysis? = nil

    var folderURL: URL { URL(fileURLWithPath: folder, isDirectory: true) }
    var exists: Bool { FileManager.default.fileExists(atPath: folder) }
}

enum History {
    static let key = "history"
    static let limit = 30

    /// Le separazioni ancora presenti sul disco, dalla più recente.
    static func all(defaults: UserDefaults = .standard) -> [HistoryItem] {
        guard let data = defaults.data(forKey: key),
              let items = try? JSONDecoder().decode([HistoryItem].self, from: data) else { return [] }
        return items.filter(\.exists)
    }

    static func add(song: URL?, folder: URL, quality: Quality, duration: Double? = nil, seconds: Double? = nil,
                    engine: String? = nil, analysis: SongAnalysis? = nil, defaults: UserDefaults = .standard) {
        let title = song?.deletingPathExtension().lastPathComponent ?? folder.lastPathComponent
        var items = all(defaults: defaults).filter { $0.folder != folder.path }
        items.insert(HistoryItem(title: title, folder: folder.path, date: Date(), quality: quality.rawValue,
                                 duration: duration, seconds: seconds, engine: engine, analysis: analysis), at: 0)
        save(Array(items.prefix(limit)), defaults: defaults)
    }

    static func remove(_ item: HistoryItem, defaults: UserDefaults = .standard) {
        save(all(defaults: defaults).filter { $0.id != item.id }, defaults: defaults)
    }

    private static func save(_ items: [HistoryItem], defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: key) }
    }

    /// Le tracce di una cartella di AudioLR («Canzone – Voce.wav»…), riconosciute dal nome.
    static func stems(in folder: URL, title: String) -> [(key: String, url: URL)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var found: [(key: String, url: URL)] = []
        for key in ["vocals", "lead", "backing", "drums", "bass", "guitar", "piano", "other"] + DrumSplitter.parts + ["instrumental"] {
            let name = Stem.info(key).name
            if let f = files.first(where: { $0.deletingPathExtension().lastPathComponent == "\(title) – \(name)" }) {
                found.append((key, f))
            }
        }
        return found
    }

    /// Numeri della libreria: canzoni separate e minuti di musica.
    static func stats(_ items: [HistoryItem]) -> (songs: Int, minutes: Double, averageSeconds: Double?) {
        let mins = items.compactMap(\.duration).reduce(0, +) / 60
        let times = items.compactMap(\.seconds)
        return (items.count, mins, times.isEmpty ? nil : times.reduce(0, +) / Double(times.count))
    }

    /// «oggi, 14:32», «ieri», «12 ott»
    static func when(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        if cal.isDate(date, inSameDayAs: now) { f.dateFormat = "'oggi,' HH:mm"; return f.string(from: date) }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) { return "ieri" }
        f.dateFormat = "d MMM"
        return f.string(from: date)
    }
}
