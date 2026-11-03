// Le misure di una traccia (energia, picco, forma d'onda): le stesse nella finestra (separate.js) e nel
// lavoratore che prepara i file (save-worker.js), così i numeri salvati non cambiano.
(function (NS) {
  "use strict";

  /** Energia, picco e forma d'onda di una traccia (Stem.measure e i picchi per il disegno). */
  function measure(ch, points = 600) {
    let e = 0, peak = 0;
    const n = ch[0].length, peaks = new Float32Array(points), step = Math.max(1, Math.floor(n / points));
    for (let p = 0; p < points; p++) {
      let m = 0;
      for (let i = p * step, end = Math.min(n, i + step); i < end; i++) {
        const v = Math.max(Math.abs(ch[0][i]), Math.abs(ch[1][i]));
        if (v > m) m = v;
      }
      peaks[p] = m;
    }
    for (let c = 0; c < 2; c++) for (let i = 0; i < n; i++) { const v = ch[c][i]; e += v * v; if (Math.abs(v) > peak) peak = Math.abs(v); }
    let top = 0; for (const v of peaks) top = Math.max(top, v);
    return { energy: e, peak, peaks: Array.from(peaks, (v) => +(v / (top || 1)).toFixed(3)) };
  }

  NS.Stems = { measure };
  if (typeof module !== "undefined" && module.exports) module.exports = NS.Stems;
})(typeof self !== "undefined" ? self : globalThis);
