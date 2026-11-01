// «Progetto per…»: set di Ableton, progetto REAPER, MIDI con tempo e marcatori, foglio CUE (come Tests/DawExportTests.swift).
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const D = require("../daw.js");

// 96 BPM con un battito un po' in ritardo a metà: 20 s, battute da 4, parti
const beats = [];
for (let t = 0.5; t < 20; t += 0.625) beats.push(t);
beats[10] += 0.03;
const p = D.project({
  title: "Prova & co", bpm: 96, key: "La minore", seconds: 20,
  tracks: [{ key: "vocals", name: "Voce", file: "Samples/Imported/01 Voce.wav", seconds: 20 },
    { key: "drums", name: "Batteria", file: "Samples/Imported/02 Batteria.wav", seconds: 20 }],
  structure: { beats, firstDownbeat: 0, beatsPerBar: 4, sections: [{ start: 0.5, end: 8, label: "Intro" }, { start: 8, end: 20, label: "Strofa" }] },
});

test("segnaposto di warp sui primi battiti delle battute, multipli di 4", () => {
  const m = D.warpMarkers(p);
  assert.ok(m.length >= 7);
  for (let i = 1; i < m.length; i++) assert.strictEqual(m[i][1] - m[i - 1][1], 4);
  assert.strictEqual(m[0][1] % 4, 0);
  // Da secondi a battiti: un segnaposto cade esattamente sul suo battito
  assert.ok(Math.abs(D.beatAt(p, m[3][0]) - m[3][1]) < 1e-9);
});

test("il set di Ableton è gzip di un XML con tracce, tempo, locatori e percorsi relativi", async () => {
  const bytes = await D.als(p);
  assert.strictEqual(bytes[0], 0x1f); assert.strictEqual(bytes[1], 0x8b);       // firma di gzip
  const xml = new TextDecoder().decode(await D.gunzip(bytes));
  assert.match(xml, /^<\?xml version="1.0" encoding="UTF-8"\?>\n<Ableton MajorVersion="5"/);
  assert.strictEqual((xml.match(/<AudioTrack /g) || []).length, 2);
  assert.match(xml, /<EffectiveName Value="Voce" \/>/);
  assert.match(xml, /<RelativePath Value="Samples\/Imported\/01 Voce.wav" \/>/);
  assert.match(xml, /<Tempo><LomId Value="0" \/><Manual Value="96" \/>/);
  assert.match(xml, /<Name Value="Intro" \/>/);
  assert.match(xml, /<IsWarped Value="true" \/>/);
  assert.match(xml, /Prova &amp; co/);                                      // caratteri speciali sostituiti
  // Ben formato: ogni elemento aperto è chiuso (contando i tag)
  const open = (xml.match(/<[A-Za-z][^>]*[^/]>/g) || []).filter((t) => !t.startsWith("<?")).length;
  const close = (xml.match(/<\/[A-Za-z][^>]*>/g) || []).length;
  assert.strictEqual(open, close);
});

test("senza battiti la clip resta senza warp e il tempo è quello della canzone", () => {
  const q = D.project({ title: "X", bpm: 120, seconds: 10, tracks: [{ key: "bass", name: "Basso", file: "a.wav", seconds: 10 }] });
  assert.deepStrictEqual(D.warpMarkers(q), []);
  assert.strictEqual(D.beatAt(q, 10), 20);
  assert.match(D.abletonXml(q), /<IsWarped Value="false" \/>/);
});

test("REAPER: tempo, marcatori, tracce con colore e file", () => {
  const r = D.reaper(p);
  assert.match(r, /^<REAPER_PROJECT 0\.1 "6\.0" 0\n/);
  assert.match(r, /\n {2}TEMPO 96 4 4\n/);
  assert.match(r, /\n {2}MARKER 1 0\.5 "Intro" 0\n/);
  assert.match(r, /NAME "Voce"/);
  assert.match(r, /FILE "Samples\/Imported\/01 Voce.wav"/);
  // Corallo #FF7A66: rosso nei bit bassi, più il bit del colore scelto
  assert.match(r, new RegExp(`PEAKCOL ${0xff | (0x7a << 8) | (0x66 << 16) | 0x1000000}\\b`));
  // Ogni blocco aperto con «<» si chiude con una riga «>»
  const ls = r.trim().split("\n").map((l) => l.trim());
  assert.strictEqual(ls.filter((l) => l.startsWith("<")).length, ls.filter((l) => l === ">").length);
});

test("MIDI: intestazione, tempo che segue i battiti, marcatori delle parti", () => {
  const m = D.tempoMidi(p);
  const s = Buffer.from(m).toString("latin1");
  assert.ok(s.startsWith("MThd"));
  assert.ok(s.includes("MTrk"));
  assert.ok(s.includes("Intro") && s.includes("Strofa"));
  // Eventi di tempo: uno di partenza più uno per battito
  let tempos = 0;
  for (let i = 0; i < m.length - 2; i++) if (m[i] === 0xff && m[i + 1] === 0x51 && m[i + 2] === 0x03) tempos++;
  assert.strictEqual(tempos, 1 + beats.length - 1);
  // Un battito = 480 tick: il quinto battito cade a 4 × 480 dal primo
  assert.strictEqual(D.tickAt(p, beats[4]) - D.tickAt(p, beats[0]), 4 * 480);
});

test("foglio CUE: una traccia per parte, tempi in minuti:secondi:frame", () => {
  const c = D.cueSheet(p, "Prova.wav");
  assert.match(c, /FILE "Prova.wav" WAVE/);
  assert.match(c, /TRACK 01 AUDIO\r\n {4}TITLE "Intro"\r\n {4}INDEX 01 00:00:38/);
  assert.match(c, /TRACK 02 AUDIO\r\n {4}TITLE "Strofa"\r\n {4}INDEX 01 00:08:00/);
  assert.match(D.folderName(p, "daw"), /Tracce per DAW \(96 BPM, La minore\)$/);
});
