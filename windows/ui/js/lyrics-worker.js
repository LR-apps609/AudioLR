// Il testo della canzone dalla voce separata: Whisper (OpenAI, licenza MIT) con Transformers.js (licenza
// Apache 2.0), tutto sul computer. I file del modello non arrivano da Internet: li chiede alla finestra,
// che li legge dalla cartella dei modelli di IsoLR (scaricati la prima volta come gli altri).
// Risultato: le parole con il loro tempo (inizio e fine, in secondi).
import { pipeline, env } from "../vendor/tjs/transformers.min.js";

// Mai da Internet: con un file del modello mancante si dava la colpa a huggingface.co e la richiesta usciva (dal
// tester t18). Con i soli modelli «locali» Transformers.js chiede prima alla cache (la finestra, qui sotto) e se
// il file non c'è dà l'errore normale («file was not found locally»), senza uscire dal computer.
env.allowLocalModels = true;
env.allowRemoteModels = false;
env.useBrowserCache = false;
env.backends.onnx.wasm.wasmPaths = new URL("../vendor/tjs/", import.meta.url).href;

let nextId = 0;
const asking = new Map();                       // id → resolve
const post = (type, data = {}, transfer = []) => self.postMessage({ type, ...data }, transfer);

/** Un file del modello, chiesto alla finestra («onnx/encoder_model.onnx», «tokenizer.json»…). */
function askFile(path) {
  const id = ++nextId;
  return new Promise((resolve) => { asking.set(id, resolve); post("file", { id, path }); });
}

// Transformers.js guarda prima nella «cache»: qui la cache è la finestra, quindi Internet non serve mai
env.useCustomCache = true;
env.customCache = {
  async match(key) {
    const url = String(key && key.url ? key.url : key);
    const i = url.indexOf("/resolve/main/");
    if (i < 0) return undefined;
    const bytes = await askFile(url.slice(i + "/resolve/main/".length));
    return bytes ? new Response(bytes) : undefined;
  },
  async put() {},
};

let asr = null, device = null;

async function open(webgpu) {
  if (asr) return;
  const options = { dtype: { encoder_model: "fp32", decoder_model_merged: "q4" } };
  // Prima la scheda grafica (WebGPU), poi il processore
  for (const d of webgpu ? ["webgpu", "wasm"] : ["wasm"]) {
    try { asr = await pipeline("automatic-speech-recognition", "isolr/whisper", { ...options, device: d }); device = d; return; }
    catch (e) { if (d === "wasm") throw e; }
  }
}

self.onmessage = async (e) => {
  const m = e.data;
  if (m.type === "file") { const r = asking.get(m.id); asking.delete(m.id); if (r) r(m.bytes || null); return; }
  if (m.type !== "transcribe") return;
  try {
    post("progress", { step: "Preparo il modello del testo…" });
    await open(m.webgpu);
    post("progress", { step: "Ascolto la voce…" });
    const out = await asr(m.audio, {
      return_timestamps: "word", chunk_length_s: 30, stride_length_s: 5,
      language: m.language || null, task: "transcribe",
    });
    const words = (out.chunks || []).map((c) => ({ text: c.text, start: c.timestamp[0], end: c.timestamp[1] ?? c.timestamp[0] }));
    post("done", { words, device });
  } catch (err) {
    post("error", { message: String((err && err.message) || err) });
  }
};
