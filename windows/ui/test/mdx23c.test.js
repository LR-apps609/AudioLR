// Prova del motore MDX23C per Windows (windows/ui/core/mdx23c-core.js).
//   node windows/ui/test/mdx23c.test.js
//       senza modello: STFT avanti e indietro, e la ricucitura dei pezzi con una rete finta (identità)
//   node windows/ui/test/mdx23c.test.js <cartella con Nome.onnx, Nome.json, Nome-prova.f32> Nome
//       anche il pezzo di prova del modello originale (PyTorch) attraverso STFT in JavaScript e rete in
//       ONNX Runtime (onnxruntime-node), confrontato con gli strumenti originali: deve superare MIN_DB (60 dB)
const fs = require("fs"), path = require("path");
const M = require("../core/mdx23c-core.js");

function snr(ref, est) {
  let s = 0, d = 0;
  for (let i = 0; i < ref.length; i++) { s += ref[i] * ref[i]; d += (ref[i] - est[i]) ** 2; }
  return 10 * Math.log10(s / Math.max(d, 1e-20));
}

function signal(n, seed = 1) {
  let r = seed;
  const rnd = () => ((r = (r * 1103515245 + 12345) % 2147483648) / 2147483648) - 0.5;
  const ch = [new Float32Array(n), new Float32Array(n)];
  for (let i = 0; i < n; i++) {
    const t = i / 44100, kick = Math.sin(2 * Math.PI * 60 * t) * Math.exp(-((t % 0.5) * 12));
    ch[0][i] = 0.5 * kick + 0.1 * rnd();
    ch[1][i] = 0.4 * kick + 0.1 * rnd();
  }
  return ch;
}

let failed = false;
function check(name, db, min) {
  const ok = db > min;
  console.log(`${ok ? "ok  " : "NO  "} ${name}: ${db.toFixed(1)} dB (serve più di ${min})`);
  if (!ok) failed = true;
}

(async () => {
  // 1. STFT e iSTFT: avanti e indietro senza perdite
  const stft = new M.PlainSTFT(2048, 512);
  const x = signal(20000)[0];
  const z = stft.forward(x);
  check("STFT → iSTFT", snr(x, stft.inverse(z.re, z.im, z.T, x.length)), 100);

  // 2. Rete finta che restituisce lo spettro così com'è, due strumenti uguali: ricucita deve dare la traccia
  const cfg = { n_fft: 2048, hop: 512, dim_f: 1025, frames: 32, chunk: 512 * 31, sources: ["a", "b"], overlap: 4 };
  const mix = signal(100000, 7);
  const fake = async (spec) => { const y = new Float32Array(spec.length * 2); y.set(spec, 0); y.set(spec, spec.length); return y; };
  let last = 0;
  const parts = await M.separate(mix, cfg, fake, { onProgress: (p) => { last = p; } });
  for (let k = 0; k < 2; k++) for (let c = 0; c < 2; c++) check(`ricucitura, strumento ${k}, canale ${c}`, snr(mix[c], parts[k][c]), 90);
  if (last !== 1) { console.log("NO   avanzamento non arrivato a 1"); failed = true; }

  // 3. Il modello vero (o quello piccolo con pesi a caso) contro PyTorch
  const [dir, name] = process.argv.slice(2);
  if (dir) {
    // ORT_WEB=<…/onnxruntime-web/dist/ort.node.min.js>: con ONNX Runtime Web (WASM), lo stesso dell'app
    const web = process.env.ORT_WEB;
    const ort = web ? require(path.resolve(web)) : require("onnxruntime-node");
    if (web) ort.env.wasm.numThreads = 1;
    const mc = JSON.parse(fs.readFileSync(path.join(dir, name + ".json"), "utf8"));
    const buf = fs.readFileSync(path.join(dir, name + "-prova.f32"));
    const f = new Float32Array(buf.buffer, buf.byteOffset, buf.length / 4);
    const chunk = f[0], S = f[1];
    if (chunk !== mc.chunk || S !== mc.sources.length) throw new Error("prova e descrizione non corrispondono");
    const piece = [f.slice(2, 2 + chunk), f.slice(2 + chunk, 2 + 2 * chunk)];
    const ref = f.slice(2 + 2 * chunk);
    const t0 = Date.now();
    const file = path.join(dir, name + ".onnx");
    const session = web
      ? await ort.InferenceSession.create(new Uint8Array(fs.readFileSync(file)), { executionProviders: ["wasm"], graphOptimizationLevel: "all" })
      : await ort.InferenceSession.create(file, { graphOptimizationLevel: "all" });
    const t1 = Date.now();
    const stems = await M.runChunk(piece, mc, new M.PlainSTFT(mc.n_fft, mc.hop), M.onnxRunner(ort, session, mc));
    const t2 = Date.now();
    const est = new Float32Array(ref.length);
    for (let k = 0; k < S; k++) for (let c = 0; c < 2; c++) est.set(stems[k][c], (k * 2 + c) * chunk);
    check(`${name} (${web ? "ONNX Runtime Web" : "ONNX Runtime"}, ${mc.precision} bit, ${mc.sources.join(", ")}) / modello originale`, snr(ref, est), Number(process.env.MIN_DB || 60));
    console.log(`     modello aperto in ${((t1 - t0) / 1000).toFixed(1)} s, pezzo da ${(chunk / 44100).toFixed(2)} s in ${((t2 - t1) / 1000).toFixed(1)} s (processore)`);
  }
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(String(e && e.stack || e)); process.exit(1); });
