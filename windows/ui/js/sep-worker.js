// IsoLR per Windows: il lavoro pesante, fuori dalla finestra (che resta fluida). Le stesse ricette del Mac
// (Sources/Engine.swift, SeparationJob.swift): Rapida = HTDemucs; Massima = BS-RoFormer SW; Studio = voce
// media di Revive e SW, strumenti media di SW sulla base e SW sulla canzone (core/load.js).
// Più le divisioni in più: voce e cori, voce maschile e femminile, batteria nei suoi pezzi.
// Sui computer deboli ogni modello si chiede alla finestra quando serve e si chiude appena ha finito
// (uno alla volta in memoria): cambia solo la memoria, non il risultato.
/* global ort, AudioLREngine, AudioLRRoFormer, AudioLRMDX23C */
importScripts("../vendor/ort.webgpu.min.js", "../app/engine-core.js", "../app/roformer-core.js");
try { importScripts("../core/mdx23c-core.js"); } catch (e) { /* DrumSep arriva con i modelli nuovi */ }
importScripts("../core/midi.js", "../core/load.js");

ort.env.wasm.wasmPaths = new URL("../vendor/", self.location).href;
ort.env.wasm.numThreads = self.crossOriginIsolated ? Math.min(8, navigator.hardwareConcurrency || 2) : 1;

let demucs = null, demucsCfg = null, cancelled = false, cpuOnly = false;
const nets = {};                                   // nome → { session, cfg, backend }
const post = (type, data = {}, transfer = []) => self.postMessage({ type, ...data }, transfer);

async function session(bytes, forceWasm) {
  const eps = !forceWasm && "gpu" in navigator ? ["webgpu", "wasm"] : ["wasm"];
  let last;
  for (const ep of eps) {
    try { return { s: await ort.InferenceSession.create(bytes, { executionProviders: [ep], graphOptimizationLevel: "all" }), ep }; }
    catch (e) { last = e; }
  }
  throw last;
}

// HTDemucs è dentro l'installer (cartella models), a pezzi come nel sito
async function loadDemucs(forceWasm) {
  if (demucs) return;
  demucsCfg = await (await fetch("../models/HTDemucsWeb.json")).json();
  const parts = [];
  let total = 0;
  for (const name of demucsCfg.parts) {
    const b = new Uint8Array(await (await fetch("../models/" + name)).arrayBuffer());
    parts.push(b); total += b.length;
  }
  const all = new Uint8Array(total);
  let o = 0;
  for (const p of parts) { all.set(p, o); o += p.length; }
  const { s, ep } = await session(all, forceWasm);
  demucs = { session: s, backend: ep };
}

async function runDemucs(input, from, span, step, name) {
  let sess, cfg;
  if (name) { if (!nets[name]) throw new Error("modello " + name + " non caricato"); sess = nets[name].session; cfg = nets[name].cfg; }
  else { await loadDemucs(cpuOnly); sess = demucs.session; cfg = demucsCfg; }
  const runCore = async (spec, wave, le, seg) => {
    const out = await sess.run({
      spec: new ort.Tensor("float32", spec, [1, 4, cfg.nfft / 2, le]),
      wave: new ort.Tensor("float32", wave, [1, 2, seg]),
    });
    return { spec: out.spec_out.data, wave: out.wave_out.data };
  };
  const stems = await AudioLREngine.separate(input, {
    segment: cfg.segment, sources: cfg.sources, runCore,
    onProgress: (p) => post("progress", { progress: from + span * p, step }), isCancelled: () => cancelled,
  });
  const out = {};
  cfg.sources.forEach((k, i) => { out[k] = stems[i]; });
  return out;
}

function netFor(name) {
  const { session: s, cfg } = nets[name];
  const T = cfg.frames, FS = cfg.freq_indices.length;
  return async (x) => (await s.run({ x: new ort.Tensor("float32", x, [1, T, FS * 2]) })).mask.data;
}

// Massima e Studio: i modelli si chiedono alla finestra quando servono e si chiudono appena finito
// (uno alla volta in memoria: due RoFormer aperti insieme sulla scheda grafica possono bloccare il computer)
let light = false, lastBackend = null;
const waiting = {};                                // nome → { resolve, reject }
async function ensure(name) {
  if (nets[name] || !light) return;
  const label = name.startsWith("Voce") ? "il modello della voce" : "il modello degli strumenti";
  post("progress", { step: `Preparo ${label} (la prima volta può volerci qualche minuto)…` });
  await new Promise((resolve, reject) => { waiting[name] = { resolve, reject }; post("need", { name }); });
}
function releaseNet(name) {
  if (!light || !nets[name]) return;
  lastBackend = nets[name].backend;
  try { nets[name].session.release(); } catch (e) { /* già chiuso */ }
  delete nets[name];
  post("released", { name });
}

async function runRoformer(name, input, from, span, step) {
  await ensure(name);
  const m = nets[name];
  if (!m) throw new Error("modello " + name + " non caricato");
  lastBackend = m.backend;
  const out = await AudioLRRoFormer.separateAll(input, m.cfg, netFor(name), {
    overlap: self.IsoLR.Load.OVERLAP,
    onProgress: (p) => post("progress", { progress: from + span * p, step }), isCancelled: () => cancelled });
  const res = {};
  m.cfg.sources.forEach((k, i) => { res[String(k).toLowerCase()] = out[i]; });
  return res;
}

const zeros = (n) => [new Float32Array(n), new Float32Array(n)];
function minus(a, b, n) {
  const out = zeros(n);
  for (let c = 0; c < 2; c++) for (let k = 0; k < n; k++) out[c][k] = a[c][k] - b[c][k];
  return out;
}
function plus(list, n) {
  const out = zeros(n);
  for (const t of list) if (t) for (let c = 0; c < 2; c++) for (let k = 0; k < n; k++) out[c][k] += t[c][k];
  return out;
}

/** Le ricette di separazione: { chiave: stereo }. `split` = chitarra e pianoforte in tracce proprie. */
async function separate(quality, mix, split) {
  const n = mix[0].length;
  let tracks;
  if (quality === "fast") {
    const d = await runDemucs(mix, 0, 1, "Separazione");
    tracks = { vocals: d.vocals, drums: d.drums, bass: d.bass, other: d.other };
  } else if (quality === "best") {
    const s = await runRoformer("StrumentiSW", mix, 0, 1, "Strumenti");
    releaseNet("StrumentiSW");
    tracks = { vocals: s.vocals, drums: s.drums, bass: s.bass, guitar: s.guitar, piano: s.piano, other: s.other };
  } else {
    // Studio (come sul Mac): voce da Revive e SW sulla canzone; strumenti dalla media di SW sulla canzone e sulla base
    const L = self.IsoLR.Load, P = 1 / 3;
    const revive = (await runRoformer("VoceRevive", mix, 0, P, "Voce 1 di 2")).vocals;
    releaseNet("VoceRevive");
    const onMix = await runRoformer("StrumentiSW", mix, P, P, "Voce 2 di 2 e strumenti");
    const voice = L.voice(revive, onMix, n);
    const onBase = await runRoformer("StrumentiSW", minus(mix, voice, n), 2 * P, P, "Strumenti sulla base");
    releaseNet("StrumentiSW");
    tracks = { vocals: voice, ...L.instruments(onMix, onBase, n) };
  }
  if (!split && tracks.guitar) {
    tracks.other = plus([tracks.other, tracks.guitar, tracks.piano], n);
    delete tracks.guitar; delete tracks.piano;
  }
  return tracks;
}

/** Le divisioni in più su una traccia già separata. */
async function extraSplit(kind, audio) {
  const n = audio[0].length;
  if (kind === "vocals") {
    const lead = (await runRoformer("VoceCori3", audio, 0, 1, "Voce e cori")).vocals;
    return { lead, backing: minus(audio, lead, n) };
  }
  if (kind === "gender") {
    const r = await runRoformer("VoceDuetto", audio, 0, 1, "Voci di uomo e di donna");
    return { male: r.male, female: r.female };
  }
  if (kind === "drums") {
    const m = nets.BatteriaDrumSep;
    if (!m || !self.IsoLRMDX23C) throw new Error("modello della batteria non caricato");
    const out = await IsoLRMDX23C.separate(audio, m.cfg, IsoLRMDX23C.onnxRunner(ort, m.session, m.cfg), {
      onProgress: (p) => post("progress", { progress: p, step: "Batteria" }), isCancelled: () => cancelled });
    const res = {};
    m.cfg.sources.forEach((k, i) => { res[k] = out[i]; });
    return res;
  }
  throw new Error("divisione sconosciuta");
}

self.onmessage = async (e) => {
  const m = e.data;
  if (m.forceWasm !== undefined) cpuOnly = m.forceWasm;
  try {
    if (m.type === "provide") {
      // Un modello chiesto dalla separazione leggera
      try {
        const { s, ep } = await session(new Uint8Array(m.bytes), cpuOnly);
        nets[m.name] = { session: s, cfg: m.cfg, backend: ep };
        if (waiting[m.name]) waiting[m.name].resolve();
      } catch (err) { if (waiting[m.name]) waiting[m.name].reject(err); }
      delete waiting[m.name];
      return;
    }
    if (m.type === "provide-error") {
      if (waiting[m.name]) waiting[m.name].reject(new Error(m.message));
      delete waiting[m.name];
      return;
    }
    if (m.type === "load") {
      if (!nets[m.name]) {
        const { s, ep } = await session(new Uint8Array(m.bytes), m.forceWasm);
        nets[m.name] = { session: s, cfg: m.cfg, backend: ep };
      }
      post("loaded", { name: m.name, backend: nets[m.name].backend });
    } else if (m.type === "cancel") {
      cancelled = true;
    } else if (m.type === "separate") {
      cancelled = false;
      light = !!m.light;
      const t0 = performance.now();
      const tracks = await separate(m.quality, [m.left, m.right], m.split);
      const keys = Object.keys(tracks);
      const buffers = keys.flatMap((k) => tracks[k]);
      const backend = (nets.StrumentiSW || demucs || {}).backend || lastBackend || "wasm";
      post("done", { keys, channels: buffers, seconds: (performance.now() - t0) / 1000, backend }, buffers.map((b) => b.buffer));
    } else if (m.type === "notes") {
      // Basic Pitch: le note di una traccia (finestre di 2 s a 22 050 Hz), poi le stesse regole del Mac
      cancelled = false;
      const bp = nets.BasicPitch;
      if (!bp) throw new Error("modello delle note non caricato");
      const cfg = bp.cfg, input = Object.keys(cfg.inputs || {})[0] || bp.session.inputNames[0];
      const run = async (win) => {
        const out = await bp.session.run({ [input]: new ort.Tensor("float32", win, [1, win.length, 1]) });
        return { frames: out[cfg.outputs.note.name].data, onsets: out[cfg.outputs.onset.name].data };
      };
      const list = await self.IsoLR.Midi.transcribe([m.left, m.right], run, () => cancelled);
      post("done", { notes: list.map((n) => ({ start: n.start, end: n.end, pitch: n.pitch, velocity: n.velocity })) });
    } else if (m.type === "split") {
      cancelled = false;
      const parts = await extraSplit(m.kind, [m.left, m.right]);
      const keys = Object.keys(parts);
      const buffers = keys.flatMap((k) => parts[k]);
      post("done", { keys, channels: buffers }, buffers.map((b) => b.buffer));
    }
  } catch (err) {
    post("error", { message: cancelled ? "annullato" : String((err && err.message) || err) });
  }
};
