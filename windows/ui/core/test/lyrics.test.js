// Il testo sincronizzato: righe, parola sotto la testina, .lrc/.srt, modifiche (come Tests/LyricsTests.swift sul Mac).
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const L = require("../lyrics.js");

const w = (text, start, end) => ({ text, start, end });
const words = [
  w("Questa", 1.0, 1.3), w("è", 1.3, 1.4), w("la", 1.4, 1.5), w("prima.", 1.5, 2.0),
  w("E", 4.0, 4.1), w("questa", 4.1, 4.4), w("la", 4.4, 4.5), w("seconda", 4.5, 5.0),
];

test("righe: a capo a fine frase e dopo una pausa", () => {
  const ls = L.lines(words);
  assert.deepStrictEqual(ls.map((l) => l.text), ["Questa è la prima.", "E questa la seconda"]);
  assert.strictEqual(ls[1].start, 4.0);
  assert.strictEqual(ls[1].end, 5.0);
  // Riga lunga: si spezza a 8 parole
  const many = Array.from({ length: 12 }, (_, i) => w("ok", i * 0.3, i * 0.3 + 0.2));
  assert.deepStrictEqual(L.lines(many).map((l) => l.to - l.from), [8, 4]);
});

test("parola sotto la testina", () => {
  const ls = L.lines(words);
  assert.strictEqual(L.current(ls, words, 0.5), null);
  assert.deepStrictEqual(L.current(ls, words, 1.45), { line: 0, word: 2 });
  assert.deepStrictEqual(L.current(ls, words, 4.6), { line: 1, word: 7 });
  assert.strictEqual(L.current(ls, words, 9), null);
});

test(".lrc e .srt", () => {
  const ls = L.lines(words);
  assert.strictEqual(L.lrcTime(62.354), "[01:02.35]");
  assert.strictEqual(L.srtTime(3723.5), "01:02:03,500");
  assert.match(L.lrc(ls, "Prova"), /^\[ti:Prova\]\n\[re:IsoLR\]\n\[00:01\.00\]Questa è la prima\.\n\[00:04\.00\]E questa la seconda\n$/);
  assert.match(L.srt(ls), /^1\n00:00:01,000 --> 00:00:02,000\nQuesta è la prima\.\n\n2\n/);
});

test("modifiche: riscrivi e sposta una riga", () => {
  const ls = L.lines(words);
  const same = L.rewrite(words, ls[1], "E questa è seconda");
  assert.strictEqual(same[6].text, "è");
  assert.strictEqual(same[6].start, 4.4);
  const fewer = L.rewrite(words, ls[1], "Seconda riga");
  assert.strictEqual(fewer.length, 6);
  assert.strictEqual(fewer[4].start, 4.0);
  assert.ok(Math.abs(fewer[5].end - 5.0) < 1e-9);
  const moved = L.shift(words, ls[0], -0.5);
  assert.strictEqual(moved[0].start, 0.5);
  assert.strictEqual(moved[4].start, 4.0);
});

test("pulizia di Whisper", () => {
  const raw = [w(" ciao ", 1, 0.5), w("", 2, 3), ...Array.from({ length: 7 }, (_, i) => w("la", 3 + i, 3.5 + i))];
  const c = L.clean(raw);
  assert.strictEqual(c[0].text, "ciao");
  assert.strictEqual(c[0].end, 1);
  assert.strictEqual(c.filter((x) => x.text === "la").length, 4);
});

test("video karaoke: titolo, riga in arrivo, parola cantata", () => {
  const K = require("../karaoke.js");
  const ls = L.lines(words);
  assert.strictEqual(K.frame(0.2, ls, words).showTitle, true);
  const before = K.frame(3.6, ls, words);
  assert.strictEqual(before.showTitle, false);
  assert.strictEqual(before.line, "E questa la seconda");
  assert.strictEqual(before.sung, null);
  const during = K.frame(1.45, ls, words);
  assert.deepStrictEqual(during.lineWords, ["Questa", "è", "la", "prima."]);
  assert.strictEqual(during.sung, 2);
  assert.strictEqual(during.next, "E questa la seconda");
});
