import Foundation
import Accelerate

// ════════════════════════════════════════════════════════════════════
//  Spettrogramma (STFT) e ritorno all'onda (iSTFT), identici a quelli
//  di Demucs: finestra di Hann, 4096 punti, passo 1024, «normalizzati»,
//  con i bordi riflessi. Core ML non gestisce i numeri complessi, quindi
//  nel modello c'è solo la rete e questa parte la fa l'app.
//  Tools/convert_demucs.py ne contiene una copia in Python e la confronta
//  con Demucs: se qui cambia qualcosa, va cambiato anche lì.
// ════════════════════════════════════════════════════════════════════

final class Spectrogram {
    let nfft: Int
    let hop: Int
    /// Frequenze tenute (l'ultima, quella di Nyquist, Demucs la scarta).
    var bins: Int { nfft / 2 }
    /// Margine che Demucs aggiunge ai due lati prima dello spettrogramma.
    var pad: Int { hop / 2 * 3 }

    private let window: [Float]
    private let forwardDFT: vDSP.DFT<Float>
    private let inverseDFT: vDSP.DFT<Float>

    init(nfft: Int = 4096) {
        self.nfft = nfft
        hop = nfft / 4
        window = (0..<nfft).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(nfft))) }
        forwardDFT = vDSP.DFT(count: nfft, direction: .forward, transformType: .complexComplex, ofType: Float.self)!
        inverseDFT = vDSP.DFT(count: nfft, direction: .inverse, transformType: .complexComplex, ofType: Float.self)!
    }

    /// Quante colonne (istanti) ha lo spettrogramma di un'onda lunga `length` campioni.
    func frames(for length: Int) -> Int { (length + hop - 1) / hop }

    /// Bordi «a specchio» come in PyTorch (il campione del bordo non si ripete).
    /// Se l'onda è più corta del margine, prima si allunga con del silenzio (come `pad1d` di Demucs).
    static func reflectPad(_ x: [Float], left: Int, right: Int) -> [Float] {
        var x = x
        var left = left, right = right
        let maxPad = max(left, right)
        var extraLeft = 0, extraRight = 0
        if x.count <= maxPad {
            let extra = maxPad - x.count + 1
            extraRight = min(right, extra)
            extraLeft = extra - extraRight
            left -= extraLeft
            right -= extraRight
            x = [Float](repeating: 0, count: extraLeft) + x + [Float](repeating: 0, count: extraRight)
        }
        let n = x.count
        var out = [Float](repeating: 0, count: n + left + right)
        for i in 0..<out.count {
            var j = i - left
            if j < 0 { j = -j } else if j >= n { j = 2 * (n - 1) - j }
            out[i] = x[j]
        }
        return out
    }

    /// Spettrogramma di un canale: parte reale e immaginaria, ciascuna `bins × frames` (prima la frequenza).
    func forward(_ x: [Float]) -> (re: [Float], im: [Float]) {
        let le = frames(for: x.count)
        let a = Self.reflectPad(x, left: pad, right: pad + le * hop - x.count)
        let b = Self.reflectPad(a, left: nfft / 2, right: nfft / 2)
        var re = [Float](repeating: 0, count: bins * le)
        var im = [Float](repeating: 0, count: bins * le)
        var frame = [Float](repeating: 0, count: nfft)
        let zeros = [Float](repeating: 0, count: nfft)
        var outR = [Float](repeating: 0, count: nfft)
        var outI = [Float](repeating: 0, count: nfft)
        let scale = 1 / Float(nfft).squareRoot()
        for j in 0..<le {
            // Demucs scarta le prime due colonne (e le ultime due)
            let start = (j + 2) * hop
            for n in 0..<nfft { frame[n] = b[start + n] * window[n] }
            forwardDFT.transform(inputReal: frame, inputImaginary: zeros, outputReal: &outR, outputImaginary: &outI)
            for k in 0..<bins {
                re[k * le + j] = outR[k] * scale
                im[k * le + j] = outI[k] * scale
            }
        }
        return (re, im)
    }

    /// Dall'uscita di `forward` (o del modello) all'onda, lunga `length` campioni.
    func inverse(re: [Float], im: [Float], length: Int) -> [Float] {
        let le = frames(for: length)
        precondition(re.count == bins * le && im.count == bins * le, "spettrogramma della misura sbagliata")
        // Due colonne di silenzio per lato, come in Demucs
        let total = nfft + hop * (le + 3)
        var buf = [Float](repeating: 0, count: total)
        var env = [Float](repeating: 0, count: total)
        var inR = [Float](repeating: 0, count: nfft)
        var inI = [Float](repeating: 0, count: nfft)
        var outR = [Float](repeating: 0, count: nfft)
        var outI = [Float](repeating: 0, count: nfft)
        // irfft divide per nfft, «normalizzato» moltiplica per √nfft
        let scale = 1 / Float(nfft).squareRoot()
        for t in 0..<(le + 4) {
            let start = t * hop
            let j = t - 2
            if j >= 0 && j < le {
                // Spettro completo e simmetrico: la parte immaginaria della frequenza 0 non conta, Nyquist è zero
                inR[0] = re[j]; inI[0] = 0
                inR[bins] = 0; inI[bins] = 0
                for k in 1..<bins {
                    let r = re[k * le + j], i = im[k * le + j]
                    inR[k] = r; inI[k] = i
                    inR[nfft - k] = r; inI[nfft - k] = -i
                }
                inverseDFT.transform(inputReal: inR, inputImaginary: inI, outputReal: &outR, outputImaginary: &outI)
                for n in 0..<nfft { buf[start + n] += outR[n] * scale * window[n] }
            }
            for n in 0..<nfft { env[start + n] += window[n] * window[n] }
        }
        let offset = nfft / 2 + pad
        var out = [Float](repeating: 0, count: length)
        for i in 0..<length {
            let e = env[offset + i]
            out[i] = e > 1e-11 ? buf[offset + i] / e : buf[offset + i]
        }
        return out
    }
}
