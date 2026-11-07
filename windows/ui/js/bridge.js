// Il ponte tra la finestra e il programma (Tauri, main.rs): file, cartelle, finestre di salvataggio,
// modelli, stop del computer, avvisi, barra nella barra delle applicazioni, aggiornamenti.
// Aperta in un browser normale (le prove automatiche) ogni funzione ha un sostituto in memoria.
(function () {
  "use strict";
  const T = window.__TAURI__;
  const DESKTOP = !!(T && T.core);
  const invoke = (cmd, args, opts) => T.core.invoke(cmd, args, opts);
  const mem = new Map();                         // file «finti» per le prove nel browser
  const enc = (s) => encodeURIComponent(s);

  const Bridge = {
    desktop: DESKTOP,

    async version() { return DESKTOP ? invoke("app_version") : "0.5.0"; },

    /** Musica › IsoLR (la crea se manca). */
    async outputDir() { return DESKTOP ? invoke("output_dir") : "C:/Users/prova/Music/IsoLR"; },

    /** Una cartella nuova per la canzone: «Titolo», «Titolo 2»… */
    async newSongDir(title) {
      if (DESKTOP) return invoke("new_song_dir", { title });
      let n = 1, dir;
      do { dir = `C:/Users/prova/Music/IsoLR/${title}${n > 1 ? " " + n : ""}`; n++; } while ([...mem.keys()].some((k) => k.startsWith(dir + "/")));
      return dir;
    },

    async writeFile(path, bytes) {
      if (!DESKTOP) { mem.set(path, bytes.slice()); return; }
      await invoke("write_file", bytes, { headers: { path: enc(path) } });
    },
    async writeText(path, text) { return Bridge.writeFile(path, new TextEncoder().encode(text)); },

    async readFile(path) {
      if (!DESKTOP) { const b = mem.get(path); if (!b) throw new Error("file non trovato"); return b; }
      return new Uint8Array(await invoke("read_file", { path }));
    },
    async readText(path) { return new TextDecoder().decode(await Bridge.readFile(path)); },

    async exists(path) { return DESKTOP ? invoke("exists", { path }) : mem.has(path); },
    async remove(path) { if (DESKTOP) return invoke("trash", { path }); for (const k of [...mem.keys()]) if (k === path || k.startsWith(path + "/")) mem.delete(k); },

    /** Le canzoni già separate: ogni cartella in Musica › IsoLR con il suo isolr.json. */
    async library() {
      if (DESKTOP) return invoke("library");
      const out = [];
      for (const [k, v] of mem) if (k.endsWith("/isolr.json")) out.push({ folder: k.slice(0, -11), meta: new TextDecoder().decode(v) });
      return out;
    },

    /** Le registrazioni di una canzone (cartella «Registrazioni»), la più recente prima. */
    async listFiles(dir, ext) {
      if (DESKTOP) return invoke("list_files", { dir, ext });
      return [...mem.keys()].filter((k) => k.startsWith(dir + "/") && k.toLowerCase().endsWith("." + ext)).reverse();
    },

    /** Dove salvare un file: la finestra di Windows. Null se si annulla. */
    async askFile(name, ext) {
      if (DESKTOP) return invoke("ask_file", { name, ext });
      return `C:/Users/prova/Downloads/${name}`;
    },
    async askFolder() { return DESKTOP ? invoke("ask_folder") : "C:/Users/prova/Downloads"; },
    async askOpen() {
      if (DESKTOP) return invoke("ask_open");
      return null;
    },

    /** La pagina di GitHub con la segnalazione già compilata, nel browser. */
    openReport(url) { if (DESKTOP) return invoke("open_report", { url }); window.lastReportUrl = url; },
    reveal(path) { if (DESKTOP) invoke("reveal", { path }); },

    /** Il computer resta sveglio mentre separa (album di notte). */
    keepAwake(on) { if (DESKTOP) invoke("keep_awake", { on }); },
    sleepNow() { if (DESKTOP) invoke("sleep_now"); },
    notify(title, body) {
      if (DESKTOP) { invoke("notify", { title, body }).catch(() => {}); return; }
      try { if (Notification.permission === "granted") new Notification(title, { body }); } catch {}
    },
    /** La barra verde sull'icona nella barra delle applicazioni (0…1, null = niente). */
    progress(p) {
      if (!DESKTOP) return;
      const w = T.window && T.window.getCurrentWindow && T.window.getCurrentWindow();
      if (!w || !w.setProgressBar) return;
      w.setProgressBar(p == null ? { status: "none" } : { status: "normal", progress: Math.round(p * 100) }).catch(() => {});
    },
    focus() { if (DESKTOP) invoke("bring_to_front").catch(() => {}); },
    /** Le canzoni arrivate dal clic destro in Esplora file («Separa con IsoLR»), una volta sola. */
    async takeOpened() { return DESKTOP ? invoke("take_opened") : []; },

    // ── Modelli di Massima e Studio (e delle divisioni in più): scaricati la prima volta ──
    async modelsReady() { return DESKTOP ? invoke("models_ready") : []; },
    /** Scarica (se manca) e verifica un modello. `onProgress(0…1)` per la barra, `onStatus(testo)` per i messaggi
     *  («Connessione lenta, riprovo (2/3)…», «Ripreso da 120 MB»). */
    async prepareModel(name, onProgress, onStatus) {
      if (!DESKTOP) throw new Error("i modelli grandi funzionano solo nell'app");
      let un = null;
      if ((onProgress || onStatus) && T.event) un = await T.event.listen("model-download", (e) => {
        const p = e.payload;
        if (p.name !== name) return;
        if (p.status != null) { if (onStatus) onStatus(p.status); } else if (onProgress) onProgress(p.progress);
      });
      try { await invoke("prepare_model", { name }); } finally { if (un) un(); }
    },
    /** «Annulla»: gli scaricamenti di modelli in corso si fermano (il pezzo arrivato resta per la volta dopo). */
    cancelDownloads() { if (DESKTOP) invoke("cancel_downloads").catch(() => {}); },
    async readModel(name, part) { return new Uint8Array(await invoke("read_model", { name, part })); },

    // ── Calcolo nativo dei RoFormer (ONNX Runtime con DirectML o processore, fuori dalla finestra) ──
    async nativeLoad(name, cpuOnly, level) { return invoke("native_load", { name, cpuOnly, level }); },
    async nativeDowngrade(name) { return invoke("native_downgrade", { name }); },
    async nativeRun(name, frames, feats, x) {
      const out = await invoke("native_run", new Uint8Array(x.buffer, x.byteOffset, x.byteLength), { headers: { name, frames: String(frames), feats: String(feats) } });
      return new Float32Array(out instanceof ArrayBuffer ? out : new Uint8Array(out).buffer);
    },
    nativeRelease(name) { if (DESKTOP) invoke("native_release", { name }).catch(() => {}); },
    /** «Annulla»: il pezzo in calcolo fuori dalla finestra si ferma a metà e i modelli si chiudono. */
    nativeCancel() { if (DESKTOP) invoke("native_cancel").catch(() => {}); },

    // ── Tempi in locale (una riga per separazione; escono solo dentro una segnalazione mandata dall'utente) ──
    timingAdd(entry) {
      if (!DESKTOP) { (window.__tempi = window.__tempi || []).push(JSON.stringify(entry)); return; }
      invoke("timing_add", { line: JSON.stringify(entry) }).catch(() => {});
    },
    async timingLast(n) { return DESKTOP ? invoke("timing_last", { n }).catch(() => []) : (window.__tempi || []).slice(-n); },
    async peakMemory() { return DESKTOP ? invoke("peak_memory").catch(() => null) : null; },
    /// La memoria vera del PC in GB (navigator.deviceMemory si ferma a 8); null nel browser.
    async memoryGB() { return DESKTOP ? invoke("memory_gb").catch(() => null) : null; },
    async nativeBackend(name) { return DESKTOP ? invoke("native_backend", { name }) : null; },
    async nativeGpuError() { return DESKTOP ? invoke("native_gpu_error") : null; },

    // ── Sorveglianza e rapporto senza «Segnala» (salute.rs) ──
    /** Il battito della finestra (ogni secondo): cosa sta facendo, e se è nascosta (orologi rallentati). */
    heartbeat(doing, hidden) { if (DESKTOP) invoke("heartbeat", { doing, hidden }).catch(() => {}); },
    /** Una riga nel registro sul computer. */
    logLine(line) { if (DESKTOP) invoke("log_line", { line }).catch(() => {}); },
    async takeProblems() { return DESKTOP ? invoke("take_problems").catch(() => []) : (window.__problemi || []).splice(0); },
    async systemFacts() { return DESKTOP ? invoke("system_facts").catch((e) => "Informazioni del PC non disponibili: " + e) : "PC di prova (nel browser)"; },
    /** Salva il rapporto sul Desktop (o in Download) e lo mostra: torna il percorso. */
    async saveReport(text) { if (DESKTOP) return invoke("save_report", { text }); window.__rapporto = text; return "C:\\Users\\***\\Desktop\\Rapporto IsoLR.txt"; },
    /** Toglie il nome utente dai percorsi (C:\Users\***). */
    async redact(text) { return DESKTOP ? invoke("redact_text", { text }).catch(() => text) : text.replace(/([A-Za-z]:[\\/]Users[\\/])[^\\/\n"']+/gi, "$1***"); },

    // ── Aggiornamenti ──
    async checkUpdate() { return DESKTOP ? invoke("check_update") : null; },
    async installUpdate(url, onProgress) {
      let un = null;
      if (onProgress && T.event) un = await T.event.listen("update-download", (e) => onProgress(e.payload.progress));
      try { await invoke("install_update", { url }); } finally { if (un) un(); }
    },
  };

  // Le preferenze (come le Impostazioni del Mac): nel profilo della finestra
  const Prefs = {
    get(k, d) { try { const v = localStorage.getItem("isolr." + k); return v == null ? d : JSON.parse(v); } catch { return d; } },
    set(k, v) { try { localStorage.setItem("isolr." + k, JSON.stringify(v)); } catch {} },
  };

  window.Bridge = Bridge;
  window.Prefs = Prefs;
})();
