// ════════════════════════════════════════════════════════════════════
//  Confronto con l'originale: la tua registrazione contro la traccia
//  separata (la voce, il basso…), negli stessi secondi della canzone.
//  • Intonazione: l'altezza (YIN) ogni 10 ms in tutte e due; una nota è
//    «intonata» se sta entro 50 cent dall'originale. Un'ottava sopra o
//    sotto vale lo stesso (una donna che canta la parte di un uomo).
//  • Tempo: gli attacchi delle due tracce, spostati finché combaciano:
//    di quanto sei in anticipo o in ritardo, in media.
//  Copia di Sources/Compare.swift: se lì cambia qualcosa, va cambiato anche qui.
// ════════════════════════════════════════════════════════════════════
(function (root) {
  "use strict";

  const NS = (root.IsoLR = root.IsoLR || {});

  class CompareResult {
    constructor(o) {
      /// Quota dei momenti intonati (0…1), dove suonano tutte e due.
      this.inTune = o.inTune;
      /// Di quanto sei in media sopra (+) o sotto (−) l'originale, in cent.
      this.cents = o.cents;
      /// Di quanto sei in anticipo (−) o in ritardo (+), in millisecondi.
      this.offsetMs = o.offsetMs;
      /// Secondi confrontati (dove suonano tutte e due).
      this.seconds = o.seconds;
      /// Da dove a dove hai suonato, in secondi della canzone.
      this.start = o.start;
      this.end = o.end;
      /// Le due linee dell'altezza (in semitoni MIDI, null = silenzio), un punto ogni `step` secondi da `start`.
      this.mine = o.mine;
      this.original = o.original;
      this.step = o.step;
    }
    /// «Ottimo», «Buono»…: una parola sul risultato.
    get verdict() {
      const v = this.inTune;
      if (v >= 0.85) return "Ottimo";
      if (v >= 0.7) return "Buono";
      if (v >= 0.5) return "Quasi";
      return "Da ripassare";
    }
  }

  const rate = 44100;
  /// Si lavora a 11 025 Hz: basta per l'altezza di voce e strumenti ed è quattro volte più veloce.
  const down = 4;
  const hop = 110;               // 10 ms a 11 025 Hz
  const frame = 512;

  /// L'errore di quando non c'è abbastanza suono (come Compare.Problem.silent).
  function silent() {
    const e = new Error("Nella registrazione o nella traccia scelta non c'è abbastanza suono da confrontare.");
    e.code = "silent";
    return e;
  }

  const round = (x) => (x < 0 ? -Math.floor(-x + 0.5) : Math.floor(x + 0.5));

  function run(take, original) {
    const a = decimate(take), b = decimate(original);
    const n = Math.min(a.length, b.length);
    if (!(n > frame * 4)) throw silent();
    const sr = rate / down;
    // Dove hai suonato: le colonne con abbastanza volume
    const frames = Math.trunc((n - frame) / hop);
    const ra = new Float32Array(frames), rb = new Float32Array(frames);
    let ma = 0, mb = 0;
    for (let t = 0; t < frames; t++) {
      ra[t] = rms(a, t * hop); rb[t] = rms(b, t * hop);
      if (ra[t] > ma) ma = ra[t];
      if (rb[t] > mb) mb = rb[t];
    }
    const la = Math.fround(ma * Math.fround(0.03)), lb = Math.fround(mb * Math.fround(0.03));
    let first = -1, last = -1;
    for (let t = 0; t < frames; t++) if (ra[t] > la) { if (first < 0) first = t; last = t; }
    if (first < 0 || !(last > first + 50)) throw silent();
    const mine = [], orig = [], diffs = [];
    for (let t = first; t <= last; t++) {
      const pa = ra[t] > la ? yin(a, t * hop, sr) : null;
      const pb = rb[t] > lb ? yin(b, t * hop, sr) : null;
      mine.push(pa === null ? null : midi(pa));
      orig.push(pb === null ? null : midi(pb));
      if (pa !== null && pb !== null) {
        // Un'ottava sopra o sotto conta come la stessa nota
        let d = 1200 * Math.log2(pa / pb);
        d -= 1200 * round(d / 1200);
        diffs.push(d);
      }
    }
    if (diffs.length < 30) throw silent();
    const inTune = diffs.filter((d) => Math.abs(d) <= 50).length / diffs.length;
    const sorted = diffs.slice().sort((x, y) => x - y);
    const cents = sorted[Math.trunc(sorted.length / 2)];
    const offset = lag(onsets(a, first, last), onsets(b, first, last));
    const step = hop / sr;
    return new CompareResult({ inTune, cents, offsetMs: offset * step * 1000, seconds: diffs.length * step,
                               start: first * step, end: last * step, mine, original: orig, step });
  }

  /// Da 44,1 kHz a 11 025 Hz, con un filtro che toglie gli acuti prima (niente suoni «riflessi»).
  function decimate(x) {
    if (!(x.length > 64)) return new Float32Array(0);
    const taps = 31;
    const fc = 0.9 / down / 2;
    const h = new Float32Array(taps);
    for (let i = 0; i < taps; i++) {
      const m = i - Math.trunc(taps / 2);
      const sinc = m === 0 ? 2 * fc : Math.sin(2 * Math.PI * fc * m) / (Math.PI * m);
      h[i] = sinc * (0.54 - 0.46 * Math.cos((2 * Math.PI * i) / (taps - 1)));
    }
    // vDSP.convolve sull'onda allungata di taps−1 zeri: escono x.count − 1 campioni filtrati
    // (il filtro è simmetrico, quindi convoluzione e correlazione coincidono)
    const len = x.length - 1;
    const out = new Float32Array(Math.ceil(len / down));
    for (let o = 0, i = 0; i < len; i += down, o++) {
      let s = 0;
      const lim = Math.min(taps, x.length - i);
      for (let k = 0; k < lim; k++) s += x[i + k] * h[k];
      out[o] = s;
    }
    return out;
  }

  function rms(x, at) {
    if (at + frame > x.length) return 0;
    let s = 0;
    for (let i = at; i < at + frame; i++) s += x[i] * x[i];
    return Math.fround(Math.sqrt(s / frame));
  }

  /// Altezza in Hz con YIN (de Cheveigné e Kawahara, 2002); null se il suono non ha una nota chiara.
  function yin(x, at, sr, fmin = 60, fmax = 1000, threshold = 0.15) {
    const w = frame / 2;
    const lo = Math.trunc(sr / fmax), hi = Math.min(w - 1, Math.trunc(sr / fmin));
    if (at + frame > x.length || !(hi > lo + 2)) return null;
    threshold = Math.fround(threshold);
    const d = new Float32Array(hi + 1);
    for (let tau = 1; tau <= hi; tau++) {
      let s = 0;
      for (let i = 0; i < w; i++) { const v = x[at + i] - x[at + i + tau]; s += v * v; }
      d[tau] = s;
    }
    // Differenza normalizzata cumulativa
    let cum = 0;
    const nd = new Float32Array(hi + 1).fill(1);
    for (let tau = 1; tau <= hi; tau++) {
      cum = Math.fround(cum + d[tau]);
      nd[tau] = cum > 0 ? (d[tau] * tau) / cum : 1;
    }
    let tau = lo;
    while (tau < hi) {
      if (nd[tau] < threshold) {
        while (tau + 1 < hi && nd[tau + 1] < nd[tau]) tau += 1;
        break;
      }
      tau += 1;
    }
    if (!(tau < hi) || !(nd[tau] < threshold)) return null;
    // Interpolazione parabolica intorno al minimo
    const a = nd[tau - 1], b = nd[tau], c = nd[tau + 1];
    const den = Math.fround(a - 2 * b + c);
    const shift = den !== 0 ? Math.fround((a - c) / (2 * den)) : 0;
    return sr / (tau + Math.max(-1, Math.min(1, shift)));
  }

  function midi(hz) { return 69 + 12 * Math.log2(hz / 440); }

  /// Forza degli attacchi (crescita del volume) colonna per colonna, tra `from` e `to`.
  function onsets(x, from, to) {
    let prev = 0;
    const out = [];
    for (let t = from; t <= to; t++) {
      const e = Math.log1p(1000 * rms(x, t * hop));
      out.push(Math.max(0, e - prev));
      prev = e;
    }
    return out;
  }

  /// Lo spostamento (in colonne, ±15 = ±150 ms) che fa combaciare meglio gli attacchi:
  /// positivo = la tua registrazione arriva dopo.
  function lag(mine, original, maxLag = 15) {
    let best = 0, bestScore = -Infinity;
    for (let l = -maxLag; l <= maxLag; l++) {
      let s = 0;
      for (let i = 0; i < original.length; i++) {
        const j = i + l;
        if (j >= 0 && j < mine.length) s += original[i] * mine[j];
      }
      if (s > bestScore) { bestScore = s; best = l; }
    }
    return best;
  }

  const api = { CompareResult, rate, down, hop, frame, run, decimate, rms, yin, midi, onsets, lag };
  NS.Compare = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : globalThis);
