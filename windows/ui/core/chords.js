// ════════════════════════════════════════════════════════════════════
//  Accordi, calcolati sulle tracce separate senza batteria e senza voce:
//  per ogni battito le note che suonano (croma) si confrontano con le
//  24 triadi maggiori e minori; il basso aiuta a trovare la fondamentale.
//  Poi una scelta su tutta la canzone (Viterbi): cambiare accordo costa un
//  po', così un passaggio veloce di chitarra non diventa un accordo nuovo,
//  e gli accordi della tonalità sono un poco favoriti.
//  È una stima: maggiori e minori, senza settime e sospesi.
//  Copia di Sources/Chords.swift: se lì cambia qualcosa, va cambiato anche qui.
// ════════════════════════════════════════════════════════════════════
(function (root) {
  "use strict";

  const NS = (root.IsoLR = root.IsoLR || {});
  const need = (file, name) => (typeof module !== "undefined" && module.exports ? require("./" + file) : NS[name]);
  const STFT = () => need("stft.js", "STFT");

  const names = ["Do", "Do♯", "Re", "Mi♭", "Mi", "Fa", "Fa♯", "Sol", "La♭", "La", "Si♭", "Si"];
  const english = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"];

  class ChordSpan {
    constructor(start, end, root, minor) {
      /// Secondi dall'inizio della canzone.
      this.start = start;
      this.end = end;
      /// 0 = Do … 11 = Si; null = nessun accordo (silenzio, solo batteria o voce).
      this.root = root;
      this.minor = minor;
    }
    /// Da JSON (salvato dall'app o da qui).
    static from(o) { return o instanceof ChordSpan ? o : new ChordSpan(o.start, o.end, o.root ?? null, !!o.minor); }

    /// «Am», «F♯», «—»; `shift` in semitoni (per il tono cambiato in «Esercitati»).
    name({ italian = false, shift = 0 } = {}) {
      if (this.root === null || this.root === undefined) return "—";
      const k = (((this.root + shift) % 12) + 12) % 12;
      return (italian ? names[k] : english[k]) + (this.minor ? "m" : "");
    }
  }

  const rate = 44100;
  const hop = 2205;

  /// Fondamentale, terza e quinta (la fondamentale pesa di più).
  function template(rootNote, minor) {
    const t = new Array(12).fill(0);
    t[rootNote] = 1;
    t[(rootNote + (minor ? 3 : 4)) % 12] = 0.8;
    t[(rootNote + 7) % 12] = 0.8;
    return t;
  }

  /// Le triadi della scala: in Do maggiore C, Dm, Em, F, G, Am (la relativa minore usa le stesse).
  function inKey(rootNote, minor, key) {
    const tonic = key.minor ? (key.root + 3) % 12 : key.root;
    const d = (((rootNote - tonic) % 12) + 12) % 12;
    return minor ? [2, 4, 9].includes(d) : [0, 5, 7].includes(d);
  }

  /// Croma a 20 colonne al secondo tra `low` e `high` Hz, compresso col logaritmo; l'ultima casella è il volume.
  function chroma(x, low, high, fft = 8192) {
    const { PlainSTFT, pitchClasses } = STFT();
    const s = PlainSTFT.shared(fft, hop);
    const F = s.bins, pc = pitchClasses(fft, rate, low, high);
    const out = [];
    s.magnitudes(x, (t, mag) => {
      const row = new Float64Array(13);
      let total = 0;
      for (let f = 1; f < F; f++) {
        const p = pc[f];
        if (p < 0) continue;
        const e = mag[f] * mag[f];
        row[p] += e;
        total += e;
      }
      if (total > 1e-12) for (let i = 0; i < 12; i++) row[i] = Math.log1p((100 * row[i]) / total);
      row[12] = Math.sqrt(total);
      out.push(row);
    });
    return out;
  }

  /// Accordi da `harmonic` (strumenti senza batteria e voce) e `bass`, un'etichetta per battito.
  /// Senza battiti (`beats` null o meno di 4) si usa una griglia di mezzo secondo. `key`: {root, minor} o null.
  function detect({ harmonic, bass, beats = null, key = null }) {
    const Rhythm = need("rhythm.js", "Rhythm");
    const seconds = harmonic.length / rate;
    if (!(seconds > 2)) return [];
    let grid = beats ? Array.from(beats) : [];
    if (grid.length < 4) { grid = []; for (let i = 0; i * 0.5 < seconds; i++) grid.push(i * 0.5); }
    if (grid[0] > 0.05) grid.unshift(0);
    if (grid[grid.length - 1] < seconds - 0.05) grid.push(seconds);
    const treble = chroma(harmonic, 110, 4200);
    const low = chroma(bass && bass.length ? bass : harmonic, 35, 260);
    const fps = rate / hop;
    const mean = (c, a, b) => {
      const i0 = Math.max(0, Math.min(c.length - 1, Math.trunc(a * fps))), i1 = Math.max(i0 + 1, Math.min(c.length, Math.trunc(b * fps)));
      const m = new Float64Array(13);
      for (let i = i0; i < i1; i++) for (let k = 0; k < 13; k++) m[k] += c[i][k];
      for (let k = 0; k < 13; k++) m[k] /= i1 - i0;
      return m;
    };
    const steps = [];
    for (let i = 0; i < grid.length - 1; i++) steps.push([grid[i], grid[i + 1]]);
    const loud = steps.map(([a, b]) => mean(treble, a, b)[12]);
    const quiet = (loud.length ? Math.max(...loud) : 0) * 0.02;
    const templates = [];
    for (let q = 0; q < 24; q++) templates.push(template(q % 12, q >= 12));
    // 24 accordi + «nessuno»
    const states = 25;
    const cost = steps.map(([a, b], t) => {
      const row = new Float64Array(states);
      const c = mean(treble, a, b).subarray(0, 12), bl = mean(low, a, b).subarray(0, 12);
      let top = -Infinity;
      for (let i = 0; i < 12; i++) if (bl[i] > top) top = bl[i];
      const bmax = Math.max(1e-9, top);
      for (let q = 0; q < 24; q++) {
        const r = q % 12, minor = q >= 12;
        let score = Rhythm.cosine(c, templates[q]);
        score += (0.15 * bl[r]) / bmax;
        if (key && inKey(r, minor, key)) score += 0.04;
        row[q] = -score;
      }
      row[24] = loud[t] <= quiet ? -1 : 0.2;
      return row;
    });
    // Viterbi: restare costa 0, cambiare costa `change`
    const change = 0.18;
    const argmin = (v) => { let b = 0; for (let i = 1; i < v.length; i++) if (v[i] < v[b]) b = i; return b; };
    let acc = Float64Array.from(cost[0]);
    const back = [];
    for (let t = 1; t < steps.length; t++) {
      const best = argmin(acc);
      const next = new Float64Array(states), from = new Int32Array(states);
      for (let q = 0; q < states; q++) {
        const stay = acc[q], jump = acc[best] + change;
        if (stay <= jump) { next[q] = stay + cost[t][q]; from[q] = q; } else { next[q] = jump + cost[t][q]; from[q] = best; }
      }
      acc = next;
      back.push(from);
    }
    const path = new Int32Array(steps.length);
    path[steps.length - 1] = argmin(acc);
    for (let t = steps.length - 1; t > 0; t--) path[t - 1] = back[t - 1][path[t]];
    // Battiti uguali di fila diventano un accordo solo
    const out = [];
    for (let t = 0; t < path.length; t++) {
      const q = path[t];
      const r = q === 24 ? null : q % 12, minor = q >= 12 && q < 24;
      const l = out[out.length - 1];
      if (l && l.root === r && l.minor === minor) {
        out[out.length - 1] = new ChordSpan(l.start, steps[t][1], r, minor);
      } else {
        out.push(new ChordSpan(steps[t][0], steps[t][1], r, minor));
      }
    }
    return out;
  }

  const api = { ChordSpan, rate, hop, detect, template, inKey, chroma };
  NS.Chords = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : globalThis);
