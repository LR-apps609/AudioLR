// ════════════════════════════════════════════════════════════════════
//  Dall'audio alle note: Basic Pitch di Spotify (licenza Apache 2.0) trova
//  le note di una traccia, e qui diventano un file MIDI da trascinare in un
//  programma di musica. La rete gira fuori di qui (onnxruntime-web); qui c'è
//  tutto il resto, identico all'app: preparazione dell'audio, finestre,
//  ricerca delle note (copia di basic_pitch/note_creation.py) e file MIDI.
//  Copia di Sources/Midi.swift: se lì cambia qualcosa, va cambiato anche qui.
// ════════════════════════════════════════════════════════════════════
(function (root) {
  "use strict";

  const NS = (root.IsoLR = root.IsoLR || {});
  const f32 = Math.fround;
  const round = (x) => (x < 0 ? -Math.floor(-x + 0.5) : Math.floor(x + 0.5));

  /// Una nota: inizio e fine in secondi, nota MIDI (60 = Do centrale), forza 1…127.
  function note(start, end, pitch, velocity) { return { start, end, pitch, velocity }; }

  // Le misure di Basic Pitch (basic_pitch/constants.py)
  const rate = 22050;
  const hop = 256;
  const windowSamples = rate * 2 - hop;              // 43 844 campioni per finestra
  const framesPerWindow = 172;
  const overlapFrames = 30;
  const fps = Math.trunc(rate / hop);                 // 86 colonne al secondo
  const midiOffset = 21;                              // la prima nota del pianoforte (La0)
  const keys = 88;

  // ── Audio ─────────────────────────────────────────────────────────

  /// Stereo a 44,1 kHz → mono a 22 050 Hz (con filtro, perché le frequenze alte non tornino giù come rumore).
  function prepare(audio) {
    if (!audio.length || !audio[0].length) return new Float32Array(0);
    const n = audio[0].length;
    let mono = audio[0];
    if (audio.length > 1) {
      mono = new Float32Array(n);
      for (let i = 0; i < n; i++) mono[i] = f32(f32(audio[0][i] + audio[1][i]) * 0.5);
    }
    // Filtro passa-basso a 31 coefficienti (sinc con finestra di Hann), taglio a 10 kHz, poi un campione su due
    const taps = 31, cutoff = 10000 / 44100;
    const h = new Float32Array(taps);
    for (let i = 0; i < taps; i++) {
      const x = i - Math.trunc(taps / 2);
      const sinc = x === 0 ? 2 * cutoff : Math.sin(2 * Math.PI * cutoff * x) / (Math.PI * x);
      h[i] = sinc * (0.5 - 0.5 * Math.cos((2 * Math.PI * i) / (taps - 1)));
    }
    // Come vDSP_desamp sull'onda con 15 zeri davanti: out[k] = Σ padded[2k + p] · h[p]
    const pad = Math.trunc(taps / 2);
    const outCount = Math.trunc((n + 1) / 2);
    const out = new Float32Array(outCount);
    for (let k = 0; k < outCount; k++) {
      let s = 0;
      const base = 2 * k - pad;
      for (let p = 0; p < taps; p++) {
        const j = base + p;
        if (j >= 0 && j < n) s += mono[j] * h[p];
      }
      out[k] = s;
    }
    return out;
  }

  // ── Rete ──────────────────────────────────────────────────────────

  /// Le finestre da dare alla rete (ognuna lunga `windowSamples`), su tutta la traccia già a 22 050 Hz.
  function windows(x) {
    const W = windowSamples;
    const overlap = overlapFrames * hop;
    const step = W - overlap;
    const lead = overlap / 2;
    const total = lead + x.length;
    const out = [];
    for (let start = 0; start < total; start += step) {
      const win = new Float32Array(W);
      for (let i = 0; i < W && start + i < total; i++) {
        const j = start + i - lead;
        if (j >= 0) win[i] = x[j];
      }
      out.push(win);
    }
    return out;
  }

  /// Note e attacchi per ogni colonna (colonne × 88), su tutta la traccia (già a 22 050 Hz).
  /// `run(finestra)` → {frames, onsets}: Float32Array 172×88 (la rete, per esempio con onnxruntime-web; può essere async).
  async function activations(x, run, isCancelled = () => false) {
    const T = framesPerWindow, K = keys, half = overlapFrames / 2;
    const frames = [], onsets = [];
    for (const win of windows(x)) {
      if (isCancelled()) { const e = new Error("annullato"); e.name = "AbortError"; throw e; }
      const { frames: f, onsets: o } = await run(win);
      // Si tolgono le colonne sovrapposte, metà all'inizio e metà alla fine (unwrap_output)
      for (let t = half; t < T - half; t++) {
        frames.push(Float32Array.from(f.subarray ? f.subarray(t * K, (t + 1) * K) : f.slice(t * K, (t + 1) * K)));
        onsets.push(Float32Array.from(o.subarray ? o.subarray(t * K, (t + 1) * K) : o.slice(t * K, (t + 1) * K)));
      }
    }
    const total = Math.floor((x.length * fps) / rate);
    return { frames: frames.slice(0, total), onsets: onsets.slice(0, total) };
  }

  // ── Note ──────────────────────────────────────────────────────────

  /// Le note dalle attivazioni (output_to_notes_polyphonic, con il «trucco Melodia»).
  /// `frames`, `onsets`: una riga (88 valori) per colonna. I calcoli seguono i Float a 32 bit dell'app.
  function notes(frames, rawOnsets, { onsetThreshold = 0.5, frameThreshold = 0.3, minNoteLength = 11,
                                      energyTolerance = 11, melodia = true } = {}) {
    const n = frames.length, K = keys;
    if (!(n > 2)) return [];
    onsetThreshold = f32(onsetThreshold);
    frameThreshold = f32(frameThreshold);
    // Attacchi in più dove le note crescono di colpo (get_infered_onsets, 2 differenze)
    const diff = new Float32Array(n * K);
    let maxDiff = 0, maxOnset = 0;
    for (let t = 0; t < n; t++) {
      for (let k = 0; k < K; k++) {
        maxOnset = Math.max(maxOnset, f32(rawOnsets[t][k]));
        if (t < 2) continue;
        const d1 = f32(frames[t][k] - frames[t - 1][k]), d2 = f32(frames[t][k] - frames[t - 2][k]);
        const d = Math.max(0, Math.min(d1, d2));
        diff[t * K + k] = d;
        maxDiff = Math.max(maxDiff, d);
      }
    }
    const onsets = new Float32Array(n * K);
    for (let t = 0; t < n; t++) for (let k = 0; k < K; k++) onsets[t * K + k] = rawOnsets[t][k];
    if (maxDiff > 0) {
      for (let i = 0; i < n * K; i++) onsets[i] = Math.max(onsets[i], f32(f32(maxOnset * diff[i]) / maxDiff));
    }
    // Massimi locali nel tempo sopra la soglia, dal più recente al più vecchio (come np.where al contrario)
    const peaks = [];
    for (let t = 1; t < n - 1; t++) {
      for (let k = 0; k < K; k++) {
        const v = onsets[t * K + k];
        if (v > onsets[(t - 1) * K + k] && v > onsets[(t + 1) * K + k] && v >= onsetThreshold) peaks.push([t, k]);
      }
    }
    peaks.reverse();

    const fr = new Float32Array(n * K);
    for (let t = 0; t < n; t++) for (let k = 0; k < K; k++) fr[t * K + k] = frames[t][k];
    const energy = Float32Array.from(fr);
    const found = [];
    const clear = (t, k) => {
      energy[t * K + k] = 0;
      if (k < K - 1) energy[t * K + k + 1] = 0;
      if (k > 0) energy[t * K + k - 1] = 0;
    };
    const mean = (a, b, k) => {
      if (!(b > a)) return 0;
      let s = 0;
      for (let t = a; t < b; t++) s = f32(s + fr[t * K + k]);
      return f32(s / (b - a));
    };
    for (const [start, k] of peaks) {
      if (start >= n - 1) continue;
      let i = start + 1, below = 0;
      while (i < n - 1 && below < energyTolerance) {
        below = energy[i * K + k] < frameThreshold ? below + 1 : 0;
        i += 1;
      }
      i -= below;
      if (i - start <= minNoteLength) continue;
      for (let t = start; t < i; t++) clear(t, k);
      found.push({ start, end: i, pitch: k + midiOffset, amp: mean(start, i, k) });
    }
    if (melodia) {
      // Le celle con energia, dalla più forte: l'energia si può solo azzerare, mai crescere,
      // quindi la più forte rimasta è sempre la prima della lista non ancora azzerata
      const cells = [];
      for (let t = 0; t < n; t++) for (let k = 0; k < K; k++) if (energy[t * K + k] > frameThreshold) cells.push(t * K + k);
      cells.sort((a, b) => (energy[a] !== energy[b] ? energy[b] - energy[a] : a - b));
      for (const c of cells) {
        const bt = Math.trunc(c / K), bk = c % K;
        if (!(energy[c] > frameThreshold)) continue;
        energy[c] = 0;
        let i = bt + 1, below = 0;
        while (i < n - 1 && below < energyTolerance) {
          below = energy[i * K + bk] < frameThreshold ? below + 1 : 0;
          clear(i, bk);
          i += 1;
        }
        const end = i - 1 - below;
        i = bt - 1;
        below = 0;
        while (i > 0 && below < energyTolerance) {
          below = energy[i * K + bk] < frameThreshold ? below + 1 : 0;
          clear(i, bk);
          i -= 1;
        }
        const start = i + 1 + below;
        if (end - start <= minNoteLength) continue;
        found.push({ start, end, pitch: bk + midiOffset, amp: mean(start, end, bk) });
      }
    }
    return found
      .map((x) => note(time(x.start), time(x.end), x.pitch, Math.max(1, Math.min(127, round(f32(127 * x.amp))))))
      .sort((a, b) => (a.start !== b.start ? a.start - b.start : a.pitch - b.pitch));
  }

  /// Secondi di una colonna, con la correzione di Basic Pitch per le finestre (model_frames_to_time).
  function time(f) {
    const original = (f * hop) / rate;
    const offset = (hop / rate) * (framesPerWindow - windowSamples / hop) + 0.0018;
    return original - offset * Math.floor(f / framesPerWindow);
  }

  /// Tutta la traccia: dall'audio separato (stereo a 44,1 kHz) alle note, con la rete `run`.
  async function transcribe(audio, run, isCancelled) {
    const a = await activations(prepare(audio), run, isCancelled);
    return notes(a.frames, a.onsets);
  }

  // ── File MIDI ─────────────────────────────────────────────────────

  /// Il suono General MIDI più vicino a ogni traccia.
  function program(stem) {
    switch (stem) {
      case "vocals": case "lead": case "male": case "female": return 53;   // voce «oohs»
      case "backing": return 52;                 // coro «aahs»
      case "bass": return 33;                    // basso elettrico
      case "guitar": return 25;                  // chitarra acustica
      case "piano": return 0;                    // pianoforte
      default: return 48;                        // archi
    }
  }

  /// Un file MIDI (formato 0, una traccia) con le note, al tempo della canzone se si conosce: Uint8Array.
  function data(list, { bpm = 120, program: prog = 0, name = "" } = {}) {
    const ppq = 480;
    const tempo = Math.max(30, Math.min(300, bpm));
    const ticks = (s) => round(((s * tempo) / 60) * ppq);
    const vlq = (v) => {
      v = Math.max(0, v);
      const bytes = [v & 0x7f];
      v >>= 7;
      while (v > 0) { bytes.unshift((v & 0x7f) | 0x80); v >>= 7; }
      return bytes;
    };
    // Eventi assoluti: (tick, ordine, byte); a parità di tick prima gli spegnimenti
    const events = [];
    for (const n of list) {
      const p = Math.max(0, Math.min(127, n.pitch));
      events.push({ tick: ticks(n.start), order: 1, bytes: [0x90, p, n.velocity & 0xff] });
      events.push({ tick: Math.max(ticks(n.end), ticks(n.start) + 1), order: 0, bytes: [0x80, p, 0] });
    }
    events.sort((a, b) => (a.tick !== b.tick ? a.tick - b.tick : a.order - b.order));
    const track = [];
    const title = Array.from(new TextEncoder().encode(name).subarray(0, 120));
    if (title.length) track.push(0x00, 0xff, 0x03, ...vlq(title.length), ...title);
    const us = Math.trunc(60000000 / tempo);
    track.push(0x00, 0xff, 0x51, 0x03, (us >> 16) & 0xff, (us >> 8) & 0xff, us & 0xff);
    track.push(0x00, 0xc0, prog & 0xff);
    let last = 0;
    for (const e of events) {
      track.push(...vlq(e.tick - last), ...e.bytes);
      last = e.tick;
    }
    track.push(0x00, 0xff, 0x2f, 0x00);
    const be32 = (v) => [(v >>> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];
    const ascii = (s) => Array.from(s, (c) => c.charCodeAt(0));
    const out = [...ascii("MThd"), ...be32(6), 0, 0, 0, 1, ppq >> 8, ppq & 0xff, ...ascii("MTrk"), ...be32(track.length)];
    const bytes = new Uint8Array(out.length + track.length);
    bytes.set(out, 0);
    bytes.set(track, out.length);
    return bytes;
  }

  const api = { note, rate, hop, windowSamples, framesPerWindow, overlapFrames, fps, midiOffset, keys,
                prepare, windows, activations, notes, time, transcribe, MidiFile: { program, data } };
  NS.Midi = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : globalThis);
