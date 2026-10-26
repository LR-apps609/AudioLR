// Tempo e tonalità su segnali di cui si sa la risposta (Tests/AnalysisTests.swift).
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const Analysis = require("../analysis.js");
const { SongAnalysis } = Analysis;

const rate = 44100;
const near = (a, b, tol, msg) => assert.ok(Math.abs(a - b) <= tol, `${msg || ""} ${a} invece di ${b} (±${tol})`);

function clicks(bpm, seconds = 20) {
  const n = Math.trunc(seconds * rate);
  const x = new Float32Array(n);
  const period = 60 / bpm;
  for (let i = 0; i < Math.trunc(seconds / period); i++) {
    const s = Math.trunc(i * period * rate);
    for (let j = 0; j < Math.min(4000, n - s); j++) {
      const t = j / rate;
      const noise = Math.random() * 2 - 1;
      x[s + j] += Math.sin(2 * Math.PI * 60 * t) * Math.exp(-t * 30) * (i % 2 === 0 ? 1 : 0.5) + 0.3 * noise * Math.exp(-t * 80);
    }
  }
  return x;
}

function chords(prog, seconds = 2) {
  const each = Math.trunc(seconds * rate);
  const x = new Float32Array(each * prog.length * 2);
  let o = 0;
  for (let r = 0; r < 2; r++) {
    for (const chord of prog) {
      for (let j = 0; j < each; j++) {
        const t = j / rate;
        let v = 0;
        for (const m of chord) {
          const f = 440 * Math.pow(2, (m - 69) / 12);
          for (let k = 1; k <= 3; k++) v += Math.sin(2 * Math.PI * f * k * t) / k;
        }
        x[o++] = v * 0.1;
      }
    }
  }
  return x;
}

test("tempo", () => {
  for (const bpm of [128, 92, 75]) near(Analysis.tempo(clicks(bpm)), bpm, 1.5, `${bpm} BPM`);
});

test("tonalità", () => {
  const cMajor = Analysis.key(chords([[60, 64, 67], [65, 69, 72], [67, 71, 74], [60, 64, 67]]));
  assert.strictEqual(cMajor.root, 0);
  assert.strictEqual(cMajor.minor, false);
  const aMinor = Analysis.key(chords([[57, 60, 64], [62, 65, 69], [64, 68, 71], [57, 60, 64]]));
  assert.strictEqual(aMinor.root, 9);
  assert.strictEqual(aMinor.minor, true);
});

test("nomi", () => {
  const a = new SongAnalysis({ bpm: 127.6, keyRoot: 9, minor: true, keyConfidence: 0.8 });
  assert.strictEqual(a.keyName, "La minore");
  assert.strictEqual(a.keyShort, "Am");
  assert.strictEqual(a.camelot, "8A");
  assert.strictEqual(a.bpmText, "128 BPM");
  const k = (keyRoot, minor) => new SongAnalysis({ bpm: 120, keyRoot, minor, keyConfidence: 1 }).camelot;
  assert.strictEqual(k(0, false), "8B");
  assert.strictEqual(k(7, false), "9B");
  assert.strictEqual(k(4, true), "9A");
  // Il JSON salvato ha solo i campi, i nomi si ricalcolano
  assert.strictEqual(SongAnalysis.from(JSON.parse(JSON.stringify(a))).keyName, "La minore");
});

test("analyze usa la batteria per il tempo", () => {
  const drums = clicks(100, 12);
  const harm = chords([[60, 64, 67], [65, 69, 72], [67, 71, 74]], 2);
  const n = Math.min(drums.length, harm.length);
  const d = drums.subarray(0, n), h = harm.subarray(0, n);
  const a = Analysis.analyze({ drums: [d, d], other: [h, h] });
  assert.ok(a);
  near(a.bpm, 100, 1.5);
  assert.strictEqual(a.keyRoot, 0);
});

test("analyze: canzone troppo corta", () => {
  const x = new Float32Array(rate * 3);
  assert.strictEqual(Analysis.analyze({ drums: [x, x] }), null);
});
