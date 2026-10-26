// Battiti, battute e parti su canzoni finte: tempo, primo battito della battuta e ritornello che torna
// (RhythmTests in Tests/AnalysisTests.swift).
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const Rhythm = require("../rhythm.js");

const sr = 44100;
const near = (a, b, tol, msg) => assert.ok(Math.abs(a - b) <= tol, `${msg || ""} ${a} invece di ${b} (±${tol})`);

/// Un colpo corto (rumore che si spegne) a ogni battito; il primo di ogni battuta più forte e più basso.
function song(bpm, seconds, offsetBeats = 0) {
  const n = Math.trunc(seconds * sr);
  const drums = new Float32Array(n), bass = new Float32Array(n);
  const period = 60 / bpm;
  let k = 0, t = 0.2;
  while (t < seconds - 0.3) {
    const s = Math.trunc(t * sr);
    const down = (k + offsetBeats) % 4 === 0;
    for (let i = 0; i < 2000 && s + i < n; i++) {
      const env = Math.fround(Math.exp(-i / 300));
      drums[s + i] += (down ? 0.9 : 0.5) * env * (Math.random() * 2 - 1);
      if (down) bass[s + i] += 0.6 * env * Math.sin((2 * Math.PI * 55 * i) / sr);
    }
    k += 1;
    t += period;
  }
  return { drums, bass };
}

test("i battiti seguono il tempo", () => {
  const { drums, bass } = song(120, 30);
  const s = Rhythm.structure({ rhythm: drums, low: bass, harmonic: bass, vocal: new Float32Array(drums.length), all: drums, bpm: 120 });
  assert.ok(s);
  const gaps = s.beats.slice(1).map((b, i) => b - s.beats[i]).sort((a, b) => a - b);
  near(gaps[Math.trunc(gaps.length / 2)], 0.5, 0.02, "a 120 BPM un battito ogni mezzo secondo");
  assert.ok(s.beats.length > 50);
});

test("il primo battito della battuta è quello forte", () => {
  // Il primo colpo della canzone è il terzo della battuta: il primo battito vero è il secondo colpo dopo
  const { drums, bass } = song(100, 40, 2);
  const s = Rhythm.structure({ rhythm: drums, low: bass, harmonic: bass, vocal: new Float32Array(drums.length), all: drums, bpm: 100 });
  assert.ok(s);
  // Ogni primo battito della battuta deve cadere dove c'è il basso
  const down = Rhythm.downbeats(s);
  const hits = down.filter((t) => { const i = Math.trunc(t * sr); return Rhythm.rms(bass, i - 500, i + 1500) > 0.05; });
  assert.ok(hits.length / Math.max(1, down.length) > 0.8);
});

test("nomi delle parti dalle ripetizioni", () => {
  // Strofa (voce piano), ritornello (voce forte), strofa, ritornello: il gruppo che torna più forte è il ritornello
  assert.deepStrictEqual(Rhythm.labels([0, 1, 0, 1, 2], [0.3, 0.5, 0.3, 0.5, 0.0], [0.2, 0.6, 0.2, 0.6, 0.1]),
    ["Strofa", "Ritornello", "Strofa", "Ritornello", "Finale"]);
  assert.strictEqual(Rhythm.labels([3, 0, 1, 0, 1], [0, 0.3, 0.5, 0.3, 0.5], [0.1, 0.2, 0.6, 0.2, 0.6])[0], "Intro");
});

test("confini dove la canzone cambia", () => {
  // Due blocchi di 8 battute molto diversi: il confine cade sull'ottava
  const a = [1, 0, 0], b = [0, 1, 0];
  const feats = [...Array(8).fill(a), ...Array(8).fill(b)];
  const sim = feats.map((x) => feats.map((y) => Rhythm.cosine(x, y)));
  assert.deepStrictEqual(Rhythm.boundaries(Rhythm.novelty(sim)), [0, 8, 16]);
});

test("battiti: periodo troppo corto o segnale troppo breve", () => {
  assert.deepStrictEqual(Rhythm.beats(new Float32Array(10), 50), []);
  assert.deepStrictEqual(Rhythm.beats(new Float32Array(1000), 1), []);
});
