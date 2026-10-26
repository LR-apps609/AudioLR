// La STFT contro una DFT scritta per esteso: stessi numeri di torch.stft (Hann, centrata, riflessa).
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const { PlainSTFT, RealFFT, reflectPad, round } = require("../stft.js");

function dft(x) {
  const n = x.length, re = new Float64Array(n / 2 + 1), im = new Float64Array(n / 2 + 1);
  for (let k = 0; k <= n / 2; k++) {
    for (let i = 0; i < n; i++) {
      re[k] += x[i] * Math.cos((2 * Math.PI * k * i) / n);
      im[k] -= x[i] * Math.sin((2 * Math.PI * k * i) / n);
    }
  }
  return { re, im };
}

test("FFT reale uguale alla DFT", () => {
  const x = Float64Array.from({ length: 64 }, (_, i) => Math.sin(i * 0.7) + 0.3 * Math.cos(i * 2.1) + (i % 5) * 0.1);
  const re = new Float64Array(33), im = new Float64Array(33);
  new RealFFT(64).forward(x, re, im);
  const d = dft(x);
  for (let k = 0; k <= 32; k++) {
    assert.ok(Math.abs(re[k] - d.re[k]) < 1e-9 && Math.abs(im[k] - d.im[k]) < 1e-9, `banda ${k}`);
  }
});

test("STFT: colonne, bordi riflessi e finestra di Hann", () => {
  const nfft = 32, hop = 8;
  const x = Float32Array.from({ length: 100 }, (_, i) => Math.sin(i * 0.37) * (1 + i / 100));
  const s = new PlainSTFT(nfft, hop);
  const { re, im } = s.forward(x);
  const T = s.frames(x.length);
  assert.strictEqual(T, 1 + Math.floor(100 / hop));
  const xp = reflectPad(x, nfft / 2, nfft / 2);
  for (const t of [0, 1, 6, T - 1]) {
    const frame = new Float64Array(nfft);
    for (let n = 0; n < nfft; n++) {
      const w = Math.fround(0.5 - 0.5 * Math.cos((2 * Math.PI * n) / nfft));
      frame[n] = (t * hop + n < xp.length ? xp[t * hop + n] : 0) * w;
    }
    const d = dft(frame);
    for (let k = 0; k < s.bins; k++) {
      assert.ok(Math.abs(re[k * T + t] - d.re[k]) < 1e-4 && Math.abs(im[k * T + t] - d.im[k]) < 1e-4, `colonna ${t} banda ${k}`);
    }
  }
});

test("onda più corta del margine: si allunga col silenzio (pad1d)", () => {
  assert.deepStrictEqual(Array.from(reflectPad(Float32Array.from([1, 2, 3]), 4, 4)), [0, 0, 3, 2, 1, 2, 3, 0, 0, 0, 3]);
  const s = new PlainSTFT(16, 4);
  assert.strictEqual(s.forward(Float32Array.from([1, 2, 3])).re.length, s.bins * 1);
});

test("arrotondamento come Swift", () => {
  assert.strictEqual(round(2.5), 3);
  assert.strictEqual(round(-2.5), -3);
  assert.strictEqual(round(-2.4), -2);
});
