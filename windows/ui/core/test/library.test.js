// Filtri della libreria, anteprima e tempo/tonalità nei file (come Tests/LibraryTests.swift sul Mac).
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const L = require("../library.js");
const T = require("../tags.js");

const item = (title, bpm, keyRoot, minor, quality = "best", ago = 0, stems = ["vocals"]) =>
  ({ meta: { title, quality, created: new Date(Date.now() - ago * 1000).toISOString(), analysis: bpm ? { bpm, keyRoot, minor } : null, stems: stems.map((key) => ({ key })) } });

test("Camelot: compatibili stessa casella, ±1, relativa", () => {
  assert.ok(L.compatible([9, true], [2, true]));
  assert.ok(L.compatible([9, true], [4, true]));
  assert.ok(L.compatible([9, true], [0, false]));
  assert.ok(!L.compatible([9, true], [6, true]));
  assert.strictEqual(L.camelot(1, false).number, 3);
  assert.ok(L.compatible([4, false], [11, false]), "12B e 1B sono vicini");
});

test("filtri e ordine", () => {
  const items = [item("Uno", 120, 9, true, "best", 30), item("Due", 64, 0, false, "studio", 20), item("Tre", 140, 6, true, "best", 10, ["piano"]), item("Vecchia", null, null, false, "best", 5)];
  let f = L.empty();
  assert.deepStrictEqual(L.apply(items, f).map((e) => e.meta.title), ["Vecchia", "Tre", "Due", "Uno"]);
  f = { ...L.empty(), keyRoot: 9, minor: true };
  assert.deepStrictEqual(L.apply(items, f).map((e) => e.meta.title), ["Uno"]);
  f.compatible = true;
  assert.deepStrictEqual(L.apply(items, f).map((e) => e.meta.title).sort(), ["Due", "Uno"]);
  f = { ...L.empty(), bpmMin: 118, bpmMax: 130 };
  assert.deepStrictEqual(L.apply(items, f).map((e) => e.meta.title), ["Uno"]);
  f.halfDouble = true;
  assert.deepStrictEqual(L.apply(items, f).map((e) => e.meta.title).sort(), ["Due", "Uno"]);
  assert.deepStrictEqual(L.apply(items, { ...L.empty(), quality: "studio" }).map((e) => e.meta.title), ["Due"]);
  assert.deepStrictEqual(L.apply(items, { ...L.empty(), instrument: "piano" }).map((e) => e.meta.title), ["Tre"]);
  assert.deepStrictEqual(L.apply(items, { ...L.empty(), sort: "bpm" }).map((e) => e.meta.title), ["Due", "Uno", "Tre", "Vecchia"]);
  const c = L.chips({ ...L.empty(), keyRoot: 9, minor: true, compatible: true, bpmMin: 120 });
  assert.deepStrictEqual(c.map((x) => x.id), ["key", "bpm"]);
  assert.strictEqual(L.clear({ ...L.empty(), keyRoot: 9 }, "key").keyRoot, null);
});

test("anteprima: 20 s centrati, dentro la canzone", () => {
  assert.deepStrictEqual(L.previewRange(200, 0.5), [90, 110]);
  assert.deepStrictEqual(L.previewRange(200, 0), [0, 20]);
  assert.deepStrictEqual(L.previewRange(200, 1), [180, 200]);
  assert.deepStrictEqual(L.previewRange(12, 0.5), [0, 12]);
});

test("dati dal nome e tonalità trasposta", () => {
  const t = T.info("Eminem - Till I Collapse [HD]", { bpm: 119.6, keyRoot: 9, minor: true }, 2);
  assert.deepStrictEqual(t, { title: "Till I Collapse [HD]", artist: "Eminem", bpm: 120, key: "Bm" });
  assert.strictEqual(T.info("Senza trattino", null).artist, null);
});

function fakeWav(n = 1000) {
  const b = new Uint8Array(44 + n * 4), v = new DataView(b.buffer);
  const s = (o, t) => { for (let i = 0; i < t.length; i++) b[o + i] = t.charCodeAt(i); };
  s(0, "RIFF"); v.setUint32(4, 36 + n * 4, true); s(8, "WAVE"); s(12, "fmt "); v.setUint32(16, 16, true); v.setUint16(20, 1, true);
  v.setUint16(22, 2, true); v.setUint32(24, 44100, true); v.setUint32(28, 44100 * 4, true); v.setUint16(32, 4, true); v.setUint16(34, 16, true);
  s(36, "data"); v.setUint32(40, n * 4, true);
  return b;
}

test("WAV: id3 e LIST si rileggono, la misura RIFF è giusta, due volte non si accumulano", () => {
  const t = { title: "Canzone", artist: "Artista", bpm: 128, key: "F#m" };
  const once = T.wav(fakeWav(), t), twice = T.wav(once, t);
  const tags = T.readWav(twice);
  assert.strictEqual(tags.TBPM, "128");
  assert.strictEqual(tags.TKEY, "F#m");
  assert.strictEqual(tags.TIT2, "Canzone");
  assert.strictEqual(tags.TPE1, "Artista");
  assert.strictEqual(new DataView(twice.buffer).getUint32(4, true), twice.length - 8);
  assert.strictEqual(once.length, twice.length);
});

test("FLAC: commenti Vorbis, audio intatto", () => {
  // STREAMINFO (ultimo blocco) e due byte finti di audio
  const si = new Uint8Array(34);
  const flac = Uint8Array.from([..."fLaC"].map((c) => c.charCodeAt(0)).concat([0x80, 0, 0, 34], [...si], [0xff, 0xf8]));
  const out = T.flac(flac, { title: "Canzone", bpm: 96, key: "Eb" });
  const tags = T.readFlac(out);
  assert.strictEqual(tags.BPM, "96");
  assert.strictEqual(tags.INITIALKEY, "Eb");
  assert.strictEqual(out[4] & 0x80, 0, "STREAMINFO non è più l'ultimo");
  assert.deepStrictEqual([...out.subarray(out.length - 2)], [0xff, 0xf8]);
});

test("M4A: atomi iTunes si rileggono", () => {
  const udta = T.m4aUdta({ title: "Canzone", artist: "Artista", bpm: 100, key: "C" });
  const box = (type, body) => { const n = 8 + body.length; return [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255, ...[...type].map((c) => c.charCodeAt(0)), ...body]; };
  const file = Uint8Array.from(box("moov", box("udta", udta)));
  const tags = T.readM4a(file);
  assert.strictEqual(tags.tmpo, 100);
  assert.strictEqual(tags["©nam"], "Canzone");
  assert.strictEqual(tags["©ART"], "Artista");
});

test("ricerca senza accenti e maiuscole, anche con titoli NFD", () => {
  const items = [item("àncora"), item("Perche\u0301 no"), item("Èlite"), item("L'ultima canzone è qui 🎸")];
  const titles = (text) => L.apply(items, { ...L.empty(), text }).map((e) => e.meta.title);
  assert.deepStrictEqual(titles("ancora"), ["àncora"]);
  assert.strictEqual(titles("perche").length, 1);
  assert.strictEqual(titles("perché").length, 1);
  assert.strictEqual(titles("ELITE").length, 1);
  assert.strictEqual(titles("e qui").length, 1);
});

test("dai tester (t15): il passaggio A–B nel nome del file con i decimi e senza «:»", () => {
  assert.strictEqual(L.passageLabel(0.3, 0.9), "0m00,3s–0m00,9s");
  assert.strictEqual(L.passageLabel(5, 12.5), "0m05,0s–0m12,5s");
  assert.strictEqual(L.passageLabel(65, 600), "1m05,0s–10m00,0s");
  assert.doesNotMatch(L.passageLabel(61.2, 62), /:/);
});
