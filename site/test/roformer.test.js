// Prova del motore RoFormer per Windows: il pezzo di prova del modello originale (PyTorch) passa da
// STFT e maschere in JavaScript e dalla rete in ONNX Runtime; si confronta con gli strumenti originali.
//   node site/test/roformer.test.js <cartella con Nome.onnx, Nome.json, Nome-prova.f32> Nome
const fs = require("fs"), path = require("path");
const ort = require("onnxruntime-node");
const R = require("../app/roformer-core.js");

(async () => {
  const [dir, name] = process.argv.slice(2);
  const cfg = JSON.parse(fs.readFileSync(path.join(dir, name + ".json"), "utf8"));
  const buf = fs.readFileSync(path.join(dir, name + "-prova.f32"));
  const f = new Float32Array(buf.buffer, buf.byteOffset, buf.length / 4);
  const chunk = f[0], S = f[1];
  const mix = [f.slice(2, 2 + chunk), f.slice(2 + chunk, 2 + 2 * chunk)];
  const ref = f.slice(2 + 2 * chunk);
  const t0 = Date.now();
  const session = await ort.InferenceSession.create(path.join(dir, name + ".onnx"), { graphOptimizationLevel: "all" });
  const T = cfg.frames, FS = cfg.freq_indices.length;
  const runNet = async (x) => (await session.run({ x: new ort.Tensor("float32", x, [1, T, FS * 2]) })).mask.data;
  const t1 = Date.now();
  const stems = await R.runChunkAll(mix, cfg, new R.PlainSTFT(cfg.n_fft, cfg.hop), runNet);
  const t2 = Date.now();
  let s = 0, d = 0;
  for (let k = 0; k < S; k++) for (let c = 0; c < 2; c++) for (let i = 0; i < chunk; i++) {
    const r = ref[(k * 2 + c) * chunk + i], e = stems[k][c][i];
    s += r * r; d += (r - e) * (r - e);
  }
  const db = 10 * Math.log10(s / Math.max(d, 1e-20));
  console.log(`${name} (Windows, ONNX ${cfg.precision} bit): ${db.toFixed(1)} dB dal modello originale · ${cfg.sources.join(", ")} · ` +
    `modello aperto in ${((t1 - t0) / 1000).toFixed(1)} s, pezzo da ${(chunk / 44100).toFixed(1)} s in ${((t2 - t1) / 1000).toFixed(1)} s (processore)`);
  if (!(db > 40)) { console.error("NON FEDELE"); process.exit(1); }
})().catch((e) => { console.error(String(e)); process.exit(1); });
