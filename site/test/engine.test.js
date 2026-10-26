// Prova del motore del sito: lo spettrogramma, la rete ONNX e la ricucitura danno lo stesso risultato
// di Demucs originale (file di prova prodotto da Tools/web_demucs.py). Si esegue con Node:
//   node site/test/engine.test.js <cartella con HTDemucsWeb.onnx e HTDemucsWeb-prova.f32> [Nome, di serie HTDemucsWeb]
const fs = require("fs"), path = require("path");
const ort = require("onnxruntime-node");
const E = require("../app/engine-core.js");

function snr(ref, est) {
  let a = 0, b = 0;
  for (let i = 0; i < ref.length; i++) { a += ref[i] * ref[i]; const d = ref[i] - est[i]; b += d * d; }
  return 10 * Math.log10(a / Math.max(b, 1e-20));
}

(async () => {
  const dir = process.argv[2], name = process.argv[3] || "HTDemucsWeb";
  const raw = fs.readFileSync(path.join(dir, name + "-prova.f32"));
  const all = new Float32Array(raw.buffer, raw.byteOffset, raw.byteLength / 4);
  const L = all[0], S = all[1];
  const piece = [all.slice(2, 2 + L), all.slice(2 + L, 2 + 2 * L)];
  const session = await ort.InferenceSession.create(path.join(dir, name + ".onnx"));
  const runCore = async (spec, wave, le, seg) => {
    const out = await session.run({ spec: new ort.Tensor("float32", spec, [1, 4, 2048, le]), wave: new ort.Tensor("float32", wave, [1, 2, seg]) });
    return { spec: out.spec_out.data, wave: out.wave_out.data };
  };
  // 1. Un pezzo, come lo lavora il sito
  const t0 = Date.now();
  const res = await E.runSegment(new E.Spectrogram(), piece, S, runCore);
  let sig = 0, err = 0;
  for (let s = 0; s < S; s++) for (let c = 0; c < 2; c++) {
    const o = 2 + 2 * L + (s * 2 + c) * L, r = res[s][c];
    for (let i = 0; i < L; i++) { const x = all[o + i]; sig += x * x; const d = x - r[i]; err += d * d; }
  }
  const q = 10 * Math.log10(sig / Math.max(err, 1e-20));
  console.log(`Sito / Demucs originale: ${q.toFixed(1)} dB (pezzo da ${(L / 44100).toFixed(1)} s in ${((Date.now() - t0) / 1000).toFixed(1)} s)`);
  if (!(q > 40)) { console.error("il motore del sito non dà lo stesso risultato di Demucs"); process.exit(1); }
  // 2. Una canzone più lunga di un pezzo: la ricucitura ridà la somma giusta (tracce ≈ canzone)
  const n = Math.floor(L * 1.6), mix = [new Float32Array(n), new Float32Array(n)];
  for (let c = 0; c < 2; c++) for (let i = 0; i < n; i++) mix[c][i] = piece[c][i % L];
  const stems = await E.separate(mix, { segment: L, sources: ["drums", "bass", "other", "vocals"], runCore });
  const sum = new Float32Array(n);
  for (let s = 0; s < S; s++) for (let i = 0; i < n; i++) sum[i] += stems[s][0][i];
  const q2 = snr(mix[0], sum);
  console.log(`Canzone intera, tracce sommate / canzone: ${q2.toFixed(1)} dB`);
  if (!(q2 > 15)) { console.error("la ricucitura dei pezzi non torna"); process.exit(1); }
  console.log("OK");
})().catch((e) => { console.error(e); process.exit(1); });
