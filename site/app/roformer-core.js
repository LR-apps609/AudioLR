// ════════════════════════════════════════════════════════════════════
//  AudioLR per Windows: i modelli RoFormer (Massima e Studio), copia
//  esatta di Sources/VoiceRoFormer.swift. La rete gira con ONNX Runtime
//  (scheda grafica o processore); qui ci sono STFT, raccolta delle
//  bande, maschere per ogni strumento, iSTFT e ricucitura dei pezzi.
//  Tools/convert_roformer.py ne contiene la copia in Python, confrontata
//  con il modello originale: se qui cambia qualcosa, va cambiato anche lì.
// ════════════════════════════════════════════════════════════════════
(function (root) {
  "use strict";
  const FFT = (root.AudioLREngine || (typeof require !== "undefined" ? require("./engine-core.js") : null)).FFT;

  // ── STFT e iSTFT come torch.stft/istft (Hann, centrate con riflessione, non normalizzate) ──
  class PlainSTFT {
    constructor(nfft = 2048, hop = 441) {
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

    // Un canale → parte reale e immaginaria, bins × frames (prima la frequenza)
    forward(x) {
      const { nfft, hop, bins } = this, T = this.frames(x.length);
      const xp = PlainSTFT.reflectPad(x, nfft / 2);
      const re = new Float32Array(bins * T), im = new Float32Array(bins * T);
      const fr = new Float64Array(nfft), fi = new Float64Array(nfft);
      for (let t = 0; t < T; t++) {
        const s = t * hop;
        for (let n = 0; n < nfft; n++) { fr[n] = (s + n < xp.length ? xp[s + n] : 0) * this.window[n]; fi[n] = 0; }
        this.fft.forward(fr, fi);
        for (let k = 0; k < bins; k++) { re[k * T + t] = fr[k]; im[k * T + t] = fi[k]; }
      }
      return { re, im, T };
    }

    // Dallo spettro (bins × frames) all'onda lunga `length`
    inverse(re, im, T, length) {
      const { nfft, hop } = this, half = nfft / 2;
      const total = nfft + hop * (T - 1);
      const buf = new Float64Array(total), env = new Float64Array(total);
      const fr = new Float64Array(nfft), fi = new Float64Array(nfft);
      for (let t = 0; t < T; t++) {
        fr[0] = re[t]; fi[0] = 0;
        fr[half] = re[half * T + t]; fi[half] = 0;
        for (let k = 1; k < half; k++) {
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
  // runNet(x: Float32Array (1, T, FS·2)) → Promise<Float32Array> maschere (1, S, T, FS·2)
  async function runChunkAll(piece, cfg, stft, runNet) {
    const T = cfg.frames, F = stft.bins, FI = cfg.freq_indices, FS = FI.length, S = Math.max(1, cfg.sources.length);
    const z = piece.map((ch) => stft.forward(ch));
    if (z[0].T !== T) throw new Error("pezzo della misura sbagliata");
    const x = new Float32Array(T * FS * 2);
    for (let j = 0; j < FS; j++) {
      const g = FI[j], f = g >> 1, s = g & 1, base = f * T, zr = z[s].re, zi = z[s].im;
      for (let t = 0; t < T; t++) { x[t * FS * 2 + j * 2] = zr[base + t]; x[t * FS * 2 + j * 2 + 1] = zi[base + t]; }
    }
    const mask = await runNet(x);
    const per = T * FS * 2;
    if (mask.length !== per * S) throw new Error("il modello ha risposto con misure inattese");
    const all = [];
    for (let k = 0; k < S; k++) {
      const o = k * per;
      // Le bande si sovrappongono: si sommano le maschere per frequenza e si fa la media
      const sumR = new Float32Array(2 * F * T), sumI = new Float32Array(2 * F * T);
      for (let j = 0; j < FS; j++) {
        const g = FI[j];
        for (let t = 0; t < T; t++) {
          sumR[g * T + t] += mask[o + t * FS * 2 + j * 2];
          sumI[g * T + t] += mask[o + t * FS * 2 + j * 2 + 1];
        }
      }
      const out = [];
      for (let s = 0; s < 2; s++) {
        const re = new Float32Array(F * T), im = new Float32Array(F * T), zr = z[s].re, zi = z[s].im;
        for (let f = 0; f < F; f++) {
          const g = f * 2 + s, d = Math.max(cfg.num_bands_per_freq[f], 1e-8);
          for (let t = 0; t < T; t++) {
            const mr = sumR[g * T + t] / d, mi = sumI[g * T + t] / d;
            const ar = zr[f * T + t], ai = zi[f * T + t];
            re[f * T + t] = ar * mr - ai * mi;
            im[f * T + t] = ar * mi + ai * mr;
          }
        }
        out.push(stft.inverse(re, im, T, piece[s].length));
      }
      all.push(out);
    }
    return all;
  }

  function hamming(n) {
    const w = new Float32Array(n);
    if (n === 1) { w[0] = 1; return w; }
    for (let i = 0; i < n; i++) w[i] = 0.54 - 0.46 * Math.cos((2 * Math.PI * i) / (n - 1));
    return w;
  }

  // Nessuno strumento può essere più forte del pezzo, né contenere numeri non validi
  function plausible(piece, stems) {
    let a = 0;
    for (let c = 0; c < 2; c++) for (let i = 0; i < piece[c].length; i++) a += piece[c][i] * piece[c][i];
    if (a < 1e-6 * piece[0].length) return true;
    for (const st of stems) {
      let b = 0;
      for (let c = 0; c < 2; c++) for (let i = 0; i < st[c].length; i++) { const v = st[c][i]; if (!Number.isFinite(v)) return false; b += v * v; }
      if (b / a >= 2) return false;
    }
    return true;
  }

  // Tutta la canzone a pezzi sovrapposti (overlap 2: ogni punto coperto da due pezzi), ricuciti con Hamming
  async function separateAll(mix, cfg, runNet, { overlap = 2, onProgress = () => {}, isCancelled = () => false } = {}) {
    const stft = new PlainSTFT(cfg.n_fft, cfg.hop), chunk = cfg.chunk, S = Math.max(1, cfg.sources.length);
    const length = mix[0].length, step = Math.max(1, Math.round(chunk / Math.max(overlap, 1)));
    const w = hamming(chunk);
    const out = Array.from({ length: S }, () => [new Float32Array(length), new Float32Array(length)]);
    const count = new Float32Array(length);
    const starts = [];
    for (let s = 0; s < length; s += step) starts.push(s);
    for (let n = 0; n < starts.length; n++) {
      if (isCancelled()) throw new Error("annullato");
      const start = starts[n], len = Math.min(chunk, length - start);
      const piece = [new Float32Array(chunk), new Float32Array(chunk)];
      for (let c = 0; c < 2; c++) piece[c].set(mix[c].subarray(start, start + len));
      const v = await runChunkAll(piece, cfg, stft, runNet);
      if (!plausible(piece, v)) throw new Error("risultato non plausibile");
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

  const api = { PlainSTFT, runChunkAll, separateAll, hamming, plausible };
  root.AudioLRRoFormer = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : globalThis);
