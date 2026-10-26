// ════════════════════════════════════════════════════════════════════
//  Battiti, battute e parti della canzone, calcolati sulle tracce separate.
//  • Battiti: dagli attacchi della batteria, con la programmazione dinamica
//    di Ellis (2007): ogni battito cade su un attacco forte e lontano dal
//    precedente quanto vuole il tempo.
//  • Primo battito della battuta (4/4): dove il basso attacca e gli accordi
//    cambiano più spesso, tra le quattro posizioni possibili.
//  • Parti: le battute si confrontano tra loro (accordi, timbro, voce); i
//    punti dove la canzone «cambia» dividono le parti, le parti che si
//    somigliano hanno la stessa lettera. Il ritornello è la parte con la voce
//    che torna più volte ed è più forte; senza voce: intro, strumentale, finale.
//  Copia di Sources/Rhythm.swift: se lì cambia qualcosa, va cambiato anche qui.
// ════════════════════════════════════════════════════════════════════
(function (root) {
  "use strict";

  const NS = (root.IsoLR = root.IsoLR || {});
  const need = (file, name) => (typeof module !== "undefined" && module.exports ? require("./" + file) : NS[name]);
  const STFT = () => need("stft.js", "STFT");

  const rate = 44100;
  const hop = 441;                                   // 100 colonne al secondo

  /// I primi battiti di ogni battuta (struttura: {beats, firstDownbeat, beatsPerBar, sections}).
  function downbeats(s) {
    const out = [];
    for (let i = s.firstDownbeat; i < s.beats.length; i += s.beatsPerBar) out.push(s.beats[i]);
    return out;
  }

  // ── Battiti ────────────────────────────────────────────────────────

  /// Battiti (in colonne) dalla forza degli attacchi `env` e dal periodo `period` (colonne per battito).
  function beats(env, period, tightness = 100) {
    const n = env.length;
    if (!(n > Math.trunc(period * 4)) || !(period >= 2)) return [];
    // Gli attacchi si normalizzano, così la tolleranza sul tempo pesa allo stesso modo in ogni canzone
    let mean = 0;
    for (let i = 0; i < n; i++) mean += env[i];
    mean /= n;
    let v = 0;
    for (let i = 0; i < n; i++) v += (env[i] - mean) * (env[i] - mean);
    const sd = Math.max(1e-9, Math.sqrt(v / n));
    const score = new Float64Array(n);
    const back = new Int32Array(n).fill(-1);
    const R = STFT().round;
    const lo = R(period / 2), hi = R(period * 2);
    // Il costo di ogni distanza si calcola una volta sola
    const pen = new Float64Array(hi + 1);
    for (let d = 1; d <= hi; d++) { const l = Math.log(d / period); pen[d] = tightness * l * l; }
    for (let t = 0; t < n; t++) {
      let best = 0, arg = -1;
      if (t - lo >= 0) {
        for (let p = Math.max(0, t - hi); p <= t - lo; p++) {
          const s = score[p] - pen[t - p];
          if (arg < 0 || s > best) { best = s; arg = p; }
        }
      }
      score[t] = env[t] / sd + Math.max(0, best);
      back[t] = best > 0 ? arg : -1;
    }
    // L'ultimo battito: il punteggio più alto nell'ultimo periodo
    let t = -1;
    for (let i = Math.max(0, n - Math.trunc(period)); i < n; i++) if (t < 0 || score[i] > score[t]) t = i;
    if (t < 0) t = n - 1;
    const out = [];
    while (t >= 0) { out.push(t); t = back[t]; }
    return out.reverse();
  }

  /// Il massimo di `x` attorno alla colonna `i` (±w).
  function around(x, i, w = 3) {
    const a = Math.max(0, i - w), b = Math.min(x.length, i + w + 1);
    if (!(b > a)) return 0;
    let s = 0;
    for (let k = a; k < b; k++) if (x[k] > s) s = x[k];
    return s;
  }

  /// Tra le `bpb` posizioni, quella del primo battito: dove attacca il basso (o la cassa) e cambiano gli accordi.
  function downbeatPhase(beatCols, low, change, bpb = 4) {
    if (beatCols.length < bpb * 2) return 0;
    let best = 0, bestScore = -Infinity;
    let top = low.length ? -Infinity : 1;
    for (let i = 0; i < low.length; i++) if (low[i] > top) top = low[i];
    const lowMax = Math.max(1e-9, top);
    for (let phase = 0; phase < bpb; phase++) {
      let s = 0, n = 0;
      for (let i = phase; i < beatCols.length; i += bpb) {
        s += around(low, beatCols[i]) / lowMax + (i < change.length ? change[i] : 0);
        n += 1;
      }
      const score = n > 0 ? s / n : 0;
      if (score > bestScore) { bestScore = score; best = phase; }
    }
    return best;
  }

  // ── Caratteristiche per battito ───────────────────────────────────

  /// Note (Do…Si) per finestre di `hop` campioni, normalizzate: una riga (Float64Array 12) per finestra.
  function chromaFrames(x, fft = 8192, step = 4410) {
    const { PlainSTFT, pitchClasses } = STFT();
    const s = PlainSTFT.shared(fft, step);
    const F = s.bins, pc = pitchClasses(fft, rate, 55, 5000);
    const out = [];
    s.magnitudes(x, (t, mag) => {
      const row = new Float64Array(12);
      let total = 0;
      for (let f = 1; f < F; f++) {
        const p = pc[f];
        if (p < 0) continue;
        row[p] += mag[f];
        total += mag[f];
      }
      if (total > 1e-9) for (let i = 0; i < 12; i++) row[i] /= total;
      out.push(row);
    });
    return out;
  }

  /// Energia (RMS) di `x` tra i campioni `a` e `b`.
  function rms(x, a, b) {
    a = Math.max(0, Math.min(x.length, a));
    b = Math.max(a, Math.min(x.length, b));
    if (!(b > a)) return 0;
    let s = 0;
    for (let i = a; i < b; i++) s += x[i] * x[i];
    return Math.fround(Math.sqrt(s / (b - a)));
  }

  function cosine(a, b) {
    let ab = 0, aa = 0, bb = 0;
    const n = Math.min(a.length, b.length);
    for (let i = 0; i < n; i++) { ab += a[i] * b[i]; aa += a[i] * a[i]; bb += b[i] * b[i]; }
    return aa > 0 && bb > 0 ? ab / Math.sqrt(aa * bb) : 0;
  }

  // ── Parti ─────────────────────────────────────────────────────────

  /// Dove la canzone cambia: novità di Foote sulla matrice delle somiglianze tra battute (kernel a scacchiera).
  function novelty(sim, half = 4) {
    const n = sim.length;
    const out = new Array(n).fill(0);
    for (let i = 0; i < n; i++) {
      let s = 0;
      for (let a = -half; a < half; a++) {
        for (let b = -half; b < half; b++) {
          const x = i + a, y = i + b;
          if (x < 0 || y < 0 || x >= n || y >= n) continue;
          // Stessa parte (entrambi prima o entrambi dopo): +; a cavallo: −
          const sign = (a < 0) === (b < 0) ? 1 : -1;
          const g = Math.exp(-0.5 * (Math.pow((a + 0.5) / half, 2) + Math.pow((b + 0.5) / half, 2)));
          s += sign * g * sim[x][y];
        }
      }
      out[i] = Math.max(0, s);
    }
    return out;
  }

  /// I confini (indici di battuta) dai picchi della novità: almeno `minBars` battute per parte.
  function boundaries(nov, minBars = 4) {
    const n = nov.length;
    if (!(n > minBars * 2)) return [0, n];
    const mean = nov.reduce((s, v) => s + v, 0) / n;
    const sd = Math.sqrt(nov.reduce((s, v) => s + (v - mean) * (v - mean), 0) / n);
    const threshold = mean + 0.5 * sd;
    const peaks = [];
    for (let i = 1; i < n - 1; i++) {
      if (nov[i] > threshold && nov[i] >= nov[i - 1] && nov[i] >= nov[i + 1]) peaks.push({ i, v: nov[i] });
    }
    // I più forti per primi; un picco troppo vicino a uno già scelto si scarta
    const chosen = [];
    for (const p of peaks.sort((a, b) => b.v - a.v)) {
      if (chosen.every((c) => Math.abs(c - p.i) >= minBars) && p.i >= minBars && n - p.i >= minBars) chosen.push(p.i);
    }
    return [0, ...chosen.sort((a, b) => a - b), n];
  }

  /// Le parti si raggruppano per somiglianza: una parte nuova va nel gruppo più simile, se lo è abbastanza.
  function groups(features, threshold = 0.93) {
    const centers = [], counts = [], out = [];
    for (const f of features) {
      let best = -1, bestSim = -1;
      centers.forEach((c, g) => {
        const s = cosine(f, c);
        if (s > bestSim) { bestSim = s; best = g; }
      });
      if (best >= 0 && bestSim >= threshold) {
        out.push(best);
        const k = counts[best];
        centers[best] = centers[best].map((v, j) => (v * k + f[j]) / (k + 1));
        counts[best] += 1;
      } else {
        out.push(centers.length);
        centers.push(Array.from(f));
        counts.push(1);
      }
    }
    return out;
  }

  /// I nomi delle parti dai gruppi, dalla voce e dal volume.
  function labels(groupsOf, vocal, loud) {
    const n = groupsOf.length;
    if (n === 0) return [];
    const maxLoud = Math.max(1e-9, loud.length ? Math.max(...loud) : 1);
    const sung = groupsOf.map((_, i) => vocal[i] > 0.12);
    const count = new Map();
    for (const g of groupsOf) count.set(g, (count.get(g) || 0) + 1);
    // Ritornello: tra i gruppi cantati, quello che torna di più e suona più forte.
    // (In Swift si scorre un Set, in ordine casuale: qui nell'ordine in cui i gruppi compaiono.)
    let chorus = null, bestScore = -1;
    for (const g of new Set(groupsOf)) {
      const idx = [];
      for (let i = 0; i < n; i++) if (groupsOf[i] === g && sung[i]) idx.push(i);
      if (!idx.length || (count.get(g) || 0) < 2) continue;
      const s = count.get(g) + (2 * idx.reduce((a, i) => a + loud[i] / maxLoud, 0)) / idx.length;
      if (s > bestScore) { bestScore = s; chorus = g; }
    }
    const out = [];
    let seenChorus = false;
    for (let i = 0; i < n; i++) {
      if (!sung[i]) {
        out.push(i === 0 ? "Intro" : i === n - 1 ? "Finale" : "Strumentale");
      } else if (groupsOf[i] === chorus) {
        out.push("Ritornello"); seenChorus = true;
      } else if (count.get(groupsOf[i]) === 1 && seenChorus && i < n - 1) {
        out.push("Ponte");
      } else {
        out.push("Strofa");
      }
    }
    return out;
  }

  /// Battiti, battute e parti di una canzone separata (mono di ogni gruppo di tracce).
  /// Restituisce {beats, firstDownbeat, beatsPerBar, sections: [{start, end, label, group}]} o null.
  function structure({ rhythm, low, harmonic, vocal, all, bpm }) {
    const Analysis = need("analysis.js", "Analysis");
    const fps = rate / hop;
    const env = Analysis.onsetEnvelope(rhythm, hop);
    const beatCols = beats(env, (fps * 60) / bpm);
    if (beatCols.length < 16) return null;
    const lowEnv = Analysis.onsetEnvelope(low, hop);
    // Cambio di accordi a ogni battito: la nota media del battito prima contro quella del battito dopo
    const chroma = chromaFrames(harmonic);
    const cps = rate / 4410;
    const chromaMean = (a, b) => {
      const i0 = Math.max(0, Math.trunc(a * cps)), i1 = Math.min(chroma.length, Math.max(i0 + 1, Math.trunc(b * cps)));
      const m = new Array(12).fill(0);
      if (!(i1 > i0)) return m;
      for (let i = i0; i < i1; i++) for (let k = 0; k < 12; k++) m[k] += chroma[i][k];
      return m.map((v) => v / (i1 - i0));
    };
    const times = beatCols.map((c) => c / fps);
    const change = new Array(times.length).fill(0);
    for (let i = 1; i < times.length - 1; i++) {
      change[i] = 1 - cosine(chromaMean(times[i - 1], times[i]), chromaMean(times[i], times[i + 1]));
    }
    const bpb = 4;
    const first = downbeatPhase(beatCols, lowEnv, change, bpb);
    // Battute: dal primo battito, quattro battiti l'una
    const bars = [];
    for (let i = first; i < times.length - 1; i += bpb) {
      bars.push([times[i], i + bpb < times.length ? times[i + bpb] : times[times.length - 1]]);
    }
    if (bars.length < 8) return { beats: times, firstDownbeat: first, beatsPerBar: bpb, sections: [] };
    // Una riga per battuta: accordi (12) e timbro (volume per fasce, normalizzato), più la voce
    const sr = rate;
    const feats = bars.map(([a, b]) => {
      const c = chromaMean(a, b);
      const s0 = Math.trunc(a * sr), s1 = Math.trunc(b * sr);
      const l = rms(all, s0, s1) + 1e-9;
      return c.concat([rms(low, s0, s1) / l, rms(harmonic, s0, s1) / l, rms(vocal, s0, s1) / l, rms(rhythm, s0, s1) / l]);
    });
    const B = bars.length;
    const sim = Array.from({ length: B }, () => new Float64Array(B));
    for (let i = 0; i < B; i++) for (let j = i; j < B; j++) { const s = cosine(feats[i], feats[j]); sim[i][j] = s; sim[j][i] = s; }
    const cuts = boundaries(novelty(sim));
    const segFeat = [], vocalShare = [], loud = [];
    for (let k = 0; k < cuts.length - 1; k++) {
      const lo = cuts[k], hi = cuts[k + 1];
      const m = new Array(feats[0].length).fill(0);
      for (let i = lo; i < hi; i++) for (let j = 0; j < m.length; j++) m[j] += feats[i][j];
      segFeat.push(m.map((v) => v / (hi - lo)));
      const s0 = Math.trunc(bars[lo][0] * sr), s1 = Math.trunc(bars[hi - 1][1] * sr);
      const l = rms(all, s0, s1) + 1e-9;
      vocalShare.push(rms(vocal, s0, s1) / l);
      loud.push(l);
    }
    const g = groups(segFeat);
    const names = labels(g, vocalShare, loud);
    const sections = [];
    for (let k = 0; k < cuts.length - 1; k++) {
      const start = k === 0 ? 0 : bars[cuts[k]][0];
      const end = k === cuts.length - 2 ? all.length / sr : bars[cuts[k + 1]][0];
      // Due parti uguali di fila diventano una sola
      const last = sections[sections.length - 1];
      if (last && last.label === names[k] && last.group === g[k]) {
        sections[sections.length - 1] = { start: last.start, end, label: last.label, group: last.group };
      } else {
        sections.push({ start, end, label: names[k], group: g[k] });
      }
    }
    return { beats: times, firstDownbeat: first, beatsPerBar: bpb, sections };
  }

  const api = { rate, hop, downbeats, beats, downbeatPhase, chromaFrames, rms, cosine, novelty, boundaries, groups, labels, structure };
  NS.Rhythm = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : globalThis);
