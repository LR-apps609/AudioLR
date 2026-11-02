import Accelerate
import Foundation

// «Pulisci la voce»: Togli rumore e Togli riverbero, due calcoli di IsoLR senza modelli (niente da scaricare,
// nessuna licenza di terzi). Gli stessi numeri di Tools/denoise_ref.py e Tools/dereverb_ref.py, e di
// windows/ui/core/cleanup.js su Windows. Perché non DeepFilterNet: docs/LICENZE-MODELLI.md e Tools/prova_canto.py.

/// Trasformata di Fourier di un segnale reale lungo n (potenza di 2), con vDSP.
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

/// Lo spettro comune ai due calcoli: finestra di Hann di 2048 punti ogni 512, a 44,1 kHz; un guadagno per riga e
/// fotogramma, lo stesso per i due canali (l'immagine stereo non cambia).
enum SpectralGain {
    static let N = 2048, H = 512

    /// `gains(p, T, B)`: dall'energia (somma dei canali, T·B) al guadagno (T·B).
    static func run(_ channels: [[Float]], progress: (Double) -> Void, isCancelled: () -> Bool,
                    gains: (_ p: [Float], _ T: Int, _ B: Int) -> [Float]) throws -> [[Float]] {
        guard let n = channels.first?.count, n > 0 else { return channels }
        let B = N / 2 + 1, T = (n + N) / H + 1
        let fft = RealFFT(N)
        let win = (0..<N).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(N))) }
        var frame = [Float](repeating: 0, count: N), re = [Float](repeating: 0, count: B), im = re
        func load(_ x: [Float], _ t: Int) {
            // Il segnale con N/2 zeri prima: il fotogramma t parte da t·H − N/2
            let o = t * H - N / 2
            for i in 0..<N { let j = o + i; frame[i] = (j >= 0 && j < n) ? x[j] * win[i] : 0 }
        }
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
        let g = gains(p, T, B)
        p = []
        progress(0.5)
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

    /// L'energia media sulle righe vicine (±fw) e nel tempo (smooth).
    static func smoothed(_ p: [Float], _ T: Int, _ B: Int, fw: Int, smooth: Float) -> [Float] {
        var q = [Float](repeating: 0, count: T * B), row = [Float](repeating: 0, count: B)
        for t in 0..<T {
            for k in 0..<B {
                let a = max(0, k - fw), b = min(B, k + fw + 1)
                var s: Float = 0
                for j in a..<b { s += p[t * B + j] }
                row[k] = s / Float(b - a)
            }
            for k in 0..<B { q[t * B + k] = t > 0 ? smooth * q[(t - 1) * B + k] + (1 - smooth) * row[k] : row[k] }
        }
        return q
    }
}

/// Togli rumore: un «noise gate» spettrale. Il profilo del rumore è la media delle righe nei momenti più silenziosi
/// (il 10% dei fotogrammi con meno energia, dove la voce tace); ogni riga si abbassa (fino a −20 dB) solo dove la
/// sua energia non supera di molto quel profilo. Se la traccia ha silenzio digitale, o se i momenti «silenziosi»
/// sono ancora voce, toglie meno o niente: una voce pulita non si tocca.
enum Denoise {
    static let quiet = 0.10, over: Float = 2.0, floorDB = -20.0, fw = 2, smooth: Float = 0.6, release: Float = 0.7
    static let silent = 0.05, trustDB = (12.0, 20.0)

    static func gains(_ p: [Float], _ T: Int, _ B: Int) -> [Float] {
        let ones = [Float](repeating: 1, count: T * B)
        var total = [Double](repeating: 0, count: T)
        for t in 0..<T { var s = 0.0; for k in 0..<B { s += Double(p[t * B + k]) }; total[t] = s }
        let mx = total.max() ?? 0
        let edge = SpectralGain.N / SpectralGain.H
        let cand = Array(edge..<max(edge + 1, T - edge)).filter { $0 < T }
        let alive = cand.filter { total[$0] > 1e-10 * max(mx, 1e-30) }
        // Tanti fotogrammi di silenzio digitale: la traccia non ha un rumore di fondo da togliere
        guard !alive.isEmpty, Double(alive.count) >= (1 - silent) * Double(cand.count) else { return ones }
        let k = max(1, Int((quiet * Double(alive.count)).rounded(.toNearestOrEven)))
        let order = alive.sorted { total[$0] != total[$1] ? total[$0] < total[$1] : $0 < $1 }
        let q = Array(order.prefix(k))
        var noise = [Float](repeating: 0, count: B)
        for t in q { for f in 0..<B { noise[f] += p[t * B + f] } }
        for f in 0..<B { noise[f] = noise[f] / Float(k) + 1e-12 }
        // Quanto il silenzio sta sotto la parte forte (90° percentile, interpolato come numpy): se poco, i momenti
        // «silenziosi» sono ancora voce e il profilo non è affidabile; allora si toglie meno, fino a niente
        let sorted = order.map { total[$0] }, pos = 0.9 * Double(sorted.count - 1), lo = Int(pos)
        let loud = sorted[lo] + (sorted[min(lo + 1, sorted.count - 1)] - sorted[lo]) * (pos - Double(lo))
        let qm = q.reduce(0.0) { $0 + total[$1] } / Double(k)
        let span = 10 * log10(loud / max(qm, 1e-30))
        let trust = Float(min(max((span - trustDB.0) / (trustDB.1 - trustDB.0), 0), 1))
        guard trust > 0 else { return ones }
        let s = SpectralGain.smoothed(p, T, B, fw: fw, smooth: smooth)
        let floor = 1 - trust * (1 - Float(pow(10, floorDB / 20)))
        var g = ones, prev = [Float](repeating: 1, count: B)
        for t in 0..<T {
            for f in 0..<B {
                let v = floor + (1 - floor) * min(max(1 - over * noise[f] / max(s[t * B + f], 1e-20), 0), 1).squareRoot()
                prev[f] = max(v, release * prev[f] + (1 - release) * v)
                g[t * B + f] = prev[f]
            }
        }
        return g
    }

    static func process(_ channels: [[Float]], progress: (Double) -> Void = { _ in },
                        isCancelled: () -> Bool = { false }) throws -> [[Float]] {
        try SpectralGain.run(channels, progress: progress, isCancelled: isCancelled, gains: gains)
    }
}

/// Togli riverbero: dove l'energia di una riga dello spettro si spiega come la coda di quella di 116 ms prima,
/// smorzata come in una sala grande, è riverbero e si abbassa (fino a −18 dB); note che partono o restano tenute
/// passano intatte.
enum Dereverb {
    static let delay = 10
    static let t60: Float = 2.0, r0: Float = 1.3, r1: Float = 2.2, floorDB: Float = -18
    static let fw = 3, smooth: Float = 0.85

    static func gains(_ p: [Float], _ T: Int, _ B: Int) -> [Float] {
        let s = SpectralGain.smoothed(p, T, B, fw: fw, smooth: smooth)
        let total = s.reduce(0.0) { $0 + Double($1) }
        let eps = Float(1e-10 + 1e-8 * total / Double(T * B))
        let decay = Float(exp(-2 * (3 * log(10.0) / Double(t60)) * Double(delay * SpectralGain.H) / 44100))
        let floor = Float(pow(10, Double(floorDB) / 20))
        var g = [Float](repeating: 0, count: T * B), prev = [Float](repeating: 1, count: B)
        for t in 0..<T {
            for k in 0..<B {
                let late: Float = t >= delay ? decay * s[(t - delay) * B + k] : 0
                let r = s[t * B + k] / (late + eps)
                var v = min(max((r - r0) / (r1 - r0), 0), 1)
                v = floor + (1 - floor) * v * v * (3 - 2 * v)
                prev[k] = max(v, 0.5 * prev[k] + 0.5 * v)
                g[t * B + k] = prev[k]
            }
        }
        return g
    }

    static func process(_ channels: [[Float]], progress: (Double) -> Void = { _ in },
                        isCancelled: () -> Bool = { false }) throws -> [[Float]] {
        try SpectralGain.run(channels, progress: progress, isCancelled: isCancelled, gains: gains)
    }
}

/// Pulisci la voce: rumore, riverbero o tutti e due, a 44,1 kHz stereo.
enum Cleanup {
    static func run(_ audio: [[Float]], noise: Bool, reverb: Bool, progress: @escaping (Double) -> Void,
                    isCancelled: @escaping () -> Bool) async throws -> [[Float]] {
        var x = audio
        let both = noise && reverb
        if noise { x = try Denoise.process(x, progress: { progress((both ? 0.5 : 1) * $0) }, isCancelled: isCancelled) }
        if reverb {
            x = try Dereverb.process(x, progress: { progress((both ? 0.5 : 0) + (both ? 0.5 : 1) * $0) }, isCancelled: isCancelled)
        }
        progress(1)
        return x
    }
}
