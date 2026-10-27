// ════════════════════════════════════════════════════════════════════
//  Warp, come Sources/Warp.swift sul Mac: i segnaposto sulle battute
//  (spostati a mano se il riconoscimento ha sbagliato), la griglia dei
//  battiti rifatta dai segnaposto, e la mappa del tempo per «Metti a tempo»:
//  ogni battuta dura beatsPerBar·60/BPM, il tono non cambia.
//  Prima del primo segnaposto vale il rapporto della prima battuta, dopo
//  l'ultimo quello dell'ultima. Solo calcoli: il suono lo stira Signalsmith.
// ════════════════════════════════════════════════════════════════════
(function (root) {
  "use strict";

  const NS = (root.IsoLR = root.IsoLR || {});

  /// I primi battiti di ogni battuta (i segnaposto di partenza).
  function downbeats(structure) {
    if (!structure || !structure.beats || !structure.beats.length) return [];
    const out = [];
    for (let i = structure.firstDownbeat || 0; i < structure.beats.length; i += structure.beatsPerBar || 4) out.push(structure.beats[i]);
    return out;
  }

  /// Il tempo medio (mediana delle battute) dei segnaposto.
  function bpmOf(marks, beatsPerBar = 4) {
    if (marks.length < 2) return 0;
    const bars = [];
    for (let i = 1; i < marks.length; i++) bars.push(marks[i] - marks[i - 1]);
    bars.sort((a, b) => a - b);
    const m = bars[Math.floor(bars.length / 2)];
    return m > 0 ? (60 * beatsPerBar) / m : 0;
  }

  /// I battiti dai segnaposto: beatsPerBar battiti uguali tra due segnaposto; prima del primo e dopo
  /// l'ultimo, la stessa distanza della battuta vicina, dentro la canzone (0…duration).
  function beatsFromMarks(marks, beatsPerBar = 4, duration = Infinity) {
    const m = [...marks].sort((a, b) => a - b);
    if (m.length < 2) return { beats: m.slice(), firstDownbeat: 0 };
    const beats = [];
    const first = (m[1] - m[0]) / beatsPerBar;
    for (let t = m[0] - first; t >= -1e-9; t -= first) beats.unshift(Math.max(0, t));
    const firstDownbeat = beats.length;
    for (let i = 0; i + 1 < m.length; i++) {
      const step = (m[i + 1] - m[i]) / beatsPerBar;
      for (let k = 0; k < beatsPerBar; k++) beats.push(m[i] + k * step);
    }
    const last = (m[m.length - 1] - m[m.length - 2]) / beatsPerBar;
    for (let t = m[m.length - 1]; t < duration - 1e-9; t += last) beats.push(t);
    if (!isFinite(duration)) beats.push(m[m.length - 1]);
    return { beats: beats.map((x) => +x.toFixed(4)), firstDownbeat };
  }

  /// La mappa del tempo: ancore (sorgente → destinazione) crescenti, lineare tra le ancore,
  /// fuori con la pendenza della prima e dell'ultima battuta.
  class WarpMap {
    constructor(src, dst) {
      if (src.length !== dst.length || src.length < 2) throw new Error("servono almeno due segnaposto");
      this.src = src.slice(); this.dst = dst.slice();
    }
    /// Ogni battuta lunga beatsPerBar·60/bpm; il primo segnaposto finisce dove lo porta il rapporto della prima battuta.
    static toTempo(marks, bpm, beatsPerBar = 4) {
      const m = [...marks].sort((a, b) => a - b);
      if (m.length < 2) throw new Error("servono almeno due segnaposto");
      const bar = (beatsPerBar * 60) / bpm;
      const d0 = m[0] * (bar / (m[1] - m[0]));
      return new WarpMap(m, m.map((_, i) => d0 + i * bar));
    }
    static interp(xs, ys, x) {
      const n = xs.length;
      let i;
      if (x <= xs[0]) i = 0;
      else if (x >= xs[n - 1]) i = n - 2;
      else { let lo = 0, hi = n - 1; while (hi - lo > 1) { const mid = (lo + hi) >> 1; if (xs[mid] <= x) lo = mid; else hi = mid; } i = lo; }
      return ys[i] + ((x - xs[i]) * (ys[i + 1] - ys[i])) / (xs[i + 1] - xs[i]);
    }
    /// Secondo della versione a tempo per un secondo della canzone originale.
    map(t) { return WarpMap.interp(this.src, this.dst, t); }
    /// E al contrario.
    inverse(t) { return WarpMap.interp(this.dst, this.src, t); }
    /// Quanto dura la versione a tempo di una canzone lunga `duration`.
    length(duration) { return Math.max(0, this.map(duration) - this.map(0)); }
    /// I tratti da stirare, nella versione a tempo che parte da 0: { srcStart, srcEnd, dstStart, dstEnd, rate }
    /// (rate = secondi di originale per secondo nuovo: >1 accelera).
    segments(duration) {
      const off = this.map(0);
      const cuts = [0, ...this.src.filter((x) => x > 0 && x < duration), duration];
      const out = [];
      for (let i = 0; i + 1 < cuts.length; i++) {
        const a = cuts[i], b = cuts[i + 1];
        if (b - a < 1e-6) continue;
        const da = this.map(a) - off, db = this.map(b) - off;
        out.push({ srcStart: a, srcEnd: b, dstStart: da, dstEnd: db, rate: (b - a) / (db - da) });
      }
      return out;
    }
  }

  /// Tempo, battiti, parti e accordi della versione a tempo: battiti regolari al BPM esatto.
  function mapAnalysis(analysis, map, bpm, duration) {
    if (!analysis) return analysis;
    const off = map.map(0), at = (t) => +(map.map(t) - off).toFixed(4);
    const out = Object.assign({}, analysis, { bpm });
    const len = map.length(duration);
    const s = analysis.structure;
    if (s) {
      const bpb = s.beatsPerBar || 4;
      const g = beatsFromMarks(map.src.map(at), bpb, len);
      out.structure = Object.assign({}, s, { beats: g.beats, firstDownbeat: g.firstDownbeat,
        sections: (s.sections || []).map((x) => Object.assign({}, x, { start: at(x.start), end: Math.min(len, at(x.end)) })) });
    }
    if (analysis.chords) out.chords = analysis.chords.map((c) => Object.assign({}, c, { start: at(c.start), end: Math.min(len, at(c.end)) }));
    return out;
  }

  /// La griglia corretta a mano, nella stessa canzone: battiti dai segnaposto, parti e accordi restano.
  function withGrid(analysis, marks, duration) {
    const s = (analysis && analysis.structure) || { beatsPerBar: 4, sections: [] };
    const bpb = s.beatsPerBar || 4;
    const g = beatsFromMarks(marks, bpb, duration);
    const bpm = bpmOf(marks, bpb);
    return Object.assign({}, analysis, { bpm: bpm ? +bpm.toFixed(2) : analysis && analysis.bpm,
      structure: Object.assign({}, s, { beats: g.beats, firstDownbeat: g.firstDownbeat, beatsPerBar: bpb }) });
  }

  const api = { downbeats, bpmOf, beatsFromMarks, WarpMap, mapAnalysis, withGrid };
  NS.Warp = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : globalThis);
