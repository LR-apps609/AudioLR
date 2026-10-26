// AudioLR nel browser: il lavoro pesante, fuori dalla pagina (la pagina resta fluida).
// Riceve la canzone già decodificata (2 canali a 44,1 kHz) e restituisce le tracce. Nessuna rete,
// tranne il modello che arriva da questo stesso sito (e poi resta nella cache del browser).
/* global ort, AudioLREngine */
importScripts("../vendor/ort.webgpu.min.js", "engine-core.js", "roformer-core.js");

const MODEL = "../models/HTDemucsWeb.json";
const CACHE = "audiolr-modelli-v1";
let session = null, config = null, backend = null, cancelled = false;
// I modelli RoFormer (Massima e Studio, solo nell'app per Windows): nome → { session, cfg }
const roformers = {};

ort.env.wasm.wasmPaths = new URL("../vendor/", self.location).href;
// Più thread solo se la pagina è «isolata» (serve SharedArrayBuffer); altrimenti uno
ort.env.wasm.numThreads = self.crossOriginIsolated ? Math.min(4, navigator.hardwareConcurrency || 2) : 1;

function post(type, data = {}, transfer = []) { self.postMessage({ type, ...data }, transfer); }

// Il modello a pezzi (il sito non accetta file sopra 100 MB), con la cache del browser
async function fetchModel(onProgress) {
  config = await (await fetch(MODEL, { cache: "no-cache" })).json();
  const cache = "caches" in self ? await caches.open(CACHE) : null;
  const parts = [];
  let done = 0;
  const total = config.bytes || 1;
  for (const name of config.parts) {
    const url = new URL("../models/" + name, self.location).href;
    const cached = cache ? await cache.match(url) : undefined;
    const res = cached || await fetch(url);
    if (!res.ok) throw new Error("modello non disponibile (" + res.status + ")");
    // Si legge il pezzo una volta sola, con la barra; poi, se è nuovo, si mette nella cache.
    // (Leggere e mettere in cache lo stesso flusso insieme può bloccarsi in Safari.)
    const reader = res.body.getReader();
    const chunks = [];
    for (;;) {
      const { done: end, value } = await reader.read();
      if (end) break;
      chunks.push(value);
      done += value.length;
      onProgress(Math.min(1, done / total));
    }
    if (cache && !cached) {
      try { await cache.put(url, new Response(new Blob(chunks))); } catch (e) { /* senza cache si riscarica la prossima volta */ }
    }
    parts.push(...chunks);
  }
  const buf = new Uint8Array(done);
  let o = 0;
  for (const c of parts) { buf.set(c, o); o += c.length; }
  return buf;
}

async function load(forceWasm) {
  const bytes = await fetchModel((p) => post("download", { progress: p }));
  const providers = [];
  if (!forceWasm && "gpu" in navigator) providers.push("webgpu");
  providers.push("wasm");
  for (const ep of providers) {
    try {
      session = await ort.InferenceSession.create(bytes, { executionProviders: [ep], graphOptimizationLevel: "all" });
      backend = ep;
      break;
    } catch (e) {
      // Se la grafica non va, un lavoratore nuovo riprova con il processore (ONNX Runtime lo richiede)
      if (ep === "webgpu") { post("fallback", { reason: String(e && e.message || e) }); return; }
      throw e;
    }
  }
  post("ready", { backend, sources: config.sources, segment: config.segment });
}

async function runCore(spec, wave, le, seg) {
  const feeds = {
    spec: new ort.Tensor("float32", spec, [1, 4, config.nfft / 2, le]),
    wave: new ort.Tensor("float32", wave, [1, 2, seg]),
  };
  const out = await session.run(feeds);
  return { spec: out.spec_out.data, wave: out.wave_out.data };
}

// Un modello RoFormer dai byte che manda la pagina (scaricati e verificati dall'app), sulla scheda grafica se c'è
async function loadRoformer(name, bytes, cfg, forceWasm) {
  if (roformers[name]) return;
  const eps = !forceWasm && "gpu" in navigator ? ["webgpu", "wasm"] : ["wasm"];
  let last;
  for (const ep of eps) {
    try {
      const s = await ort.InferenceSession.create(new Uint8Array(bytes), { executionProviders: [ep], graphOptimizationLevel: "all" });
      roformers[name] = { session: s, cfg, backend: ep };
      return;
    } catch (err) { last = err; }
  }
  throw last;
}

function netFor(name) {
  const { session: s, cfg } = roformers[name];
  const T = cfg.frames, FS = cfg.freq_indices.length;
  return async (x) => (await s.run({ x: new ort.Tensor("float32", x, [1, T, FS * 2]) })).mask.data;
}

// Massima: SW su tutta la canzone. Studio come sul Mac: la voce è la media di Revive, Kim e SW sulla
// canzone; gli strumenti la media di SW sulla base senza voce e di SW sulla canzone.
// La base è sempre la canzone meno la voce, come nell'app per Mac.
async function separateRoformer(quality, left, right) {
  const t0 = performance.now();
  const mix = [left, right], n = left.length;
  const sw = roformers.StrumentiSW, names = sw.cfg.sources;
  const studio = quality === "studio";
  // Quanto pesa ogni passaggio sulla barra: Studio ne fa quattro
  const steps = studio ? [["VoceRevive", "Voce 1 di 3"], ["VoceRoFormer9", "Voce 2 di 3"], ["StrumentiSW", "Voce 3 di 3"], ["StrumentiSW", "Strumenti"]]
                       : [["StrumentiSW", "Strumenti"]];
  let done = 0;
  const run = async (name, input, step) => {
    const m = roformers[name];
    const out = await AudioLRRoFormer.separateAll(input, m.cfg, netFor(name), {
      onProgress: (p) => post("progress", { progress: (done + p) / steps.length, step }), isCancelled: () => cancelled });
    done += 1;
    return out;
  };
  const pick = (m, out) => out[Math.max(0, roformers[m].cfg.sources.indexOf("vocals"))];
  let voice, tracks;
  if (studio) {
    // Le voci si sommano man mano: in memoria resta una sola canzone per volta (le canzoni lunghe pesano)
    voice = pick("VoceRevive", await run("VoceRevive", mix, steps[0][1]));
    {
      const kim = pick("VoceRoFormer9", await run("VoceRoFormer9", mix, steps[1][1]));
      for (let c = 0; c < 2; c++) for (let k = 0; k < n; k++) voice[c][k] += kim[c][k];
    }
    const onMix = await run("StrumentiSW", mix, steps[2][1]);
    const swVoice = onMix[names.indexOf("vocals")];
    for (let c = 0; c < 2; c++) for (let k = 0; k < n; k++) voice[c][k] = (voice[c][k] + swVoice[c][k]) / 3;
    const base = [new Float32Array(n), new Float32Array(n)];
    for (let c = 0; c < 2; c++) for (let k = 0; k < n; k++) base[c][k] = mix[c][k] - voice[c][k];
    const onBase = await run("StrumentiSW", base, steps[3][1]);
    tracks = names.map((_, i) => {
      if (names[i] === "vocals") return null;
      const t = onBase[i];
      for (let c = 0; c < 2; c++) for (let k = 0; k < n; k++) t[c][k] = (t[c][k] + onMix[i][c][k]) / 2;
      return t;
    });
  } else {
    const stems = await run("StrumentiSW", mix, steps[0][1]);
    voice = stems[names.indexOf("vocals")];
    tracks = stems.map((s, i) => (names[i] === "vocals" ? null : s));
  }
  const keys = [], kept = [];
  for (let i = 0; i < names.length; i++) if (tracks[i]) { keys.push(names[i]); kept.push(tracks[i]); }
  const base = [new Float32Array(n), new Float32Array(n)];
  for (let c = 0; c < 2; c++) for (let k = 0; k < n; k++) base[c][k] = mix[c][k] - voice[c][k];
  const all = [voice, ...kept, base];
  const gain = AudioLREngine.safeGain(all);
  const buffers = all.flat().map((a) => { if (gain !== 1) for (let k = 0; k < a.length; k++) a[k] *= gain; return a; });
  post("done", { keys: ["vocals", ...keys, "instrumental"], channels: buffers, seconds: (performance.now() - t0) / 1000, backend: sw.backend },
    buffers.map((b) => b.buffer));
}

self.onmessage = async (e) => {
  const m = e.data;
  try {
    if (m.type === "loadRoformer") { await loadRoformer(m.name, m.bytes, m.cfg, m.forceWasm); post("roformerReady", { name: m.name, backend: roformers[m.name].backend }); }
    else if (m.type === "separateRoformer") { cancelled = false; await separateRoformer(m.quality, m.left, m.right); }
    else if (m.type === "load") await load(m.forceWasm);
    else if (m.type === "cancel") cancelled = true;
    else if (m.type === "separate") {
      cancelled = false;
      const t0 = performance.now();
      const stems = await AudioLREngine.separate([m.left, m.right], {
        segment: config.segment, sources: config.sources, runCore,
        onProgress: (p) => post("progress", { progress: p }),
        isCancelled: () => cancelled,
      });
      // La base senza voce è esattamente la canzone meno la voce, come nell'app: più piena e fedele
      // della somma degli strumenti, e voce + base ridanno la canzone
      const v = config.sources.indexOf("vocals");
      const n = m.left.length, mix = [m.left, m.right], base = [new Float32Array(n), new Float32Array(n)];
      for (let c = 0; c < 2; c++) for (let k = 0; k < n; k++) base[c][k] = mix[c][k] - stems[v][c][k];
      const all = [...stems, base];
      const gain = AudioLREngine.safeGain(all);
      const buffers = all.flat().map((a) => { if (gain !== 1) for (let k = 0; k < a.length; k++) a[k] *= gain; return a; });
      post("done", { keys: [...config.sources, "instrumental"], channels: buffers, seconds: (performance.now() - t0) / 1000, backend },
        buffers.map((b) => b.buffer));
    }
  } catch (err) {
    post("error", { message: cancelled ? "annullato" : String(err && err.message || err) });
  }
};
