// Piano roll e Slice to MIDI: le regole senza disegno né suono (come Tests/NoteEditTests.swift sul Mac).
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const N = require("../notes.js");
const S = require("../slice.js");

const near = (a, b, tol, msg) => assert.ok(Math.abs(a - b) <= tol, `${msg || ""} ${a} invece di ${b} (±${tol})`);

// ── Piano roll ──

test("griglia: quattro sedicesimi per battito, anche prima del primo e dopo l'ultimo", () => {
  const g = N.grid({ beats: [1, 1.5, 2, 2.5] }, 120, 3.2);
  near(g[0], 0, 1e-9);
  assert.ok(g.some((t) => Math.abs(t - 1.125) < 1e-9), "sedicesimo dentro il battito");
  assert.ok(g.some((t) => Math.abs(t - 3) < 1e-9), "dopo l'ultimo battito, stesso passo");
  near(N.snap(1.13, g), 1.125, 1e-9, "aggancio");
  near(N.snap(5, []), 5, 0, "senza griglia");
  const plain = N.grid(null, 60, 2);
  near(plain[1] - plain[0], 0.25, 1e-9, "senza battiti: dal BPM");
});

test("modifiche: sposta (agganciato), allunga, aggiungi, togli, annulla, ripristina", () => {
  const e = new N.Editor([{ start: 0.5, end: 1, pitch: 60, velocity: 80 }, { start: 1, end: 1.5, pitch: 64, velocity: 70 }]);
  const g = N.grid(null, 120, 4);
  const [a, b] = e.notes.map((n) => n.id);
  e.move([a], 0.11, 2, g);
  near(e.find(a).start, 0.625, 1e-9, "inizio agganciato al sedicesimo");
  near(e.find(a).end - e.find(a).start, 0.5, 1e-9, "lunghezza invariata");
  assert.strictEqual(e.find(a).pitch, 62);
  e.resize(b, 1.02, g);
  near(e.find(b).end, 1 + N.MIN_LEN, 1e-9, "mai più corta del minimo");
  const c = e.add(2.01, 67, g);
  near(e.find(c).start, 2, 1e-9);
  near(e.find(c).end, 2.125, 1e-9, "lunga un sedicesimo");
  assert.deepStrictEqual(e.within(0, 3, 66, 68), [c], "selezione a rettangolo");
  e.remove([c]);
  assert.strictEqual(e.notes.length, 2);
  e.undo();
  assert.strictEqual(e.notes.length, 3, "annulla la cancellazione");
  e.undo(); e.undo(); e.undo();
  near(e.find(a).start, 0.5, 1e-9, "annulla fino all'inizio");
  assert.strictEqual(e.edited, false);
  e.move([a], -5, 0);
  near(e.find(a).start, 0, 1e-9, "mai prima dell'inizio");
  e.reset();
  assert.deepStrictEqual(e.list().map((n) => n.pitch), [60, 64], "ripristina le note rilevate");
  assert.strictEqual(e.edited, false, "dopo Ripristina non sono più modificate");
  assert.strictEqual(new N.Editor([], [{ start: 0, end: 1, pitch: 60, velocity: 90 }]).edited, true, "riaperte modificate");
  assert.deepStrictEqual(N.range([{ pitch: 60 }]), [48, 72], "almeno due ottave");
});

// ── Slice ──

function clicks(times, rate, len) {
  const x = new Float32Array(Math.round(len * rate));
  let seed = 7;
  for (const t of times) {
    const s = Math.round(t * rate);
    for (let i = 0; i < 2000 && s + i < x.length; i++) { seed = (seed * 16807) % 2147483647; x[s + i] = ((seed / 2147483647) * 2 - 1) * Math.exp(-i / 300); }
  }
  return [x, x.slice()];
}

test("attacchi: i colpi della batteria finta, entro 10 ms", () => {
  const rate = 44100, times = [0.25, 0.75, 1.0, 1.5, 1.625];
  const on = S.onsets(clicks(times, rate, 2), rate, { sensitivity: 0.5 });
  assert.strictEqual(on.length, times.length, `trovati ${on.length}`);
  on.forEach((o, i) => near(o / rate, times[i], 0.01, `colpo ${i + 1}`));
  assert.deepStrictEqual(S.onsets([new Float32Array(44100), new Float32Array(44100)], rate), [], "silenzio: nessun colpo");
  assert.strictEqual(S.onsets(clicks([0, 0.5], rate, 1), rate)[0], 0, "un colpo proprio all'inizio della traccia");
});

test("fette: dall'attacco al successivo; sposta, unisci, dividi; audio con dissolvenze; MIDI 36, 37…", () => {
  const rate = 1000;
  let l = S.slices([100, 400, 700], 1000, rate, { preroll: 0.005 });
  assert.deepStrictEqual(l, [{ start: 95, end: 395 }, { start: 395, end: 695 }, { start: 695, end: 1000 }]);
  l = S.move(l, 1, 10, rate);
  assert.deepStrictEqual(l[1].start, 105, "non scavalca la fetta prima");
  assert.strictEqual(l[0].end, 105);
  l = S.merge(l, 0);
  assert.deepStrictEqual(l, [{ start: 95, end: 695 }, { start: 695, end: 1000 }]);
  l = S.split(l, 300, rate);
  assert.strictEqual(l.length, 3);
  const ch = [new Float32Array(1000).fill(1), new Float32Array(1000).fill(1)];
  const r = S.render(ch, { start: 0, end: 100 }, rate, 0.01);
  assert.strictEqual(r[0].length, 100);
  assert.strictEqual(r[0][0], 0, "dissolvenza all'inizio");
  assert.strictEqual(r[0][50], 1);
  const mid = S.midi(l, rate, { bpm: 120 });
  assert.strictEqual(String.fromCharCode(...mid.slice(0, 4)), "MThd");
  const ons = []; for (let i = 0; i + 2 < mid.length; i++) if (mid[i] === 0x90) ons.push(mid[i + 1]);
  assert.deepStrictEqual(ons, [36, 37, 38]);
  assert.strictEqual(S.fileName(0), "Slice 01.wav");
  assert.strictEqual(S.noteOf(200), 127);
  assert.match(S.readme("Canzone", "Batteria", 3, 120), /Drum Rack/);
});
