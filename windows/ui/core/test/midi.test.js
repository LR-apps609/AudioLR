// Ricerca delle note, preparazione dell'audio e file MIDI (Tests/MidiTests.swift, senza il modello).
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const Midi = require("../midi.js");

const near = (a, b, tol, msg) => assert.ok(Math.abs(a - b) <= tol, `${msg || ""} ${a} invece di ${b} (±${tol})`);
const grid = (n) => Array.from({ length: n }, () => new Float32Array(Midi.keys));

test("note dalle attivazioni", () => {
  const n = 120;
  const frames = grid(n), onsets = grid(n);
  // Do centrale (60 → indice 39) da 10 a 40, con attacco a 10
  for (let t = 10; t < 40; t++) frames[t][39] = 0.8;
  onsets[9][39] = 0.2; onsets[10][39] = 0.9; onsets[11][39] = 0.3;
  // Un La (69 → 48) senza attacco: lo trova il «trucco Melodia»
  for (let t = 60; t < 95; t++) frames[t][48] = 0.6;
  const notes = Midi.notes(frames, onsets);
  assert.deepStrictEqual(notes.map((x) => x.pitch), [60, 69]);
  near(notes[0].start, Midi.time(10), 1e-9);
  assert.strictEqual(notes[0].velocity, Math.round(127 * 0.8));
  // Troppo corta (meno di 11 colonne): niente nota
  const short = grid(n);
  for (let t = 20; t < 26; t++) short[t][30] = 0.9;
  assert.deepStrictEqual(Midi.notes(short, grid(n)), []);
});

test("file MIDI", () => {
  const notes = [Midi.note(0, 0.5, 60, 100), Midi.note(0.5, 1, 64, 90)];
  const d = Midi.MidiFile.data(notes, { bpm: 120, program: 33, name: "Prova" });
  const ascii = (s) => Array.from(s, (c) => c.charCodeAt(0));
  assert.deepStrictEqual(Array.from(d.subarray(0, 4)), ascii("MThd"));
  assert.deepStrictEqual(Array.from(d.subarray(8, 10)), [0, 0], "formato 0");
  assert.deepStrictEqual(Array.from(d.subarray(12, 14)), [0x01, 0xe0], "480 tick per battito");
  assert.deepStrictEqual(Array.from(d.subarray(14, 18)), ascii("MTrk"));
  const len = (d[18] << 24) | (d[19] << 16) | (d[20] << 8) | d[21];
  assert.strictEqual(len, d.length - 22);
  assert.deepStrictEqual(Array.from(d.subarray(d.length - 3)), [0xff, 0x2f, 0x00], "fine traccia");
  // Due note accese e due spente; a 120 BPM mezzo secondo = 480 tick (0x83 0x60)
  assert.strictEqual(d.filter((b) => b === 0x90).length, 2);
  assert.strictEqual(d.filter((b) => b === 0x80).length, 2);
  assert.ok(Array.from(d).some((b, i) => b === 0x83 && d[i + 1] === 0x60));
  assert.ok(d.includes(0xc0) && d[d.indexOf(0xc0) + 1] === 33, "suono del basso");
});

test("suono di ogni traccia", () => {
  assert.strictEqual(Midi.MidiFile.program("vocals"), 53);
  assert.strictEqual(Midi.MidiFile.program("female"), 53);
  assert.strictEqual(Midi.MidiFile.program("backing"), 52);
  assert.strictEqual(Midi.MidiFile.program("bass"), 33);
  assert.strictEqual(Midi.MidiFile.program("guitar"), 25);
  assert.strictEqual(Midi.MidiFile.program("piano"), 0);
  assert.strictEqual(Midi.MidiFile.program("other"), 48);
});

test("prepare dimezza la frequenza e toglie gli acuti", () => {
  const n = 44100;
  const tone = (f) => { const x = Float32Array.from({ length: n }, (_, i) => 0.5 * Math.sin((2 * Math.PI * f * i) / 44100)); return [x, x]; };
  const peak = (x) => { let m = 0; for (let i = 2000; i < 20000; i++) m = Math.max(m, Math.abs(x[i])); return m; };
  const low = Midi.prepare(tone(440));
  assert.strictEqual(low.length, n / 2);
  near(peak(low), 0.5, 0.03);
  assert.ok(peak(Midi.prepare(tone(16000))) < 0.05, "sopra 11 kHz non deve tornare giù come rumore");
});

test("finestre e colonne della rete", async () => {
  // 3 s a 22 050 Hz: le colonne sono quelle dell'audio, senza le sovrapposte
  const x = new Float32Array(22050 * 3);
  const wins = Midi.windows(x);
  assert.ok(wins.every((w) => w.length === Midi.windowSamples));
  let calls = 0;
  const run = async (w) => {
    calls++;
    const f = new Float32Array(Midi.framesPerWindow * Midi.keys);
    // Colonna t della finestra k: valore k*1000+t, per vedere come si ricuciono
    for (let t = 0; t < Midi.framesPerWindow; t++) f[t * Midi.keys] = (calls - 1) * 1000 + t;
    return { frames: f, onsets: f };
  };
  const a = await Midi.activations(x, run);
  assert.strictEqual(calls, wins.length);
  assert.strictEqual(a.frames.length, Math.floor((x.length * Midi.fps) / Midi.rate));
  assert.strictEqual(a.frames[0][0], 15);
  assert.strictEqual(a.frames[142][0], 1015);
});
