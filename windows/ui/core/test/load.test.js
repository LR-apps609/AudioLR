// I modelli di ogni qualità, un modello alla volta sui computer deboli e le medie di Studio (come Tests/AppTests.swift sul Mac).
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const L = require("../load.js");

const st = (a, b) => [Float32Array.from(a), Float32Array.from(b)];
const arr = (x) => x.map((c) => Array.from(c));

test("un modello alla volta sui computer deboli (non cambia il risultato)", () => {
  assert.strictEqual(L.oneAtATime({ webgpu: true, memoryGB: 8 }), false);
  assert.strictEqual(L.oneAtATime({ webgpu: false }), true);
  assert.strictEqual(L.oneAtATime({ webgpu: true, forceCpu: true }), true);
  assert.strictEqual(L.oneAtATime({ webgpu: true, fellBack: true }), true);
  assert.strictEqual(L.oneAtATime({ webgpu: true, memoryGB: 4 }), true);
});

test("modelli: Studio ne scarica due su tutti i computer, Massima uno; sovrapposizione fissa", () => {
  assert.deepStrictEqual(L.models("studio"), ["VoceRevive", "StrumentiSW"]);
  assert.deepStrictEqual(L.models("best"), ["StrumentiSW"]);
  assert.deepStrictEqual(L.models("fast"), []);
  assert.strictEqual(L.OVERLAP, 2);
  assert.ok(L.perMinute("fast") < L.perMinute("best") && L.perMinute("best") < L.perMinute("studio"));
});

test("Studio: voce e strumenti sono le medie giuste", () => {
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
});
