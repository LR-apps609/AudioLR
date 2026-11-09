// La separazione, come SeparationJob.swift sul Mac: una coda di canzoni, la qualità scelta, i modelli
// scaricati la prima volta, il lavoro nel lavoratore (sep-worker.js), poi le tracce salvate in
// Musica › IsoLR › «Titolo», con tempo, tonalità, battiti, parti e accordi. Durante un album il computer
// non va in stop; alla fine un avviso (e, se scelto, lo stop).
/* global Bridge, Prefs, Encode */
(function () {
  "use strict";
  const RATE = 44100;

  // I modelli e i tempi di ogni qualità sono in core/load.js
  const QUALITY = {
    fast: { title: "Rapida", icon: "bolt", line: "4 tracce · per provare un'idea", keys: ["vocals", "drums", "bass", "other"] },
    best: { title: "Massima", icon: "sparkle", line: "6 tracce · pulita e veloce", keys: ["vocals", "drums", "bass", "guitar", "piano", "other"] },
    studio: { title: "Studio", icon: "star", line: "6 tracce · la più pulita", keys: ["vocals", "drums", "bass", "guitar", "piano", "other"] },
  };
  const EXTRA = {
    vocals: { source: "vocals", parts: ["lead", "backing"], model: "VoceCori3", title: "Separa voce e cori", detail: "La voce principale da una parte, i cori dall'altra: karaoke tenendo i cori", icon: "people", size: "circa 200 MB" },
    gender: { source: "vocals", parts: ["male", "female"], model: "VoceDuetto", title: "Separa voce maschile e femminile", detail: "Nei duetti la voce di uomo da una parte, quella di donna dall'altra: canti solo la tua parte", icon: "people", size: "circa 170 MB" },
    clean: { source: "vocals", parts: ["clean"], model: null, title: "Pulisci la voce", detail: "Togli il rumore di fondo e la coda del riverbero: la voce asciutta, per un remix o per cantarci sopra", icon: "sparkle", size: "niente da scaricare" },
    drums: { source: "drums", parts: ["kick", "snare", "toms", "hh", "ride", "crash"], model: "BatteriaDrumSep", title: "Dividi la batteria", detail: "Cassa, rullante, tom, charleston, ride e crash in corsie proprie", icon: "grid", size: "circa 200 MB" },
  };

  /** Il computer (core/load.js): sui computer deboli i modelli si aprono uno alla volta. */
  let realMemory = null;
  Bridge.memoryGB().then((g) => { if (g) realMemory = g; });
  function loadInfo(fellBack = false) {
    return { webgpu: "gpu" in navigator, forceCpu: Prefs.get("forceCpu", false), fellBack, memoryGB: realMemory || navigator.deviceMemory };
  }

  // Il tempo per una canzone di 4 minuti, dalla velocità vera di questo PC quando c'è (core/load.js)
  function estimate(q, seconds = 240) {
    const lib = (window.IsoApp && IsoApp.ui && IsoApp.ui.library) || [];
    return IsoLR.Load.estimate(q, { library: lib, webgpu: "gpu" in navigator, seconds });
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
      this.skipped = [];          // canzoni della coda non riuscite: { name, error }
      this.phase = "idle";        // idle · pending · working · done · failed
      this.current = null;        // la canzone aperta: { folder, meta }
      this.pending = null;        // canzone scelta ma non ancora separata
      this.progress = 0; this.step = ""; this.error = null;
      this.worker = null; this.loaded = new Set(); this.batch = null;
      this.cpu = false;           // la scheda grafica qui non riesce a calcolare: si lavora con il processore
    }
    /** La fase del lavoro (come le spunte del Mac): model · reading · separating · saving; con l'ora d'inizio. */
    setStage(stage) { if (this.stage !== stage) { this.stage = stage; this.stageStarted = Date.now(); } }

    emit() {
      // Il registro: gli ultimi passi, per «Segnala» (dicono dove si è fermata una separazione)
      const line = this.error && this.phase === "failed" ? "Errore: " + this.error : this.step;
      if (line && line !== this.lastLine) { this.lastLine = line; Job.log(line); }
      // Un cambio vero (fase, passo, errore) arriva subito; il solo avanzamento al massimo 10 volte al secondo:
      // il lavoratore manda anche centinaia di aggiornamenti e ognuno ridisegnava la schermata
      const key = `${this.phase}|${this.stage}|${this.error}|${String(this.step || "").replace(/\s*\d+%$/, "")}|${this.splitting}|${this.queue.length}`;
      const now = performance.now();
      if (key !== this.lastKey || now - (this.lastEmit || 0) >= 100) { this.lastKey = key; this.flush(); return; }
      if (!this.emitTimer) this.emitTimer = setTimeout(() => this.flush(), Math.max(0, 100 - (now - this.lastEmit)));
    }
    flush() {
      clearTimeout(this.emitTimer); this.emitTimer = null;
      this.lastEmit = performance.now();
      this.dispatchEvent(new Event("change"));
      // La barra sull'icona nella barra delle applicazioni: solo quando cambia il numero intero
      if (this.phase === "working") {
        const pct = Math.round((this.progress || 0) * 100);
        if (pct !== this.lastPct) { this.lastPct = pct; Bridge.progress(this.progress); }
      } else this.lastPct = null;
    }
    /** Aspetta `p`, ma un «Annulla» la interrompe subito (prima un download o un'analisi andavano fino in fondo). */
    guard(p) { return this.cancelGate ? Promise.race([p, this.cancelGate]) : p; }
    static log(line) {
      const t = new Date().toLocaleTimeString("it-IT");
      Job.lines.push(`${t} ${line.replace(/ \d+%$/, "")}`);
      // Anche nel registro sul computer: dopo un blocco o una chiusura si sa dove si era fermata
      Bridge.logLine(line.replace(/ \d+%$/, ""));
      if (Job.lines.length > 40) Job.lines.shift();
    }
    get busy() { return this.phase === "working"; }

    /** Canzoni trascinate: la prima diventa «pronta» (si sceglie la qualità), le altre in coda se si lavora già. */
    add(files) {
      const all = [...files].filter(Boolean), list = all.filter((f) => f.size > 0);
      // Un file vuoto (0 byte) prima veniva scartato in silenzio: sembrava che il trascinamento non funzionasse
      const empty = all.filter((f) => !f.size);
      if (empty.length) window.dispatchEvent(new CustomEvent("isolr-avviso", { detail: empty.length === 1
        ? `«${empty[0].name}» è vuoto (0 byte): non c'è niente da separare`
        : `${empty.length} file vuoti (0 byte) lasciati fuori: non c'è niente da separare` }));
      if (!list.length) return;
      // Niente in lavorazione e nessuna pronta, ma una coda rimasta: la prima della coda torna pronta
      if (!this.busy && !this.pending && this.queue.length) { this.pending = this.queue.shift(); this.phase = "pending"; this.error = null; }
      else if (!this.busy && !this.queue.length) {
        this.pending = list.shift(); this.phase = "pending"; this.error = null;
      }
      for (const f of list) this.queue.push(f);
      this.emit();
    }
    /** «Togli» sulla canzone pronta: passa pronta la prossima della coda (prima la coda restava ferma e Separa spento). */
    clearPending() {
      this.pending = this.queue.length ? this.queue.shift() : null;
      this.phase = this.pending ? "pending" : this.current ? "done" : "idle"; this.emit();
    }
    reset() { if (this.busy) return; this.preview = null; this.pending = null; this.current = null; this.queue = []; this.skipped = []; this.phase = "idle"; this.emit(); }

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
          // Separazione leggera: il lavoratore chiede un modello quando serve, e dice quando l'ha chiuso
          if (m.type === "need") { this.provide(m.name); return; }
          if (m.type === "released") { this.loaded.delete(m.name); Bridge.nativeRelease(m.name); return; }
          if (m.type === "infer") { this.infer(m); return; }
          if (m.type === "downgrade") { this.downgrade(m); return; }
          if (m.type === "progress") { if (m.progress != null) this.progress = m.progress; if (m.step) this.step = m.step; this.emit(); return; }
          w.removeEventListener("message", on);
          if (m.type === "error") reject(new Error(m.message)); else resolve(m);
        };
        w.addEventListener("message", on);
        // «Annulla» chiude il lavoratore: questa attesa finisce subito con «annullato»
        this.abort = (err) => { w.removeEventListener("message", on); reject(err); };
        w.onerror = (e) => { w.removeEventListener("message", on); this.worker = null; reject(new Error("il lavoro si è interrotto (" + (e.message || "memoria insufficiente?") + ")")); };
        w.postMessage(msg, transfer);
      });
    }

    /** Apre un RoFormer fuori dalla finestra (ONNX Runtime nativo): dice dove calcola, o null se non si può. */
    async openNative(name, cfg) {
      if (!Bridge.desktop || !/roformer/i.test(cfg.kind || "")) return null;
      try {
        // Si parte dal gradino che ha funzionato l'ultima volta per questo modello (0 = scheda grafica al massimo)
        // Mai un'attesa infinita: se il motore non risponde in 10 minuti si continua senza (e lo si scrive nel registro)
        let timer;
        const limit = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("il motore non ha risposto in 10 minuti")), 600000); });
        const backend = await Promise.race([Bridge.nativeLoad(name, this.onCpu, Prefs.get(`nativeLevel.${name}`, 0)), limit]).finally(() => clearTimeout(timer));
        Job.log(`${name}: ${backend}`);
        if (backend === "Processore" && !this.onCpu) { const why = await Bridge.nativeGpuError(); if (why) Job.log(`DirectML non ha aperto il modello: ${why.slice(0, 300)}`); }
        return backend;
      } catch (e) { Job.log(`Calcolo nativo non disponibile (${e.message || e}): resto nella finestra`); return null; }
    }

    /** Un modello ha sbagliato sulla scheda grafica: si riapre al gradino dopo, e lo si ricorda per le volte dopo. */
    async downgrade(m) {
      const w = this.worker;              // la risposta va a questo lavoratore, non a uno nato dopo un «Annulla»
      try {
        const [level, backend] = await Bridge.nativeDowngrade(m.name);
        Prefs.set(`nativeLevel.${m.name}`, level);
        Job.log(`${m.name}: risultato sbagliato, riprovo su «${backend}»`);
        if (w && w === this.worker) w.postMessage({ type: "inferred", id: m.id, name: m.name, mask: backend });
      } catch (e) {
        if (w && w === this.worker) w.postMessage({ type: "infer-error", id: m.id, message: String(e.message || e) });
      }
    }

    /** Un pezzo chiesto dal lavoratore: lo calcola il modello aperto fuori dalla finestra. */
    async infer(m) {
      const w = this.worker;
      try {
        const mask = await Bridge.nativeRun(m.name, m.frames, m.feats, m.x);
        const backend = await Bridge.nativeBackend(m.name);
        if (w && w === this.worker) w.postMessage({ type: "inferred", id: m.id, name: m.name, mask, backend }, [mask.buffer]);
      } catch (e) {
        if (w && w === this.worker) w.postMessage({ type: "infer-error", id: m.id, message: String(e.message || e) });
      }
    }

    /** Il modello chiesto dal lavoratore (già scaricato), senza aspettare risposta. */
    async provide(name) {
      try {
        const cfg = JSON.parse(new TextDecoder().decode(await Bridge.readModel(name, "json")));
        const backend = await this.openNative(name, cfg);
        if (backend) { this.worker.postMessage({ type: "provide", name, cfg, native: true, backend }); this.loaded.add(name); return; }
        const bytes = await Bridge.readModel(name, "onnx");
        this.worker.postMessage({ type: "provide", name, bytes: bytes.buffer, cfg }, [bytes.buffer]);
        this.loaded.add(name);
      } catch (e) {
        if (this.worker) this.worker.postMessage({ type: "provide-error", name, message: String(e.message || e) });
      }
    }

    /** Il modello sul disco (scaricato la prima volta), con la barra e i messaggi del download
     *  («Connessione lenta, riprovo (2/3)…», «Ripreso da 120 MB»). «Annulla» la interrompe subito. */
    async download(name, label) {
      let note = "", pct = null;
      const show = () => {
        this.step = `Scarico ${label} (solo la prima volta)${note ? " · " + note : ""}…${pct != null ? ` ${pct}%` : ""}`;
        this.emit();
      };
      show();
      await this.guard(Bridge.prepareModel(name,
        // Appena i dati riprendono ad arrivare, l'avviso «la connessione si è interrotta…» sparisce
        (p) => { if (/^la connessione/.test(note) && Math.round(p * 100) !== pct) note = ""; this.progress = p; pct = Math.round(p * 100); show(); },
        (s) => { note = s; show(); }));
    }

    /** Scarica (la prima volta), verifica e carica nel lavoratore un modello. */
    async model(name, label) {
      if (this.loaded.has(name)) return;
      this.setStage("model");
      await this.download(name, label);
      this.step = `Preparo ${label}…`; this.progress = 0; this.emit();
      const cfg = JSON.parse(new TextDecoder().decode(await Bridge.readModel(name, "json")));
      const backend = await this.openNative(name, cfg);
      if (backend) await this.call({ type: "load", name, cfg, native: true, backend });
      else {
        const bytes = await Bridge.readModel(name, "onnx");
        await this.call({ type: "load", name, bytes: bytes.buffer, cfg, forceWasm: this.onCpu }, [bytes.buffer]);
      }
      this.loaded.add(name);
    }

    get onCpu() { return this.cpu || Prefs.get("forceCpu", false); }

    /** Come sul Mac: se la scheda grafica apre i modelli ma poi non riesce a calcolare, si rifà tutto con il processore. */
    async withFallback(work) {
      try { return await work(); } catch (e) {
        // Già sul processore, annullato, o il calcolo nativo ha già provato tutti i gradini: rifare tutto non serve
        if (this.onCpu || /annullato|anche sul processore/.test(String(e.message || e))) throw e;
        Job.log("La scheda grafica non riesce (" + String(e.message || e) + "): si riprova con il processore");
        if (this.worker) this.worker.terminate();
        // Anche i modelli aperti fuori dalla finestra si chiudono: si riaprono sul processore
        for (const n of this.loaded) Bridge.nativeRelease(n);
        this.worker = null; this.loaded = new Set(); this.cpu = true;
        this.step = "La scheda grafica non riesce: riprovo con il processore…"; this.progress = 0; this.emit();
        return work();
      }
    }

    /** Separa la canzone pronta (e poi quelle in coda) con la qualità scelta. */
    /** «Anteprima 20 s»: separa solo 20 s dal centro (o dal punto `at`, 0…1) con la qualità scelta. Non va in libreria. */
    startPreview(quality, at = 0.5) {
      if (!this.pending || this.busy) return;
      return this.start(quality, { preview: true, at });
    }
    /** Dall'anteprima alla canzone intera, con la stessa qualità. */
    separateFull() {
      const p = this.preview;
      if (!p || this.busy) return;
      this.preview = null; this.current = null; this.pending = p.file;
      return this.start(p.quality);
    }
    /** Indietro dall'anteprima: la canzone torna pronta. */
    backFromPreview() {
      const p = this.preview;
      if (!p || this.busy) return;
      this.preview = null; this.current = null; this.pending = p.file; this.phase = "pending"; this.emit();
    }

    async start(quality, opts = {}) {
      if (!this.pending || this.busy) return;
      if (!this.batch) { this.batch = { start: Date.now(), songs: 0, failed: 0 }; this.skipped = []; Bridge.keepAwake(true); }
      const file = this.pending;
      this.preview = opts.preview ? { file, quality, start: 0 } : null;
      this.pending = null;
      this.phase = "working"; this.progress = 0; this.step = "Apro la canzone…"; this.error = null; this.title = file.name.replace(/\.[^.]+$/, "");
      this.quality = quality; this.peaks = null; this.stage = null; this.setStage("reading"); this.cancelled = false;
      // Le scelte delle Impostazioni valgono dall'inizio di ogni canzone: la schermata mostra le tracce che nasceranno davvero
      this.makeInstrumental = Prefs.get("makeInstrumental", true); this.splitGuitarPiano = Prefs.get("splitGuitarPiano", true);
      const stop = () => { if (this.cancelled) throw new Error("annullato"); };
      // «Annulla» fa finire subito l'attesa in corso (download, analisi, salvataggio), qualunque sia
      this.cancelGate = new Promise((_, reject) => { this.cancelNow = reject; });
      this.cancelGate.catch(() => {});
      // I tempi di ogni passo, per il registro dei tempi su questo computer
      const tAll = performance.now(), laps = [];
      let lapAt = tAll, lapName = "Apro la canzone";
      const lap = (next) => { const t = performance.now(); laps.push([lapName, +((t - lapAt) / 1000).toFixed(1)]); lapAt = t; lapName = next; };
      let songSeconds = null, backend = null;
      this.emit();
      try {
        let song = await this.guard(decode(file));
        stop();
        if (this.preview) {
          // Solo 20 secondi: il tratto si taglia qui, il resto del lavoro è identico
          const [a, b] = IsoLR.Library.previewRange(song.seconds, opts.at ?? 0.5);
          const i0 = Math.floor(a * RATE), i1 = Math.floor(b * RATE);
          song = { left: song.left.slice(i0, i1), right: song.right.slice(i0, i1), seconds: b - a };
          this.preview.start = a;
        }
        // La forma d'onda della canzone, che si colora man mano che viene separata
        this.peaks = measure([song.left, song.right], 240).peaks; this.emit();
        let loudest = 0; for (const v of this.peaks) loudest = Math.max(loudest, v);
        const silent = loudest < 3e-5;              // sotto i -90 dB: non c'è niente da separare
        if (song.seconds > 60 * 60) throw new Error("la canzone è più lunga di un'ora");
        songSeconds = song.seconds;
        lap("Modelli");
        const t0 = performance.now();
        const split = this.splitGuitarPiano;
        let light = false;
        const res = await this.withFallback(async () => {
          // Il lavoratore apre i modelli uno alla volta quando servono e li chiude appena finito: con la voce e
          // gli strumenti aperti insieme la scheda grafica si poteva bloccare su «Preparo il modello degli strumenti»
          light = true;
          for (const m of IsoLR.Load.models(quality)) {
            const label = m.startsWith("Voce") ? "il modello della voce" : "il modello degli strumenti";
            if (!light) { await this.model(m, label); continue; }
            this.setStage("model");
            await this.download(m, label);
            stop();
          }
          lap("Separazione");
          this.setStage("separating");
          this.step = "Separazione"; this.progress = 0; this.emit();
          // Al lavoratore va una copia: la canzone serve ancora qui per la base
          const L = song.left.slice(), R = song.right.slice();
          return this.call({ type: "separate", quality, light, left: L, right: R, split, forceWasm: this.onCpu }, [L.buffer, R.buffer]);
        });
        const tracks = {};
        res.keys.forEach((k, i) => { tracks[k] = [res.channels[2 * i], res.channels[2 * i + 1]]; });
        // La base è sempre la canzone meno la voce (voce + base ridanno la canzone)
        const n = tracks.vocals[0].length, mixL = song.left, mixR = song.right;
        if (this.makeInstrumental) {
          tracks.instrumental = [new Float32Array(n), new Float32Array(n)];
          for (let i = 0; i < n; i++) { tracks.instrumental[0][i] = mixL[i] - tracks.vocals[0][i]; tracks.instrumental[1][i] = mixR[i] - tracks.vocals[1][i]; }
        }
        backend = res.backend;
        stop();
        lap("Tempo, tonalità e accordi");
        this.setStage("saving"); this.progress = 1;
        this.step = "Tempo, tonalità e accordi"; this.emit();
        const analysis = await this.guard(analyze(tracks, (w) => { this.analysisWorker = w; }));
        this.analysisWorker = null;
        stop();
        lap("Salvataggio");
        this.step = "Salvo le tracce"; this.emit();
        const took = (performance.now() - t0) / 1000;
        // L'anteprima va in Musica › IsoLR › .anteprima (sovrascritta ogni volta), che la libreria non mostra
        const into = this.preview ? `${await Bridge.outputDir()}/.anteprima` : null;
        this.current = await this.guard(save(this.title, tracks, { quality, seconds: song.seconds, took, backend: res.backend, analysis, source: file.name }, into, () => this.cancelled));
        lap(null);
        this.phase = "done";
        this.record({ quality, seconds: songSeconds, total: (performance.now() - tAll) / 1000, laps, backend, preview: !!this.preview, ok: true });
        if (!this.preview) {
          this.batch.songs++;
          if (silent) window.dispatchEvent(new CustomEvent("isolr-avviso", { detail: `«${this.title}» è muta: le tracce sono vuote e tempo e tonalità non ci sono` }));
          this.finishedAt = Date.now();           // per la festa di fine separazione (non riaprendo dalla libreria)
        }
        this.emit();
      } catch (e) {
        if (this.analysisWorker) { this.analysisWorker.terminate(); this.analysisWorker = null; }
        if (lapName) lap(null);
        if (this.cancelled) {
          // Annullata: la canzone torna pronta da separare, nessun errore
          this.preview = null;
          this.pending = file; this.phase = "pending"; this.error = null; this.emit();
          this.record({ quality, seconds: songSeconds, total: (performance.now() - tAll) / 1000, laps, backend, preview: !!opts.preview, ok: false, cancelled: true });
          this.finishBatch(true);
          return;
        }
        this.error = String(e.message || e); this.phase = "failed"; this.batch.failed++;
        // In una coda la prossima canzone parte subito: chi non riesce resta scritta, con il perché
        if (this.queue.length && !this.preview) this.skipped.push({ name: file.name, error: this.error });
        this.record({ quality, seconds: songSeconds, total: (performance.now() - tAll) / 1000, laps, backend, preview: !!opts.preview, ok: false, error: this.error.slice(0, 200) });
        this.emit();
      }
      this.cancelGate = null;
      // La prossima della coda, con la stessa qualità (non dopo un'anteprima: si ascolta e si decide)
      if (this.queue.length && !this.preview) { this.pending = this.queue.shift(); return this.start(quality); }
      this.finishBatch();
    }

    finishBatch(quiet = false) {
      const b = this.batch; this.batch = null;
      Bridge.keepAwake(false); Bridge.progress(null);
      if (quiet) return;
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

    /** Annulla subito: il lavoratore si chiude (anche a metà di un pezzo), i modelli si liberano, la canzone
     *  torna «pronta». Prima si aspettava la fine del pezzo in corso: sul processore anche più di un minuto. */
    cancel() {
      this.queue = [];
      this.cancelled = true;
      if (this.worker) { this.worker.terminate(); this.worker = null; }
      // Fuori dalla finestra: il pezzo in calcolo si ferma a metà, i modelli si chiudono, i download si fermano
      for (const n of this.loaded) Bridge.nativeRelease(n);
      Bridge.nativeCancel();
      Bridge.cancelDownloads();
      if (this.analysisWorker) { this.analysisWorker.terminate(); this.analysisWorker = null; }
      this.loaded = new Set();
      if (this.abort) { this.abort(new Error("annullato")); this.abort = null; }
      if (this.cancelNow) { this.cancelNow(new Error("annullato")); this.cancelNow = null; }
      this.step = "Annullo…"; this.emit();
    }

    /** Una riga nel registro dei tempi di questo computer (mai inviata da sola: va in «Segnala» se la mandi). */
    async record(r) {
      try {
        const mem = await Bridge.peakMemory();
        // Il nome della scheda grafica (una volta sola): serve a capire i tempi, niente altro
        if (this.gpuName === undefined) {
          this.gpuName = null;
          try { const a = navigator.gpu && await navigator.gpu.requestAdapter(); if (a && a.info) this.gpuName = a.info.description || [a.info.vendor, a.info.architecture].filter(Boolean).join(" ") || null; } catch {}
        }
        const gpu = this.gpuName;
        Bridge.timingAdd({ date: new Date().toISOString(), quality: r.quality, song: r.seconds != null ? +r.seconds.toFixed(1) : null,
          seconds: +r.total.toFixed(1), steps: r.laps, engine: r.backend || null, gpu, peakMB: mem, preview: r.preview || undefined,
          ok: r.ok, cancelled: r.cancelled || undefined, error: r.error || undefined, cores: navigator.hardwareConcurrency, memoryGB: navigator.deviceMemory });
      } catch {}
    }

    /** Voce e cori, voce maschile e femminile, batteria nei suoi pezzi: accanto alle altre tracce. */
    async split(kind) {
      const x = EXTRA[kind], cur = this.current;
      if (!cur || this.splitting) return;
      this.splitting = kind; this.splitProgress = 0; this.splitError = null; this.emit();
      // Il progresso del lavoratore diventa quello della divisione; la notifica rientra qui una volta sola
      let inside = false;
      const listen = () => { if (inside) return; inside = true; this.splitProgress = this.progress; this.emit(); inside = false; };
      this.addEventListener("change", listen);
      try {
        const src = cur.meta.stems.find((s) => s.key === x.source);
        if (kind === "clean") {
          await addStems(cur, { clean: await this.cleanVoice(cur.folder + "/" + src.file) });
        } else {
          const res = await this.withFallback(async () => {
            await this.model(x.model, "il modello");
            const audio = Encode.readWav(await Bridge.readFile(cur.folder + "/" + src.file));
            return this.call({ type: "split", kind, left: audio[0], right: audio[1] }, [audio[0].buffer, audio[1].buffer]);
          });
          const parts = {};
          res.keys.forEach((k, i) => { parts[k] = [res.channels[2 * i], res.channels[2 * i + 1]]; });
          await addStems(cur, parts);
        }
      } catch (e) { this.splitError = String(e.message || e); }
      this.removeEventListener("change", listen);
      this.splitting = null; this.emit();
    }

    /** Pulisci la voce (Cleanup.run sul Mac): rumore e riverbero, calcoli senza modelli, nel lavoratore. */
    async cleanVoice(path) {
      const audio = Encode.readWav(await Bridge.readFile(path));
      this.step = "Pulisco la voce…"; this.emit();
      const res = await this.call({ type: "clean", left: audio[0], right: audio[1], noise: Prefs.get("cleanNoise", true), reverb: Prefs.get("cleanReverb", true) },
        [audio[0].buffer, audio[1].buffer]);
      return [res.channels[0], res.channels[1]];
    }

    /** Le note di una traccia (Basic Pitch), per MIDI, spartito e tablatura. */
    async transcribe(ch) {
      await this.model("BasicPitch", "il modello delle note");
      const L = ch[0].slice(), R = ch[1].slice();
      const res = await this.call({ type: "notes", left: L, right: R }, [L.buffer, R.buffer]);
      return res.notes;
    }

    async open(entry) { if (this.busy) return; this.finishedAt = null; this.preview = null; this.current = entry; this.pending = null; this.phase = "done"; this.emit(); }
  }
  Job.lines = [];

  // ── Analisi: tempo, tonalità, battiti, parti e accordi (core/*.js, come Analysis.swift), in un lavoratore ──
  function analyze(tracks, onWorker) {
    return new Promise((resolve) => {
      let w;
      try { w = new Worker("js/analysis-worker.js"); } catch { resolve(null); return; }
      if (onWorker) onWorker(w);                 // «Annulla» lo può chiudere a metà
      const keys = Object.keys(tracks).filter((k) => k !== "instrumental");
      const buffers = keys.flatMap((k) => [tracks[k][0].slice(), tracks[k][1].slice()]);
      w.onmessage = (e) => { w.terminate(); resolve(e.data.analysis || null); };
      w.onerror = () => { w.terminate(); resolve(null); };
      w.postMessage({ keys, channels: buffers }, buffers.map((b) => b.buffer));
    });
  }

  const NAMES = {
    vocals: "Voce", clean: "Voce pulita", lead: "Voce solista", backing: "Cori", male: "Voce maschile", female: "Voce femminile", drums: "Batteria",
    kick: "Cassa", snare: "Rullante", toms: "Tom", hh: "Charleston", ride: "Ride", crash: "Crash",
    bass: "Basso", guitar: "Chitarra", piano: "Pianoforte", other: "Altri strumenti", instrumental: "Base (senza voce)",
  };
  const ORDER = ["vocals", "clean", "lead", "male", "backing", "female", "drums", "kick", "snare", "toms", "hh", "ride", "crash", "bass", "guitar", "piano", "other", "instrumental"];

  /** Le tracce in una cartella nuova, nel formato delle impostazioni, più isolr.json con tutto il resto. */
  async function save(title, tracks, info, into = null, cancelled = () => false) {
    const folder = into || await Bridge.newSongDir(title);
    // «Annulla» durante il salvataggio: ci si ferma tra un file e l'altro e la cartella a metà va nel Cestino
    // (isolr.json si scrive per ultimo, quindi una cartella a metà non compare mai nella libreria)
    const stop = async () => {
      if (!cancelled()) return;
      if (!into) await Bridge.remove(folder).catch(() => {});
      throw new Error("annullato");
    };
    const format = Prefs.get("outputFormat", "wav24");
    // Se anche una sola traccia supera il massimo, tutte si abbassano dello stesso tanto (Stem.safeGain)
    let top = 0;
    const m = {};
    for (const k of Object.keys(tracks)) { m[k] = measure(tracks[k]); top = Math.max(top, m[k].peak); }
    const gain = top > 0.98 ? 0.98 / top : 1;
    const total = Object.keys(tracks).filter((k) => k !== "instrumental").reduce((s, k) => s + m[k].energy, 0) || 1;
    const stems = [];
    for (const k of ORDER.filter((x) => tracks[x])) {
      await stop();
      const ext = Encode.FORMATS[format].ext;
      const file = `${title} – ${NAMES[k]}.${ext}`;
      // Le tracce di lavoro restano sempre anche in WAV (per riaprirle e mescolarle); il formato scelto è la copia «bella»
      await Bridge.writeFile(`${folder}/${file}`, await Encode.encode(tracks[k], format, gain));
      let work = file;
      if (format !== "wav24") { work = `.lavoro/${k}.wav`; await Bridge.writeFile(`${folder}/${work}`, Encode.wav(tracks[k], 24, gain)); }
      stems.push({ key: k, name: NAMES[k], file: work, export: file, share: k === "instrumental" ? null : m[k].energy / total,
        peakDB: m[k].peak > 0 ? +(20 * Math.log10(m[k].peak * gain)).toFixed(1) : -120, peaks: m[k].peaks });
    }
    await stop();
    const meta = { version: 1, title, created: new Date().toISOString(), quality: info.quality, duration: info.seconds, took: info.took,
      engine: engineName(info.backend) + (info.mode ? ` · modalità ${info.mode}` : ""), gainDB: +(20 * Math.log10(gain)).toFixed(2),
      source: info.source, analysis: info.analysis, stems };
    await Bridge.writeText(`${folder}/isolr.json`, JSON.stringify(meta));
    return { folder, meta };
  }

  /** Il nome del motore per la scheda della canzone. Il calcolo nativo dice già dove ha lavorato
   *  («Scheda grafica (DirectML)», «Processore»…): prima si guardava solo WebGPU e risultava sempre «Processore». */
  function engineName(backend) {
    if (backend === "webgpu") return "Scheda grafica (WebGPU)";
    if (typeof backend === "string" && /scheda|processore/i.test(backend)) return backend;
    return "Processore";
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
    // Le cartelle che iniziano con un punto (l'anteprima) non sono canzoni della libreria
    for (const it of list) {
      if (/[\\/]\.[^\\/]*$/.test(it.folder)) continue;
      try { out.push({ folder: it.folder, meta: JSON.parse(it.meta) }); } catch {}
    }
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

  window.Separation = { Job, QUALITY, EXTRA, NAMES, ORDER, estimate, loadInfo, library, decode, measure, saveVersion };
})();
