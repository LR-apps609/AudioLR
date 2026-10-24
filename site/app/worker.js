// AudioLR nel browser: il lavoro pesante, fuori dalla pagina (la pagina resta fluida).
// Riceve la canzone già decodificata (2 canali a 44,1 kHz) e restituisce le tracce. Nessuna rete,
// tranne il modello che arriva da questo stesso sito (e poi resta nella cache del browser).
/* global ort, AudioLREngine */
importScripts("../vendor/ort.webgpu.min.js", "engine-core.js");

const MODEL = "../models/HTDemucsWeb.json";
const CACHE = "audiolr-modelli-v1";
let session = null, config = null, backend = null, cancelled = false;

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

self.onmessage = async (e) => {
  const m = e.data;
  try {
    if (m.type === "load") await load(m.forceWasm);
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
