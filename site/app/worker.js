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

// L'avanzamento alla pagina al massimo 10 volte al secondo (prima: a ogni pezzetto di rete, centinaia),
// e sempre l'ultimo valore
function throttled(fn, ms = 100) {
  let last = 0;
  return (p, extra) => { const now = performance.now(); if (p >= 1 || now - last >= ms) { last = now; fn(p, extra); } };
}

const TRIES = 5;            // tentativi per pezzo del modello
const STALL_MS = 30000;     // senza dati per 30 secondi la connessione si considera caduta
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

// Un pezzo del modello dalla rete. Se la connessione cade o si ferma, si riprova con un'attesa crescente
// (1, 2, 4, 8 s) ripartendo da dove si era arrivati (Range: GitHub Pages lo accetta; se il server manda
// di nuovo tutto, si ricomincia il pezzo). `onBytes(n, tentativo)` riceve i byte nuovi.
async function download(url, onBytes) {
  let chunks = [], got = 0, lastError = null;
  for (let attempt = 1; attempt <= TRIES; attempt++) {
    if (attempt > 1) { onBytes(0, attempt); await wait(1000 * 2 ** (attempt - 2)); }
    const ctl = new AbortController();
    let timer = setTimeout(() => ctl.abort(), STALL_MS);
    try {
      const res = await fetch(url, { signal: ctl.signal, headers: got ? { Range: `bytes=${got}-` } : {} });
      if (got && res.status === 200) { onBytes(-got, attempt); chunks = []; got = 0; }   // niente ripresa: da capo
      else if (!res.ok) throw new Error("modello non disponibile (" + res.status + ")");
      const reader = res.body.getReader();
      for (;;) {
        const { done, value } = await reader.read();
        clearTimeout(timer); timer = setTimeout(() => ctl.abort(), STALL_MS);
        if (done) break;
        chunks.push(value); got += value.length;
        onBytes(value.length, attempt);
      }
      clearTimeout(timer);
      return chunks;
    } catch (e) {
      clearTimeout(timer);
      lastError = ctl.signal.aborted ? new Error("la connessione si è fermata") : e;
      if (/non disponibile \(4/.test(String(e.message))) throw e;    // 404 e simili: riprovare non serve
    }
  }
  throw new Error("non riesco a scaricare il modello (" + (lastError && lastError.message || "rete") + "): controlla la connessione e riprova");
}

async function sha256(buf) {
  if (!self.crypto || !crypto.subtle) return null;
  const h = new Uint8Array(await crypto.subtle.digest("SHA-256", buf));
  return Array.from(h, (b) => b.toString(16).padStart(2, "0")).join("");
}

// Il modello a pezzi (il sito non accetta file sopra 100 MB), con la cache del browser. Un pezzo nuovo entra
// nella cache solo dopo il controllo (dimensione e impronta SHA-256): un download rovinato non resta lì.
async function fetchModel(onProgress, again = false) {
  let res = null;
  for (let attempt = 0; ; attempt++) {
    try { res = await fetch(MODEL, { cache: "no-cache" }); if (res.ok) break; } catch (e) { /* si riprova */ }
    if (attempt >= 3) throw new Error("non riesco a raggiungere il sito: controlla la connessione e riprova");
    await wait(1000 * 2 ** attempt);
  }
  config = await res.json();
  const cache = "caches" in self ? await caches.open(CACHE) : null;
  const parts = [], fresh = [];
  let done = 0, retry = 0;
  const total = config.bytes || 1;
  const report = throttled(() => onProgress(Math.min(1, done / total), { done, total, retry }));
  for (const name of config.parts) {
    const url = new URL("../models/" + name, self.location).href;
    const cached = cache ? await cache.match(url) : undefined;
    let chunks;
    if (cached) {
      // Dalla cache: tutto in una volta (niente barra a scatti per un file già sul computer)
      chunks = [new Uint8Array(await cached.arrayBuffer())];
      done += chunks[0].length; report(done / total);
    } else {
      chunks = await download(url, (n, attempt) => { done += n; retry = attempt > 1 ? attempt : 0; report(done / total); });
      fresh.push([url, chunks]);
    }
    parts.push(...chunks);
  }
  onProgress(Math.min(1, done / total), { done, total, retry: 0 });
  const buf = new Uint8Array(done);
  let o = 0;
  for (const c of parts) { buf.set(c, o); o += c.length; }
  // Controllo: dimensione giusta e, se il sito la dà, l'impronta. Se non torna, la cache si svuota e si
  // riscarica una volta (per esempio un modello vecchio rimasto nel browser dopo un aggiornamento del sito)
  let bad = config.bytes && done !== config.bytes;
  if (!bad && config.sha256 && (fresh.length || again)) {
    const h = await sha256(buf);
    bad = h != null && h !== config.sha256;
  }
  if (bad) {
    if (cache) try { await caches.delete(CACHE); } catch (e) { /* niente */ }
    if (!again) return fetchModel(onProgress, true);
    throw new Error("il modello scaricato è rovinato: riprova");
  }
  if (cache) for (const [url, chunks] of fresh) {
    try { await cache.put(url, new Response(new Blob(chunks))); } catch (e) { /* senza cache si riscarica la prossima volta */ }
  }
  return buf;
}

async function load(forceWasm) {
  const bytes = await fetchModel((p, info) => post("download", { progress: p, ...info }));
  const providers = [];
  // La scheda grafica solo se il browser ne dà davvero una: senza, si andava al processore solo dopo un
  // tentativo fallito e un secondo lavoratore (ONNX Runtime e modello aperti due volte, secondi persi)
  let gpu = !forceWasm && "gpu" in navigator;
  if (gpu) { try { gpu = !!(await navigator.gpu.requestAdapter()); } catch (e) { gpu = false; } }
  if (gpu) providers.push("webgpu");
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
        onProgress: throttled((p) => post("progress", { progress: p })),
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
