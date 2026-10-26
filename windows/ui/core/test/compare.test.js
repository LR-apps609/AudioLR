// Confronto con l'originale (Tests/CompareTests.swift).
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const Compare = require("../compare.js");

const near = (a, b, tol, msg) => assert.ok(Math.abs(a - b) <= tol, `${msg || ""} ${a} invece di ${b} (±${tol})`);

/// Una melodia di note tenute (con armonici), con pause tra una nota e l'altra.
function melody(notes, { cents = 0, delay = 0, octave = 0 } = {}) {
  const sr = 44100, note = 0.5, gap = 0.1;
  const x = new Float32Array(Math.trunc((notes.length * (note + gap) + 1) * sr));
  notes.forEach((m, k) => {
    const f = 440 * Math.pow(2, (m - 69 + cents / 100) / 12 + octave);
    const start = Math.trunc((k * (note + gap) + delay + 0.2) * sr);
    for (let i = 0; i < Math.trunc(note * sr); i++) {
      const t = i / sr;
      const env = Math.min(1, t / 0.01) * Math.min(1, (note - t) / 0.02);
      x[start + i] = 0.3 * env * (Math.sin(2 * Math.PI * f * t) + 0.4 * Math.sin(4 * Math.PI * f * t));
    }
  });
  return x;
}

const tune = [60, 62, 64, 65, 67, 65, 64, 62, 60, 64, 67, 72];

test("la stessa melodia è intonata", () => {
  const r = Compare.run(melody(tune), melody(tune));
  assert.ok(r.inTune > 0.95, `${r.inTune}`);
  near(r.cents, 0, 5);
  near(r.offsetMs, 0, 10);
  assert.strictEqual(r.verdict, "Ottimo");
});

test("crescente e in ritardo", () => {
  const r = Compare.run(melody(tune, { cents: 30, delay: 0.05 }), melody(tune));
  near(r.cents, 30, 6);
  near(r.offsetMs, 50, 15);
});

test("stonata", () => {
  const r = Compare.run(melody(tune, { cents: 100 }), melody(tune));
  assert.ok(r.inTune < 0.2, `${r.inTune}`);
  assert.strictEqual(r.verdict, "Da ripassare");
});

test("un'ottava sopra vale la stessa nota", () => {
  const r = Compare.run(melody(tune, { octave: 1 }), melody(tune));
  assert.ok(r.inTune > 0.9, `${r.inTune}`);
});

test("il silenzio è un errore", () => {
  assert.throws(() => Compare.run(new Float32Array(44100 * 3), melody(tune)), (e) => e.code === "silent");
});

test("YIN trova il La 440", () => {
  const sr = 11025;
  const x = Float32Array.from({ length: 2048 }, (_, i) => Math.sin((2 * Math.PI * 440 * i) / sr));
  near(Compare.yin(x, 0, sr) ?? 0, 440, 2);
});
