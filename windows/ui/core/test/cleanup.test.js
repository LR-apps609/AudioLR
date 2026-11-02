// «Pulisci la voce» (Tests/CleanupTests.swift): FFT, Togli rumore con una rete finta contro il riferimento numpy,
// Togli riverbero contro il riferimento e su un riverbero sintetico.
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

test("FFT di 960 punti come la somma diretta", () => {
  const n = 960, f = new C.MixedFFT(n), re = new Float64Array(n), im = new Float64Array(n);
  for (let i = 0; i < n; i++) { re[i] = Math.sin(i * 0.37) + 0.3 * Math.cos(i * 1.9); im[i] = 0.1 * Math.sin(i * 0.11); }
  const r0 = re.slice(), i0 = im.slice();
  f.forward(re, im);
  let err = 0;
  for (const k of [0, 1, 7, 63, 64, 480, 959]) {
    let xr = 0, xi = 0;
    for (let j = 0; j < n; j++) { const a = (-2 * Math.PI * j * k) / n; xr += r0[j] * Math.cos(a) - i0[j] * Math.sin(a); xi += r0[j] * Math.sin(a) + i0[j] * Math.cos(a); }
    err = Math.max(err, Math.abs(xr - re[k]), Math.abs(xi - im[k]));
  }
  assert.ok(err < 1e-8, `errore ${err}`);
  const rf = new C.RealFFT(n), x = Float64Array.from(r0), R = new Float64Array(n / 2 + 1), I = new Float64Array(n / 2 + 1), y = new Float64Array(n);
  rf.forward(x, R, I); rf.inverse(R, I, y);
  for (let i = 0; i < n; i++) assert.ok(Math.abs(y[i] / n - x[i]) < 1e-9);
});

test("Togli rumore: il calcolo intorno alla rete è quello di deepfilter_ref (rete finta)", async () => {
  const cfg = { sr: 48000, fft: 960, hop: 480, nb_erb: 32, nb_df: 96, order: 5, lookahead: 2, alpha: 0.99, frames: 30, ctx: 5,
    widths: [2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 5, 5, 7, 7, 8, 10, 12, 13, 15, 18, 20, 24, 28, 31, 37, 42, 50, 56, 67] };
  const F = cfg.frames, E = 32, D = 96, O = 5;
  const net = async (fe, fs) => {
    const m = new Float32Array(F * E), coefs = new Float32Array(F * D * O * 2);
    for (let i = 0; i < F * E; i++) m[i] = 1 / (1 + Math.exp(-3 * fe[i]));
    for (let t = 0; t < F; t++) for (let f = 0; f < D; f++) for (let o = 0; o < O; o++) {
      coefs[(t * D + f) * O * 2 + 2 * o] = 0.1 * (o + 1) * fs[t * D + f];
      coefs[(t * D + f) * O * 2 + 2 * o + 1] = 0.05 * fs[F * D + t * D + f];
    }
    return { m, coefs };
  };
  const y = await C.denoise(signal(19200, 48000, 7), cfg, net);
  const want = fixture("denoise-finta.f32");
  assert.strictEqual(y.length, want.length);
  const q = snr(want, y);
  assert.ok(q > 60, `${q.toFixed(1)} dB dal riferimento`);
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
