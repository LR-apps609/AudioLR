// ════════════════════════════════════════════════════════════════════
//  «Pulisci la voce», come Sources/Cleanup.swift sul Mac:
//  Togli rumore (DeepFilterNet3 di Hendrik Schröter, MIT o Apache 2.0) e
//  Togli riverbero (un calcolo di IsoLR, senza modello). Gli stessi numeri
//  di Tools/deepfilter_ref.py e Tools/dereverb_ref.py.
// ════════════════════════════════════════════════════════════════════
(function (root) {
  "use strict";
  const STFT = (root.IsoLR && root.IsoLR.STFT) || (typeof require !== "undefined" ? require("./stft.js") : null);

  /** FFT complessa di n = 2^k · m (m dispari e piccolo, es. 960 = 64 · 15), in place, non normalizzata. */
  class MixedFFT {
    constructor(n) {
      let m = n;
      while (m % 2 === 0) m /= 2;
      this.n = n; this.m = m; this.p = n / m;
      this.fft = new STFT.FFT(this.p);
      this.wr = new Float64Array(n); this.wi = new Float64Array(n);
      for (let j = 0; j < n; j++) { this.wr[j] = Math.cos((2 * Math.PI * j) / n); this.wi[j] = -Math.sin((2 * Math.PI * j) / n); }
      this.sr = Array.from({ length: m }, () => new Float64Array(this.p));
      this.si = Array.from({ length: m }, () => new Float64Array(this.p));
    }
    forward(re, im) {
      const { n, m, p } = this;
      if (m === 1) { this.fft.forward(re, im); return; }
      for (let r = 0; r < m; r++) {
        const a = this.sr[r], b = this.si[r];
        for (let q = 0; q < p; q++) { a[q] = re[m * q + r]; b[q] = im[m * q + r]; }
        this.fft.forward(a, b);
      }
      for (let k = 0; k < n; k++) {
        const kk = k % p;
        let xr = 0, xi = 0;
        for (let r = 0; r < m; r++) {
          const j = (r * k) % n, cr = this.wr[j], ci = this.wi[j], ar = this.sr[r][kk], ai = this.si[r][kk];
          xr += ar * cr - ai * ci; xi += ar * ci + ai * cr;
        }
        re[k] = xr; im[k] = xi;
      }
    }
  }

  /** Segnale reale: avanti verso le righe 0…n/2, indietro alla somma intera (come irfft · n). */
  class RealFFT {
    constructor(n) {
      this.n = n; this.f = new MixedFFT(n);
      this.zr = new Float64Array(n); this.zi = new Float64Array(n);
    }
    forward(x, re, im) {
      const n = this.n, zr = this.zr, zi = this.zi;
      for (let i = 0; i < n; i++) { zr[i] = x[i]; zi[i] = 0; }
      this.f.forward(zr, zi);
      for (let k = 0; k <= n / 2; k++) { re[k] = zr[k]; im[k] = zi[k]; }
    }
    inverse(re, im, out) {
      const n = this.n, h = n / 2, zr = this.zr, zi = this.zi;
      // Indietro = coniugato dell'avanti del coniugato
      zr[0] = re[0]; zi[0] = 0; zr[h] = re[h]; zi[h] = 0;
      for (let k = 1; k < h; k++) { zr[k] = re[k]; zi[k] = -im[k]; zr[n - k] = re[k]; zi[n - k] = im[k]; }
      this.f.forward(zr, zi);
      for (let i = 0; i < n; i++) out[i] = zr[i];
    }
  }

  // ── Togli rumore ──────────────────────────────────────────────────

  /**
   * Una traccia mono a 48 kHz → la stessa senza rumore. `net(fe, fs)` è la rete (ONNX), asincrona:
   * fe Float32Array [1,1,F,32], fs [1,2,F,96] → { m: [1,1,F,32], coefs: [1,F,96,10] }.
   */
  async function denoise(x, cfg, net, opts = {}) {
    const N = cfg.fft, H = cfg.hop, B = N / 2 + 1, E = cfg.nb_erb, D = cfg.nb_df, O = cfg.order, a = cfg.alpha;
    const onProgress = opts.onProgress || (() => {}), isCancelled = opts.isCancelled || (() => false);
    const n = x.length, xp = new Float32Array(n + N);
    xp.set(x);
    const T = Math.floor(xp.length / H);
    const half = N / 2, win = new Float32Array(N);
    for (let i = 0; i < N; i++) { const s = Math.sin((0.5 * Math.PI * (i + 0.5)) / half); win[i] = Math.sin(0.5 * Math.PI * s * s); }
    const fft = new RealFFT(N);
    const sr = new Float32Array(T * B), si = new Float32Array(T * B);
    const buf = new Float64Array(N), re = new Float64Array(B), im = new Float64Array(B);
    const norm = 1 / ((N * N) / (2 * H));
    for (let t = 0; t < T; t++) {
      for (let i = 0; i < N - H; i++) buf[i] = (t > 0 ? xp[(t - 1) * H + i] : 0) * win[i];
      for (let i = 0; i < H; i++) buf[N - H + i] = xp[t * H + i] * win[N - H + i];
      fft.forward(buf, re, im);
      for (let k = 0; k < B; k++) { sr[t * B + k] = re[k] * norm; si[t * B + k] = im[k] * norm; }
    }
    // Le caratteristiche
    const erb = new Float32Array(T * E), lowR = new Float32Array(T * D), lowI = new Float32Array(T * D);
    const s = new Float32Array(E), u = new Float32Array(D);
    for (let b = 0; b < E; b++) s[b] = -60 + b * (-30 / (E - 1));
    for (let f = 0; f < D; f++) u[f] = 0.001 + f * (-0.0009 / (D - 1));
    for (let t = 0; t < T; t++) {
      let k = 0;
      for (let b = 0; b < E; b++) {
        const w = cfg.widths[b];
        let sum = 0;
        for (let j = 0; j < w; j++) { const r = sr[t * B + k + j], i = si[t * B + k + j]; sum += r * r + i * i; }
        k += w;
        const e = Math.fround(Math.log10(Math.fround(sum / w) + 1e-10) * 10);
        s[b] = e * (1 - a) + s[b] * a;
        erb[t * E + b] = (e - s[b]) / 40;
      }
      for (let f = 0; f < D; f++) {
        const r = sr[t * B + f], i = si[t * B + f];
        u[f] = Math.sqrt(r * r + i * i) * (1 - a) + u[f] * a;
        const q = Math.sqrt(u[f]);
        lowR[t * D + f] = r / q; lowI[t * D + f] = i / q;
      }
    }
    // La rete a pezzi; ogni pezzo si applica e si ricostruisce subito
    const F = cfg.frames, back = O - 1 - cfg.lookahead;
    const band = new Int32Array(B);
    for (let b = 0, k = 0; b < E; b++) for (let j = 0; j < cfg.widths[b]; j++) band[k++] = b;
    const y = new Float32Array(T * H), mem = new Float64Array(N - H), frame = new Float64Array(N);
    const orr = new Float64Array(B), oii = new Float64Array(B);
    let start = 0;
    while (start < T) {
      if (isCancelled()) throw new Error("annullato");
      const a0 = Math.max(0, start - cfg.ctx);
      const fe = new Float32Array(F * E), fs = new Float32Array(2 * F * D);
      for (let i = 0; i < F; i++) {
        const t = a0 + i;
        if (t >= T) break;
        fe.set(erb.subarray(t * E, t * E + E), i * E);
        fs.set(lowR.subarray(t * D, t * D + D), i * D);
        fs.set(lowI.subarray(t * D, t * D + D), F * D + i * D);
      }
      const { m, coefs: c } = await net(fe, fs);
      const end = Math.min(a0 + F - cfg.ctx, T);
      for (let t = start; t < end; t++) {
        const i = t - a0;
        for (let k = 0; k < B; k++) { const g = m[i * E + band[k]]; orr[k] = sr[t * B + k] * g; oii[k] = si[t * B + k] * g; }
        for (let f = 0; f < D; f++) {
          let r = 0, q = 0;
          for (let o = 0; o < O; o++) {
            const tt = t + o - back;
            if (tt < 0 || tt >= T) continue;
            const xr = sr[tt * B + f], xi = si[tt * B + f], j = (i * D + f) * O * 2 + 2 * o, cr = c[j], ci = c[j + 1];
            r += xr * cr - xi * ci; q += xr * ci + xi * cr;
          }
          orr[f] = r; oii[f] = q;
        }
        fft.inverse(orr, oii, frame);
        for (let j = 0; j < N; j++) frame[j] *= win[j];
        for (let j = 0; j < H; j++) y[t * H + j] = frame[j] + mem[j];
        for (let j = 0; j < N - H; j++) mem[j] = frame[H + j];
      }
      start = end;
      onProgress(start / T);
    }
    const d = N - H;
    return y.slice(d, d + n);
  }

  // ── Togli riverbero ───────────────────────────────────────────────

  const DR = { N: 2048, H: 512, delay: 10, t60: 2.0, r0: 1.3, r1: 2.2, floorDB: -18, fw: 3, smooth: 0.85 };

  /** Tracce (1 o 2) a 44,1 kHz → stesse tracce senza la coda del riverbero (stesso guadagno sui canali). */
  function dereverb(channels, opts = {}) {
    const { N, H, delay, t60, r0, r1, floorDB, fw, smooth } = DR;
    const onProgress = opts.onProgress || (() => {}), isCancelled = opts.isCancelled || (() => false);
    const n = channels[0].length, B = N / 2 + 1, T = Math.floor((n + N) / H) + 1;
    const win = new Float32Array(N);
    for (let i = 0; i < N; i++) win[i] = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / N);
    const fft = new RealFFT(N), frame = new Float64Array(N), re = new Float64Array(B), im = new Float64Array(B);
    const load = (x, t) => {
      const o = t * H - N / 2;
      for (let i = 0; i < N; i++) { const j = o + i; frame[i] = j >= 0 && j < n ? x[j] * win[i] : 0; }
    };
    const p = new Float32Array(T * B);
    for (const x of channels) {
      if (isCancelled()) throw new Error("annullato");
      for (let t = 0; t < T; t++) {
        load(x, t); fft.forward(frame, re, im);
        for (let k = 0; k < B; k++) p[t * B + k] += re[k] * re[k] + im[k] * im[k];
      }
    }
    onProgress(0.3);
    const row = new Float32Array(B);
    let total = 0;
    for (let t = 0; t < T; t++) {
      for (let k = 0; k < B; k++) {
        const a = Math.max(0, k - fw), b = Math.min(B, k + fw + 1);
        let sum = 0;
        for (let j = a; j < b; j++) sum += p[t * B + j];
        row[k] = sum / (b - a);
      }
      for (let k = 0; k < B; k++) {
        const v = t > 0 ? smooth * p[(t - 1) * B + k] + (1 - smooth) * row[k] : row[k];
        p[t * B + k] = v; total += v;
      }
    }
    const eps = 1e-10 + (1e-8 * total) / (T * B);
    const dec = Math.exp((-2 * ((3 * Math.log(10)) / t60) * delay * H) / 44100);
    const floor = Math.pow(10, floorDB / 20);
    const g = new Float32Array(T * B), prev = new Float32Array(B).fill(1);
    for (let t = 0; t < T; t++) {
      for (let k = 0; k < B; k++) {
        const late = t >= delay ? dec * p[(t - delay) * B + k] : 0;
        const r = p[t * B + k] / (late + eps);
        let s = Math.min(Math.max((r - r0) / (r1 - r0), 0), 1);
        s = s * s * (3 - 2 * s);
        const v = floor + (1 - floor) * s;
        prev[k] = Math.max(v, 0.5 * prev[k] + 0.5 * v);
        g[t * B + k] = prev[k];
      }
    }
    onProgress(0.5);
    let nw = 0;
    for (let i = 0; i < N; i++) nw += win[i] * win[i];
    nw /= H;
    return channels.map((x, ci) => {
      if (isCancelled()) throw new Error("annullato");
      const out = new Float64Array((T - 1) * H + N);
      for (let t = 0; t < T; t++) {
        load(x, t); fft.forward(frame, re, im);
        for (let k = 0; k < B; k++) { re[k] *= g[t * B + k]; im[k] *= g[t * B + k]; }
        fft.inverse(re, im, frame);
        for (let i = 0; i < N; i++) out[t * H + i] += (frame[i] / N) * win[i];
      }
      const res = new Float32Array(n);
      for (let i = 0; i < n; i++) res[i] = out[N / 2 + i] / nw;
      onProgress(0.5 + (0.5 * (ci + 1)) / channels.length);
      return res;
    });
  }

  const api = { MixedFFT, RealFFT, denoise, dereverb, DR };
  root.IsoLR = root.IsoLR || {};
  root.IsoLR.Cleanup = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : globalThis);
