// «Testo», come Sources/LyricsView.swift sul Mac: le parole della voce a tempo con il mixer (Ctrl+Alt+L,
// «Vai più a fondo» › «Testo»). Si trascrive una volta con Whisper (js/lyrics-worker.js, tutto sul computer),
// poi la riga in corso si illumina e la parola cantata diventa d'oro; un clic su una riga salta lì e la
// riga si corregge (testo, −0,1 s / +0,1 s). Esporta .lrc e .srt; «Video karaoke…» (js/video.js).
// Le regole sono in core/lyrics.js; il testo si salva come «isolr-testo.json» accanto alle tracce.
/* global Bridge, Encode, IsoLR, IsoApp, Icon, IconFill, Prefs, KaraokeVideo */
(function () {
  "use strict";
  const L = IsoLR.Lyrics, RATE = 44100;
  const esc = (s) => IsoApp.esc(s), fmt = (t) => IsoApp.fmt(t);
  const LANGS = [["", "Automatica"], ["it", "Italiano"], ["en", "Inglese"], ["es", "Spagnolo"], ["fr", "Francese"], ["de", "Tedesco"], ["pt", "Portoghese"]];
  const MODELS = ["WhisperEncoder", "WhisperDecoder"];
  const cache = new Map();                      // cartella → testo (per «Esercitati»)

  async function load(folder) {
    if (cache.has(folder)) return cache.get(folder);
    let lyr = null;
    try { if (await Bridge.exists(folder + "/" + L.FILE)) lyr = JSON.parse(await Bridge.readText(folder + "/" + L.FILE)); } catch { lyr = null; }
    cache.set(folder, lyr);
    return lyr;
  }
  async function save(folder, lyr) {
    cache.set(folder, lyr);
    await Bridge.writeText(folder + "/" + L.FILE, JSON.stringify(lyr, null, 2));
  }

  /** I file del modello che il lavoratore chiede (nomi di Transformers.js → modelli scaricati di IsoLR). */
  async function modelFile(path, parts) {
    const json = async (name) => { if (!parts[name]) parts[name] = JSON.parse(new TextDecoder().decode(await Bridge.readModel(name, "json"))); return parts[name]; };
    const bytes = async (name) => { const b = await Bridge.readModel(name, "onnx"); return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength); };
    const text = (obj) => new TextEncoder().encode(JSON.stringify(obj)).buffer;
    if (path === "onnx/encoder_model.onnx") return bytes("WhisperEncoder");
    if (path === "onnx/decoder_model_merged_q4.onnx") return bytes("WhisperDecoder");
    const enc = { "config.json": "config", "generation_config.json": "generation_config", "preprocessor_config.json": "preprocessor_config" };
    const dec = { "tokenizer.json": "tokenizer", "tokenizer_config.json": "tokenizer_config" };
    if (enc[path]) return text((await json("WhisperEncoder"))[enc[path]]);
    if (dec[path]) return text((await json("WhisperDecoder"))[dec[path]]);
    return null;
  }

  /** La voce come Whisper la vuole: mono a 16 kHz. */
  async function mono16k(ch) {
    const n = ch[0].length, src = new OfflineAudioContext(1, Math.ceil((n * 16000) / RATE), 16000);
    const buf = src.createBuffer(ch.length, n, RATE);
    ch.forEach((c, i) => buf.copyToChannel(c, i));
    const node = src.createBufferSource(); node.buffer = buf; node.connect(src.destination); node.start();
    return (await src.startRendering()).getChannelData(0);
  }

  /** Trascrive la voce: { language, words }. `step(testo, avanzamento|null)` per la barra. */
  async function transcribe(voiceCh, language, step) {
    for (const m of MODELS) {
      step("Scarico il modello del testo (solo la prima volta)…", 0);
      await Bridge.prepareModel(m, (p) => step(`Scarico il modello del testo (solo la prima volta)… ${Math.round(p * 100)}%`, p));
    }
    step("Preparo la voce…", null);
    const audio = await mono16k(voiceCh);
    const w = new Worker("js/lyrics-worker.js", { type: "module" });
    const parts = {};
    try {
      return await new Promise((resolve, reject) => {
        w.onerror = (e) => reject(new Error(e.message || "il lavoro del testo si è interrotto"));
        w.onmessage = async (e) => {
          const m = e.data;
          if (m.type === "file") {
            let b = null;
            try { b = await modelFile(m.path, parts); } catch { b = null; }
            w.postMessage({ type: "file", id: m.id, bytes: b }, b ? [b] : []);
          } else if (m.type === "progress") step(m.step, null);
          else if (m.type === "done") resolve({ language: language || null, words: L.clean(m.words), device: m.device });
          else if (m.type === "error") reject(new Error(m.message));
        };
        w.postMessage({ type: "transcribe", audio, language: language || null, webgpu: "gpu" in navigator && !Prefs.get("forceCpu", false) }, [audio.buffer]);
      });
    } finally { w.terminate(); }
  }

  function open(cur, player) {
    if (!cur) return;
    player.pause();
    const voice = cur.meta.stems.find((s) => s.key === "vocals") || cur.meta.stems.find((s) => s.key === "lead");
    let lyr = null, sel = -1, raf = 0, busy = false;
    const html = `<div class="ed-head"><div><h2>Testo</h2><div class="muted">${esc(cur.meta.title)}</div></div><div class="grow"></div>
        <select class="pop" id="l-lang" aria-label="Lingua del testo" title="La lingua del testo: «Automatica» la riconosce da sola">${LANGS.map(([c, n]) => `<option value="${c}" ${Prefs.get("lyricsLanguage", "") === c ? "selected" : ""}>${n}</option>`).join("")}</select>
        <button class="btn" data-l="go" ${voice ? "" : "disabled"} title="Trascrive la voce separata con Whisper, tutto sul computer (la prima volta scarica il modello, circa 500 MB)">${Icon("mic")}<span id="l-go">Trascrivi la voce</span></button></div>
      <div class="lyr-list" id="l-list"></div>
      <div class="ed-bar" id="l-edit" hidden>
        <input type="text" id="l-text" aria-label="Testo della riga" style="flex:1">
        <button class="btn small" data-l="apply">Applica</button>
        <button class="btn small" data-l="earlier" title="La riga arriva prima">−0,1 s</button>
        <button class="btn small" data-l="later" title="La riga arriva dopo">+0,1 s</button>
      </div>
      <div class="ed-foot">
        <button class="btn" data-l="play">${Icon("play")}<span id="l-play">Ascolta</span></button>
        <span id="l-status" class="muted"></span>
        <div class="grow"></div>
        <button class="btn" data-l="lrc" title="Il testo con i tempi delle righe, per i lettori musicali e i karaoke">Esporta .lrc</button>
        <button class="btn" data-l="srt" title="Il testo come sottotitoli, per i programmi video">Esporta .srt</button>
        <button class="btn" data-l="video" title="Un video con la base e il testo che si illumina, per YouTube o Instagram">Video karaoke…</button>
        <button class="btn" data-close>Chiudi</button>
      </div>`;

    window.Sheets.open(html, async (sheet, close) => {
      sheet.classList.add("wide");
      const $ = (q) => sheet.querySelector(q);
      const list = $("#l-list");
      const status = (t) => { $("#l-status").textContent = t || ""; };
      const lines = () => (lyr ? L.lines(lyr.words) : []);

      function render() {
        const ls = lines();
        $("#l-go").textContent = lyr ? "Rifai" : "Trascrivi la voce";
        for (const k of ["lrc", "srt", "video"]) sheet.querySelector(`[data-l="${k}"]`).disabled = !ls.length;
        if (!ls.length) {
          list.innerHTML = `<div class="lyr-empty">${Icon("note")}<b>${voice ? "Il testo non c'è ancora." : "Questa canzone non ha la traccia della voce."}</b>
            <span class="muted">«Trascrivi la voce» ascolta la voce separata e scrive il testo, parola per parola, con i tempi.</span></div>`;
          return;
        }
        list.innerHTML = ls.map((l, i) => `<button class="lyr-line ${i === sel ? "sel" : ""}" data-i="${i}"><span class="lyr-t">${fmt(l.start)}</span><span class="lyr-w">${
          lyr.words.slice(l.from, l.to).map((w, k) => `<span data-w="${l.from + k}">${esc(w.text.trim())}</span>`).join(" ")}</span></button>`).join("");
        $("#l-edit").hidden = sel < 0;
      }

      // La riga e la parola sotto la testina, a ogni fotogramma
      let lastLine = -1, lastWord = -1;
      function tick() {
        raf = requestAnimationFrame(tick);
        $("#l-play").textContent = player.playing ? "Pausa" : "Ascolta";
        if (!lyr) return;
        const now = L.current(lines(), lyr.words, player.position);
        const line = now ? now.line : -1, word = now && now.word != null ? now.word : -1;
        if (line === lastLine && word === lastWord) return;
        list.querySelectorAll(".lyr-line.now").forEach((e) => e.classList.remove("now"));
        list.querySelectorAll(".lyr-w .sung").forEach((e) => e.classList.remove("sung"));
        const el = line >= 0 && list.querySelector(`[data-i="${line}"]`);
        if (el) { el.classList.add("now"); if (line !== lastLine && player.playing) el.scrollIntoView({ block: "center", behavior: "smooth" }); }
        const we = word >= 0 && list.querySelector(`[data-w="${word}"]`);
        if (we) we.classList.add("sung");
        lastLine = line; lastWord = word;
      }

      async function store() { lyr.edited = true; await save(cur.folder, lyr); lastLine = -1; render(); }

      sheet.addEventListener("click", async (e) => {
        const line = e.target.closest(".lyr-line");
        if (line) {
          sel = +line.dataset.i;
          const l = lines()[sel];
          $("#l-text").value = l.text;
          if (player.duration) player.seek(l.start / player.duration);
          lastLine = -1; render();
          return;
        }
        const b = e.target.closest("[data-l]");
        if (!b) return;
        const act = b.dataset.l, l = sel >= 0 ? lines()[sel] : null;
        if (act === "play") player.toggle();
        else if (act === "apply" && l) { lyr.words = L.rewrite(lyr.words, l, $("#l-text").value); await store(); }
        else if (act === "earlier" && l) { lyr.words = L.shift(lyr.words, l, -0.1); await store(); }
        else if (act === "later" && l) { lyr.words = L.shift(lyr.words, l, 0.1); await store(); }
        else if (act === "lrc" || act === "srt") {
          const text = act === "lrc" ? L.lrc(lines(), cur.meta.title) : L.srt(lines());
          const path = await Bridge.askFile(`${cur.meta.title}.${act}`, act);
          if (path) { await Bridge.writeText(path, text); status(`Salvato: ${path.split(/[\\/]/).pop()}`); }
        } else if (act === "video") videoSheet(cur, lyr);
        else if (act === "go" && !busy && voice) {
          busy = true; b.disabled = true;
          const lang = $("#l-lang").value;
          Prefs.set("lyricsLanguage", lang);
          try {
            const ch = Encode.readWav(await Bridge.readFile(cur.folder + "/" + voice.file));
            const res = await transcribe(ch, lang, (t, p) => status(p != null ? `${t}` : t));
            lyr = { version: 1, language: res.language, words: res.words, edited: false };
            await save(cur.folder, lyr);
            status(res.words.length ? `${res.words.length} parole · ${res.device === "webgpu" ? "scheda grafica" : "processore"}` : "Nessuna parola trovata nella voce");
            sel = -1; render();
          } catch (err) { status("Non riuscito: " + (err.message || err)); }
          busy = false; b.disabled = false;
        }
      });
      $("#l-text").addEventListener("keydown", (e) => { if (e.key === "Enter") sheet.querySelector('[data-l="apply"]').click(); });

      lyr = await load(cur.folder);
      render();
      tick();
      const obs = new MutationObserver(() => { if (!document.body.contains(sheet)) { cancelAnimationFrame(raf); obs.disconnect(); } });
      obs.observe(document.body, { childList: true, subtree: true });
    });
  }

  /** «Video karaoke…»: formato, voce bassa sì/no, crea. */
  function videoSheet(cur, lyr) {
    const html = `<h2>Video karaoke</h2><div class="muted">La base e il testo che si illumina parola per parola, sullo sfondo dello Studio di notte.</div>
      <label class="setting"><span>Formato</span><select class="pop" id="v-shape">${Object.entries(IsoLR.Karaoke.SHAPES).map(([k, s]) => `<option value="${k}">${s.title}</option>`).join("")}</select></label>
      <label class="setting"><span>Voce bassa sotto la base<small>Per chi impara la canzone</small></span><input type="checkbox" id="v-voice"></label>
      <div class="bar" id="v-bar" hidden><i style="width:0%"></i></div>
      <div class="muted" id="v-status"></div>
      <div class="actions"><button class="btn" data-close>Chiudi</button><button class="btn prominent" id="v-go">Crea il video…</button></div>`;
    window.Sheets.open(html, (sheet) => {
      let stop = false, busy = false;
      const $ = (q) => sheet.querySelector(q);
      sheet.querySelector("[data-close]").addEventListener("click", () => { stop = true; });
      $("#v-go").addEventListener("click", async () => {
        if (busy) return;
        const base = cur.meta.stems.find((s) => s.key === "instrumental"), voice = cur.meta.stems.find((s) => s.key === "vocals");
        if (!base) { $("#v-status").textContent = "Serve la base (senza voce): attivala in Impostazioni › Tracce e separa di nuovo"; return; }
        const shape = $("#v-shape").value;
        const path = await Bridge.askFile(`${cur.meta.title} – Karaoke${shape === "portrait" ? " verticale" : ""}.mp4`, "mp4");
        if (!path) return;
        busy = true; $("#v-go").disabled = true; $("#v-bar").hidden = false;
        try {
          const audio = Encode.readWav(await Bridge.readFile(cur.folder + "/" + base.file));
          if ($("#v-voice").checked && voice) {
            const v = Encode.readWav(await Bridge.readFile(cur.folder + "/" + voice.file));
            for (let c = 0; c < 2; c++) for (let i = 0; i < audio[c].length && i < v[c].length; i++) audio[c][i] += v[c][i] * 0.25;
          }
          const mp4 = await KaraokeVideo.render({ lyrics: lyr, title: cur.meta.title, audio, shape,
            progress: (p) => { $("#v-bar i").style.width = `${Math.round(p * 100)}%`; $("#v-status").textContent = `Creo il video… ${Math.round(p * 100)}%`; },
            cancelled: () => stop });
          await Bridge.writeFile(path, mp4);
          $("#v-status").textContent = `Fatto: ${path.split(/[\\/]/).pop()}`;
          Bridge.reveal(path);
        } catch (err) { $("#v-status").textContent = String(err.message || err) === "annullato" ? "Annullato" : "Non riuscito: " + (err.message || err); }
        busy = false; $("#v-go").disabled = false;
      });
    });
  }

  /** In «Esercitati»: la riga del testo che si canta adesso e la prossima (vuoto se la canzone non ha il testo). */
  function strip(lyr, t) {
    if (!lyr || !lyr.words || !lyr.words.length) return null;
    const ls = L.lines(lyr.words), now = L.current(ls, lyr.words, t);
    const next = now ? now.line + 1 : ls.findIndex((l) => l.start > t);
    return { line: now ? ls[now.line].text : "", next: next >= 0 && next < ls.length ? ls[next].text : "" };
  }

  window.LyricsUI = { open, load, save, strip, transcribe, cache };
})();
