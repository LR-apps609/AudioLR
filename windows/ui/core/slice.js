// ════════════════════════════════════════════════════════════════════
//  Slice to MIDI, come Sources/Slicer.swift sul Mac: gli attacchi di una
//  traccia (flusso spettrale con soglia che segue la musica), le fette tra
//  un attacco e l'altro, i ritocchi (sposta, unisci, dividi), l'audio di ogni
//  fetta con dissolvenze brevi e il file MIDI che le richiama nel ritmo della
//  canzone (nota 36 = fetta 1, come i pad di un Drum Rack).
// ════════════════════════════════════════════════════════════════════
(function (root) {
  "use strict";
  const NS = (root.IsoLR = root.IsoLR || {});
  const STFT = NS.STFT || (typeof require !== "undefined" ? require("./stft.js") : null);
  const Midi = NS.Midi || (typeof require !== "undefined" ? require("./midi.js") : null);
  const N = 1024, H = 256;                          // finestra di 23 ms, un passo ogni 5,8 ms a 44,1 kHz
  const FIRST_NOTE = 36;                            // Do1: il primo pad di un Drum Rack

  /** Mono dalla traccia stereo. */
  function mono(ch) {
    const n = ch[0].length, out = new Float32Array(n), r = ch[1] || ch[0];
    for (let i = 0; i < n; i++) out[i] = (ch[0][i] + r[i]) / 2;
    return out;
  }

  /** Il flusso spettrale (quanto cresce l'energia, banda per banda), normalizzato a 1. */
  function flux(x) {
    const frames = Math.max(0, Math.floor((x.length - N) / H) + 1);
    const fft = new STFT.RealFFT(N), re = new Float64Array(N / 2 + 1), im = new Float64Array(N / 2 + 1);
    const win = new Float64Array(N), buf = new Float64Array(N);
    for (let i = 0; i < N; i++) win[i] = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / N);
    let prev = new Float64Array(N / 2 + 1), cur = new Float64Array(N / 2 + 1);
    const out = new Float32Array(frames);
    let top = 0;
    for (let f = 0; f < frames; f++) {
      for (let i = 0; i < N; i++) buf[i] = x[f * H + i] * win[i];
      fft.forward(buf, re, im);
      let s = 0;
      for (let k = 1; k <= N / 2; k++) {
        cur[k] = Math.log1p(10 * Math.hypot(re[k], im[k]));
        const d = cur[k] - prev[k];
        if (d > 0) s += d;
      }
      out[f] = f === 0 ? 0 : s;
      if (out[f] > top) top = out[f];
      [prev, cur] = [cur, prev];
    }
    if (top > 0) for (let f = 0; f < frames; f++) out[f] /= top;
    return out;
  }

  /** Gli attacchi, in campioni. `sensitivity` 0…1 (più alta = più colpi), `minGap` secondi tra due colpi. */
  function onsets(ch, rate = 44100, { sensitivity = 0.5, minGap = 0.07 } = {}) {
    const x = ch instanceof Float32Array ? ch : mono(ch);
    const fl = flux(x), half = Math.max(2, Math.round((0.1 * rate) / H));
    const delta = 0.03 + 0.3 * (1 - Math.max(0, Math.min(1, sensitivity)));
    const gap = Math.round((minGap * rate) / H);
    const out = [];
    let last = -Infinity, sum = 0;
    // Media mobile su ±0,1 s: la soglia sale dove la musica è piena e scende dove è vuota
    for (let i = 0; i < Math.min(fl.length, half); i++) sum += fl[i];
    for (let i = 0; i < fl.length; i++) {
      const a = i - half - 1, b = i + half;
      if (b < fl.length) sum += fl[b];
      if (a >= 0) sum -= fl[a];
      const count = Math.min(fl.length, i + half + 1) - Math.max(0, i - half);
      const thr = sum / count + delta;
      const v = fl[i];
      if (v < thr || v < 0.04) continue;
      if ((i > 0 && fl[i - 1] > v) || (i + 1 < fl.length && fl[i + 1] >= v)) continue;
      if (i - last < gap) continue;
      // Il flusso cresce quando il colpo entra nella finestra: l'attacco è verso la sua fine
      out.push(Math.max(0, i * H + N - H));
      last = i;
    }
    return out;
  }

  /** Le fette: da ogni attacco (con un piccolo anticipo) al successivo; l'ultima fino alla fine. */
  function slices(starts, length, rate = 44100, { preroll = 0.005 } = {}) {
    const pre = Math.round(preroll * rate);
    const pos = [...new Set(starts.map((s) => Math.max(0, Math.min(length - 1, s - pre))))].sort((a, b) => a - b);
    if (!pos.length) return length > 0 ? [{ start: 0, end: length }] : [];
    return pos.map((s, i) => ({ start: s, end: i + 1 < pos.length ? pos[i + 1] : length }));
  }

  const MIN = (rate) => Math.round(0.01 * rate);

  /** Sposta l'inizio della fetta `i` (e la fine della precedente), senza scavalcare le vicine. */
  function move(list, i, to, rate = 44100) {
    if (i <= 0 || i >= list.length) return list;
    const lo = list[i - 1].start + MIN(rate), hi = list[i].end - MIN(rate);
    const p = Math.round(Math.max(lo, Math.min(hi, to)));
    return list.map((s, k) => (k === i - 1 ? { ...s, end: p } : k === i ? { ...s, start: p } : s));
  }

  /** Unisce la fetta `i` con la successiva. */
  function merge(list, i) {
    if (i < 0 || i + 1 >= list.length) return list;
    const out = list.slice();
    out.splice(i, 2, { start: list[i].start, end: list[i + 1].end });
    return out;
  }

  /** Divide in due la fetta che contiene `at`. */
  function split(list, at, rate = 44100) {
    const i = list.findIndex((s) => at > s.start + MIN(rate) && at < s.end - MIN(rate));
    if (i < 0) return list;
    const p = Math.round(at), out = list.slice();
    out.splice(i, 1, { start: list[i].start, end: p }, { start: p, end: list[i].end });
    return out;
  }

  /** L'audio di una fetta, con dissolvenze brevi ai bordi (niente clic). */
  function render(ch, s, rate = 44100, fade = 0.003) {
    const n = Math.max(0, s.end - s.start), f = Math.min(Math.floor(n / 2), Math.round(fade * rate));
    return ch.map((c) => {
      const out = c.slice(s.start, s.end);
      for (let i = 0; i < f; i++) { const g = i / f; out[i] *= g; out[n - 1 - i] *= g; }
      return out;
    });
  }

  /** La nota MIDI di una fetta (36, 37, …; mai oltre 127). */
  const noteOf = (i) => Math.min(127, FIRST_NOTE + i);

  /** Il file MIDI che suona le fette nel loro ritmo originale. */
  function midi(list, rate, { bpm = 120, name = "" } = {}) {
    const notes = list.map((s, i) => ({ start: s.start / rate, end: s.end / rate, pitch: noteOf(i), velocity: 100 }));
    return Midi.MidiFile.data(notes, { bpm, program: 0, name });
  }

  /** Il nome di ogni file: «Slice 01.wav»… */
  const fileName = (i) => `Slice ${String(i + 1).padStart(2, "0")}.wav`;

  /** Come caricare le fette nei programmi musicali. */
  function readme(title, stem, count, bpm) {
    return [
      `${title} – Slice ${stem}`,
      ``,
      `${count} fette (Slice 01.wav … Slice ${String(count).padStart(2, "0")}.wav) e un file MIDI che le suona nel ritmo originale${bpm ? ` (${Math.round(bpm)} BPM)` : ""}.`,
      `La fetta 1 è la nota 36 (Do1), la fetta 2 la nota 37, e così via: come i pad di un Drum Rack.`,
      ``,
      `Ableton Live`,
      `1. Crea una traccia MIDI con un Drum Rack vuoto.`,
      `2. Seleziona tutte le fette nel Finder/Esplora file e trascinale sul primo pad (Do1): Live le mette in fila, una per pad.`,
      `3. Trascina il file .mid nella traccia: suona le fette nel ritmo della canzone. Sposta le note per cambiare il ritmo.`,
      ``,
      `Logic Pro`,
      `1. Crea una traccia «Drum Machine Designer» (o «Quick Sampler» in modalità Slice).`,
      `2. Trascina le fette sui pad a partire da Do1 (in Quick Sampler: trascina la traccia intera e usa i segnaposto).`,
      `3. Trascina il file .mid nella traccia.`,
      ``,
      `Creato con IsoLR.`,
    ].join("\n");
  }

  const api = { mono, flux, onsets, slices, move, merge, split, render, noteOf, midi, fileName, readme, FIRST_NOTE };
  NS.Slice = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : globalThis);
