// Spartito, tablatura e MusicXML (Tests/SheetTests.swift).
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { Score, Tab, MusicXML } = require("../sheet.js");

const note = (a, b, p) => ({ start: a, end: b, pitch: p, velocity: 90 });

/// Controllo minimo che l'XML sia ben formato: ogni tag aperto si chiude, nell'ordine giusto.
function balanced(xml) {
  const body = xml.replace(/<\?xml[^>]*\?>/, "").replace(/<!DOCTYPE[^>]*>/, "");
  const stack = [];
  for (const m of body.matchAll(/<(\/?)([A-Za-z][\w-]*)([^>]*?)(\/?)>/g)) {
    const [, close, name, , self] = m;
    if (self) continue;
    if (close) { if (stack.pop() !== name) return false; } else stack.push(name);
  }
  // Niente «&» o «<» nudi nel testo
  return stack.length === 0 && !/&(?!amp;|lt;|gt;|quot;|apos;)/.test(body);
}

const count = (xml, re) => (xml.match(re) || []).length;

test("le note sui battiti", () => {
  // 120 BPM: un battito = 0,5 s, un sedicesimo = 0,125 s
  const s = Score.build([note(0, 0.5, 60), note(0.5, 1.0, 62), note(1.0, 2.0, 64)], { bpm: 120, monophonic: true });
  assert.strictEqual(s.bars.length, 1);
  assert.deepStrictEqual(s.bars[0].map((e) => e.length), [4, 4, 8]);
  assert.deepStrictEqual(s.bars[0].map((e) => e.pitches), [[60], [62], [64]]);
});

test("pause e legature sulla stanghetta", () => {
  // Pausa di un battito, poi una nota che passa la stanghetta
  const s = Score.build([note(0.5, 3.0, 67)], { bpm: 120, monophonic: true });
  assert.strictEqual(s.bars.length, 2);
  assert.deepStrictEqual(s.bars[0][0].pitches, []);
  assert.ok(s.bars[0][s.bars[0].length - 1].tieOut);
  assert.ok(s.bars[1][0].tieIn);
  assert.strictEqual(s.bars[0][s.bars[0].length - 1].length + s.bars[1][0].length, 20);
  assert.strictEqual(s.bars[1].reduce((a, e) => a + e.length, 0), 16);
});

test("segue i battiti veri", () => {
  // Battiti irregolari: la nota sul quinto battito va all'inizio della seconda battuta
  const beats = [0.0, 0.5, 1.1, 1.6, 2.2, 2.7, 3.3, 3.8, 4.4];
  const st = { beats, firstDownbeat: 0, beatsPerBar: 4, sections: [] };
  const s = Score.build([note(0, 0.5, 60), note(2.2, 2.7, 62)], { structure: st, bpm: 100, monophonic: true });
  assert.deepStrictEqual(s.bars[1][0].pitches, [62]);
  assert.strictEqual(s.bars[1][0].start, 0);
});

test("durate divise in figure", () => {
  assert.deepStrictEqual(Score.split(5).map((f) => f.length), [4, 1]);
  assert.deepStrictEqual(Score.split(12).map((f) => f.length), [12]);
  assert.deepStrictEqual(Score.split(15).map((f) => f.length), [12, 3]);
});

test("armatura di chiave", () => {
  assert.strictEqual(new Score([], 120, 7, false).fifths, 1);    // Sol maggiore
  assert.strictEqual(new Score([], 120, 2, true).fifths, -1);    // Re minore
  assert.strictEqual(new Score([], 120, 9, true).fifths, 0);     // La minore
});

test("la tablatura del basso resta in basso sul manico", () => {
  // Mi1 (corda vuota), La1, Do2, Re2
  const s = Score.build([note(0, 0.5, 28), note(0.5, 1, 33), note(1, 1.5, 36), note(1.5, 2, 38)], { bpm: 120, monophonic: true });
  const p = Tab.positions(s, Tab.bass)[0].map((x) => x[0]);
  assert.deepStrictEqual(p.map((x) => x.string), [3, 2, 2, 1]);
  assert.deepStrictEqual(p.map((x) => x.fret), [0, 0, 3, 0]);
  const t = Tab.text(s, Tab.bass, "Prova");
  assert.ok(t.includes("E|0-------"), t);
  assert.ok(t.includes("G|"));
});

test("MusicXML ben formato", () => {
  const s = Score.build([note(0, 0.5, 64), note(0, 0.5, 67), note(0.5, 2.6, 69)], { bpm: 120, monophonic: false });
  const x = MusicXML.data(s, "guitar", "Prova & co", "Chitarra", 25);
  assert.ok(balanced(x), x);
  assert.ok(x.includes("<work-title>Prova &amp; co</work-title>"));
  assert.strictEqual(count(x, /<part id=/g), 2);
  assert.ok(count(x, /<technical>.*?<fret>/g) > 0);
  assert.ok(count(x, /<chord\/>/g) > 0);
  assert.ok(count(x, /<tie /g) > 0);
  // Con xmllint (se c'è) il controllo vero
  let lint = null;
  try { lint = execFileSync("which", ["xmllint"]).toString().trim(); } catch { /* non c'è */ }
  if (lint) {
    const f = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "isolr-")), "prova.musicxml");
    fs.writeFileSync(f, x);
    execFileSync(lint, ["--noout", "--nonet", f]);
    const parts = execFileSync(lint, ["--nonet", "--xpath", "count(//part)", f]).toString().trim();
    assert.strictEqual(parts, "2");
  }
});

test("tipo di pentagramma", () => {
  assert.strictEqual(MusicXML.kind("guitar", []), "guitar");
  assert.strictEqual(MusicXML.kind("bass", []), "bassGuitar");
  assert.strictEqual(MusicXML.kind("piano", [note(0, 1, 40), note(1, 2, 45), note(2, 3, 50)]), "bass");
  assert.strictEqual(MusicXML.kind("vocals", []), "treble");
});
