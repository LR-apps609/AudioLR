// «Pulisci la voce» (Tests/CleanupTests.swift): FFT, Togli rumore e Togli riverbero contro i riferimenti numpy
// (Tools/denoise_ref.py, dereverb_ref.py), poi su voci sintetiche con rumore e con riverbero.
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const path = require("path");
const C = require("../cleanup.js");

const fixture = (name) => { const b = fs.readFileSync(path.join(__dirname, "fixtures", name)); return new Float32Array(b.buffer, b.byteOffset, b.length / 4); };
const snr = (ref, x) => { let a = 0, b = 0; for (let i = 0; i < ref.length; i++) { a += ref[i] * ref[i]; b += (ref[i] - x[i]) ** 2; } return 10 * Math.log10(a / Math.max(b, 1e-30)); };

/** Lo stesso ingresso di Tools/make_cleanup_fixtures.py. */
function signal(n, sr, seed) {
  let s = seed;
  const out = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    s = ((Math.imul(s, 1103515245) + 12345) >>> 0) & 0x7fffffff;
    const noise = (s / 2147483648) * 2 - 1, t = i / sr;
    out[i] = 0.3 * Math.sin(2 * Math.PI * 220 * t) + 0.2 * Math.sin(2 * Math.PI * 1330 * t) * (t % 0.25 < 0.12 ? 1 : 0) + 0.05 * noise;
  }
  return out;
}

/** Note a pause sopra un fruscio leggero (phrases di make_cleanup_fixtures.py). */
function gated(n, sr, seed) {
  let s = seed;
  const out = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    s = ((Math.imul(s, 1103515245) + 12345) >>> 0) & 0x7fffffff;
    const noise = (s / 2147483648) * 2 - 1, t = i / sr;
    out[i] = 0.3 * Math.sin(2 * Math.PI * 330 * t) * (t % 0.5 < 0.25 ? 1 : 0) + 0.01 * noise;
  }
  return out;
}

test("FFT reale di 2048 punti: avanti e indietro", () => {
  const n = 2048, rf = new C.RealFFT(n), x = new Float64Array(n), R = new Float64Array(n / 2 + 1), I = new Float64Array(n / 2 + 1), y = new Float64Array(n);
  for (let i = 0; i < n; i++) x[i] = Math.sin(i * 0.37) + 0.3 * Math.cos(i * 1.9);
  rf.forward(x, R, I); rf.inverse(R, I, y);
  for (let i = 0; i < n; i++) assert.ok(Math.abs(y[i] / n - x[i]) < 1e-9);
});

test("Togli rumore: uguale a denoise_ref", () => {
  const out = C.denoise([gated(33075, 44100, 17), gated(33075, 44100, 19)]);
  const want = fixture("denoise.f32");
  const q0 = snr(want.subarray(0, 33075), out[0]), q1 = snr(want.subarray(33075), out[1]);
  assert.ok(q0 > 40 && q1 > 40, `${q0.toFixed(1)} / ${q1.toFixed(1)} dB dal riferimento`);
});

test("Togli riverbero: uguale a dereverb_ref", () => {
  const out = C.dereverb([signal(22050, 44100, 11), signal(22050, 44100, 13)]);
  const want = fixture("dereverb.f32");
  const q0 = snr(want.subarray(0, 22050), out[0]), q1 = snr(want.subarray(22050), out[1]);
  assert.ok(q0 > 60 && q1 > 60, `${q0.toFixed(1)} / ${q1.toFixed(1)} dB dal riferimento`);
});

/** Frasi di 1,25 s con pause, armoniche con vibrato. */
function phrases(seconds = 6) {
  const sr = 44100, n = Math.round(seconds * sr), dry = new Float32Array(n), env = new Float32Array(n), raw = new Float32Array(n);
  for (let i = 0; i < n; i++) raw[i] = Math.sin((2 * Math.PI * 0.4 * i) / sr) > 0 ? 1 : 0;
  let acc = 0;
  for (let i = 0; i < n; i++) { acc += raw[i] - (i >= 400 ? raw[i - 400] : 0); env[Math.max(0, i - 200)] = acc / 400; }
  let ph = 0;
  for (let i = 0; i < n; i++) {
    const t = i / sr, f0 = 220 * Math.pow(2, (Math.floor(t * 1.5) % 5) / 12) * (1 + 0.01 * Math.sin(2 * Math.PI * 5.5 * t));
    ph += (2 * Math.PI * f0) / sr;
    let v = 0;
    for (let k = 1; k < 15; k++) v += (Math.sin(k * ph) / k) * Math.exp(-k / 8);
    dry[i] = 0.2 * v * env[i];
  }
  return { dry, env };
}
function reverb(x, t60, offset) {
  const sr = 44100, n = x.length;
  let wet = new Float64Array(n);
  for (const d0 of [1116, 1188, 1277, 1356, 1422, 1491]) {
    const d = d0 + offset, g = Math.pow(10, (-3 * d) / (t60 * sr)), y = new Float64Array(n);
    for (let i = 0; i < n; i++) y[i] = x[i] + (i >= d ? g * y[i - d] : 0);
    for (let i = 0; i < n; i++) wet[i] += y[i];
  }
  for (const [d0, g] of [[556, 0.5], [441, 0.5]]) {
    const d = d0 + offset, y = new Float64Array(n);
    for (let i = 0; i < n; i++) y[i] = -g * wet[i] + (i >= d ? wet[i - d] + g * y[i - d] : 0);
    wet = y;
  }
  let ex = 0, ew = 0;
  for (let i = 0; i < n; i++) { ex += x[i] * x[i]; ew += wet[i] * wet[i]; }
  const k = Math.sqrt(ex / ew), out = new Float32Array(n);
  for (let i = 0; i < n; i++) out[i] = x[i] + 0.7 * k * wet[i];
  return out;
}
const level = (x, mask) => { let s = 0, c = 0; for (let i = 0; i < x.length; i++) if (mask[i]) { s += x[i] * x[i]; c++; } return 10 * Math.log10(s / Math.max(c, 1) + 1e-20); };

test("Togli rumore: le pause si puliscono, le note restano; una voce senza rumore non cambia", () => {
  const { dry, env } = phrases();
  const note = Array.from(env, (e) => e > 0.99);
  const gap = new Array(dry.length).fill(false);
  for (let i = 2205; i < dry.length - 2205; i++) { let ok = true; for (let j = i - 2205; j <= i + 2205 && ok; j += 49) ok = env[j] < 0.01; gap[i] = ok; }
  // Silenzio digitale nelle pause: niente da togliere
  const same = C.denoise([dry, dry]);
  assert.ok(snr(dry, same[0]) > 40, `voce senza rumore cambiata: ${snr(dry, same[0]).toFixed(1)} dB`);
  // Fruscio bianco 30 dB sotto la voce
  let s = 5, ev = 0, c = 0;
  for (let i = 0; i < dry.length; i++) if (note[i]) { ev += dry[i] * dry[i]; c++; }
  const amp = Math.sqrt(ev / c) / Math.pow(10, 30 / 20) * Math.sqrt(3), x = new Float32Array(dry.length);
  for (let i = 0; i < dry.length; i++) { s = ((Math.imul(s, 1103515245) + 12345) >>> 0) & 0x7fffffff; x[i] = dry[i] + amp * ((s / 2147483648) * 2 - 1); }
  const out = C.denoise([x, x]);
  const cut = level(x, gap) - level(out[0], gap), notes = level(out[0], note) - level(x, note);
  assert.ok(cut > 10, `fruscio nelle pause solo ${cut.toFixed(1)} dB in meno`);
  assert.ok(Math.abs(notes) < 0.5, `note ${notes.toFixed(2)} dB`);
  assert.ok(snr(dry, out[0]) > snr(dry, x) + 3, `${snr(dry, x).toFixed(1)} → ${snr(dry, out[0]).toFixed(1)} dB`);
});

test("Togli riverbero: la voce senza riverbero resta com'è, la coda nelle pause scende", () => {
  const { dry, env } = phrases();
  const note = Array.from(env, (e) => e > 0.99);
  const same = C.dereverb([dry, dry]);
  assert.ok(level(same[0], note) - level(dry, note) > -0.5, "abbassa una voce senza riverbero");
  const gap = new Array(dry.length).fill(false);
  for (let i = 2205; i < dry.length - 2205; i++) { let ok = true; for (let j = i - 2205; j <= i + 2205 && ok; j += 49) ok = env[j] < 0.01; gap[i] = ok; }
  for (const t60 of [0.6, 1.2]) {
    const l = reverb(dry, t60, 0), r = reverb(dry, t60, 23), out = C.dereverb([l, r]);
    const cut = level(l, gap) - level(out[0], gap), notes = level(out[0], note) - level(l, note);
    assert.ok(cut > 8, `T60 ${t60}: coda solo ${cut.toFixed(1)} dB in meno`);
    assert.ok(notes > -2, `T60 ${t60}: note ${notes.toFixed(1)} dB`);
  }
});
