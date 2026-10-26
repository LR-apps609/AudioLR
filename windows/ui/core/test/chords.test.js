// Accordi su una progressione nota (Tests/ChordTests.swift).
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const Chords = require("../chords.js");
const { ChordSpan } = Chords;

const near = (a, b, tol, msg) => assert.ok(Math.abs(a - b) <= tol, `${msg || ""} ${a} invece di ${b} (±${tol})`);

/// Una triade suonata con armonici (come un pianoforte semplice), più la fondamentale nel basso.
function song(chords, each = 2, silence = 0) {
  const sr = 44100, n = Math.trunc(each * sr);
  const h = new Float32Array(n * chords.length + silence), b = new Float32Array(n * chords.length + silence);
  let o = 0;
  for (const [r, minor] of chords) {
    const notes = [r, r + (minor ? 3 : 4), r + 7].map((m) => 261.63 * Math.pow(2, m / 12));
    const low = 65.41 * Math.pow(2, r / 12);
    for (let j = 0; j < n; j++, o++) {
      const t = j / sr;
      let x = 0;
      for (const f of notes) for (let k = 1; k <= 4; k++) x += Math.sin(2 * Math.PI * f * k * t) / (k * k);
      h[o] = 0.1 * x;
      b[o] = 0.3 * Math.sin(2 * Math.PI * low * t);
    }
  }
  return { harmonic: h, bass: b };
}

test("trova la progressione", () => {
  // C – Am – F – G
  const s = song([[0, false], [9, true], [5, false], [7, false]]);
  const beats = [];
  for (let i = 0; i * 0.5 < 8; i++) beats.push(i * 0.5);
  const c = Chords.detect({ harmonic: s.harmonic, bass: s.bass, beats, key: { root: 0, minor: false } });
  assert.deepStrictEqual(c.map((x) => x.name()), ["C", "Am", "F", "G"]);
  near(c[1].start, 2, 0.01);
  near(c[c.length - 1].end, 8, 0.01);
});

test("il silenzio non è un accordo", () => {
  const s = song([[2, true]], 2, 44100 * 2);
  const c = Chords.detect({ harmonic: s.harmonic, bass: s.bass, beats: null, key: null });
  assert.deepStrictEqual(c.map((x) => x.name()), ["Dm", "—"]);
});

test("nomi e trasposizione", () => {
  const a = new ChordSpan(0, 1, 9, true);
  assert.strictEqual(a.name(), "Am");
  assert.strictEqual(a.name({ italian: true }), "Lam");
  assert.strictEqual(a.name({ shift: 2 }), "Bm");
  assert.strictEqual(a.name({ shift: -10 }), "Bm");
  assert.strictEqual(new ChordSpan(0, 1, null, false).name(), "—");
  assert.strictEqual(ChordSpan.from({ start: 0, end: 1, minor: false }).name(), "—");
});

test("accordi della tonalità", () => {
  assert.ok(Chords.inKey(9, true, { root: 0, minor: false }));
  assert.ok(Chords.inKey(7, false, { root: 9, minor: true }));
  assert.ok(!Chords.inKey(1, false, { root: 0, minor: false }));
});

test("troppo corta: nessun accordo", () => {
  assert.deepStrictEqual(Chords.detect({ harmonic: new Float32Array(44100), bass: new Float32Array(0) }), []);
});
