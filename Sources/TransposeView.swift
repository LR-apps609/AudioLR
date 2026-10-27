import SwiftUI

// ════════════════════════════════════════════════════════════════════
//  Il tasto «Tonalità» nella barra del mixer e il suo pannello: − e +,
//  «Originale», la tonalità nuova a parole, «Porta alla mia voce» (dalla
//  nota più alta comoda di chi canta) e il capotasto per la chitarra.
// ════════════════════════════════════════════════════════════════════

/// Il tasto nella barra del mixer: «Do magg.» oppure «Re magg. · +2».
struct TransposeButton: View {
    @ObservedObject var mixer: MixPlayer
    @EnvironmentObject private var job: SeparationJob
    var compact: Bool
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down")
                Text(title).monospacedDigit()
            }
        }
        .popover(isPresented: $open, arrowEdge: .bottom) { TransposePanel(mixer: mixer).environmentObject(job) }
        .help("Transpose: la canzone in un'altra tonalità, senza cambiare la velocità (⌥⌘↑ e ⌥⌘↓)")
        .accessibilityLabel("Tonalità: \(accessible)")
        .background(alignment: .center) {
            // Le scorciatoie: un semitono su o giù anche a pannello chiuso
            Group {
                Button("") { mixer.transpose(by: 1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("") { mixer.transpose(by: -1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
            }
            .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private var title: String {
        let s = mixer.semitones
        guard let a = job.analysis else { return s == 0 ? (compact ? "" : "Tonalità") : PitchShift.label(s) }
        let k = SongAnalysis.english[((a.keyRoot + s) % 12 + 12) % 12] + (a.minor ? "m" : "")
        return s == 0 ? k : "\(k) · \(PitchShift.label(s))"
    }
    private var accessible: String {
        guard let a = job.analysis else { return mixer.semitones == 0 ? "originale" : "\(mixer.semitones) semitoni" }
        return Transpose.keyName(root: a.keyRoot, minor: a.minor, shift: mixer.semitones)
    }
}

struct TransposePanel: View {
    @ObservedObject var mixer: MixPlayer
    @EnvironmentObject private var job: SeparationJob
    /// La nota più alta che chi canta raggiunge comodo (MIDI); 0 = non ancora scelta.
    @AppStorage("myTopNote") private var myTop = 0
    @State private var range: (low: Double, high: Double)?
    @State private var measuring = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // La tonalità, da dove a dove
            VStack(alignment: .leading, spacing: 4) {
                Text("TONALITÀ").font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
                if let a = job.analysis {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Transpose.keyName(root: a.keyRoot, minor: a.minor, shift: 0))
                            .font(.system(size: 15, weight: mixer.semitones == 0 ? .semibold : .regular))
                            .foregroundStyle(mixer.semitones == 0 ? Color.primary : Color.secondary)
                        if mixer.semitones != 0 {
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            Text(Transpose.keyName(root: a.keyRoot, minor: a.minor, shift: mixer.semitones))
                                .font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(Theme.brass)
                        }
                    }
                } else {
                    Text("Tonalità non misurata (separazione delle prime versioni)").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Button { mixer.transpose(by: -1) } label: { Image(systemName: "minus").frame(width: 22) }
                    .disabled(mixer.semitones <= PitchShift.range.lowerBound).help("Un semitono sotto (⌥⌘↓)")
                Text(mixer.semitones == 0 ? "Originale" : "\(PitchShift.label(mixer.semitones)) semitoni")
                    .font(.system(size: 13, weight: .medium)).monospacedDigit().frame(minWidth: 90)
                Button { mixer.transpose(by: 1) } label: { Image(systemName: "plus").frame(width: 22) }
                    .disabled(mixer.semitones >= PitchShift.range.upperBound).help("Un semitono sopra (⌥⌘↑)")
                Spacer()
                Button("Originale") { mixer.semitones = 0 }.disabled(mixer.semitones == 0)
            }
            Text("Cambia solo il tono: la velocità resta quella. Anche i file scaricati e gli accordi seguono la tonalità scelta.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Divider()
            // Per chi canta
            VStack(alignment: .leading, spacing: 6) {
                Label("Per chi canta", systemImage: "music.mic").font(.system(size: 12, weight: .semibold))
                if let r = range {
                    Text("La voce della canzone va da \(Transpose.noteName(Int(r.low.rounded()))) a \(Transpose.noteName(Int(r.high.rounded())))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack {
                        Picker("La tua nota più alta comoda", selection: $myTop) {
                            Text("Scegli…").tag(0)
                            ForEach((48...84).reversed(), id: \.self) { m in Text(Transpose.noteName(m)).tag(m) }
                        }
                        .fixedSize()
                        if myTop > 0 {
                            let s = Transpose.suggest(songHigh: r.high, myHigh: myTop)
                            Button(s == 0 ? "È già giusta" : "Porta alla mia voce (\(PitchShift.label(s)))") { mixer.semitones = s }
                                .buttonStyle(.borderedProminent).disabled(s == mixer.semitones)
                        }
                    }
                    Text("Do4 è il Do centrale. Una voce maschile arriva in genere a Sol4–La4, una femminile a Do5–Mi5.")
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                } else if measuring {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Misuro la voce…").font(.system(size: 12)).foregroundStyle(.secondary) }
                } else {
                    Text("Serve la traccia della voce con abbastanza canto").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }

            // Per la chitarra: il capotasto
            if let chords = job.analysis?.chords, let c = Transpose.capo(chords: chords, shift: mixer.semitones) {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Label("Per la chitarra", systemImage: "guitars").font(.system(size: 12, weight: .semibold))
                    Text("Capotasto al \(c.capo)° tasto: suoni le forme di \(c.shapes.joined(separator: " · "))")
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(width: 340)
        .task(id: job.folder) { await measure() }
    }

    /// L'estensione della voce, misurata una volta per canzone (qualche secondo, fuori dalla finestra).
    private func measure() async {
        range = nil
        guard let v = job.stems.first(where: { $0.key == "vocals" }) ?? job.stems.first(where: { $0.key == "lead" }) else { return }
        measuring = true
        let url = v.url
        range = await Task.detached(priority: .userInitiated) { () -> (low: Double, high: Double)? in
            guard let a = try? AudioIO.read(url) else { return nil }
            let mono = zip(a[0], a[min(1, a.count - 1)]).map { ($0 + $1) / 2 }
            return Transpose.vocalRange(mono)
        }.value
        measuring = false
    }
}
