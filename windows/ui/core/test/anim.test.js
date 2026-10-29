// Le regole delle animazioni (come Tests/AnimationTests.swift sul Mac).
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const A = require("../anim.js");

test("il logo batte sui battiti veri", () => {
  const beats = [0.5, 1.0, 1.5, 2.0];
  assert.strictEqual(A.pulse(0.2, beats, 120), 0);
  assert.ok(Math.abs(A.pulse(1.0, beats) - 1) < 1e-9);
  assert.ok(A.pulse(1.05, beats) > A.pulse(1.15, beats));
  assert.strictEqual(A.pulse(1.3, beats), 0);
  assert.strictEqual(A.pulse(3.0, beats), 0);
});

test("senza battiti batte sul BPM; senza niente è fermo", () => {
  assert.ok(Math.abs(A.pulse(1.0, [], 120) - 1) < 1e-9);
  assert.strictEqual(A.pulse(1.4, [], 120), 0);
  assert.strictEqual(A.pulse(1.0, [], null), 0);
});

test("la festa dura 2,5 s e usa tutti i colori delle tracce", () => {
  assert.strictEqual(A.progress(0), 0);
  assert.ok(Math.abs(A.progress(A.DURATION / 2) - 0.5) < 1e-9);
  assert.strictEqual(A.progress(A.DURATION), null);
  assert.strictEqual(A.progress(-1), null);
  const c = A.confetti();
  assert.strictEqual(c.length, 24);
  assert.deepStrictEqual([...new Set(c.map((x) => x.color))].sort(), [0, 1, 2, 3, 4, 5]);
});
