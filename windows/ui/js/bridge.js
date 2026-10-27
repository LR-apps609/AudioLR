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

    // ── Modelli di Massima e Studio (e delle divisioni in più): scaricati la prima volta ──
    async modelsReady() { return DESKTOP ? invoke("models_ready") : []; },
    async prepareModel(name, onProgress) {
      if (!DESKTOP) throw new Error("i modelli grandi funzionano solo nell'app");
      let un = null;
      if (onProgress && T.event) un = await T.event.listen("model-download", (e) => { if (e.payload.name === name) onProgress(e.payload.progress); });
      try { await invoke("prepare_model", { name }); } finally { if (un) un(); }
    },
    async readModel(name, part) { return new Uint8Array(await invoke("read_model", { name, part })); },

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
