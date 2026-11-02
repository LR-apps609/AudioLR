import Accelerate
import CoreML
import Foundation

// «Pulisci la voce»: Togli rumore (DeepFilterNet3 di Hendrik Schröter, MIT o Apache 2.0) e Togli riverbero
// (un calcolo di IsoLR, senza modello). Lo stesso calcolo di Tools/deepfilter_ref.py e Tools/dereverb_ref.py,
// e di windows/ui/core/cleanup.js su Windows.

/// Trasformata di Fourier di un segnale reale lungo n (n = f·2^k, f ∈ {1, 3, 5, 15}), con vDSP.
final class RealFFT {
    let n: Int
    private let fwd: vDSP_DFT_Setup
    private let inv: vDSP_DFT_Setup
    private var zr: [Float], zi: [Float], or_: [Float], oi: [Float]

    init(_ n: Int) {
        self.n = n
        fwd = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .FORWARD)!
        inv = vDSP_DFT_zop_CreateSetup(fwd, vDSP_Length(n), .INVERSE)!
        zr = [Float](repeating: 0, count: n); zi = zr; or_ = zr; oi = zr
    }

    deinit {
        vDSP_DFT_DestroySetup(fwd)
        vDSP_DFT_DestroySetup(inv)
    }

    /// x (n campioni) → le righe 0…n/2 (reale e immaginario), senza normalizzazione.
    func forward(_ x: UnsafePointer<Float>, re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>) {
        for i in 0..<n { zr[i] = x[i]; zi[i] = 0 }
        vDSP_DFT_Execute(fwd, zr, zi, &or_, &oi)
        for k in 0...n / 2 { re[k] = or_[k]; im[k] = oi[k] }
    }

    /// Le righe 0…n/2 → n campioni reali: la somma intera, senza dividere per n (come irfft·n).
    func inverse(re: UnsafePointer<Float>, im: UnsafePointer<Float>, out: UnsafeMutablePointer<Float>) {
        let h = n / 2
        zr[0] = re[0]; zi[0] = 0
        zr[h] = re[h]; zi[h] = 0
        for k in 1..<h {
            zr[k] = re[k]; zi[k] = im[k]
            zr[n - k] = re[k]; zi[n - k] = -im[k]
        }
        vDSP_DFT_Execute(inv, zr, zi, &or_, &oi)
        for i in 0..<n { out[i] = or_[i] }
    }
}

struct DeepFilterConfig: Codable {
    let sr, fft, hop: Int
    let nb_erb, nb_df, order, lookahead: Int
    let alpha: Float
    let frames, ctx: Int
    let widths: [Int]
}

/// Togli rumore: una traccia mono a 48 kHz → la stessa senza rumore, stessa lunghezza.
final class Denoiser {
    static let modelName = "DeepFilter"
    let model: MLModel
    let cfg: DeepFilterConfig
    private let fft: RealFFT
    private let win: [Float]

    init(model: MLModel, config: DeepFilterConfig) {
        self.model = model
        cfg = config
        fft = RealFFT(config.fft)
        let half = Double(config.fft / 2)
        win = (0..<config.fft).map { i in
            let s = sin(0.5 * Double.pi * (Double(i) + 0.5) / half)
            return Float(sin(0.5 * Double.pi * s * s))
        }
    }

    func process(_ x: [Float], progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }) throws -> [Float] {
        let N = cfg.fft, H = cfg.hop, B = N / 2 + 1, E = cfg.nb_erb, D = cfg.nb_df, O = cfg.order
        let n = x.count
        let xp = x + [Float](repeating: 0, count: N)
        let T = xp.count / H
        // Lo spettro (come DFState.analysis)
        var sr = [Float](repeating: 0, count: T * B), si = sr
        var buf = [Float](repeating: 0, count: N)
        let norm = 1 / Float(N * N / (2 * H))
        sr.withUnsafeMutableBufferPointer { R in
            si.withUnsafeMutableBufferPointer { I in
                for t in 0..<T {
                    for i in 0..<(N - H) { buf[i] = (t > 0 ? xp[(t - 1) * H + i] : 0) * win[i] }
                    for i in 0..<H { buf[N - H + i] = xp[t * H + i] * win[N - H + i] }
                    buf.withUnsafeBufferPointer { fft.forward($0.baseAddress!, re: R.baseAddress! + t * B, im: I.baseAddress! + t * B) }
                    for k in 0..<B { R[t * B + k] *= norm; I[t * B + k] *= norm }
                }
            }
        }
        // Le caratteristiche: bande ERB in dB normalizzate, spettro basso normalizzato
        var erb = [Float](repeating: 0, count: T * E)
        var lowR = [Float](repeating: 0, count: T * D), lowI = lowR
        var s = (0..<E).map { -60 + Float($0) * (-30 / Float(E - 1)) }
        var u = (0..<D).map { 0.001 + Float($0) * (-0.0009 / Float(D - 1)) }
        let a = cfg.alpha
        for t in 0..<T {
            var k = 0
            for b in 0..<E {
                let w = cfg.widths[b]
                var sum: Float = 0
                for j in 0..<w { let r = sr[t * B + k + j], i = si[t * B + k + j]; sum += r * r + i * i }
                k += w
                let e = log10(sum / Float(w) + 1e-10) * 10
                s[b] = e * (1 - a) + s[b] * a
                erb[t * E + b] = (e - s[b]) / 40
            }
            for f in 0..<D {
                let r = sr[t * B + f], i = si[t * B + f]
                u[f] = (r * r + i * i).squareRoot() * (1 - a) + u[f] * a
                let q = u[f].squareRoot()
                lowR[t * D + f] = r / q
                lowI[t * D + f] = i / q
            }
        }
        // La rete a pezzi; ogni pezzo pronto si applica e si ricostruisce subito
        let F = cfg.frames
        let fe = try MLMultiArray(shape: [1, 1, NSNumber(value: F), NSNumber(value: E)], dataType: .float32)
        let fs = try MLMultiArray(shape: [1, 2, NSNumber(value: F), NSNumber(value: D)], dataType: .float32)
        var y = [Float](repeating: 0, count: T * H)
        var mem = [Float](repeating: 0, count: N - H)
        var orr = [Float](repeating: 0, count: B), oii = orr, frame = [Float](repeating: 0, count: N)
        var band = [Int](repeating: 0, count: B)
        do { var k = 0; for b in 0..<E { for _ in 0..<cfg.widths[b] { band[k] = b; k += 1 } } }
        let back = O - 1 - cfg.lookahead
        var start = 0
        while start < T {
            if isCancelled() { throw CancellationError() }
            // All'inizio niente contesto finto (la rete parte da zero come sull'intera traccia); gli zeri dopo la
            // fine invece sono quelli che la rete vede comunque
            let a0 = max(0, start - cfg.ctx)
            let pe = fe.dataPointer.assumingMemoryBound(to: Float.self), ps = fs.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0..<F {
                let t = a0 + i
                let ok = t >= 0 && t < T
                for b in 0..<E { pe[i * E + b] = ok ? erb[t * E + b] : 0 }
                for f in 0..<D {
                    ps[i * D + f] = ok ? lowR[t * D + f] : 0
                    ps[F * D + i * D + f] = ok ? lowI[t * D + f] : 0
                }
            }
            let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["feat_erb": fe, "feat_spec": fs]))
            guard let mArr = out.featureValue(for: "m")?.multiArrayValue, let cArr = out.featureValue(for: "coefs")?.multiArrayValue else {
                throw SeparationError("il modello del rumore non ha dato un risultato")
            }
            let m = MLShapedArray<Float>(converting: mArr).scalars, c = MLShapedArray<Float>(converting: cArr).scalars
            let end = min(a0 + F - cfg.ctx, T)
            for t in start..<end {
                let i = t - a0
                // La maschera ERB su tutte le righe
                for k in 0..<B {
                    let g = m[i * E + band[k]]
                    orr[k] = sr[t * B + k] * g; oii[k] = si[t * B + k] * g
                }
                // Il filtro profondo sulle prime righe, dallo spettro originale (2 fotogrammi indietro, 2 avanti)
                for f in 0..<D {
                    var re: Float = 0, im: Float = 0
                    for o in 0..<O {
                        let tt = t + o - back
                        guard tt >= 0, tt < T else { continue }
                        let xr = sr[tt * B + f], xi = si[tt * B + f]
                        let cr = c[(i * D + f) * O * 2 + 2 * o], ci = c[(i * D + f) * O * 2 + 2 * o + 1]
                        re += xr * cr - xi * ci
                        im += xr * ci + xi * cr
                    }
                    orr[f] = re; oii[f] = im
                }
                // Ricostruzione (come DFState.synthesis)
                orr.withUnsafeBufferPointer { R in oii.withUnsafeBufferPointer { I in
                    frame.withUnsafeMutableBufferPointer { fft.inverse(re: R.baseAddress!, im: I.baseAddress!, out: $0.baseAddress!) }
                } }
                for j in 0..<N { frame[j] *= win[j] }
                for j in 0..<H { y[t * H + j] = frame[j] + mem[j] }
                for j in 0..<(N - H) { mem[j] = frame[H + j] }
            }
            start = end
            progress(Double(start) / Double(T))
        }
        let d = N - H
        return Array(y[d..<(d + n)])
    }
}

/// Togli riverbero: dove l'energia di una riga dello spettro si spiega come la coda di quella di 116 ms prima,
/// smorzata come in una sala grande, è riverbero e si abbassa (fino a −18 dB); note che partono o restano tenute
/// passano intatte. Stesso guadagno per i due canali. Lavora a 44,1 kHz.
enum Dereverb {
    static let N = 2048, H = 512, delay = 10
    static let t60: Float = 2.0, r0: Float = 1.3, r1: Float = 2.2, floorDB: Float = -18
    static let fw = 3, smooth: Float = 0.85

    static var window: [Float] { (0..<N).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(N))) } }

    static func process(_ channels: [[Float]], progress: (Double) -> Void = { _ in },
                        isCancelled: () -> Bool = { false }) throws -> [[Float]] {
        guard let n = channels.first?.count, n > 0 else { return channels }
        let B = N / 2 + 1, T = (n + N) / H + 1
        let fft = RealFFT(N), win = window
        var frame = [Float](repeating: 0, count: N), re = [Float](repeating: 0, count: B), im = re
        func load(_ x: [Float], _ t: Int) {
            // Il segnale con N/2 zeri prima: il fotogramma t parte da t·H − N/2
            let o = t * H - N / 2
            for i in 0..<N { let j = o + i; frame[i] = (j >= 0 && j < n) ? x[j] * win[i] : 0 }
        }
        // 1) L'energia (somma dei canali)
        var p = [Float](repeating: 0, count: T * B)
        for x in channels {
            if isCancelled() { throw CancellationError() }
            for t in 0..<T {
                load(x, t)
                frame.withUnsafeBufferPointer { fft.forward($0.baseAddress!, re: &re, im: &im) }
                for k in 0..<B { p[t * B + k] += re[k] * re[k] + im[k] * im[k] }
            }
        }
        progress(0.3)
        // 2) Il guadagno
        var row = [Float](repeating: 0, count: B)
        var total: Double = 0
        for t in 0..<T {
            for k in 0..<B {
                let a = max(0, k - fw), b = min(B, k + fw + 1)
                var s: Float = 0
                for j in a..<b { s += p[t * B + j] }
                row[k] = s / Float(b - a)
            }
            for k in 0..<B {
                let v = t > 0 ? smooth * p[(t - 1) * B + k] + (1 - smooth) * row[k] : row[k]
                p[t * B + k] = v
                total += Double(v)
            }
        }
        let eps = Float(1e-10 + 1e-8 * total / Double(T * B))
        let decay = Float(exp(-2 * (3 * log(10.0) / Double(t60)) * Double(delay * H) / 44100))
        let floor = Float(pow(10, Double(floorDB) / 20))
        var g = [Float](repeating: 0, count: T * B), prev = [Float](repeating: 1, count: B)
        for t in 0..<T {
            for k in 0..<B {
                let late: Float = t >= delay ? decay * p[(t - delay) * B + k] : 0
                let r = p[t * B + k] / (late + eps)
                var s = min(max((r - r0) / (r1 - r0), 0), 1)
                s = s * s * (3 - 2 * s)
                let v = floor + (1 - floor) * s
                prev[k] = max(v, 0.5 * prev[k] + 0.5 * v)
                g[t * B + k] = prev[k]
            }
        }
        p = []
        progress(0.5)
        // 3) Ogni canale con il guadagno, ricostruito
        let norm = win.reduce(0) { $0 + $1 * $1 } / Float(H)
        var result: [[Float]] = []
        for (ci, x) in channels.enumerated() {
            if isCancelled() { throw CancellationError() }
            var out = [Float](repeating: 0, count: (T - 1) * H + N)
            for t in 0..<T {
                load(x, t)
                frame.withUnsafeBufferPointer { fft.forward($0.baseAddress!, re: &re, im: &im) }
                for k in 0..<B { re[k] *= g[t * B + k]; im[k] *= g[t * B + k] }
                re.withUnsafeBufferPointer { R in im.withUnsafeBufferPointer { I in
                    frame.withUnsafeMutableBufferPointer { fft.inverse(re: R.baseAddress!, im: I.baseAddress!, out: $0.baseAddress!) }
                } }
                // irfft = somma / N
                for i in 0..<N { out[t * H + i] += frame[i] / Float(N) * win[i] }
            }
            result.append((0..<n).map { out[N / 2 + $0] / norm })
            progress(0.5 + 0.5 * Double(ci + 1) / Double(channels.count))
        }
        return result
    }
}

extension ModelStore {
    /// Il modello di «Togli rumore», pronto (scaricato e preparato se serve). Sul processore: è piccolo
    /// e le sue GRU a 16 bit (Neural Engine) sbagliano.
    func denoiser(progress: @escaping (Double) -> Void) async throws -> Denoiser {
        let cfg = try JSONDecoder().decode(DeepFilterConfig.self, from: try await config(Denoiser.modelName))
        return Denoiser(model: try await mlModel(Denoiser.modelName, units: .cpuOnly, progress: progress), config: cfg)
    }
}

/// Pulisci la voce: rumore, riverbero o tutti e due, a 44,1 kHz stereo.
enum Cleanup {
    static func run(_ audio: [[Float]], noise: Bool, reverb: Bool, progress: @escaping (Double) -> Void,
                    isCancelled: @escaping () -> Bool) async throws -> [[Float]] {
        var x = audio
        let share = noise && reverb ? 0.75 : 1.0
        if noise {
            let model = try await ModelStore.shared.denoiser { p in progress(p * 0.1) }
            let n = x[0].count
            let up = try AudioIO.convert(x, from: AudioIO.sampleRate, to: Double(model.cfg.sr))
            var clean: [[Float]] = []
            for (c, ch) in up.enumerated() {
                clean.append(try model.process(ch, progress: { p in
                    progress(0.1 + (share - 0.1) * (Double(c) + p) / Double(up.count))
                }, isCancelled: isCancelled))
            }
            x = try AudioIO.convert(clean, from: Double(model.cfg.sr), to: AudioIO.sampleRate).map { ch in
                ch.count >= n ? Array(ch.prefix(n)) : ch + [Float](repeating: 0, count: n - ch.count)
            }
        }
        if reverb {
            let base = noise ? share : 0
            x = try Dereverb.process(x, progress: { progress(base + (1 - base) * $0) }, isCancelled: isCancelled)
        }
        progress(1)
        return x
    }
}
