// Carico sul computer: quando è leggero, quali modelli, e le medie di Studio leggera (come Tests/AppTests.swift sul Mac).
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const L = require("../load.js");

const st = (a, b) => [Float32Array.from(a), Float32Array.from(b)];
const arr = (x) => x.map((c) => Array.from(c));

test("automatico: leggero senza WebGPU, con il solo processore, dopo il ripiego o con poca memoria", () => {
  assert.strictEqual(L.isLight({ mode: "auto", webgpu: true, memoryGB: 8 }), false);
  assert.strictEqual(L.isLight({ mode: "auto", webgpu: false }), true);
  assert.strictEqual(L.isLight({ mode: "auto", webgpu: true, forceCpu: true }), true);
  assert.strictEqual(L.isLight({ mode: "auto", webgpu: true, fellBack: true }), true);
  assert.strictEqual(L.isLight({ mode: "auto", webgpu: true, memoryGB: 4 }), true);
  // Le scelte delle Impostazioni vincono
  assert.strictEqual(L.isLight({ mode: "full", webgpu: false }), false);
  assert.strictEqual(L.isLight({ mode: "light", webgpu: true }), true);
  assert.match(L.text({ mode: "auto", webgpu: false }), /^leggera \(automatica/);
  assert.strictEqual(L.text({ mode: "auto" }), null);
});

test("modelli: in leggero Studio ne scarica due, Massima uno, pezzi meno sovrapposti", () => {
  assert.deepStrictEqual(L.models("studio", false), ["VoceRevive", "VoceRoFormer9", "StrumentiSW", "HTDemucsFT-1"]);
  assert.deepStrictEqual(L.models("studio", true), ["VoceRevive", "StrumentiSW"]);
  assert.deepStrictEqual(L.models("best", true), ["StrumentiSW"]);
  assert.strictEqual(L.overlap(true), 1.5);
  assert.strictEqual(L.overlap(false), 2);
  assert.ok(L.perMinute("studio", true) < L.perMinute("studio", false));
  assert.ok(L.perMinute("best", true) < L.perMinute("best", false));
});

test("Studio leggera: voce e strumenti sono le medie giuste", () => {
  const n = 3;
  const revive = st([1, 1, 1], [2, 2, 2]);
  const part = (v) => st([v, v, v], [v, v, v]);
  const onMix = { vocals: st([3, 3, 3], [4, 4, 4]), drums: part(2), bass: part(4), guitar: part(6), piano: part(8), other: part(10) };
  const onBase = { drums: part(4), bass: part(2), guitar: part(0), piano: part(2), other: part(0) };
  assert.deepStrictEqual(arr(L.voice(revive, onMix, n)), [[2, 2, 2], [3, 3, 3]]);
  const a = L.instruments(onMix, onBase, n);
  assert.deepStrictEqual(arr(a.drums)[0], [3, 3, 3]);
  assert.deepStrictEqual(arr(a.bass)[0], [3, 3, 3]);
  assert.deepStrictEqual(arr(a.guitar)[0], [3, 3, 3]);
  assert.deepStrictEqual(arr(a.piano)[0], [5, 5, 5]);
  assert.deepStrictEqual(arr(a.other)[0], [5, 5, 5]);
  // Ricetta B: solo SW sulla canzone
  const b = L.instruments(onMix, null, n);
  assert.strictEqual(b.drums, onMix.drums);
  assert.strictEqual(b.other, onMix.other);
});
