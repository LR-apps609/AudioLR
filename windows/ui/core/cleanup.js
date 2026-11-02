// ════════════════════════════════════════════════════════════════════
//  «Pulisci la voce», come Sources/Cleanup.swift sul Mac: Togli rumore e
//  Togli riverbero, due calcoli di IsoLR senza modelli (niente da scaricare).
//  Gli stessi numeri di Tools/denoise_ref.py e Tools/dereverb_ref.py.
// ════════════════════════════════════════════════════════════════════
(function (root) {
  "use strict";
  const STFT = (root.IsoLR && root.IsoLR.STFT) || (typeof require !== "undefined" ? require("./stft.js") : null);

  /** Segnale reale di n punti (potenza di 2): avanti verso le righe 0…n/2, indietro alla somma intera (irfft · n). */
  class RealFFT {
    constructor(n) {
      this.n = n; this.f = new STFT.FFT(n);
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

  // ── Lo spettro comune: finestra di Hann di 2048 punti ogni 512, stesso guadagno per i canali ──
  const N = 2048, H = 512;

  /** Tracce (1 o 2) a 44,1 kHz; `gains(p, T, B)` dall'energia (somma dei canali, T·B) al guadagno (T·B). */
  function spectralGain(channels, gains, opts = {}) {
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
    const g = gains(p, T, B);
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

  /** L'energia media sulle righe vicine (±fw) e nel tempo (smooth), in un array nuovo. */
  function smoothed(p, T, B, fw, smooth) {
    const q = new Float32Array(T * B), row = new Float32Array(B);
    for (let t = 0; t < T; t++) {
      for (let k = 0; k < B; k++) {
        const a = Math.max(0, k - fw), b = Math.min(B, k + fw + 1);
        let sum = 0;
        for (let j = a; j < b; j++) sum += p[t * B + j];
        row[k] = sum / (b - a);
      }
      for (let k = 0; k < B; k++) q[t * B + k] = t > 0 ? smooth * q[(t - 1) * B + k] + (1 - smooth) * row[k] : row[k];
    }
    return q;
  }

  // ── Togli rumore ──────────────────────────────────────────────────

  const DN = { quiet: 0.1, over: 2.0, floorDB: -20, fw: 2, smooth: 0.6, release: 0.7, silent: 0.05, trust: [12, 20] };

  /** Il guadagno del «noise gate» spettrale (denoise_ref.gains). */
  function denoiseGains(p, T, B) {
    const { quiet, over, floorDB, fw, smooth, release, silent, trust: tr } = DN;
    const ones = () => new Float32Array(T * B).fill(1);
    const total = new Float64Array(T);
    let mx = 0;
    for (let t = 0; t < T; t++) { let s = 0; for (let k = 0; k < B; k++) s += p[t * B + k]; total[t] = s; mx = Math.max(mx, s); }
    const edge = N / H, cand = [];
    for (let t = edge; t < Math.max(edge + 1, T - edge); t++) cand.push(t);
    const alive = cand.filter((t) => total[t] > 1e-10 * Math.max(mx, 1e-30));
    if (!alive.length || alive.length < (1 - silent) * cand.length) return ones();
    // Arrotondamento «al pari» come Python e Swift (0,5 → 0, 1,5 → 2)
    const raw = quiet * alive.length, fl = Math.floor(raw), d = raw - fl;
    const k = Math.max(1, d > 0.5 || (d === 0.5 && fl % 2 === 1) ? fl + 1 : fl);
    const order = alive.slice().sort((a, b) => total[a] - total[b] || a - b);
    const q = order.slice(0, k);
    const noise = new Float64Array(B);
    for (const t of q) for (let f = 0; f < B; f++) noise[f] += p[t * B + f];
    for (let f = 0; f < B; f++) noise[f] = noise[f] / k + 1e-12;
    // Il 90° percentile dell'energia (come numpy: interpolazione lineare) contro la media dei momenti silenziosi
    const sorted = order.map((t) => total[t]), pos = 0.9 * (sorted.length - 1), lo = Math.floor(pos);
    const loud = sorted[lo] + (sorted[Math.min(lo + 1, sorted.length - 1)] - sorted[lo]) * (pos - lo);
    let qm = 0;
    for (const t of q) qm += total[t];
    const span = 10 * Math.log10(loud / Math.max(qm / k, 1e-30));
    const trust = Math.min(Math.max((span - tr[0]) / (tr[1] - tr[0]), 0), 1);
    if (trust === 0) return ones();
    const s = smoothed(p, T, B, fw, smooth);
    const floor = 1 - trust * (1 - Math.pow(10, floorDB / 20));
    const g = new Float32Array(T * B), prev = new Float32Array(B).fill(1);
    for (let t = 0; t < T; t++) {
      for (let f = 0; f < B; f++) {
        const v = floor + (1 - floor) * Math.sqrt(Math.min(Math.max(1 - (over * noise[f]) / Math.max(s[t * B + f], 1e-20), 0), 1));
        prev[f] = Math.max(v, release * prev[f] + (1 - release) * v);
        g[t * B + f] = prev[f];
      }
    }
    return g;
  }

  /** Tracce (1 o 2) a 44,1 kHz → stesse tracce con meno rumore di fondo (stesso guadagno sui canali). */
  function denoise(channels, opts = {}) { return spectralGain(channels, denoiseGains, opts); }

  // ── Togli riverbero ───────────────────────────────────────────────

  const DR = { delay: 10, t60: 2.0, r0: 1.3, r1: 2.2, floorDB: -18, fw: 3, smooth: 0.85 };

  /** Il guadagno di Togli riverbero (dereverb_ref.gains). */
  function dereverbGains(p, T, B) {
    const { delay, t60, r0, r1, floorDB, fw, smooth } = DR;
    const s = smoothed(p, T, B, fw, smooth);
    let total = 0;
    for (let i = 0; i < T * B; i++) total += s[i];
    const eps = 1e-10 + (1e-8 * total) / (T * B);
    const dec = Math.exp((-2 * ((3 * Math.log(10)) / t60) * delay * H) / 44100);
    const floor = Math.pow(10, floorDB / 20);
    const g = new Float32Array(T * B), prev = new Float32Array(B).fill(1);
    for (let t = 0; t < T; t++) {
      for (let k = 0; k < B; k++) {
        const late = t >= delay ? dec * s[(t - delay) * B + k] : 0;
        const r = s[t * B + k] / (late + eps);
        let v = Math.min(Math.max((r - r0) / (r1 - r0), 0), 1);
        v = floor + (1 - floor) * v * v * (3 - 2 * v);
        prev[k] = Math.max(v, 0.5 * prev[k] + 0.5 * v);
        g[t * B + k] = prev[k];
      }
    }
    return g;
  }

  /** Tracce (1 o 2) a 44,1 kHz → stesse tracce senza la coda del riverbero (stesso guadagno sui canali). */
  function dereverb(channels, opts = {}) { return spectralGain(channels, dereverbGains, opts); }

  const api = { RealFFT, spectralGain, denoise, dereverb, DN, DR };
  root.IsoLR = root.IsoLR || {};
  root.IsoLR.Cleanup = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : globalThis);
