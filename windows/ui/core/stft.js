// ════════════════════════════════════════════════════════════════════
//  STFT come PlainSTFT dell'app (Sources/VoiceRoFormer.swift), che usano
//  tempo, tonalità, battiti e accordi: finestra di Hann periodica, centrata
//  con i bordi riflessi come torch.stft, non normalizzata, nfft/2+1 bande.
//  Nel browser lo spettrogramma intero di una canzone non sta in memoria
//  (8192 punti × 4800 colonne), quindi si consegna una colonna alla volta.
// ════════════════════════════════════════════════════════════════════
(function (root) {
  "use strict";

  // ── FFT complessa, in place, non normalizzata ─────────────────────
  // Radice 2 con due passaggi fusi alla volta (radice 2²): stessi numeri, metà dei giri sulla memoria.
  class FFT {
    constructor(n) {
      if (n < 1 || (n & (n - 1)) !== 0) throw new Error("FFT: la misura deve essere una potenza di 2");
      this.n = n;
      this.rev = new Uint32Array(n);
      const bits = Math.round(Math.log2(n));
      for (let i = 0; i < n; i++) {
        let r = 0;
        for (let b = 0; b < bits; b++) r |= ((i >> b) & 1) << (bits - 1 - b);
        this.rev[i] = r;
      }
      // Fattori di rotazione per passaggio, uno dopo l'altro: per la misura 2h stanno in [h, 2h)
      this.tr = new Float64Array(Math.max(2, n));
      this.ti = new Float64Array(Math.max(2, n));
      for (let size = 2; size <= n; size <<= 1) {
        const half = size >> 1;
        for (let k = 0; k < half; k++) {
          this.tr[half + k] = Math.cos((2 * Math.PI * k) / size);
          this.ti[half + k] = -Math.sin((2 * Math.PI * k) / size);
        }
      }
      this.odd = bits % 2 === 1;
    }
    forward(re, im) {
      const n = this.n, rev = this.rev, tr = this.tr, ti = this.ti;
      for (let i = 0; i < n; i++) {
        const j = rev[i];
        if (j > i) {
          let t = re[i]; re[i] = re[j]; re[j] = t;
          t = im[i]; im[i] = im[j]; im[j] = t;
        }
      }
      let h = 1;
      if (this.odd) {
        // Un passaggio da 2 da solo, se i passaggi sono dispari
        for (let a = 0; a + 1 < n; a += 2) {
          const xr = re[a + 1], xi = im[a + 1];
          re[a + 1] = re[a] - xr; im[a + 1] = im[a] - xi;
          re[a] += xr; im[a] += xi;
        }
        h = 2;
      }
      for (; h * 4 <= n; h *= 4) {
        const q = 4 * h;
        for (let start = 0; start < n; start += q) {
          for (let k = 0; k < h; k++) {
            const w1r = tr[h + k], w1i = ti[h + k], w2r = tr[2 * h + k], w2i = ti[2 * h + k];
            const a0 = start + k, a1 = a0 + h, a2 = a1 + h, a3 = a2 + h;
            // Primo passaggio (misura 2h): (a0, a1) e (a2, a3)
            let br = re[a1], bi = im[a1];
            const t1r = br * w1r - bi * w1i, t1i = br * w1i + bi * w1r;
            br = re[a3]; bi = im[a3];
            const t3r = br * w1r - bi * w1i, t3i = br * w1i + bi * w1r;
            const r0 = re[a0], i0 = im[a0], r2 = re[a2], i2 = im[a2];
            const x0r = r0 + t1r, x0i = i0 + t1i, x1r = r0 - t1r, x1i = i0 - t1i;
            const x2r = r2 + t3r, x2i = i2 + t3i, x3r = r2 - t3r, x3i = i2 - t3i;
            // Secondo passaggio (misura 4h): (x0, x2) con w2, (x1, x3) con w2 · (−i)
            const ur = x2r * w2r - x2i * w2i, ui = x2r * w2i + x2i * w2r;
            const pr = x3r * w2r - x3i * w2i, pi = x3r * w2i + x3i * w2r;
            re[a0] = x0r + ur; im[a0] = x0i + ui; re[a2] = x0r - ur; im[a2] = x0i - ui;
            re[a1] = x1r + pi; im[a1] = x1i - pr; re[a3] = x1r - pi; im[a3] = x1i + pr;
          }
        }
      }
    }
  }

  // ── FFT di un segnale reale: una FFT complessa lunga la metà (due volte più veloce) ──
  class RealFFT {
    constructor(n) {
      this.n = n;
      this.half = new FFT(n / 2);
      this.zr = new Float64Array(n / 2);
      this.zi = new Float64Array(n / 2);
      this.wr = new Float64Array(n / 2 + 1);
      this.wi = new Float64Array(n / 2 + 1);
      for (let k = 0; k <= n / 2; k++) {
        this.wr[k] = Math.cos((2 * Math.PI * k) / n);
        this.wi[k] = -Math.sin((2 * Math.PI * k) / n);
      }
    }
    /// `x` lungo n; scrive le bande 0…n/2 in `re`, `im` (lunghi almeno n/2+1).
    forward(x, re, im) {
      const m = this.n / 2, zr = this.zr, zi = this.zi;
      for (let i = 0; i < m; i++) { zr[i] = x[2 * i]; zi[i] = x[2 * i + 1]; }
      this.half.forward(zr, zi);
      for (let k = 0; k <= m; k++) {
        const a = k % m, b = (m - k) % m;
        // Pari: (Z[k] + Z*[m−k]) / 2, dispari: (Z[k] − Z*[m−k]) / 2i
        const er = (zr[a] + zr[b]) / 2, ei = (zi[a] - zi[b]) / 2;
        const or = (zi[a] + zi[b]) / 2, oi = -(zr[a] - zr[b]) / 2;
        const wr = this.wr[k], wi = this.wi[k];
        re[k] = er + or * wr - oi * wi;
        im[k] = ei + or * wi + oi * wr;
      }
    }
  }

  /// Bordi «a specchio» come in PyTorch; se l'onda è più corta del margine, prima silenzio
  /// (come Spectrogram.reflectPad dell'app).
  function reflectPad(x, left, right) {
    let src = x, l = left, r = right;
    const maxPad = Math.max(left, right);
    if (x.length <= maxPad) {
      const extra = maxPad - x.length + 1;
      const extraRight = Math.min(right, extra), extraLeft = extra - extraRight;
      l -= extraLeft; r -= extraRight;
      src = new Float32Array(x.length + extra);
      src.set(x, extraLeft);
    }
    const n = src.length;
    const out = new Float32Array(n + l + r);
    for (let i = 0; i < out.length; i++) {
      let j = i - l;
      if (j < 0) j = -j; else if (j >= n) j = 2 * (n - 1) - j;
      out[i] = src[j];
    }
    return out;
  }

  const cache = new Map();

  class PlainSTFT {
    constructor(nfft = 2048, hop = 441) {
      this.nfft = nfft;
      this.hop = hop;
      this.bins = nfft / 2 + 1;
      this.window = new Float64Array(nfft);
      for (let i = 0; i < nfft; i++) this.window[i] = Math.fround(0.5 - 0.5 * Math.cos((2 * Math.PI * i) / nfft));
      this.fft = new RealFFT(nfft);
      this.frame = new Float64Array(nfft);
      this.re = new Float64Array(this.bins);
      this.im = new Float64Array(this.bins);
      this.mag = new Float64Array(this.bins);
    }
    /// Una STFT per misura, riusata (finestra e tabelle si preparano una volta).
    static shared(nfft, hop) {
      const k = nfft + ":" + hop;
      if (!cache.has(k)) cache.set(k, new PlainSTFT(nfft, hop));
      return cache.get(k);
    }

    frames(length) { return 1 + Math.floor(length / this.hop); }

    /// Chiama `each(t, re, im)` per ogni colonna; i vettori si riusano, vanno letti subito.
    columns(x, each) {
      const nfft = this.nfft, half = nfft / 2, hop = this.hop, w = this.window, frame = this.frame;
      const T = this.frames(x.length), n = x.length;
      // Onde cortissime: il bordo segue pad1d, si prepara tutto (sono pochi campioni)
      const padded = n <= half ? reflectPad(x, half, half) : null;
      const plen = n + nfft;
      for (let t = 0; t < T; t++) {
        const s = t * hop;
        if (padded) {
          for (let i = 0; i < nfft; i++) frame[i] = (s + i < padded.length ? padded[s + i] : 0) * w[i];
        } else if (s >= half && s + nfft - half <= n) {
          const o = s - half;
          for (let i = 0; i < nfft; i++) frame[i] = x[o + i] * w[i];
        } else {
          for (let i = 0; i < nfft; i++) {
            const p = s + i;
            if (p >= plen) { frame[i] = 0; continue; }
            let j = p - half;
            if (j < 0) j = -j; else if (j >= n) j = 2 * (n - 1) - j;
            frame[i] = x[j] * w[i];
          }
        }
        this.fft.forward(frame, this.re, this.im);
        each(t, this.re, this.im);
      }
      return T;
    }

    /// Come `columns`, ma con l'ampiezza di ogni banda (|z|).
    magnitudes(x, each) {
      const F = this.bins, mag = this.mag;
      return this.columns(x, (t, re, im) => {
        for (let f = 0; f < F; f++) mag[f] = Math.sqrt(re[f] * re[f] + im[f] * im[f]);
        each(t, mag);
      });
    }

    /// Spettrogramma intero come in Swift (`bins × frames`, prima la frequenza): solo per onde corte.
    forward(x) {
      const T = this.frames(x.length), F = this.bins;
      const re = new Float32Array(F * T), im = new Float32Array(F * T);
      this.columns(x, (t, r, i) => {
        for (let k = 0; k < F; k++) { re[k * T + t] = r[k]; im[k * T + t] = i[k]; }
      });
      return { re, im };
    }
  }

  /// Arrotondamento come `.rounded()` di Swift: i mezzi si allontanano dallo zero.
  function round(x) { return x < 0 ? -Math.floor(-x + 0.5) : Math.floor(x + 0.5); }

  /// La classe di nota (0 = Do … 11 = Si) di ogni banda tra `low` e `high` Hz; −1 fuori.
  function pitchClasses(fft, rate, low, high) {
    const F = fft / 2 + 1, pc = new Int8Array(F).fill(-1);
    for (let f = 1; f < F; f++) {
      const hz = (f * rate) / fft;
      if (!(hz >= low && hz <= high)) continue;
      pc[f] = ((round(69 + 12 * Math.log2(hz / 440)) % 12) + 12) % 12;
    }
    return pc;
  }

  const api = { FFT, RealFFT, PlainSTFT, reflectPad, round, pitchClasses };
  root.IsoLR = root.IsoLR || {};
  root.IsoLR.STFT = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : globalThis);
