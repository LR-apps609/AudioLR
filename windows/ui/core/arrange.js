// ════════════════════════════════════════════════════════════════════
//  Rimonta («taglia e sposta»), come Sources/Arrange.swift sul Mac: la
//  canzone come fila di blocchi (all'inizio le sue parti: intro, strofa,
//  ritornello…) da dividere sulle battute, spostare, duplicare, togliere.
//  La versione nuova è la fila dei blocchi una dopo l'altra, con una
//  dissolvenza equal-power di 10 ms a ogni giunzione (lunga quanto la somma).
// ════════════════════════════════════════════════════════════════════
(function (root) {
  "use strict";

  const NS = (root.IsoLR = root.IsoLR || {});
  const FADE = 0.01;
  let nextId = 1;
  const block = (srcStart, srcEnd, label, group) => ({ id: nextId++, srcStart, srcEnd, label, group });

  /// I blocchi di partenza: le parti della canzone, senza buchi da 0 alla fine.
  function fromSections(sections, duration) {
    const s = (sections || []).filter((x) => x.end > x.start).slice().sort((a, b) => a.start - b.start);
    if (!s.length) return [block(0, duration, "Canzone", 0)];
    const out = [];
    let t = 0;
    for (const x of s) {
      const a = Math.max(t, Math.min(duration, x.start)), b = Math.min(duration, x.end);
      if (a > t + 0.05) out.push(block(t, a, "Inizio", -1));
      if (b > a + 0.05) out.push(block(a, b, x.label, x.group));
      t = Math.max(t, b);
    }
    if (duration > t + 0.05) out.push(block(t, duration, "Fine", -1));
    else if (out.length) out[out.length - 1].srcEnd = duration;
    return out;
  }

  const lengthOf = (b) => b.srcEnd - b.srcStart;
  const total = (blocks) => blocks.reduce((s, b) => s + lengthOf(b), 0);

  /// Dove inizia ogni blocco nella versione nuova.
  function layout(blocks) {
    let t = 0;
    return blocks.map((b) => { const o = Object.assign({}, b, { dstStart: t, dstEnd: t + lengthOf(b) }); t += lengthOf(b); return o; });
  }

  /// Il blocco e il secondo dell'originale a un secondo della versione nuova.
  function locate(blocks, t) {
    const l = layout(blocks);
    let i = l.findIndex((b) => t < b.dstEnd);
    if (i < 0) i = l.length - 1;
    return { index: i, src: l[i].srcStart + Math.max(0, t - l[i].dstStart) };
  }

  /// Divide il blocco `i` sul primo battito di battuta più vicino a `src` (secondi dell'originale);
  /// senza battute, proprio lì. Niente se il taglio cadrebbe a meno di mezzo secondo dai bordi.
  function split(blocks, i, src, downbeats) {
    const b = blocks[i];
    if (!b) return blocks;
    let cut = src;
    const inside = (downbeats || []).filter((d) => d > b.srcStart + 0.5 && d < b.srcEnd - 0.5);
    if (inside.length) cut = inside.reduce((best, d) => (Math.abs(d - src) < Math.abs(best - src) ? d : best), inside[0]);
    if (cut <= b.srcStart + 0.5 || cut >= b.srcEnd - 0.5) return blocks;
    const out = blocks.slice();
    out.splice(i, 1, block(b.srcStart, cut, b.label, b.group), block(cut, b.srcEnd, b.label, b.group));
    return out;
  }

  /// Sposta il blocco `from` al posto `to` (indice nella fila senza il blocco).
  function move(blocks, from, to) {
    const out = blocks.slice();
    const [b] = out.splice(from, 1);
    out.splice(Math.max(0, Math.min(out.length, to)), 0, b);
    return out;
  }
  function duplicate(blocks, i) {
    const out = blocks.slice();
    const b = blocks[i];
    out.splice(i + 1, 0, block(b.srcStart, b.srcEnd, b.label, b.group));
    return out;
  }
  function remove(blocks, i) { return blocks.length > 1 ? blocks.filter((_, k) => k !== i) : blocks; }

  /// Una traccia (canali Float32Array) rimontata: lunga esattamente la somma dei blocchi. A ogni giunzione
  /// i due lati continuano per 5 ms oltre il taglio e si incrociano con curve seno/coseno.
  function render(channels, blocks, rate = 44100, fade = FADE) {
    const n = channels[0].length, l = layout(blocks);
    const len = Math.round(total(blocks) * rate), half = Math.max(1, Math.round((fade * rate) / 2));
    const out = channels.map(() => new Float32Array(len));
    const at = (c, i) => (i >= 0 && i < n ? channels[c][i] : 0);
    for (const b of l) {
      const d0 = Math.round(b.dstStart * rate), d1 = Math.min(len, Math.round(b.dstEnd * rate)), s0 = Math.round(b.srcStart * rate);
      for (let c = 0; c < channels.length; c++) {
        const src = channels[c], o = out[c];
        for (let i = d0; i < d1; i++) { const j = s0 + i - d0; o[i] = j < n ? src[j] : 0; }
      }
    }
    for (let k = 1; k < l.length; k++) {
      const a = l[k - 1], b = l[k], J = Math.round(b.dstStart * rate);
      const aEnd = Math.round(a.srcEnd * rate), bStart = Math.round(b.srcStart * rate);
      if (aEnd === bStart) continue;                 // taglio dove la canzone continua da sola: niente da incrociare
      if (aEnd + half > n || bStart - half < 0) {
        // Un lato non può continuare (fine o inizio della canzone): A si spegne prima del taglio, B si accende dopo
        for (let i = -half; i < half; i++) {
          const p = J + i;
          if (p < 0 || p >= len) continue;
          const g = i < 0 ? Math.cos(((i + half + 0.5) / half) * (Math.PI / 2)) : Math.sin(((i + 0.5) / half) * (Math.PI / 2));
          for (let c = 0; c < channels.length; c++) out[c][p] *= g;
        }
        continue;
      }
      for (let i = -half; i < half; i++) {
        const p = J + i;
        if (p < 0 || p >= len) continue;
        const x = (i + half + 0.5) / (2 * half), ga = Math.cos((x * Math.PI) / 2), gb = Math.sin((x * Math.PI) / 2);
        for (let c = 0; c < channels.length; c++) out[c][p] = at(c, aEnd + i) * ga + at(c, bStart + i) * gb;
      }
    }
    return out;
  }

  /// Battiti, parti (= i blocchi con il loro nome) e accordi della versione rimontata; tempo e tonalità uguali.
  function mapAnalysis(analysis, blocks) {
    if (!analysis) return analysis;
    const l = layout(blocks), out = Object.assign({}, analysis);
    const s = analysis.structure;
    if (s) {
      const bpb = s.beatsPerBar || 4, beats = [], down = [];
      s.beats.forEach((t, i) => void (down[i] = (((i - (s.firstDownbeat || 0)) % bpb) + bpb) % bpb === 0));
      let firstDownbeat = -1;
      for (const b of l) {
        s.beats.forEach((t, i) => {
          if (t < b.srcStart - 1e-6 || t >= b.srcEnd - 1e-6) return;
          if (firstDownbeat < 0 && down[i]) firstDownbeat = beats.length;
          beats.push(+(b.dstStart + t - b.srcStart).toFixed(4));
        });
      }
      const sections = l.map((b) => ({ start: +b.dstStart.toFixed(4), end: +b.dstEnd.toFixed(4), label: b.label, group: Math.max(0, b.group) }));
      out.structure = Object.assign({}, s, { beats, firstDownbeat: Math.max(0, firstDownbeat), sections });
    }
    if (analysis.chords) {
      const chords = [];
      for (const b of l) for (const c of analysis.chords) {
        const a = Math.max(c.start, b.srcStart), e = Math.min(c.end, b.srcEnd);
        if (e - a > 1e-3) chords.push(Object.assign({}, c, { start: +(b.dstStart + a - b.srcStart).toFixed(4), end: +(b.dstStart + e - b.srcStart).toFixed(4) }));
      }
      out.chords = chords;
    }
    return out;
  }

  const api = { FADE, fromSections, layout, locate, total, split, move, duplicate, remove, render, mapAnalysis };
  NS.Arrange = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : globalThis);
