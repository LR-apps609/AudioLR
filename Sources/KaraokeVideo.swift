import SwiftUI
import AppKit
import AVFoundation
import CoreVideo

// ════════════════════════════════════════════════════════════════════
//  Video karaoke: la base (senza voce, o con la voce bassa) e il testo
//  sincronizzato grande, con la parola cantata in oro, sullo sfondo dello
//  «Studio di notte» con l'onda che scorre. MP4 H.264 + AAC, orizzontale
//  1920×1080 (YouTube) o verticale 1080×1920 (Instagram, TikTok).
//  Il video si disegna fotogramma per fotogramma (AVAssetWriter), l'audio
//  si scrive in AAC, poi i due si uniscono senza ricodificare.
// ════════════════════════════════════════════════════════════════════

enum KaraokeVideo {
    enum Shape: String, CaseIterable, Identifiable {
        case landscape, portrait
        var id: String { rawValue }
        var title: String { self == .landscape ? "Orizzontale 1920×1080 (YouTube)" : "Verticale 1080×1920 (Instagram, TikTok)" }
        var size: CGSize { self == .landscape ? CGSize(width: 1920, height: 1080) : CGSize(width: 1080, height: 1920) }
    }

    static let fps: Int32 = 30
    /// Secondi del titolo all'inizio.
    static let titleSeconds = 3.0

    /// Cosa si vede in un istante: il titolo (all'inizio), la riga in corso con la parola cantata e la prossima.
    struct Frame: Equatable {
        var showTitle: Bool
        var line: String?
        var sung: Int?
        var lineWords: [String]
        var next: String?
    }

    /// Le regole del fotogramma all'istante `t` (le stesse di windows/ui/core/karaoke.js).
    static func frame(at t: Double, lines: [LyricLine], words: [LyricWord]) -> Frame {
        let now = Lyrics.current(lines, words: words, at: t)
        let upcoming = lines.firstIndex { $0.start > t }
        var f = Frame(showTitle: t < titleSeconds && (lines.first?.start ?? .infinity) > t, line: nil, sung: nil, lineWords: [], next: nil)
        if let n = now {
            let l = lines[n.line]
            f.line = l.text
            f.lineWords = l.words.map { words[$0].text.trimmingCharacters(in: .whitespaces) }
            if let w = n.word { f.sung = w - l.words.lowerBound }
            if n.line + 1 < lines.count { f.next = lines[n.line + 1].text }
        } else if let u = upcoming {
            // Prima della riga: la si mostra già, in grigio, da 2 secondi prima
            if lines[u].start - t < 2 {
                f.line = lines[u].text
                f.lineWords = lines[u].words.map { words[$0].text.trimmingCharacters(in: .whitespaces) }
            }
            if u + 1 < lines.count, f.line != nil { f.next = lines[u + 1].text }
        }
        return f
    }

    /// Crea il video. `voiceGain` 0 = senza voce. `progress` 0…1.
    static func render(lyrics: Lyrics, title: String, base: URL, voice: URL?, voiceGain: Float,
                       shape: Shape, to out: URL, progress: @escaping (Double) -> Void) async throws {
        var audio = try AudioIO.read(base)
        if let v = voice, voiceGain > 0 {
            let vo = try AudioIO.read(v)
            for c in 0..<min(audio.count, vo.count) {
                for i in 0..<min(audio[c].count, vo[c].count) { audio[c][i] += vo[c][i] * voiceGain }
            }
        }
        let duration = Double(audio.first?.count ?? 0) / AudioIO.sampleRate
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("karaoke-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let silent = work.appendingPathComponent("video.mp4")
        let sound = work.appendingPathComponent("audio.m4a")
        try AudioIO.write(audio, to: sound, format: .aac)
        let peaks = Peaks.of(audio, count: max(200, Int(duration * 20)))
        try await writeVideo(lyrics: lyrics, title: title, peaks: peaks, duration: duration, shape: shape, to: silent) { progress(0.95 * $0) }
        try await mux(video: silent, audio: sound, to: out)
        progress(1)
    }

    // MARK: Video

    private static func writeVideo(lyrics: Lyrics, title: String, peaks: [Float], duration: Double, shape: Shape,
                                   to url: URL, progress: @escaping (Double) -> Void) async throws {
        let size = shape.size
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? SeparationError("non riesco a creare il video") }
        writer.startSession(atSourceTime: .zero)
        let lines = Lyrics.lines(lyrics.words)
        let total = Int(duration * Double(fps))
        for i in 0..<max(1, total) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            try Task.checkCancellation()
            let t = Double(i) / Double(fps)
            guard let pool = adaptor.pixelBufferPool else { throw SeparationError("non riesco a disegnare il video") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let pb = buffer else { throw SeparationError("non riesco a disegnare il video") }
            let f = frame(at: t, lines: lines, words: lyrics.words)
            draw(f, title: title, peaks: peaks, at: t, duration: duration, size: size, into: pb)
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
            if i % 30 == 0 { progress(Double(i) / Double(max(1, total))) }
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? SeparationError("il video non si è chiuso bene") }
    }

    /// Disegna un fotogramma (anche per le schermate di prova).
    static func draw(_ f: Frame, title: String, peaks: [Float], at t: Double, duration: Double, size: CGSize, into pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        draw(f, title: title, peaks: peaks, at: t, duration: duration, size: size, in: ctx)
    }

    static func draw(_ f: Frame, title: String, peaks: [Float], at t: Double, duration: Double, size: CGSize, in ctx: CGContext) {
        let w = size.width, h = size.height
        let rgb = CGColorSpaceCreateDeviceRGB()
        // Sfondo: l'alone viola dello «Studio di notte»
        ctx.setFillColor(CGColor(red: 0.043, green: 0.039, blue: 0.063, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        let halo = [CGColor(red: 0.165, green: 0.129, blue: 0.251, alpha: 1), CGColor(red: 0.043, green: 0.039, blue: 0.063, alpha: 0)] as CFArray
        if let g = CGGradient(colorsSpace: rgb, colors: halo, locations: [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: w * 0.6, y: h * 1.05), startRadius: 0,
                                   endCenter: CGPoint(x: w * 0.6, y: h * 1.05), endRadius: max(w, h) * 0.75, options: [])
        }
        drawWave(peaks: peaks, at: t, duration: duration, size: size, in: ctx)
        let gold = NSColor(red: 0.839, green: 0.667, blue: 0.384, alpha: 1)
        let small = min(w, h)
        if f.showTitle {
            drawText(title, size: small * 0.075, color: .white, weight: .bold, centerY: h * 0.55, width: w * 0.86, in: ctx, canvas: size)
            drawText("IsoLR · karaoke", size: small * 0.035, color: gold, weight: .semibold, centerY: h * 0.44, width: w * 0.86, in: ctx, canvas: size)
            return
        }
        if !f.lineWords.isEmpty {
            let line = NSMutableAttributedString()
            let font = NSFont.systemFont(ofSize: small * 0.07, weight: .bold)
            for (k, word) in f.lineWords.enumerated() {
                let color: NSColor = f.sung.map { k < $0 ? .white : (k == $0 ? gold : NSColor(white: 1, alpha: 0.55)) } ?? NSColor(white: 1, alpha: 0.55)
                line.append(NSAttributedString(string: (k > 0 ? " " : "") + word, attributes: [.font: font, .foregroundColor: color]))
            }
            drawAttributed(line, centerY: h * 0.54, width: w * 0.88, in: ctx, canvas: size)
        }
        if let n = f.next {
            drawText(n, size: small * 0.045, color: NSColor(white: 1, alpha: 0.45), weight: .medium, centerY: h * 0.42, width: w * 0.86, in: ctx, canvas: size)
        }
    }

    private static func drawWave(peaks: [Float], at t: Double, duration: Double, size: CGSize, in ctx: CGContext) {
        guard !peaks.isEmpty, duration > 0 else { return }
        let w = size.width, h = size.height
        let bars = 96, step = w / CGFloat(bars)
        let centre = Int(Double(peaks.count) * t / duration)
        let mid = h * 0.17
        for b in 0..<bars {
            let idx = centre + b - bars / 2
            guard idx >= 0, idx < peaks.count else { continue }
            let p = CGFloat(peaks[idx].squareRoot())
            let bh = max(3, p * h * 0.12)
            let x = CGFloat(b) * step + step * 0.25
            let played = b <= bars / 2
            ctx.setFillColor(played ? CGColor(red: 0.839, green: 0.667, blue: 0.384, alpha: 0.9) : CGColor(gray: 1, alpha: 0.18))
            ctx.fill(CGRect(x: x, y: mid - bh / 2, width: step * 0.5, height: bh))
        }
        // La testina
        ctx.setFillColor(CGColor(red: 0.95, green: 0.77, blue: 0.47, alpha: 1))
        ctx.fill(CGRect(x: w / 2 - 1.5, y: mid - h * 0.07, width: 3, height: h * 0.14))
    }

    private static func drawText(_ s: String, size: CGFloat, color: NSColor, weight: NSFont.Weight, centerY: CGFloat,
                                 width: CGFloat, in ctx: CGContext, canvas: CGSize) {
        let a = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        drawAttributed(a, centerY: centerY, width: width, in: ctx, canvas: canvas)
    }

    /// Testo centrato, a capo se non ci sta.
    private static func drawAttributed(_ a: NSAttributedString, centerY: CGFloat, width: CGFloat, in ctx: CGContext, canvas: CGSize) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let m = NSMutableAttributedString(attributedString: a)
        m.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: m.length))
        let bounds = m.boundingRect(with: CGSize(width: width, height: canvas.height), options: [.usesLineFragmentOrigin])
        let rect = CGRect(x: (canvas.width - width) / 2, y: centerY - bounds.height / 2, width: width, height: bounds.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        m.draw(with: rect, options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Unione di video e audio

    private static func mux(video: URL, audio: URL, to out: URL) async throws {
        let comp = AVMutableComposition()
        let v = AVURLAsset(url: video), a = AVURLAsset(url: audio)
        guard let vt = try await v.loadTracks(withMediaType: .video).first,
              let at = try await a.loadTracks(withMediaType: .audio).first,
              let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw SeparationError("non riesco a unire video e audio")
        }
        let vd = try await v.load(.duration), ad = try await a.load(.duration)
        try cv.insertTimeRange(CMTimeRange(start: .zero, duration: vd), of: vt, at: .zero)
        try ca.insertTimeRange(CMTimeRange(start: .zero, duration: min(vd, ad)), of: at, at: .zero)
        try? FileManager.default.removeItem(at: out)
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw SeparationError("non riesco a unire video e audio")
        }
        export.outputURL = out
        export.outputFileType = .mp4
        await export.export()
        if export.status != .completed { throw export.error ?? SeparationError("non riesco a unire video e audio") }
    }
}

/// La finestra «Video karaoke»: formato, voce sì/no, crea.
struct KaraokeVideoSheet: View {
    @EnvironmentObject private var job: SeparationJob
    let lyrics: Lyrics
    var onClose: () -> Void
    @State private var shape: KaraokeVideo.Shape = .landscape
    @State private var withVoice = false
    @State private var working = false
    @State private var progress = 0.0
    @State private var status = ""
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Video karaoke").font(.system(size: 18, weight: .bold, design: .rounded))
            Text("La base e il testo che si illumina parola per parola, sullo sfondo dello Studio di notte.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Picker("Formato", selection: $shape) {
                ForEach(KaraokeVideo.Shape.allCases) { s in Text(s.title).tag(s) }
            }
            .pickerStyle(.radioGroup)
            Toggle("Voce bassa sotto la base (per chi impara la canzone)", isOn: $withVoice)
            if working {
                ProgressView(value: progress)
                Text("Creo il video… \(Int(progress * 100))%").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            } else if !status.isEmpty {
                Text(status).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(working ? "Annulla" : "Chiudi") {
                    if working { task?.cancel() } else { onClose() }
                }
                .keyboardShortcut(.cancelAction)
                Button("Crea il video…") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || base == nil)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private var base: URL? { job.stems.first { $0.key == "instrumental" }?.url }
    private var voice: URL? { job.stems.first { $0.key == "vocals" }?.url }

    private func create() {
        guard let b = base else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(job.title) – Karaoke\(shape == .portrait ? " verticale" : "").mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        if let f = job.folder { panel.directoryURL = f }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true
        progress = 0
        let (lyr, title, s, v, gain) = (lyrics, job.title, shape, voice, withVoice ? Float(0.25) : 0)
        task = Task {
            do {
                try await KaraokeVideo.render(lyrics: lyr, title: title, base: b, voice: v, voiceGain: gain, shape: s, to: url) { p in
                    Task { @MainActor in progress = p }
                }
                await MainActor.run {
                    working = false
                    status = "Fatto: \(url.lastPathComponent)"
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                await MainActor.run {
                    working = false
                    status = error is CancellationError ? "Annullato" : "Non riuscito: \(error.localizedDescription)"
                }
            }
        }
    }
}
