// La separazione, come SeparationJob.swift sul Mac: una coda di canzoni, la qualità scelta, i modelli
// scaricati la prima volta, il lavoro nel lavoratore (sep-worker.js), poi le tracce salvate in
// Musica › IsoLR › «Titolo», con tempo, tonalità, battiti, parti e accordi. Durante un album il computer
// non va in stop; alla fine un avviso (e, se scelto, lo stop).
/* global Bridge, Prefs, Encode */
(function () {
  "use strict";
  const RATE = 44100;

  const QUALITY = {
    fast: { title: "Veloce", icon: "bolt", line: "4 tracce · per provare un'idea", models: [], perMinute: 8, keys: ["vocals", "drums", "bass", "other"] },
    best: { title: "Massima", icon: "sparkle", line: "6 tracce · pulita e veloce", models: ["StrumentiSW"], perMinute: 40, keys: ["vocals", "drums", "bass", "guitar", "piano", "other"] },
    studio: { title: "Studio", icon: "star", line: "6 tracce · la più pulita", models: ["VoceRevive", "VoceRoFormer9", "StrumentiSW", "HTDemucsFT-1"], perMinute: 200, keys: ["vocals", "drums", "bass", "guitar", "piano", "other"] },
  };
  const EXTRA = {
    vocals: { source: "vocals", parts: ["lead", "backing"], model: "VoceCori3", title: "Separa voce e cori", detail: "La voce principale da una parte, i cori dall'altra: karaoke tenendo i cori", icon: "people", size: "circa 200 MB" },
    gender: { source: "vocals", parts: ["male", "female"], model: "VoceDuetto", title: "Separa voce maschile e femminile", detail: "Nei duetti la voce di uomo da una parte, quella di donna dall'altra: canti solo la tua parte", icon: "people", size: "circa 170 MB" },
    drums: { source: "drums", parts: ["kick", "snare", "toms", "hh", "ride", "crash"], model: "BatteriaDrumSep", title: "Dividi la batteria", detail: "Cassa, rullante, tom, charleston, ride e crash in corsie proprie", icon: "grid", size: "circa 200 MB" },
  };

  // «circa 3 minuti» per una canzone di 4 minuti, come le schede della qualità sul Mac
  function estimate(q, seconds = 240) {
    const s = (QUALITY[q].perMinute * seconds) / 60;
    if (s < 50) return "circa 30 secondi";
    const m = Math.max(1, Math.round(s / 60));
    return `circa ${m} ${m === 1 ? "minuto" : "minuti"}`;
  }

  /** Legge e decodifica un file audio in stereo a 44,1 kHz (come AudioIO.read). */
  async function decode(file) {
    const bytes = await file.arrayBuffer();
    const ctx = new OfflineAudioContext(2, 1, RATE);
    let buf;
    try { buf = await ctx.decodeAudioData(bytes); } catch { throw new Error("non riesco ad aprire questo file come audio"); }
    if (buf.sampleRate !== RATE || buf.numberOfChannels !== 2) {
      const off = new OfflineAudioContext(2, Math.ceil(buf.duration * RATE), RATE);
      const src = off.createBufferSource(); src.buffer = buf; src.connect(off.destination); src.start();
      buf = await off.startRendering();
    }
    return { left: buf.getChannelData(0).slice(), right: buf.getChannelData(1).slice(), seconds: buf.duration };
  }

  /** Energia, picco e forma d'onda di una traccia (Stem.measure e i picchi per il disegno). */
  function measure(ch, points = 600) {
    let e = 0, peak = 0;
    const n = ch[0].length, peaks = new Float32Array(points), step = Math.max(1, Math.floor(n / points));
    for (let p = 0; p < points; p++) {
      let m = 0;
      for (let i = p * step, end = Math.min(n, i + step); i < end; i++) {
        const v = Math.max(Math.abs(ch[0][i]), Math.abs(ch[1][i]));
        if (v > m) m = v;
      }
      peaks[p] = m;
    }
    for (let c = 0; c < 2; c++) for (let i = 0; i < n; i++) { const v = ch[c][i]; e += v * v; if (Math.abs(v) > peak) peak = Math.abs(v); }
    let top = 0; for (const v of peaks) top = Math.max(top, v);
    return { energy: e, peak, peaks: Array.from(peaks, (v) => +(v / (top || 1)).toFixed(3)) };
  }

  class Job extends EventTarget {
    constructor() {
      super();
      this.queue = [];            // [{ file, title }]
      this.phase = "idle";        // idle · pending · working · done · failed
      this.current = null;        // la canzone aperta: { folder, meta }
      this.pending = null;        // canzone scelta ma non ancora separata
      this.progress = 0; this.step = ""; this.error = null;
      this.worker = null; this.loaded = new Set(); this.batch = null;
      this.cpu = false;           // la scheda grafica qui non riesce a calcolare: si lavora con il processore
    }
    emit() {
      // Il registro: gli ultimi passi, per «Segnala» (dicono dove si è fermata una separazione)
      const line = this.error && this.phase === "failed" ? "Errore: " + this.error : this.step;
      if (line && line !== this.lastLine) { this.lastLine = line; Job.log(line); }
      this.dispatchEvent(new Event("change"));
    }
    static log(line) {
      const t = new Date().toLocaleTimeString("it-IT");
      Job.lines.push(`${t} ${line.replace(/ \d+%$/, "")}`);
      if (Job.lines.length > 40) Job.lines.shift();
    }
    get busy() { return this.phase === "working"; }

    /** Canzoni trascinate: la prima diventa «pronta» (si sceglie la qualità), le altre in coda se si lavora già. */
    add(files) {
      const list = [...files].filter((f) => f && f.size > 0);
      if (!list.length) return;
      if (this.busy || this.queue.length) { for (const f of list) this.queue.push(f); this.emit(); return; }
      this.pending = list[0];
      for (const f of list.slice(1)) this.queue.push(f);
      this.phase = "pending"; this.error = null; this.emit();
    }
    clearPending() { this.pending = null; this.phase = this.current ? "done" : "idle"; this.emit(); }
    reset() { if (this.busy) return; this.pending = null; this.current = null; this.queue = []; this.phase = "idle"; this.emit(); }

    ensureWorker() {
      if (this.worker) return;
      this.worker = new Worker("js/sep-worker.js");
      this.loaded = new Set();
    }
    call(msg, transfer = []) {
      this.ensureWorker();
      return new Promise((resolve, reject) => {
        const w = this.worker;
        const on = (e) => {
          const m = e.data;
          if (m.type === "progress") { this.progress = m.progress; if (m.step) this.step = m.step; this.emit(); Bridge.progress(this.progress); return; }
          w.removeEventListener("message", on);
          if (m.type === "error") reject(new Error(m.message)); else resolve(m);
        };
        w.addEventListener("message", on);
        w.onerror = (e) => { w.removeEventListener("message", on); this.worker = null; reject(new Error("il lavoro si è interrotto (" + (e.message || "memoria insufficiente?") + ")")); };
        w.postMessage(msg, transfer);
      });
    }

    /** Scarica (la prima volta), verifica e carica nel lavoratore un modello. */
    async model(name, label) {
      if (this.loaded.has(name)) return;
      this.step = `Scarico ${label} (solo la prima volta)…`; this.emit();
      await Bridge.prepareModel(name, (p) => { this.progress = p; this.step = `Scarico ${label} (solo la prima volta)… ${Math.round(p * 100)}%`; this.emit(); });
      this.step = `Preparo ${label}…`; this.progress = 0; this.emit();
      const bytes = await Bridge.readModel(name, "onnx"), cfg = JSON.parse(new TextDecoder().decode(await Bridge.readModel(name, "json")));
      await this.call({ type: "load", name, bytes: bytes.buffer, cfg, forceWasm: this.onCpu }, [bytes.buffer]);
      this.loaded.add(name);
    }

    get onCpu() { return this.cpu || Prefs.get("forceCpu", false); }

    /** Come sul Mac: se la scheda grafica apre i modelli ma poi non riesce a calcolare, si rifà tutto con il processore. */
    async withFallback(work) {
      try { return await work(); } catch (e) {
        if (this.onCpu || String(e.message || e) === "annullato") throw e;
        Job.log("La scheda grafica non riesce (" + String(e.message || e) + "): si riprova con il processore");
        if (this.worker) this.worker.terminate();
        this.worker = null; this.loaded = new Set(); this.cpu = true;
        this.step = "La scheda grafica non riesce: riprovo con il processore…"; this.progress = 0; this.emit();
        return work();
      }
    }

    /** Separa la canzone pronta (e poi quelle in coda) con la qualità scelta. */
    async start(quality) {
      if (!this.pending || this.busy) return;
      if (!this.batch) { this.batch = { start: Date.now(), songs: 0, failed: 0 }; Bridge.keepAwake(true); }
      const file = this.pending;
      this.pending = null;
      this.phase = "working"; this.progress = 0; this.step = "Apro la canzone…"; this.error = null; this.title = file.name.replace(/\.[^.]+$/, "");
      this.emit();
      try {
        const song = await decode(file);
        if (song.seconds > 60 * 60) throw new Error("la canzone è più lunga di un'ora");
        const t0 = performance.now();
        const split = Prefs.get("splitGuitarPiano", true);
        const res = await this.withFallback(async () => {
          for (const m of QUALITY[quality].models) await this.model(m, m.startsWith("Voce") ? "il modello della voce" : "il modello degli strumenti");
          this.step = "Separazione"; this.progress = 0; this.emit();
          // Al lavoratore va una copia: la canzone serve ancora qui per la base
          const L = song.left.slice(), R = song.right.slice();
          return this.call({ type: "separate", quality, left: L, right: R, split, forceWasm: this.onCpu }, [L.buffer, R.buffer]);
        });
        const tracks = {};
        res.keys.forEach((k, i) => { tracks[k] = [res.channels[2 * i], res.channels[2 * i + 1]]; });
        // La base è sempre la canzone meno la voce (voce + base ridanno la canzone)
        const n = tracks.vocals[0].length, mixL = song.left, mixR = song.right;
        if (Prefs.get("makeInstrumental", true)) {
          tracks.instrumental = [new Float32Array(n), new Float32Array(n)];
          for (let i = 0; i < n; i++) { tracks.instrumental[0][i] = mixL[i] - tracks.vocals[0][i]; tracks.instrumental[1][i] = mixR[i] - tracks.vocals[1][i]; }
        }
        this.step = "Tempo, tonalità e accordi"; this.emit();
        const analysis = await analyze(tracks);
        this.step = "Salvo le tracce"; this.emit();
        const took = (performance.now() - t0) / 1000;
        this.current = await save(this.title, tracks, { quality, seconds: song.seconds, took, backend: res.backend, analysis, source: file.name });
        this.phase = "done"; this.batch.songs++;
        this.emit();
      } catch (e) {
        this.error = String(e.message || e); this.phase = "failed"; this.batch.failed++;
        this.emit();
      }
      // La prossima della coda, con la stessa qualità
      if (this.queue.length) { this.pending = this.queue.shift(); return this.start(quality); }
      this.finishBatch();
    }

    finishBatch() {
      const b = this.batch; this.batch = null;
      Bridge.keepAwake(false); Bridge.progress(null);
      if (!b) return;
      const mins = Math.round((Date.now() - b.start) / 60000);
      const time = mins < 1 ? "meno di un minuto" : mins < 60 ? `${mins} min` : `${Math.floor(mins / 60)} h ${mins % 60} min`;
      if (b.songs + b.failed > 1 || document.hidden) {
        Bridge.notify("IsoLR ha finito", `${b.songs} ${b.songs === 1 ? "canzone pronta" : "canzoni pronte"} in ${time}${b.failed ? ` · ${b.failed} non riuscite` : ""}`);
      }
      Bridge.focus();
      if (Prefs.get("sleepAfterBatch", false) && b.songs + b.failed > 1) setTimeout(() => Bridge.sleepNow(), 60000);
      if (Prefs.get("soundWhenDone", true)) chime();
    }

    cancel() { if (this.worker) this.worker.postMessage({ type: "cancel" }); this.queue = []; }

    /** Voce e cori, voce maschile e femminile, batteria nei suoi pezzi: accanto alle altre tracce. */
    async split(kind) {
      const x = EXTRA[kind], cur = this.current;
      if (!cur || this.splitting) return;
      this.splitting = kind; this.splitProgress = 0; this.splitError = null; this.emit();
      const listen = () => { this.splitProgress = this.progress; this.emit(); };
      this.addEventListener("change", listen);
      try {
        const src = cur.meta.stems.find((s) => s.key === x.source);
        const res = await this.withFallback(async () => {
          await this.model(x.model, "il modello");
          const audio = Encode.readWav(await Bridge.readFile(cur.folder + "/" + src.file));
          return this.call({ type: "split", kind, left: audio[0], right: audio[1] }, [audio[0].buffer, audio[1].buffer]);
        });
        const parts = {};
        res.keys.forEach((k, i) => { parts[k] = [res.channels[2 * i], res.channels[2 * i + 1]]; });
        await addStems(cur, parts);
      } catch (e) { this.splitError = String(e.message || e); }
      this.removeEventListener("change", listen);
      this.splitting = null; this.emit();
    }

    /** Le note di una traccia (Basic Pitch), per MIDI, spartito e tablatura. */
    async transcribe(ch) {
      await this.model("BasicPitch", "il modello delle note");
      const L = ch[0].slice(), R = ch[1].slice();
      const res = await this.call({ type: "notes", left: L, right: R }, [L.buffer, R.buffer]);
      return res.notes;
    }

    async open(entry) { if (this.busy) return; this.current = entry; this.pending = null; this.phase = "done"; this.emit(); }
  }
  Job.lines = [];

  // ── Analisi: tempo, tonalità, battiti, parti e accordi (core/*.js, come Analysis.swift), in un lavoratore ──
  function analyze(tracks) {
    return new Promise((resolve) => {
      let w;
      try { w = new Worker("js/analysis-worker.js"); } catch { resolve(null); return; }
      const keys = Object.keys(tracks).filter((k) => k !== "instrumental");
      const buffers = keys.flatMap((k) => [tracks[k][0].slice(), tracks[k][1].slice()]);
      w.onmessage = (e) => { w.terminate(); resolve(e.data.analysis || null); };
      w.onerror = () => { w.terminate(); resolve(null); };
      w.postMessage({ keys, channels: buffers }, buffers.map((b) => b.buffer));
    });
  }

  const NAMES = {
    vocals: "Voce", lead: "Voce solista", backing: "Cori", male: "Voce maschile", female: "Voce femminile", drums: "Batteria",
    kick: "Cassa", snare: "Rullante", toms: "Tom", hh: "Charleston", ride: "Ride", crash: "Crash",
    bass: "Basso", guitar: "Chitarra", piano: "Pianoforte", other: "Altri strumenti", instrumental: "Base (senza voce)",
  };
  const ORDER = ["vocals", "lead", "male", "backing", "female", "drums", "kick", "snare", "toms", "hh", "ride", "crash", "bass", "guitar", "piano", "other", "instrumental"];

  /** Le tracce in una cartella nuova, nel formato delle impostazioni, più isolr.json con tutto il resto. */
  async function save(title, tracks, info) {
    const folder = await Bridge.newSongDir(title);
    const format = Prefs.get("outputFormat", "wav24");
    // Se anche una sola traccia supera il massimo, tutte si abbassano dello stesso tanto (Stem.safeGain)
    let top = 0;
    const m = {};
    for (const k of Object.keys(tracks)) { m[k] = measure(tracks[k]); top = Math.max(top, m[k].peak); }
    const gain = top > 0.98 ? 0.98 / top : 1;
    const total = Object.keys(tracks).filter((k) => k !== "instrumental").reduce((s, k) => s + m[k].energy, 0) || 1;
    const stems = [];
    for (const k of ORDER.filter((x) => tracks[x])) {
      const ext = Encode.FORMATS[format].ext;
      const file = `${title} – ${NAMES[k]}.${ext}`;
      // Le tracce di lavoro restano sempre anche in WAV (per riaprirle e mescolarle); il formato scelto è la copia «bella»
      await Bridge.writeFile(`${folder}/${file}`, await Encode.encode(tracks[k], format, gain));
      let work = file;
      if (format !== "wav24") { work = `.lavoro/${k}.wav`; await Bridge.writeFile(`${folder}/${work}`, Encode.wav(tracks[k], 24, gain)); }
      stems.push({ key: k, name: NAMES[k], file: work, export: file, share: k === "instrumental" ? null : m[k].energy / total,
        peakDB: m[k].peak > 0 ? +(20 * Math.log10(m[k].peak * gain)).toFixed(1) : -120, peaks: m[k].peaks });
    }
    const meta = { version: 1, title, created: new Date().toISOString(), quality: info.quality, duration: info.seconds, took: info.took,
      engine: info.backend === "webgpu" ? "Scheda grafica (WebGPU)" : "Processore", gainDB: +(20 * Math.log10(gain)).toFixed(2),
      source: info.source, analysis: info.analysis, stems };
    await Bridge.writeText(`${folder}/isolr.json`, JSON.stringify(meta));
    return { folder, meta };
  }

  /** Una versione nuova di una canzone già separata (a tempo, rimontata): stesse tracce e dati, cartella nuova. */
  async function saveVersion(cur, title, tracks, { duration, analysis, kind }) {
    const folder = await Bridge.newSongDir(title);
    const format = Prefs.get("outputFormat", "wav24"), ext = Encode.FORMATS[format].ext;
    let top = 0;
    const m = {};
    for (const k of Object.keys(tracks)) { m[k] = measure(tracks[k]); top = Math.max(top, m[k].peak); }
    const gain = top > 0.98 ? 0.98 / top : 1;
    const stems = [];
    for (const s of cur.meta.stems) {
      const ch = tracks[s.key];
      if (!ch) continue;
      const file = `${title} – ${s.name}.${ext}`;
      await Bridge.writeFile(`${folder}/${file}`, await Encode.encode(ch, format, gain));
      let work = file;
      if (format !== "wav24") { work = `.lavoro/${s.key}.wav`; await Bridge.writeFile(`${folder}/${work}`, Encode.wav(ch, 24, gain)); }
      stems.push(Object.assign({}, s, { file: work, export: file, peakDB: m[s.key].peak > 0 ? +(20 * Math.log10(m[s.key].peak * gain)).toFixed(1) : -120, peaks: m[s.key].peaks }));
    }
    const meta = Object.assign({}, cur.meta, { title, created: new Date().toISOString(), duration, analysis, stems,
      gainDB: +((cur.meta.gainDB || 0) + 20 * Math.log10(gain)).toFixed(2), derivedFrom: cur.meta.title, derivation: kind });
    await Bridge.writeText(`${folder}/isolr.json`, JSON.stringify(meta));
    return { folder, meta };
  }

  /** Aggiunge tracce (le divisioni in più) a una canzone già salvata. */
  async function addStems(cur, parts) {
    const format = Prefs.get("outputFormat", "wav24");
    const gain = Math.pow(10, (cur.meta.gainDB || 0) / 20);
    for (const k of Object.keys(parts)) {
      const ext = Encode.FORMATS[format].ext, file = `${cur.meta.title} – ${NAMES[k]}.${ext}`;
      await Bridge.writeFile(`${cur.folder}/${file}`, await Encode.encode(parts[k], format, 1));
      let work = file;
      if (format !== "wav24") { work = `.lavoro/${k}.wav`; await Bridge.writeFile(`${cur.folder}/${work}`, Encode.wav(parts[k], 24, 1)); }
      const me = measure(parts[k]);
      cur.meta.stems = cur.meta.stems.filter((s) => s.key !== k);
      cur.meta.stems.push({ key: k, name: NAMES[k], file: work, export: file, share: null, peakDB: me.peak > 0 ? +(20 * Math.log10(me.peak)).toFixed(1) : -120, peaks: me.peaks });
    }
    cur.meta.stems.sort((a, b) => ORDER.indexOf(a.key) - ORDER.indexOf(b.key));
    void gain;
    await Bridge.writeText(`${cur.folder}/isolr.json`, JSON.stringify(cur.meta));
  }

  /** Le canzoni già separate, la più recente prima. */
  async function library() {
    const list = await Bridge.library();
    const out = [];
    for (const it of list) { try { out.push({ folder: it.folder, meta: JSON.parse(it.meta) }); } catch {} }
    out.sort((a, b) => String(b.meta.created).localeCompare(String(a.meta.created)));
    return out;
  }

  function chime() {
    try {
      const ctx = new AudioContext(), t = ctx.currentTime;
      [880, 1318.5].forEach((f, i) => {
        const o = ctx.createOscillator(), g = ctx.createGain();
        o.frequency.value = f; g.gain.setValueAtTime(0, t + i * 0.12); g.gain.linearRampToValueAtTime(0.15, t + i * 0.12 + 0.01); g.gain.exponentialRampToValueAtTime(0.001, t + i * 0.12 + 0.6);
        o.connect(g).connect(ctx.destination); o.start(t + i * 0.12); o.stop(t + i * 0.12 + 0.7);
      });
      setTimeout(() => ctx.close(), 1500);
    } catch {}
  }

  window.Separation = { Job, QUALITY, EXTRA, NAMES, ORDER, estimate, library, decode, measure, saveVersion };
})();
