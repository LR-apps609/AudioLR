import Foundation
import AVFoundation
import SwiftUI

// ════════════════════════════════════════════════════════════════════
//  Il mixer: le tracce separate suonano insieme, sincronizzate, con
//  muto, solo e volume per ognuna; poi si esporta il proprio mix
//  (per esempio karaoke con un filo di voce, o solo basso e batteria).
// ════════════════════════════════════════════════════════════════════

/// Le regole del mixer, separate dal suono così si possono provare.
struct MixState: Equatable {
    var gain: [String: Double] = [:]
    var muted: Set<String> = []
    var solo: Set<String> = []

    /// Il volume che una traccia ha davvero: zero se è muta, o se altre sono in «solo» e lei no.
    func effectiveGain(_ key: String) -> Double {
        if muted.contains(key) { return 0 }
        if !solo.isEmpty && !solo.contains(key) { return 0 }
        return gain[key] ?? 1
    }

    /// Scorciatoie: tutto, karaoke (senza voce), solo voce.
    enum Preset: String, CaseIterable, Identifiable {
        case all, karaoke, voice
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "Tutto"
            case .karaoke: return "Karaoke"
            case .voice: return "Solo voce"
            }
        }
    }

    mutating func apply(_ p: Preset) {
        muted = []
        solo = []
        switch p {
        case .all: break
        case .karaoke: muted = ["vocals"]
        case .voice: solo = ["vocals"]
        }
    }

    /// Quale scorciatoia corrisponde allo stato attuale (se una corrisponde).
    var preset: Preset? {
        if muted.isEmpty && solo.isEmpty { return .all }
        if muted == ["vocals"] && solo.isEmpty { return .karaoke }
        if solo == ["vocals"] && muted.isEmpty { return .voice }
        return nil
    }

    /// Somma delle tracce con i volumi del mixer.
    static func mix(_ tracks: [(key: String, audio: [[Float]])], state: MixState) -> [[Float]] {
        let n = tracks.map { $0.audio.first?.count ?? 0 }.max() ?? 0
        var out = [[Float]](repeating: [Float](repeating: 0, count: n), count: 2)
        for t in tracks {
            let g = Float(state.effectiveGain(t.key))
            guard g > 0 else { continue }
            for c in 0..<2 {
                let ch = t.audio[min(c, t.audio.count - 1)]
                for i in 0..<ch.count { out[c][i] += ch[i] * g }
            }
        }
        return out
    }
}

/// Il suono del mixer: un lettore per traccia, tutti partono nello stesso istante.
@MainActor
final class MixPlayer: ObservableObject {
    @Published var state = MixState() { didSet { applyGains() } }
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double = 0
    @Published private(set) var exporting = false

    private let engine = AVAudioEngine()
    private var players: [String: AVAudioPlayerNode] = [:]
    private var files: [String: AVAudioFile] = [:]
    private var startPosition: Double = 0
    private var startedAt: Date?
    private(set) var keys: [String] = []
    private var loadedFolder: URL?

    /// Secondi dall'inizio della canzone.
    var position: Double {
        guard isPlaying, let s = startedAt else { return startPosition }
        return min(duration, startPosition + Date().timeIntervalSince(s))
    }

    /// Prepara le tracce da mescolare (la base senza voce è già un mix, quindi resta fuori).
    func load(_ stems: [Stem], folder: URL?) {
        guard folder != loadedFolder || keys.isEmpty else { return }
        stop()
        for p in players.values { engine.detach(p) }
        players = [:]
        files = [:]
        keys = []
        duration = 0
        state = MixState()
        loadedFolder = folder
        for s in stems where s.key != "instrumental" {
            guard let f = try? AVAudioFile(forReading: s.url) else { continue }
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: f.processingFormat)
            players[s.key] = p
            files[s.key] = f
            keys.append(s.key)
            duration = max(duration, Double(f.length) / f.processingFormat.sampleRate)
        }
        applyGains()
    }

    func toggle() { isPlaying ? pause() : play(from: position >= duration - 0.05 ? 0 : position) }

    func play(from seconds: Double) {
        guard !players.isEmpty else { return }
        stopNodes()
        do { if !engine.isRunning { try engine.start() } } catch { return }
        let at = max(0, min(seconds, duration))
        for (k, p) in players {
            guard let f = files[k] else { continue }
            let rate = f.processingFormat.sampleRate
            let first = AVAudioFramePosition(at * rate)
            let count = AVAudioFrameCount(max(0, f.length - first))
            guard count > 0 else { continue }
            p.scheduleSegment(f, startingFrame: first, frameCount: count, at: nil)
        }
        // Tutti i lettori partono nello stesso istante, un attimo dopo: così restano allineati
        let when = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.08))
        for p in players.values { p.play(at: when) }
        startPosition = at
        startedAt = Date().addingTimeInterval(0.08)
        isPlaying = true
    }

    func pause() {
        startPosition = position
        stopNodes()
        isPlaying = false
    }

    func stop() {
        stopNodes()
        isPlaying = false
        startPosition = 0
    }

    func seek(to fraction: Double) {
        let t = max(0, min(1, fraction)) * duration
        if isPlaying { play(from: t) } else { startPosition = t }
    }

    /// Chiamato regolarmente dalla finestra: a fine canzone si ferma.
    func tick() {
        if isPlaying && position >= duration - 0.02 { stop() }
    }

    private func stopNodes() { for p in players.values { p.stop() } }

    private func applyGains() {
        for (k, p) in players { p.volume = Float(state.effectiveGain(k)) }
    }

    /// Salva il mix attuale accanto alle tracce, nel formato scelto nelle Impostazioni.
    func export(stems: [Stem], folder: URL, title: String) async throws -> URL {
        exporting = true
        defer { exporting = false }
        let state = self.state
        let chosen = stems.filter { $0.key != "instrumental" }
        let name = Self.exportName(state: state, title: title)
        let format = Prefs.format
        return try await Task.detached(priority: .userInitiated) {
            let tracks = try chosen.map { (key: $0.key, audio: try AudioIO.read($0.url)) }
            let mixed = MixState.mix(tracks, state: state)
            let url = folder.appendingPathComponent("\(name).\(format.fileExtension)")
            try AudioIO.write(mixed, to: url, format: format)
            return url
        }.value
    }

    /// «Canzone – Karaoke», «Canzone – Solo voce» o «Canzone – Mix».
    nonisolated static func exportName(state: MixState, title: String) -> String {
        switch state.preset {
        case .karaoke?: return "\(title) – Karaoke"
        case .voice?: return "\(title) – Solo voce"
        default: return "\(title) – Mix"
        }
    }
}
