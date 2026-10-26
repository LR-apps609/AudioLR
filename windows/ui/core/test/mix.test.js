// Mixer, sala prove e registrazione: le regole senza audio
// (Tests/PracticeTests.swift, AppTests «Mixer», DrumTests testVoiceSplitInMixer, RecorderTests songTime).
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const { MixState, mixable, rampStart, rampTarget, rampNext, clicks, beatPeriod, sectionAt, exportName, TakeClock } = require("../mix.js");

const near = (a, b, tol, msg) => assert.ok(Math.abs(a - b) <= tol, `${msg || ""} ${a} invece di ${b} (±${tol})`);

// ── Mixer ──

test("muto, solo e volume", () => {
  const m = new MixState();
  assert.strictEqual(m.effectiveGain("vocals"), 1);
  m.gain.bass = 1.3;
  assert.strictEqual(m.effectiveGain("bass"), 1.3);
  m.muted.add("drums");
  assert.strictEqual(m.effectiveGain("drums"), 0);
  m.solo.add("bass");
  assert.strictEqual(m.effectiveGain("vocals"), 0, "con un solo attivo, le altre tacciono");
  assert.strictEqual(m.effectiveGain("bass"), 1.3);
  assert.strictEqual(m.preset, null);
});

test("scorciatoie", () => {
  const m = new MixState();
  assert.strictEqual(m.preset, "all");
  m.apply("karaoke");
  assert.strictEqual(m.effectiveGain("vocals"), 0);
  assert.strictEqual(m.effectiveGain("drums"), 1);
  assert.strictEqual(m.preset, "karaoke");
  m.apply("voice");
  assert.strictEqual(m.effectiveGain("vocals"), 1);
  assert.strictEqual(m.effectiveGain("other"), 0);
  assert.strictEqual(exportName(m, "Brano"), "Brano – Solo voce");
  m.apply("all");
  m.gain.vocals = 0.3;
  assert.strictEqual(exportName(m, "Brano"), "Brano – Mix");
});

test("senza il mio strumento", () => {
  const m = new MixState();
  m.applyWithout("drums");
  for (const k of ["drums", "kick", "snare", "toms", "hh", "ride", "crash"]) assert.strictEqual(m.effectiveGain(k), 0, k);
  for (const k of ["vocals", "bass", "guitar", "piano", "other"]) assert.strictEqual(m.effectiveGain(k), 1, k);
  assert.strictEqual(m.without, "drums");
  assert.strictEqual(m.preset, null);
  assert.strictEqual(exportName(m, "Brano"), "Brano – Senza batteria");
  m.applyWithout("bass");
  assert.strictEqual(m.effectiveGain("bass"), 0);
  assert.strictEqual(m.effectiveGain("kick"), 1);
  assert.strictEqual(exportName(m, "Brano"), "Brano – Senza basso");
  // Un muto in più a mano: non è più «senza basso» e basta
  m.muted.add("vocals");
  assert.strictEqual(m.without, null);
  m.apply("all");
  assert.strictEqual(m.without, null);
  assert.strictEqual(m.preset, "all");
});

test("somma con i volumi", () => {
  const m = new MixState();
  m.gain.vocals = 0.5;
  m.muted = new Set(["bass"]);
  const out = MixState.mix([
    { key: "vocals", audio: [Float32Array.of(1, 1), Float32Array.of(2, 2)] },
    { key: "drums", audio: [Float32Array.of(0.25, 0.25), Float32Array.of(0.25, 0.25)] },
    { key: "bass", audio: [Float32Array.of(9, 9), Float32Array.of(9, 9)] }], m);
  assert.deepStrictEqual(Array.from(out[0]), [0.75, 0.75]);
  assert.deepStrictEqual(Array.from(out[1]), [1.25, 1.25]);
});

test("voce divisa nel mixer", () => {
  assert.deepStrictEqual(mixable(["vocals", "drums", "bass", "lead", "backing", "instrumental"]), ["drums", "bass", "lead", "backing"]);
  assert.deepStrictEqual(mixable(["vocals", "drums", "kick", "snare", "male", "female"]), ["kick", "snare", "male", "female"]);
  const m = new MixState();
  m.apply("backing");
  assert.strictEqual(m.effectiveGain("lead"), 0);
  assert.strictEqual(m.effectiveGain("backing"), 1);
  assert.strictEqual(m.preset, "backing");
  assert.strictEqual(exportName(m, "Brano"), "Brano – Karaoke con cori");
  m.apply("karaoke");
  assert.strictEqual(m.effectiveGain("backing"), 0);
  assert.strictEqual(m.effectiveGain("vocals"), 0);
  assert.strictEqual(m.effectiveGain("male"), 0);
  assert.strictEqual(m.effectiveGain("female"), 0);
  // Muto a mano sulla voce intera: è ancora «Karaoke»
  m.apply("all");
  m.muted = new Set(["vocals"]);
  assert.strictEqual(m.preset, "karaoke");
  m.muted = new Set();
  m.solo = new Set(["lead", "backing"]);
  assert.strictEqual(m.preset, "voice");
  // Uomo e donna insieme sono tutta la voce
  m.solo = new Set(["male", "female"]);
  assert.strictEqual(m.preset, "voice");
  m.solo = new Set(["male"]);
  assert.strictEqual(m.preset, null);
});

// ── Sala prove ──

test("rampa di velocità: +5% a giro, fino al 100%", () => {
  let r = rampStart;
  const giri = [r];
  while (r < rampTarget) { r = rampNext(r); giri.push(r); }
  assert.deepStrictEqual(giri, [0.7, 0.75, 0.8, 0.85, 0.9, 0.95, 1.0]);
  assert.strictEqual(rampNext(1.0), 1.0, "al traguardo resta lì");
  assert.strictEqual(rampNext(0.98), 1.0);
});

const grid = () => ({
  beats: Array.from({ length: 16 }, (_, i) => i * 0.5 + 0.2), firstDownbeat: 1, beatsPerBar: 4,
  sections: [{ start: 0.7, end: 4.7, label: "Strofa", group: 0 }] });

test("i clic accentano il primo battito della battuta", () => {
  const c = clicks(grid(), 0, 3);
  assert.deepStrictEqual(c.map((x) => x.time), [0.2, 0.7, 1.2, 1.7, 2.2, 2.7]);
  assert.deepStrictEqual(c.map((x) => x.strong), [false, true, false, false, false, true]);
});

test("clic solo dentro il passaggio", () => {
  assert.deepStrictEqual(clicks(grid(), 1.2, 2.2).map((x) => x.time), [1.2, 1.7]);
});

test("il conteggio segue i battiti", () => {
  near(beatPeriod(grid(), 90, 3), 0.5, 1e-9);
  // Senza battiti si usa il tempo medio
  near(beatPeriod(null, 120, 3), 0.5, 1e-9);
  near(beatPeriod(null, 0, 3), 0.5, 1e-9);
});

test("la parte in cui si è", () => {
  assert.strictEqual(sectionAt(grid(), 1).label, "Strofa");
  assert.strictEqual(sectionAt(grid(), 5), null);
});

// ── Registrazione ──

test("il secondo della canzone toglie il ritardo dell'uscita e il conteggio", () => {
  // Musica da 10 s, una battuta di conteggio da 2 s, uscita con 20 ms di ritardo
  const c = new TakeClock({ startHost: 100, at: 10, lead: 2, rate: 1, semitones: 0, outputLatency: 0.02 });
  near(c.songTime(102.02), 10, 1e-6);
  near(c.songTime(103.02), 11, 1e-6);
  // A metà velocità un secondo vero è mezzo secondo di canzone; il conteggio dura 4 s veri
  const slow = new TakeClock({ startHost: 100, at: 10, lead: 2, rate: 0.5, semitones: 0, outputLatency: 0 });
  near(slow.songTime(104), 10, 1e-9);
  near(slow.songTime(106), 11, 1e-9);
});
