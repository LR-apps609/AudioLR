// ════════════════════════════════════════════════════════════════════
//  Le note di una traccia nell'editor piano roll, come Sources/NoteEdit.swift
//  sul Mac: la griglia (sedicesimi sui battiti veri della canzone), l'aggancio,
//  e le modifiche (sposta, allunga, aggiungi, togli, selezione a rettangolo)
//  con «Annulla» e «Ripristina». Solo regole, niente disegno né suono.
// ════════════════════════════════════════════════════════════════════
(function (root) {
  "use strict";
  const NS = (root.IsoLR = root.IsoLR || {});
  const MIN_LEN = 0.03;                              // una nota non è mai più corta di 30 ms

  /** I sedicesimi della canzone: quattro per battito, sui battiti veri; prima e dopo con il passo vicino. */
  function grid(structure, bpm, duration) {
    const beats = structure && structure.beats && structure.beats.length > 1 ? structure.beats : null;
    const period = beats ? (beats[beats.length - 1] - beats[0]) / (beats.length - 1) : 60 / Math.max(30, bpm || 120);
    const b = beats ? beats.slice() : [0];
    const out = [];
    for (let t = b[0] - period; t > 0; t -= period) b.unshift(t);
    if (b[0] > 0) b.unshift(0);
    while (b[b.length - 1] < duration) b.push(b[b.length - 1] + period);
    for (let i = 0; i + 1 < b.length; i++) {
      const step = (b[i + 1] - b[i]) / 4;
      for (let k = 0; k < 4; k++) { const t = b[i] + k * step; if (t >= 0 && t <= duration + 1e-9) out.push(t); }
    }
    return out;
  }

  /** Il punto della griglia più vicino (ricerca binaria). Senza griglia il tempo resta com'è. */
  function snap(t, g) {
    if (!g || !g.length) return t;
    let lo = 0, hi = g.length - 1;
    while (hi - lo > 1) { const m = (lo + hi) >> 1; if (g[m] <= t) lo = m; else hi = m; }
    return Math.abs(g[lo] - t) <= Math.abs(g[hi] - t) ? g[lo] : g[hi];
  }

  const clampPitch = (p) => Math.max(0, Math.min(127, Math.round(p)));
  const copy = (list) => list.map((n) => ({ ...n }));

  /** L'editor: le note con un numero ciascuna, la storia per «Annulla», le note rilevate per «Ripristina». */
  class Editor {
    constructor(detected, edited) {
      this.detected = copy(detected || []);
      this.notes = copy(edited || detected || []).map((n, i) => ({ ...n, id: i + 1 }));
      this.next = this.notes.length + 1;
      this.history = [];
    }
    get edited() { return this.history.length > 0; }
    save() { this.history.push(copy(this.notes)); if (this.history.length > 200) this.history.shift(); }
    find(id) { return this.notes.find((n) => n.id === id); }

    /** Sposta le note scelte di `dt` secondi e `dp` semitoni; con la griglia l'inizio della prima si aggancia. */
    move(ids, dt, dp, g) {
      const sel = this.notes.filter((n) => ids.includes(n.id));
      if (!sel.length) return;
      this.save();
      let shift = dt;
      if (g) { const first = sel.reduce((a, n) => (n.start < a.start ? n : a)); shift = snap(first.start + dt, g) - first.start; }
      const lowest = Math.min(...sel.map((n) => n.start));
      if (lowest + shift < 0) shift = -lowest;
      for (const n of sel) { const len = n.end - n.start; n.start += shift; n.end = n.start + len; n.pitch = clampPitch(n.pitch + dp); }
    }

    /** Allunga o accorcia una nota: la fine va a `end` (agganciata alla griglia se c'è). */
    resize(id, end, g) {
      const n = this.find(id);
      if (!n) return;
      this.save();
      const e = g ? snap(end, g) : end;
      n.end = Math.max(n.start + MIN_LEN, e);
    }

    /** Una nota nuova: inizio agganciato, lunga un sedicesimo (o `len` secondi senza griglia). */
    add(start, pitch, g, len = 0.25) {
      this.save();
      const s = Math.max(0, g ? snap(start, g) : start);
      let e = s + len;
      if (g) { const i = g.indexOf(s); if (i >= 0 && i + 1 < g.length) e = g[i + 1]; }
      const n = { start: s, end: Math.max(s + MIN_LEN, e), pitch: clampPitch(pitch), velocity: 96, id: this.next++ };
      this.notes.push(n);
      return n.id;
    }

    remove(ids) {
      if (!ids.length) return;
      this.save();
      this.notes = this.notes.filter((n) => !ids.includes(n.id));
    }

    /** Le note dentro il rettangolo (tempo t0…t1, altezze p0…p1, compresi). */
    within(t0, t1, p0, p1) {
      const [a, b] = [Math.min(t0, t1), Math.max(t0, t1)], [lo, hi] = [Math.min(p0, p1), Math.max(p0, p1)];
      return this.notes.filter((n) => n.end > a && n.start < b && n.pitch >= lo && n.pitch <= hi).map((n) => n.id);
    }

    undo() { if (this.history.length) this.notes = this.history.pop(); }
    reset() { this.save(); this.notes = copy(this.detected).map((n) => ({ ...n, id: this.next++ })); }

    /** Le note in ordine, senza i numeri (per il file MIDI e lo spartito). */
    list() { return this.notes.map(({ start, end, pitch, velocity }) => ({ start, end, pitch, velocity })).sort((a, b) => a.start - b.start || a.pitch - b.pitch); }
  }

  /** Le altezze da mostrare: dalla nota più bassa alla più alta, con un po' di margine (almeno due ottave). */
  function range(list) {
    if (!list.length) return [48, 72];
    let lo = Math.min(...list.map((n) => n.pitch)) - 3, hi = Math.max(...list.map((n) => n.pitch)) + 3;
    while (hi - lo < 24) { lo--; hi++; }
    return [Math.max(0, lo), Math.min(127, hi)];
  }

  const api = { grid, snap, Editor, range, MIN_LEN };
  NS.Notes = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : globalThis);
