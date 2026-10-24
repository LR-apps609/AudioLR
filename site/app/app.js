// AudioLR nel browser: la pagina. Decodifica la canzone qui, la passa al lavoratore (worker.js),
// poi mostra un piccolo mixer come nell'app. Niente esce dal computer.
(function () {
  "use strict";
  const $ = (id) => document.getElementById(id);
  const COLORS = { vocals: "--voice", drums: "--drums", bass: "--bass", other: "--other", instrumental: "--base" };
  const NAMES = { vocals: "Voce", drums: "Batteria", bass: "Basso", other: "Altri strumenti", instrumental: "Base (senza voce)" };
  const ORDER = ["vocals", "drums", "bass", "other", "instrumental"];
  // Dentro l'app per Windows (Tauri) niente pubblicità dell'app stessa, e canzoni più lunghe
  const DESKTOP = "__TAURI_INTERNALS__" in window || location.protocol === "tauri:" || location.hostname === "tauri.localhost";
  if (DESKTOP) document.documentElement.classList.add("desktop");
  const MAX_SECONDS = DESKTOP ? 1800 : 600;

  // Barre «in attesa», come nell'app
  const bars = $("bars"), stemOrder = ["--voice", "--drums", "--bass", "--other"];
  for (let i = 0; i < 28; i++) {
    const env = Math.sin((i / 27) * Math.PI), el = document.createElement("i");
    el.style.setProperty("--c", `var(${stemOrder[Math.floor((i * 4) / 28)]})`);
    el.style.setProperty("--h", `${Math.round(18 + 52 * env)}px`);
    el.style.setProperty("--d", `${(i * 0.07).toFixed(2)}s`);
    bars.appendChild(el);
  }

  let worker = null, ready = null, forceWasm = false, songName = "", started = 0;

  function show(view) {
    for (const id of ["drop", "working", "results"]) $(id).hidden = id !== view;
    $("error").hidden = true;
  }
  function fail(msg) { show("drop"); $("error").textContent = msg; $("error").hidden = false; }
  function fmt(s) { s = Math.max(0, Math.round(s)); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`; }

  // Il lavoratore, creato alla prima canzone (così chi guarda soltanto non scarica niente)
  function startWorker() {
    if (ready) return ready;
    ready = new Promise((resolve, reject) => {
      worker = new Worker("app/worker.js");
      worker.onmessage = (e) => {
        const m = e.data;
        if (m.type === "download") { $("step").textContent = "Scarico il modello (solo la prima volta)…"; setProgress(m.progress); }
        else if (m.type === "fallback") {
          // La scheda grafica non è disponibile: un lavoratore nuovo con il processore
          worker.terminate(); ready = null; forceWasm = true;
          startWorker().then(resolve, reject);
        } else if (m.type === "ready") {
          const b = $("backend");
          b.textContent = m.backend === "webgpu" ? "Scheda grafica (WebGPU)" : "Processore (più lento)";
          b.hidden = false;
          resolve(m);
        } else if (m.type === "progress") onProgress(m.progress);
        else if (m.type === "done") onDone(m);
        else if (m.type === "error") { if (m.message === "annullato") show("drop"); else fail("Non ci sono riuscito: " + m.message); reject(new Error(m.message)); }
      };
      worker.onerror = (e) => { fail("Il browser ha interrotto il lavoro: " + (e.message || "memoria insufficiente?")); ready = null; };
      worker.postMessage({ type: "load", forceWasm });
    });
    return ready;
  }

  function setProgress(p) {
    $("bar").style.width = `${Math.round(p * 100)}%`;
    $("percent").textContent = `${Math.round(p * 100)}%`;
  }
  function onProgress(p) {
    setProgress(p);
    const elapsed = (performance.now() - started) / 1000;
    $("eta").textContent = p > 0.03 ? `Mancano circa ${fmt((elapsed / p) * (1 - p))}` : "Calcolo il tempo che manca…";
  }

  async function handle(file) {
    if (!file) return;
    songName = file.name.replace(/\.[^.]+$/, "");
    show("working");
    $("song").textContent = songName;
    $("step").textContent = "Leggo la canzone…";
    setProgress(0); $("eta").textContent = "";
    let audio;
    try {
      const ctx = new (window.AudioContext || window.webkitAudioContext)({ sampleRate: 44100 });
      audio = await ctx.decodeAudioData(await file.arrayBuffer());
      ctx.close();
    } catch { return fail("Questo file non si apre: prova con un MP3, M4A, WAV o FLAC."); }
    if (audio.duration > MAX_SECONDS) return fail("Nel browser fino a 10 minuti: per le canzoni più lunghe usa l'app.");
    if (audio.duration < 1) return fail("La canzone è troppo corta (almeno 1 secondo).");
    const left = new Float32Array(audio.getChannelData(0));
    const right = new Float32Array(audio.numberOfChannels > 1 ? audio.getChannelData(1) : audio.getChannelData(0));
    try { await startWorker(); } catch (e) { return; }
    $("step").textContent = "Separo voce e strumenti…";
    setProgress(0);
    started = performance.now();
    worker.postMessage({ type: "separate", left, right }, [left.buffer, right.buffer]);
  }

  $("file").addEventListener("change", (e) => { handle(e.target.files[0]); e.target.value = ""; });
  const drop = $("drop");
  drop.addEventListener("dragover", (e) => { e.preventDefault(); drop.classList.add("over"); });
  drop.addEventListener("dragleave", () => drop.classList.remove("over"));
  drop.addEventListener("drop", (e) => { e.preventDefault(); drop.classList.remove("over"); handle(e.dataTransfer.files[0]); });
  $("cancel").addEventListener("click", () => worker && worker.postMessage({ type: "cancel" }));
  $("again").addEventListener("click", () => { stop(); show("drop"); });

  // ── Il mixer ────────────────────────────────────────────────────────
  let ctx = null, tracks = [], sources = [], playing = false, startAt = 0, offset = 0, duration = 0, raf = 0;
  const state = { muted: new Set(), solo: new Set() };

  function gainOf(key) {
    if (state.muted.has(key)) return 0;
    if (state.solo.size && !state.solo.has(key)) return 0;
    return 1;
  }

  function onDone(m) {
    stop();
    ctx = ctx || new (window.AudioContext || window.webkitAudioContext)({ sampleRate: 44100 });
    tracks = [];
    const n = m.channels[0].length;
    duration = n / 44100;
    m.keys.forEach((key, i) => {
      const L = m.channels[i * 2], R = m.channels[i * 2 + 1];
      const buf = ctx.createBuffer(2, n, 44100);
      buf.copyToChannel(L, 0); buf.copyToChannel(R, 1);
      tracks.push({ key, buf, L, R, gain: null });
    });
    tracks.sort((a, b) => ORDER.indexOf(a.key) - ORDER.indexOf(b.key));
    state.muted.clear(); state.solo.clear(); offset = 0;
    $("title").textContent = songName;
    $("took").textContent = `Separata in ${fmt(m.seconds)} · ${m.backend === "webgpu" ? "scheda grafica" : "processore"} · tutto nel tuo browser`;
    renderStems();
    setPreset("all");
    show("results");
    tick();
  }

  function renderStems() {
    const box = $("stems");
    box.textContent = "";
    for (const t of tracks) {
      const row = document.createElement("div");
      row.className = "stem";
      const color = `var(${COLORS[t.key]})`;
      const mixable = t.key !== "instrumental";
      row.innerHTML = `<span class="badge" style="--c:${color}" aria-hidden="true"></span><b>${NAMES[t.key]}</b>` +
        (mixable ? `<button class="ms m" aria-pressed="false" title="Muto">M</button><button class="ms s" aria-pressed="false" title="Solo">S</button>`
                 : `<span></span><span></span>`) +
        `<canvas aria-hidden="true"></canvas><button class="btn ghost small">WAV</button>`;
      const [m, s] = row.querySelectorAll(".ms");
      if (m) {
        m.onclick = () => { toggle(state.muted, t.key); m.setAttribute("aria-pressed", state.muted.has(t.key)); applyGains(); syncPreset(); };
        s.onclick = () => { toggle(state.solo, t.key); s.setAttribute("aria-pressed", state.solo.has(t.key)); applyGains(); syncPreset(); };
      }
      row.querySelector(".btn").onclick = () => save(t);
      const canvas = row.querySelector("canvas");
      canvas.onclick = (e) => { const r = canvas.getBoundingClientRect(); seek(((e.clientX - r.left) / r.width) * duration); };
      t.canvas = canvas; t.color = color; t.row = row; t.peaks = peaks(t.L, t.R);
      box.appendChild(row);
    }
    drawAll();
  }

  function toggle(set, k) { set.has(k) ? set.delete(k) : set.add(k); }

  function peaks(L, R, count = 360) {
    const out = new Float32Array(count), n = L.length;
    for (let b = 0; b < count; b++) {
      let m = 0;
      const lo = Math.floor((b * n) / count), hi = Math.floor(((b + 1) * n) / count), step = Math.max(1, Math.floor((hi - lo) / 200));
      for (let i = lo; i < hi; i += step) m = Math.max(m, Math.abs((L[i] + R[i]) / 2));
      out[b] = Math.min(1, m);
    }
    return out;
  }

  function drawAll() {
    const pos = position();
    for (const t of tracks) {
      const c = t.canvas, dpr = window.devicePixelRatio || 1, w = c.clientWidth, h = c.clientHeight;
      if (!w) continue;
      if (c.width !== w * dpr) { c.width = w * dpr; c.height = h * dpr; }
      const g = c.getContext("2d");
      g.setTransform(dpr, 0, 0, dpr, 0, 0);
      g.clearRect(0, 0, w, h);
      const color = getComputedStyle(document.documentElement).getPropertyValue(COLORS[t.key]).trim();
      const audible = t.key === "instrumental" || gainOf(t.key) > 0;
      const slots = Math.floor(w / 3), p = duration ? pos / duration : 0;
      for (let s = 0; s < slots; s++) {
        const v = t.peaks[Math.floor((s * t.peaks.length) / slots)];
        const bh = Math.max(1.5, Math.sqrt(v) * h * 0.92);
        g.globalAlpha = !audible ? 0.25 : (playing || pos > 0.05) && s / slots >= p ? 0.4 : 1;
        g.fillStyle = color;
        g.fillRect(s * 3, (h - bh) / 2, 2, bh);
      }
      if (playing || pos > 0.05) { g.globalAlpha = 0.9; g.fillStyle = getComputedStyle(document.body).color; g.fillRect(p * w - 1, 0, 2, h); }
    }
  }

  function position() { return playing ? Math.min(duration, offset + (ctx.currentTime - startAt)) : offset; }

  function play(from) {
    stopSources();
    if (ctx.state === "suspended") ctx.resume();
    offset = Math.max(0, Math.min(from, duration));
    startAt = ctx.currentTime + 0.05;
    sources = tracks.filter((t) => t.key !== "instrumental").map((t) => {
      const src = ctx.createBufferSource(), gain = ctx.createGain();
      src.buffer = t.buf; gain.gain.value = gainOf(t.key);
      src.connect(gain).connect(ctx.destination);
      src.start(startAt, offset);
      t.gain = gain;
      return src;
    });
    playing = true;
    $("play").textContent = "❚❚"; $("play").setAttribute("aria-label", "Pausa");
  }
  function pause() { offset = position(); stopSources(); playing = false; $("play").textContent = "▶"; $("play").setAttribute("aria-label", "Suona"); }
  function stop() { stopSources(); playing = false; offset = 0; cancelAnimationFrame(raf); if ($("play")) $("play").textContent = "▶"; }
  function stopSources() { for (const s of sources) { try { s.stop(); } catch {} } sources = []; }
  function seek(t) { playing ? play(t) : (offset = t, drawAll(), clock()); }
  function applyGains() { for (const t of tracks) if (t.gain) t.gain.gain.setTargetAtTime(gainOf(t.key), ctx.currentTime, 0.015); drawAll(); }
  function clock() { $("clock").textContent = `${fmt(position())} / ${fmt(duration)}`; }
  function tick() {
    if (playing && position() >= duration - 0.02) pause(), offset = 0;
    clock(); drawAll();
    raf = requestAnimationFrame(tick);
  }

  $("play").addEventListener("click", () => (playing ? pause() : play(offset >= duration - 0.05 ? 0 : offset)));
  document.addEventListener("keydown", (e) => {
    if (e.code === "Space" && !$("results").hidden && !/INPUT|TEXTAREA|BUTTON/.test(document.activeElement.tagName)) { e.preventDefault(); $("play").click(); }
  });

  // Scorciatoie: Tutto, Karaoke, Solo voce
  function setPreset(p) {
    state.muted.clear(); state.solo.clear();
    if (p === "karaoke") state.muted.add("vocals");
    if (p === "voice") state.solo.add("vocals");
    for (const t of tracks) {
      const [m, s] = t.row.querySelectorAll(".ms");
      if (m) { m.setAttribute("aria-pressed", state.muted.has(t.key)); s.setAttribute("aria-pressed", state.solo.has(t.key)); }
    }
    applyGains(); syncPreset();
  }
  function syncPreset() {
    const p = !state.muted.size && !state.solo.size ? "all"
      : state.muted.size === 1 && state.muted.has("vocals") && !state.solo.size ? "karaoke"
      : state.solo.size === 1 && state.solo.has("vocals") && !state.muted.size ? "voice" : "";
    document.querySelectorAll("[data-preset]").forEach((b) => b.setAttribute("aria-pressed", b.dataset.preset === p));
  }
  document.querySelectorAll("[data-preset]").forEach((b) => b.addEventListener("click", () => setPreset(b.dataset.preset)));

  // Il file WAV si crea qui e si salva dal browser: nessun server
  function save(t) {
    const blob = new Blob([AudioLREngine.wav24([t.L, t.R])], { type: "audio/wav" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = `${songName} – ${NAMES[t.key]}.wav`;
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 4000);
  }

  // Per i WAV nella pagina serve anche il motore (solo la parte che scrive i file)
  const s = document.createElement("script"); s.src = "app/engine-core.js"; document.head.appendChild(s);
})();
