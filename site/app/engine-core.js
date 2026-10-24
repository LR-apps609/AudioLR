// ════════════════════════════════════════════════════════════════════
//  AudioLR nel browser: la stessa separazione di «Veloce» nell'app
//  (HTDemucs). La rete gira con ONNX Runtime Web; spettrogramma,
//  normalizzazione e ricucitura dei pezzi sono qui, copia esatta di
//  Sources/Spectrogram.swift e Sources/Separator.swift dell'app.
//  Niente lascia il computer: l'audio resta in questa pagina.
// ════════════════════════════════════════════════════════════════════
(function (root) {
  "use strict";

  // ── FFT complessa (radice 2), in place ──────────────────────────────
  class FFT {
    constructor(n) {
      this.n = n;
      this.rev = new Uint32Array(n);
      const bits = Math.log2(n);
      for (let i = 0; i < n; i++) {
        let r = 0;
        for (let b = 0; b < bits; b++) r |= ((i >> b) & 1) << (bits - 1 - b);
        this.rev[i] = r;
      }
      this.cos = new Float64Array(n / 2);
      this.sin = new Float64Array(n / 2);
      for (let i = 0; i < n / 2; i++) {
        this.cos[i] = Math.cos((2 * Math.PI * i) / n);
        this.sin[i] = -Math.sin((2 * Math.PI * i) / n);
      }
    }
    // Trasformata diretta (non normalizzata). re, im: Float64Array di lunghezza n.
    forward(re, im) {
      const n = this.n, rev = this.rev;
      for (let i = 0; i < n; i++) {
        const j = rev[i];
        if (j > i) {
          let t = re[i]; re[i] = re[j]; re[j] = t;
          t = im[i]; im[i] = im[j]; im[j] = t;
        }
      }
      for (let size = 2; size <= n; size <<= 1) {
        const half = size >> 1, step = n / size;
        for (let start = 0; start < n; start += size) {
          for (let k = 0; k < half; k++) {
            const wr = this.cos[k * step], wi = this.sin[k * step];
            const a = start + k, b = a + half;
            const xr = re[b] * wr - im[b] * wi, xi = re[b] * wi + im[b] * wr;
            re[b] = re[a] - xr; im[b] = im[a] - xi;
            re[a] += xr; im[a] += xi;
          }
        }
      }
    }
    // Trasformata inversa, NON divisa per n (come vDSP nell'app).
    inverse(re, im) {
      for (let i = 0; i < this.n; i++) im[i] = -im[i];
      this.forward(re, im);
      for (let i = 0; i < this.n; i++) im[i] = -im[i];
    }
  }

  // ── Spettrogramma come Demucs: Hann, 4096 punti, passo 1024, normalizzato, bordi riflessi ──
  class Spectrogram {
    constructor(nfft = 4096) {
      this.nfft = nfft;
      this.hop = nfft / 4;
      this.bins = nfft / 2;
      this.pad = (this.hop / 2) * 3;
      this.window = new Float64Array(nfft);
      for (let i = 0; i < nfft; i++) this.window[i] = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / nfft);
      this.fft = new FFT(nfft);
    }
    frames(length) { return Math.ceil(length / this.hop); }

    // Bordi a specchio come PyTorch; se l'onda è più corta del margine, prima silenzio (pad1d di Demucs)
    static reflectPad(x, left, right) {
      let src = x, l = left, r = right;
      const maxPad = Math.max(left, right);
      if (x.length <= maxPad) {
        const extra = maxPad - x.length + 1;
        const extraRight = Math.min(right, extra), extraLeft = extra - extraRight;
        l -= extraLeft; r -= extraRight;
        src = new Float64Array(x.length + extra);
        src.set(x, extraLeft);
      }
      const n = src.length, out = new Float64Array(n + l + r);
      for (let i = 0; i < out.length; i++) {
        let j = i - l;
        if (j < 0) j = -j; else if (j >= n) j = 2 * (n - 1) - j;
        out[i] = src[j];
      }
      return out;
    }

    // Un canale → parte reale e immaginaria, bins × frames (prima la frequenza)
    forward(x) {
      const { nfft, hop, bins } = this;
      const le = this.frames(x.length);
      const a = Spectrogram.reflectPad(x, this.pad, this.pad + le * hop - x.length);
      const b = Spectrogram.reflectPad(a, nfft / 2, nfft / 2);
      const re = new Float32Array(bins * le), im = new Float32Array(bins * le);
      const fr = new Float64Array(nfft), fi = new Float64Array(nfft);
      const scale = 1 / Math.sqrt(nfft);
      for (let j = 0; j < le; j++) {
        const start = (j + 2) * hop; // Demucs scarta le prime due colonne
        for (let n = 0; n < nfft; n++) { fr[n] = b[start + n] * this.window[n]; fi[n] = 0; }
        this.fft.forward(fr, fi);
        for (let k = 0; k < bins; k++) { re[k * le + j] = fr[k] * scale; im[k * le + j] = fi[k] * scale; }
      }
      return { re, im, le };
    }

    // Dallo spettro all'onda lunga `length`
    inverse(re, im, length) {
      const { nfft, hop, bins } = this;
      const le = this.frames(length);
      const total = nfft + hop * (le + 3);
      const buf = new Float64Array(total), env = new Float64Array(total);
      const fr = new Float64Array(nfft), fi = new Float64Array(nfft);
      const scale = 1 / Math.sqrt(nfft);
      for (let t = 0; t < le + 4; t++) {
        const start = t * hop, j = t - 2;
        if (j >= 0 && j < le) {
          fr[0] = re[j]; fi[0] = 0;
          fr[bins] = 0; fi[bins] = 0;
          for (let k = 1; k < bins; k++) {
            const r = re[k * le + j], i = im[k * le + j];
            fr[k] = r; fi[k] = i;
            fr[nfft - k] = r; fi[nfft - k] = -i;
          }
          this.fft.inverse(fr, fi);
          for (let n = 0; n < nfft; n++) buf[start + n] += fr[n] * scale * this.window[n];
        }
        for (let n = 0; n < nfft; n++) env[start + n] += this.window[n] * this.window[n];
      }
      const offset = nfft / 2 + this.pad, out = new Float32Array(length);
      for (let i = 0; i < length; i++) {
        const e = env[offset + i];
        out[i] = e > 1e-11 ? buf[offset + i] / e : buf[offset + i];
      }
      return out;
    }
  }

  // ── Separazione (Separator.swift) ───────────────────────────────────
  function meanStd(x) {
    const n = x.length;
    if (n < 2) return { mean: n ? x[0] : 0, std: 0 };
    let sum = 0;
    for (let i = 0; i < n; i++) sum += x[i];
    const mean = sum / n;
    let sq = 0;
    for (let i = 0; i < n; i++) { const d = x[i] - mean; sq += d * d; }
    return { mean, std: Math.sqrt(sq / (n - 1)) }; // come torch.std (n − 1)
  }

  function offsets(length, segment, overlap) {
    const step = Math.max(1, Math.floor((1 - overlap) * segment));
    const out = [];
    for (let o = 0; o < length; o += step) out.push(o);
    return out;
  }

  function weights(segment) {
    const half = Math.floor(segment / 2), w = new Float32Array(segment);
    for (let i = 0; i < half; i++) w[i] = i + 1;
    for (let i = half; i < segment; i++) w[i] = segment - i;
    let top = 0;
    for (let i = 0; i < segment; i++) top = Math.max(top, w[i]);
    for (let i = 0; i < segment; i++) w[i] /= top;
    return w;
  }

  // Tutta la canzone a media 0 e deviazione 1 (sul mono)
  function normalized(mix) {
    const n = mix[0].length, mono = new Float64Array(n);
    for (let i = 0; i < n; i++) mono[i] = (mix[0][i] + mix[1][i]) / 2;
    const s = meanStd(mono), std = s.std < 1e-8 ? 1 : s.std;
    const norm = mix.map((ch) => { const o = new Float32Array(n); for (let i = 0; i < n; i++) o[i] = (ch[i] - s.mean) / std; return o; });
    return { norm, mean: s.mean, std };
  }

  // Il pezzo che comincia a `offset`; l'ultimo è centrato come in Demucs
  function piece(norm, offset, seg) {
    const length = norm[0].length, chunk = Math.min(seg, length - offset);
    const from = offset - Math.floor((seg - chunk) / 2);
    const out = [new Float32Array(seg), new Float32Array(seg)];
    const lo = Math.max(0, from), hi = Math.min(length, from + seg);
    for (let c = 0; c < 2; c++) for (let i = lo; i < hi; i++) out[c][i - from] = norm[c][i];
    return out;
  }

  // Un pezzo nella rete: runCore(spec, wave) → { spec, wave } (Float32Array), come runSegment nell'app
  async function runSegment(stft, pieceLR, S, runCore) {
    const seg = pieceLR[0].length, le = stft.frames(seg), plane = stft.bins * le;
    const L = stft.forward(pieceLR[0]), R = stft.forward(pieceLR[1]);
    const spec = new Float32Array(4 * plane);
    spec.set(L.re, 0); spec.set(L.im, plane); spec.set(R.re, 2 * plane); spec.set(R.im, 3 * plane);
    const s1 = meanStd(spec), k = 1 / (1e-5 + s1.std);
    for (let i = 0; i < spec.length; i++) spec[i] = (spec[i] - s1.mean) * k;
    const wave = new Float32Array(2 * seg);
    wave.set(pieceLR[0], 0); wave.set(pieceLR[1], seg);
    const s2 = meanStd(wave), kt = 1 / (1e-5 + s2.std);
    for (let i = 0; i < wave.length; i++) wave[i] = (wave[i] - s2.mean) * kt;

    const out = await runCore(spec, wave, le, seg);
    if (out.spec.length !== S * 4 * plane || out.wave.length !== S * 2 * seg) throw new Error("misure inattese dal modello");
    const result = [];
    for (let s = 0; s < S; s++) {
      const channels = [];
      for (let c = 0; c < 2; c++) {
        const base = (s * 4 + c * 2) * plane;
        const re = new Float32Array(plane), im = new Float32Array(plane);
        for (let i = 0; i < plane; i++) {
          re[i] = out.spec[base + i] * s1.std + s1.mean;
          im[i] = out.spec[base + plane + i] * s1.std + s1.mean;
        }
        const x = stft.inverse(re, im, seg);
        const wb = (s * 2 + c) * seg;
        for (let i = 0; i < seg; i++) x[i] += out.wave[wb + i] * s2.std + s2.mean;
        channels.push(x);
      }
      result.push(channels);
    }
    return result;
  }

  // La canzone intera (2 canali, 44,1 kHz) → strumenti × canali
  async function separate(mix, { segment, sources, runCore, onProgress = () => {}, isCancelled = () => false, overlap = 0.25 }) {
    const length = mix[0].length, S = sources.length, stft = new Spectrogram();
    const { norm, mean, std } = normalized(mix);
    const out = Array.from({ length: S }, () => [new Float32Array(length), new Float32Array(length)]);
    const total = new Float32Array(length), w = weights(segment);
    const starts = offsets(length, segment, overlap);
    for (let n = 0; n < starts.length; n++) {
      if (isCancelled()) throw new Error("annullato");
      const offset = starts[n], chunk = Math.min(segment, length - offset), trim = Math.floor((segment - chunk) / 2);
      const result = await runSegment(stft, piece(norm, offset, segment), S, runCore);
      for (let s = 0; s < S; s++) for (let c = 0; c < 2; c++) {
        const r = result[s][c], o = out[s][c];
        for (let i = 0; i < chunk; i++) o[offset + i] += w[i] * r[trim + i];
      }
      for (let i = 0; i < chunk; i++) total[offset + i] += w[i];
      onProgress((n + 1) / starts.length);
    }
    for (let s = 0; s < S; s++) for (let c = 0; c < 2; c++) {
      const o = out[s][c];
      for (let i = 0; i < length; i++) o[i] = (o[i] / total[i]) * std + mean;
    }
    return out;
  }

  // ── WAV a 24 bit ─────────────────────────────────────────────────────
  function wav24(channels, rate = 44100, gain = 1) {
    const n = channels[0].length, ch = channels.length, bytes = n * ch * 3;
    const buf = new ArrayBuffer(44 + bytes), v = new DataView(buf);
    const str = (o, s) => { for (let i = 0; i < s.length; i++) v.setUint8(o + i, s.charCodeAt(i)); };
    str(0, "RIFF"); v.setUint32(4, 36 + bytes, true); str(8, "WAVE"); str(12, "fmt ");
    v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, ch, true);
    v.setUint32(24, rate, true); v.setUint32(28, rate * ch * 3, true); v.setUint16(32, ch * 3, true); v.setUint16(34, 24, true);
    str(36, "data"); v.setUint32(40, bytes, true);
    let o = 44;
    for (let i = 0; i < n; i++) for (let c = 0; c < ch; c++) {
      let s = Math.max(-1, Math.min(1, channels[c][i] * gain));
      let q = Math.round(s * 8388607);
      if (q < 0) q += 16777216;
      v.setUint8(o, q & 255); v.setUint8(o + 1, (q >> 8) & 255); v.setUint8(o + 2, (q >> 16) & 255);
      o += 3;
    }
    return buf;
  }

  // Se una traccia supera il massimo, tutte si abbassano dello stesso tanto (come Stem.safeGain)
  function safeGain(tracks) {
    let top = 0;
    for (const t of tracks) for (const c of t) for (let i = 0; i < c.length; i++) { const a = Math.abs(c[i]); if (a > top) top = a; }
    return top > 0.98 ? 0.98 / top : 1;
  }

  const api = { FFT, Spectrogram, meanStd, offsets, weights, normalized, piece, runSegment, separate, wav24, safeGain };
  root.AudioLREngine = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : globalThis);
