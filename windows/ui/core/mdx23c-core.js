// ════════════════════════════════════════════════════════════════════
//  IsoLR per Windows: i modelli MDX23C (la batteria divisa, «DrumSep»:
//  cassa, rullante, tom, charleston, ride, crash), copia esatta di
//  Sources/DrumSplit.swift e di RoFormer.stitch (Sources/VoiceRoFormer.swift).
//  La rete gira con ONNX Runtime (scheda grafica o processore); qui ci
//  sono STFT, iSTFT e ricucitura dei pezzi.
//  Tools/convert_mdx23c.py ne contiene la copia in Python, confrontata
//  con il modello originale: se qui cambia qualcosa, va cambiato anche lì.
//
//  Il modello (BatteriaDrumSep.onnx, release «modelli-windows») e la sua descrizione (BatteriaDrumSep.json):
//    ingresso  «spec»     float32 (1, 4, dim_f, frames)   sinistro re, sinistro im, destro re, destro im
//    uscita    «spec_out» float32 (1, S·4, dim_f, frames) per ogni strumento, nello stesso ordine
//  STFT: n_fft punti, passo hop, finestra di Hann, centrata con riflessione, non normalizzata (torch.stft);
//  si tengono le prime dim_f frequenze, quelle sopra restano a zero nella iSTFT.
//  Un pezzo è lungo `chunk` = hop·(frames − 1) campioni; la canzone si lavora a pezzi sovrapposti
//  (overlap 4) ricuciti con una finestra di Hamming.
// ════════════════════════════════════════════════════════════════════
(function (root) {
  "use strict";

  // ── FFT complessa radix-2 (come engine-core.js) ──
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
    // Trasformata diretta, non normalizzata
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
    // Trasformata inversa, NON divisa per n
    inverse(re, im) {
      for (let i = 0; i < this.n; i++) im[i] = -im[i];
      this.forward(re, im);
      for (let i = 0; i < this.n; i++) im[i] = -im[i];
    }
  }

  // ── STFT e iSTFT come torch.stft/istft (Hann, centrate con riflessione, non normalizzate) ──
  class PlainSTFT {
    constructor(nfft = 2048, hop = 512) {
      this.nfft = nfft;
      this.hop = hop;
      this.bins = nfft / 2 + 1;
      this.window = new Float64Array(nfft);
      for (let i = 0; i < nfft; i++) this.window[i] = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / nfft);
      this.fft = new FFT(nfft);
    }
    frames(length) { return 1 + Math.floor(length / this.hop); }

    static reflectPad(x, pad) {
      const n = x.length, out = new Float64Array(n + 2 * pad);
      for (let i = 0; i < out.length; i++) {
        let j = i - pad;
        if (j < 0) j = -j; else if (j >= n) j = 2 * (n - 1) - j;
        out[i] = x[Math.max(0, Math.min(n - 1, j))];
      }
      return out;
    }

    // Un canale → parte reale e immaginaria delle prime `keep` frequenze, keep × frames (prima la frequenza)
    forward(x, keep = this.bins) {
      const { nfft, hop } = this, T = this.frames(x.length);
      const xp = PlainSTFT.reflectPad(x, nfft / 2);
      const re = new Float32Array(keep * T), im = new Float32Array(keep * T);
      const fr = new Float64Array(nfft), fi = new Float64Array(nfft);
      for (let t = 0; t < T; t++) {
        const s = t * hop;
        for (let n = 0; n < nfft; n++) { fr[n] = (s + n < xp.length ? xp[s + n] : 0) * this.window[n]; fi[n] = 0; }
        this.fft.forward(fr, fi);
        for (let k = 0; k < keep; k++) { re[k * T + t] = fr[k]; im[k * T + t] = fi[k]; }
      }
      return { re, im, T };
    }

    // Dallo spettro (rows × frames, rows ≤ bins: le frequenze mancanti sono zero) all'onda lunga `length`
    inverse(re, im, T, length, rows = this.bins) {
      const { nfft, hop } = this, half = nfft / 2;
      const total = nfft + hop * (T - 1);
      const buf = new Float64Array(total), env = new Float64Array(total);
      const fr = new Float64Array(nfft), fi = new Float64Array(nfft);
      const get = (a, k, t) => (k < rows ? a[k * T + t] : 0);
      for (let t = 0; t < T; t++) {
        fr.fill(0); fi.fill(0);
        fr[0] = get(re, 0, t);
        fr[half] = get(re, half, t);
        for (let k = 1; k < Math.min(half, rows); k++) {
          const r = re[k * T + t], i = im[k * T + t];
          fr[k] = r; fi[k] = i; fr[nfft - k] = r; fi[nfft - k] = -i;
        }
        this.fft.inverse(fr, fi);
        const s = t * hop;
        for (let n = 0; n < nfft; n++) {
          buf[s + n] += (fr[n] / nfft) * this.window[n];
          env[s + n] += this.window[n] * this.window[n];
        }
      }
      const out = new Float32Array(length);
      for (let i = 0; i < length; i++) {
        const j = half + i;
        if (j >= total) break;
        out[i] = env[j] > 1e-11 ? buf[j] / env[j] : buf[j];
      }
      return out;
    }
  }

  // Un pezzo (2 canali × chunk) → ogni strumento (strumento × canale × campione).
  // runNet(spec: Float32Array (1, 4, dim_f, frames)) → Promise<Float32Array> spec_out (1, S·4, dim_f, frames)
  async function runChunk(piece, cfg, stft, runNet) {
    const T = cfg.frames, DF = cfg.dim_f, S = Math.max(1, cfg.sources.length);
    const z = piece.map((ch) => stft.forward(ch, DF));
    if (z[0].T !== T) throw new Error("pezzo della misura sbagliata");
    const x = new Float32Array(4 * DF * T);
    for (let c = 0; c < 2; c++) {
      x.set(z[c].re, (c * 2) * DF * T);
      x.set(z[c].im, (c * 2 + 1) * DF * T);
    }
    const y = await runNet(x);
    if (y.length !== S * 4 * DF * T) throw new Error("il modello della batteria ha risposto con misure inattese");
    const all = [];
    for (let k = 0; k < S; k++) {
      const stem = [];
      for (let c = 0; c < 2; c++) {
        const r0 = (k * 4 + c * 2) * DF * T, i0 = (k * 4 + c * 2 + 1) * DF * T;
        stem.push(stft.inverse(y.subarray(r0, r0 + DF * T), y.subarray(i0, i0 + DF * T), T, piece[c].length, DF));
      }
      all.push(stem);
    }
    return all;
  }

  function hamming(n) {
    const w = new Float32Array(n);
    if (n === 1) { w[0] = 1; return w; }
    for (let i = 0; i < n; i++) w[i] = 0.54 - 0.46 * Math.cos((2 * Math.PI * i) / (n - 1));
    return w;
  }

  // Nessuno strumento può essere più forte del pezzo, né contenere numeri non validi.
  // `quiet`: energia media per campione sotto la quale il pezzo è troppo piano per giudicare.
  function plausible(piece, stems, quiet = 1e-6) {
    let a = 0;
    for (let c = 0; c < 2; c++) for (let i = 0; i < piece[c].length; i++) a += piece[c][i] * piece[c][i];
    for (const st of stems) {
      let b = 0;
      for (let c = 0; c < 2; c++) for (let i = 0; i < st[c].length; i++) { const v = st[c][i]; if (!Number.isFinite(v)) return false; b += v * v; }
      if (a >= quiet * piece[0].length && b / a >= 2) return false;
    }
    return true;
  }

  // Tutta la traccia a pezzi sovrapposti (overlap 4: ogni punto coperto da quattro pezzi), ricuciti con Hamming
  async function separate(mix, cfg, runNet, { overlap = cfg.overlap || 4, onProgress = () => {}, isCancelled = () => false } = {}) {
    const stft = new PlainSTFT(cfg.n_fft, cfg.hop), chunk = cfg.chunk, S = Math.max(1, cfg.sources.length);
    const length = mix[0].length, step = Math.max(1, Math.round(chunk / Math.max(overlap, 1)));
    const w = hamming(chunk);
    const out = Array.from({ length: S }, () => [new Float32Array(length), new Float32Array(length)]);
    const count = new Float32Array(length);
    let energy = 0;
    for (let c = 0; c < 2; c++) for (let i = 0; i < length; i++) energy += mix[c][i] * mix[c][i];
    const quiet = Math.max(1e-6, (1e-3 * energy) / Math.max(1, 2 * length));
    const starts = [];
    for (let s = 0; s < length; s += step) starts.push(s);
    for (let n = 0; n < starts.length; n++) {
      if (isCancelled()) throw new Error("annullato");
      const start = starts[n], len = Math.min(chunk, length - start);
      const piece = [new Float32Array(chunk), new Float32Array(chunk)];
      for (let c = 0; c < 2; c++) piece[c].set(mix[c].subarray(start, start + len));
      const v = await runChunk(piece, cfg, stft, runNet);
      if (!plausible(piece, v, quiet)) throw new Error("risultato non plausibile");
      for (let k = 0; k < S; k++) for (let c = 0; c < 2; c++) {
        const o = out[k][c], r = v[k][c];
        for (let i = 0; i < len; i++) o[start + i] += r[i] * w[i];
      }
      for (let i = 0; i < len; i++) count[start + i] += w[i];
      onProgress((n + 1) / starts.length);
    }
    for (let i = 0; i < length; i++) count[i] = 1 / Math.max(count[i], 1e-10);
    for (let k = 0; k < S; k++) for (let c = 0; c < 2; c++) { const o = out[k][c]; for (let i = 0; i < length; i++) o[i] *= count[i]; }
    return out;
  }

  // Con ONNX Runtime (web o node): la funzione che fa girare la rete su un pezzo
  function onnxRunner(ort, session, cfg) {
    const shape = [1, 4, cfg.dim_f, cfg.frames];
    return async (x) => (await session.run({ spec: new ort.Tensor("float32", x, shape) })).spec_out.data;
  }

  const api = { FFT, PlainSTFT, runChunk, separate, hamming, plausible, onnxRunner };
  root.IsoLRMDX23C = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : globalThis);
