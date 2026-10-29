// ════════════════════════════════════════════════════════════════════
//  Le regole delle tre animazioni dello «Studio di notte», come
//  Sources/Animations.swift sul Mac: quanto «batte» la musica adesso
//  (il logo a tempo), e i tempi e i coriandoli della festa di fine
//  separazione. Solo regole, niente disegno.
// ════════════════════════════════════════════════════════════════════
(function (root) {
  "use strict";
  const NS = (root.IsoLR = root.IsoLR || {});
  const DECAY = 0.22;                                // secondi di discesa dopo ogni battito
  const DURATION = 2.5;                              // durata della festa

  /** 1 sul battito, poi scende a 0 prima del successivo. Senza battiti: la griglia del BPM; senza nemmeno quello: 0. */
  function pulse(t, beats, bpm) {
    let since;
    if (beats && beats.length) {
      if (t < beats[0]) return 0;
      let lo = 0, hi = beats.length - 1;
      while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (beats[mid] <= t) lo = mid; else hi = mid - 1; }
      since = t - beats[lo];
      if (lo === beats.length - 1 && beats.length > 1 && since > 1.5 * (beats[lo] - beats[lo - 1])) return 0;
    } else if (bpm && bpm > 20) {
      since = t % (60 / bpm);
    } else return 0;
    if (since < 0 || since >= DECAY) return 0;
    const x = since / DECAY;
    return (1 - x) * (1 - x);
  }

  /** Avanzamento della festa (0…1) dopo `elapsed` secondi; null quando è finita. */
  const progress = (elapsed) => (elapsed >= 0 && elapsed < DURATION ? elapsed / DURATION : null);

  /** I coriandoli: direzione, distanza, colore (indice nei colori delle tracce) e rotazione, sempre uguali. */
  function confetti(count = 24) {
    return Array.from({ length: count }, (_, i) => ({
      angle: (i / count) * 2 * Math.PI + (i % 3) * 0.13,
      distance: 110 + (i % 3) * 32,
      color: i % 6,
      spin: (i * 37) % 360,
    }));
  }

  const easeOut = (x) => 1 - Math.pow(1 - Math.min(Math.max(x, 0), 1), 3);

  const api = { DECAY, DURATION, pulse, progress, confetti, easeOut };
  NS.Anim = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : globalThis);
