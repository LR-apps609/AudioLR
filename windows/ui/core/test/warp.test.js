// Warp e Rimonta: le regole senza audio (come Tests/WarpTests.swift sul Mac).
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const W = require("../warp.js");
const A = require("../arrange.js");

const near = (a, b, tol, msg) => assert.ok(Math.abs(a - b) <= tol, `${msg || ""} ${a} invece di ${b} (±${tol})`);

// ── Warp ──

test("segnaposto dalla struttura e tempo medio", () => {
  const s = { beats: [0.2, 0.7, 1.2, 1.7, 2.2, 2.7, 3.2, 3.7, 4.2], firstDownbeat: 1, beatsPerBar: 4, sections: [] };
  assert.deepStrictEqual(W.downbeats(s), [0.7, 2.7]);
  near(W.bpmOf([0, 2, 4, 6.2], 4), 120, 1e-9, "mediana delle battute");
});

test("battiti dai segnaposto: uguali dentro la battuta, prima e dopo con la battuta vicina", () => {
  const g = W.beatsFromMarks([1, 3, 5.4], 4, 7);
  assert.strictEqual(g.firstDownbeat, 2, "due battiti prima del primo segnaposto (0 e 0,5)");
  assert.deepStrictEqual(g.beats.slice(0, 7), [0, 0.5, 1, 1.5, 2, 2.5, 3]);
  near(g.beats[7], 3.6, 1e-9, "seconda battuta più lunga");
  assert.ok(g.beats[g.beats.length - 1] < 7);
  near(g.beats[g.beats.length - 1] - g.beats[g.beats.length - 2], 0.6, 1e-9, "dopo l'ultimo, la battuta dell'ultima");
});

test("mappa a tempo: battute uguali, rapporti per tratto, inversa", () => {
  // Battute da 2,0 e 2,4 s, a 120 BPM (battuta 2 s)
  const m = W.WarpMap.toTempo([1, 3, 5.4], 120, 4);
  near(m.map(1), 1, 1e-9, "la prima battuta ha già 2 s: il primo segnaposto resta a 1");
  near(m.map(3), 3, 1e-9);
  near(m.map(5.4), 5, 1e-9, "la seconda battuta si accorcia a 2 s");
  near(m.map(6.6), 6, 1e-9, "dopo l'ultimo: rapporto dell'ultima battuta");
  near(m.inverse(m.map(4.2)), 4.2, 1e-9);
  const seg = m.segments(6.6);
  assert.strictEqual(seg.length, 4);
  near(seg[2].rate, 1.2, 1e-9, "2,4 s di originale in 2 s");
  near(seg[3].dstEnd, 6, 1e-9);
  near(m.length(6.6), 6, 1e-9);
});

test("prima del primo segnaposto vale il rapporto della prima battuta", () => {
  const m = W.WarpMap.toTempo([2, 4.5, 7], 120, 4);       // battute di 2,5 s → 2 s
  near(m.map(2), 1.6, 1e-9);
  near(m.map(0), 0, 1e-9);
  near(m.segments(8)[0].rate, 1.25, 1e-9);
});

test("analisi della versione a tempo: BPM esatto, battiti regolari, parti e accordi spostati", () => {
  const a = { bpm: 108, keyRoot: 0, minor: false, keyConfidence: 0.9,
    structure: { beats: [1, 1.5, 2, 2.5, 3, 3.6, 4.2, 4.8, 5.4], firstDownbeat: 0, beatsPerBar: 4, sections: [{ start: 1, end: 3, label: "Strofa", group: 0 }, { start: 3, end: 5.4, label: "Ritornello", group: 1 }] },
    chords: [{ start: 3, end: 5.4, root: 7, minor: false }] };
  const m = W.WarpMap.toTempo([1, 3, 5.4], 120, 4);
  const b = W.mapAnalysis(a, m, 120, 6.6);
  assert.strictEqual(b.bpm, 120);
  const d = b.structure.beats.slice(1).map((x, i) => x - b.structure.beats[i]);
  for (const x of d) near(x, 0.5, 1e-3, "battiti regolari");
  near(b.structure.sections[1].end, 5, 1e-6);
  near(b.chords[0].end, 5, 1e-6);
  assert.strictEqual(b.keyRoot, 0);
});

test("griglia salvata nella stessa canzone", () => {
  const a = { bpm: 100, structure: { beats: [0, 1], firstDownbeat: 0, beatsPerBar: 4, sections: [{ start: 0, end: 8, label: "Intro", group: 0 }] } };
  const b = W.withGrid(a, [0.5, 2.5, 4.5], 8);
  near(b.bpm, 120, 1e-6);
  assert.strictEqual(b.structure.sections[0].label, "Intro");
  assert.strictEqual(b.structure.beats[b.structure.firstDownbeat], 0.5);
});

// ── Rimonta ──

const secs = [{ start: 0, end: 4, label: "Intro", group: 0 }, { start: 4, end: 12, label: "Strofa", group: 1 }, { start: 12, end: 20, label: "Ritornello", group: 2 }];

test("blocchi dalle parti, senza buchi", () => {
  const b = A.fromSections(secs, 21);
  assert.deepStrictEqual(b.map((x) => x.label), ["Intro", "Strofa", "Ritornello", "Fine"]);
  near(A.total(b), 21, 1e-9);
  assert.strictEqual(A.fromSections([], 10)[0].label, "Canzone");
});

test("dividi sulla battuta, sposta, duplica, togli", () => {
  let b = A.fromSections(secs, 20);
  b = A.split(b, 1, 7.7, [0, 2, 4, 6, 8, 10, 12]);
  assert.deepStrictEqual(b.map((x) => [x.srcStart, x.srcEnd]), [[0, 4], [4, 8], [8, 12], [12, 20]], "aggancio a 8");
  assert.strictEqual(A.split(b, 0, 0.2, []).length, 4, "troppo vicino al bordo: niente");
  b = A.move(b, 3, 0);
  assert.strictEqual(b[0].label, "Ritornello");
  b = A.duplicate(b, 0);
  near(A.total(b), 28, 1e-9);
  b = A.remove(b, 1);
  near(A.total(b), 20, 1e-9);
  const loc = A.locate(b, 9);
  assert.deepStrictEqual([loc.index, loc.src], [1, 1]);
});

test("render: lunghezza esatta, giunzioni senza salti, tratti contigui intatti", () => {
  const rate = 10000, n = 10 * rate;
  const ch = [new Float32Array(n)];
  for (let i = 0; i < n; i++) ch[0][i] = Math.sin(i * 0.05);
  let b = A.fromSections([{ start: 0, end: 5, label: "A", group: 0 }, { start: 5, end: 10, label: "B", group: 1 }], 10);
  const same = A.render(ch, b, rate);
  assert.strictEqual(same[0].length, n);
  for (let i = 0; i < n; i += 37) near(same[0][i], ch[0][i], 1e-6, "contigui: identico");
  b = A.move(b, 1, 0);
  const out = A.render(ch, b, rate);
  assert.strictEqual(out[0].length, n);
  near(out[0][1000], ch[0][51000], 1e-6, "prima B");
  near(out[0][51000], ch[0][1000], 1e-6, "poi A");
  let jump = 0;
  for (let i = 49900; i < 50100; i++) jump = Math.max(jump, Math.abs(out[0][i + 1] - out[0][i]));
  assert.ok(jump < 0.2, "giunzione morbida: salto " + jump);
  // In mezzo alla canzone i due lati continuano oltre il taglio: incrocio senza buco
  let c = A.fromSections([{ start: 0, end: 3, label: "A", group: 0 }, { start: 3, end: 6, label: "B", group: 1 }, { start: 6, end: 10, label: "C", group: 2 }], 10);
  c = A.move(c, 2, 1);
  const mid = A.render(ch, c, rate);
  let j2 = 0;
  for (let i = 29900; i < 30100; i++) { j2 = Math.max(j2, Math.abs(mid[0][i + 1] - mid[0][i])); }
  assert.ok(j2 < 0.2, "incrocio morbido: salto " + j2);
  near(mid[0][31000], ch[0][61000], 1e-6, "dopo l'incrocio, C");
});

test("analisi della versione rimontata", () => {
  const a = { bpm: 120, keyRoot: 2, minor: true,
    structure: { beats: Array.from({ length: 40 }, (_, i) => i * 0.5), firstDownbeat: 0, beatsPerBar: 4, sections: secs },
    chords: [{ start: 0, end: 8, root: 2, minor: true }, { start: 8, end: 20, root: 7, minor: false }] };
  let b = A.fromSections(secs, 20);
  b = A.remove(b, 1);                                    // via la strofa (8 s)
  const m = A.mapAnalysis(a, b);
  assert.deepStrictEqual(m.structure.sections.map((x) => [x.label, x.start, x.end]), [["Intro", 0, 4], ["Ritornello", 4, 12]]);
  assert.strictEqual(m.structure.beats.length, 24);
  near(m.structure.beats[8], 4, 1e-9);
  assert.deepStrictEqual(m.chords.map((c) => [c.root, c.start, c.end]), [[2, 0, 4], [7, 4, 12]]);
  assert.strictEqual(m.bpm, 120);
});
