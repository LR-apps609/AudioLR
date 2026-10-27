// Le finestre sopra la principale, come sul Mac: Impostazioni (SettingsView.swift), Dettagli della separazione,
// Come si usa (Help.swift), Cronologia (HistoryView.swift), il risultato del confronto (CompareView) e le note,
// lo spartito e la tablatura di una traccia (MIDI, MusicXML, tab).
/* global Bridge, Prefs, Encode, Separation, IsoApp, IsoLR */
(function () {
  "use strict";
  const $ = (s, r = document) => r.querySelector(s);
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

  function open(html, onReady) {
    const o = $("#overlay");
    o.innerHTML = `<div class="sheet-bg"><div class="sheet" role="dialog">${html}</div></div>`;
    const close = () => { o.innerHTML = ""; document.removeEventListener("keydown", esc_); };
    const esc_ = (e) => { if (e.key === "Escape") close(); };
    document.addEventListener("keydown", esc_);
    o.querySelector(".sheet-bg").addEventListener("click", (e) => { if (e.target.classList.contains("sheet-bg")) close(); });
    o.querySelectorAll("[data-close]").forEach((b) => b.addEventListener("click", close));
    if (onReady) onReady(o.querySelector(".sheet"), close);
    return close;
  }
  const toggle = (key, def, label, note) => `<label class="setting"><span>${label}${note ? `<small>${note}</small>` : ""}</span><input type="checkbox" data-pref="${key}" ${Prefs.get(key, def) ? "checked" : ""}></label>`;
  const pick = (key, def, label, options, note) => `<label class="setting"><span>${label}${note ? `<small>${note}</small>` : ""}</span><select class="pop" data-pref-select="${key}">${options.map(([v, t]) => `<option value="${v}" ${Prefs.get(key, def) === v ? "selected" : ""}>${t}</option>`).join("")}</select></label>`;

  // ── Impostazioni ──
  async function settings() {
    const version = await Bridge.version();
    const tabs = {
      generale: `${pick("appearance", "auto", "Aspetto", [["auto", "Automatico (come Windows)"], ["light", "Chiaro"], ["dark", "Scuro"]])}
        ${toggle("showLibrary", true, "Mostra la libreria a sinistra")}
        ${toggle("soundWhenDone", true, "Suono quando ha finito")}
        ${toggle("sleepAfterBatch", false, "Poi metti in stop il computer", "Dopo un album (più canzoni in coda), un minuto dopo l'ultima")}`,
      tracce: `${pick("quality", "best", "Qualità predefinita", [["fast", "Veloce"], ["best", "Massima"], ["studio", "Studio"]])}
        ${pick("outputFormat", "wav24", "Formato delle tracce", Object.entries(Encode.FORMATS).map(([k, f]) => [k, f.title]))}
        ${toggle("makeInstrumental", true, "Crea anche la base senza voce (karaoke)")}
        ${toggle("splitGuitarPiano", true, "Chitarra e pianoforte in tracce proprie (Massima e Studio)")}
        <label class="setting"><span>Sposta le registrazioni di <b id="ofs">${Prefs.get("recordOffsetMs", 0)}</b> ms<small>IsoLR toglie da solo il ritardo di microfono e altoparlanti. Se le registrazioni suonano un filo in anticipo, alza il numero; se in ritardo, abbassalo.</small></span>
          <input type="range" min="-300" max="300" step="5" value="${Prefs.get("recordOffsetMs", 0)}" data-pref-range="recordOffsetMs"></label>`,
      motore: `${toggle("forceCpu", false, "Usa solo il processore", "Se la scheda grafica dà problemi. Più lento.")}
        <div class="setting"><span>Modelli scaricati<small id="models">…</small></span></div>`,
      aggiornamenti: `<div class="setting"><span>Versione</span><b>${esc(version)}</b></div>
        <div class="setting"><span>IsoLR controlla da sola gli aggiornamenti ogni 3 ore. Quando ce n'è uno, in alto compare «Aggiornamento disponibile»: un clic e si installa.</span></div>
        <div class="actions"><button class="btn" data-check>Controlla adesso</button></div>`,
      informazioni: `<div style="display:flex;gap:12px;align-items:center"><img src="img/logo.png" width="48" height="48" style="border-radius:11px" alt="">
          <div><b style="font-size:18px">IsoLR</b><div class="muted">Versione ${esc(version)} · famiglia LR · Separa voce e strumenti, tutto sul tuo computer.</div></div></div>
        <table class="plain"><tr><th>Modello</th><th>Per</th><th>Licenza</th></tr>
          <tr><td>HTDemucs (Meta)</td><td>Veloce, Studio</td><td>MIT</td></tr>
          <tr><td>BS-RoFormer SW</td><td>Massima, Studio</td><td>MIT (codice)</td></tr>
          <tr><td>BS-RoFormer Revive (unwa)</td><td>Studio, voce</td><td>—</td></tr>
          <tr><td>Mel-Band RoFormer (Kim)</td><td>Studio, voce</td><td>MIT (codice)</td></tr>
          <tr><td>Mel-Band RoFormer karaoke (aufr33, viperx)</td><td>Voce e cori</td><td>MIT (codice)</td></tr>
          <tr><td>BS-RoFormer Chorus Male-Female (Sucial)</td><td>Voce maschile e femminile</td><td>MIT (codice)</td></tr>
          <tr><td>MDX23C DrumSep (aufr33, jarredou)</td><td>Batteria divisa</td><td>—</td></tr>
          <tr><td>Basic Pitch (Spotify)</td><td>Note MIDI</td><td>Apache 2.0</td></tr>
          <tr><td>Signalsmith Stretch</td><td>Velocità e tono</td><td>MIT</td></tr></table>
        <p class="muted">Le canzoni non lasciano mai il computer. Le tracce separate di brani altrui sono per uso personale: studio, pratica, karaoke.</p>`,
    };
    let current = "generale";
    open(`<h2>Impostazioni</h2><div class="tabs">${Object.keys(tabs).map((t) => `<button data-t="${t}" class="${t === current ? "on" : ""}">${t[0].toUpperCase() + t.slice(1)}</button>`).join("")}</div>
      <div id="tab"></div><div class="actions"><button class="btn prominent" data-close>Fatto</button></div>`, (sheet) => {
      const show = async (t) => {
        current = t;
        sheet.querySelectorAll(".tabs button").forEach((b) => b.classList.toggle("on", b.dataset.t === t));
        $("#tab", sheet).innerHTML = tabs[t];
        if (t === "motore") { const r = await Bridge.modelsReady(); $("#models", sheet).textContent = r.length ? r.join(", ") : "nessuno (si scaricano alla prima separazione)"; }
      };
      sheet.addEventListener("click", async (e) => {
        const b = e.target.closest("[data-t]"); if (b) show(b.dataset.t);
        if (e.target.closest("[data-check]")) { const u = await Bridge.checkUpdate(); IsoApp.ui.update = u; IsoApp.render(); IsoApp.toast(u ? `C'è la versione ${u.version}` : "Hai già l'ultima versione"); }
      });
      sheet.addEventListener("change", (e) => {
        const el = e.target;
        if (el.dataset.pref) { Prefs.set(el.dataset.pref, el.checked); if (el.dataset.pref === "showLibrary") { IsoApp.ui.showLibrary = el.checked; IsoApp.render(); } }
        if (el.dataset.prefSelect) { Prefs.set(el.dataset.prefSelect, el.value); if (el.dataset.prefSelect === "appearance") applyAppearance(); if (el.dataset.prefSelect === "quality") { IsoApp.ui.quality = el.value; IsoApp.render(); } }
      });
      sheet.addEventListener("input", (e) => { const el = e.target; if (el.dataset.prefRange) { Prefs.set(el.dataset.prefRange, +el.value); $("#ofs", sheet).textContent = el.value; } });
      show(current);
    });
  }
  function applyAppearance() {
    const a = Prefs.get("appearance", "auto");
    if (a === "auto") document.documentElement.removeAttribute("data-theme"); else document.documentElement.dataset.theme = a;
  }

  // ── Dettagli della separazione ──
  function details(cur) {
    const m = cur.meta, a = m.analysis || {};
    const key = a.keyRoot != null ? `${IsoApp.IT_NAMES[a.keyRoot]} ${a.minor ? "minore" : "maggiore"}` : "—";
    open(`<h2>Dettagli della separazione</h2>
      <table class="plain">
        <tr><td>Canzone</td><td>${esc(m.source || m.title)}</td></tr>
        <tr><td>Qualità</td><td>${esc(Separation.QUALITY[m.quality] ? Separation.QUALITY[m.quality].title : m.quality)}</td></tr>
        <tr><td>Durata</td><td>${IsoApp.fmt(m.duration)}</td></tr>
        <tr><td>Tempo impiegato</td><td>${m.took ? Math.round(m.took) + " s" : "—"}</td></tr>
        <tr><td>Motore</td><td>${esc(m.engine || "—")}</td></tr>
        <tr><td>Tempo</td><td>${a.bpm ? Math.round(a.bpm) + " BPM" : "—"}</td></tr>
        <tr><td>Tonalità</td><td>${key}</td></tr>
        <tr><td>Volume abbassato</td><td>${m.gainDB ? m.gainDB.toFixed(1) + " dB (perché nessuna traccia distorca)" : "no"}</td></tr>
        <tr><td>Cartella</td><td>${esc(cur.folder)}</td></tr>
      </table>
      <table class="plain"><tr><th>Traccia</th><th>Quota</th><th>Picco</th></tr>${m.stems.map((s) => `<tr><td>${esc(s.name)}</td><td>${s.share != null ? Math.round(s.share * 100) + "%" : "—"}</td><td>${s.peakDB != null ? s.peakDB + " dB" : "—"}</td></tr>`).join("")}</table>
      <div class="actions"><button class="btn prominent" data-close>Fatto</button></div>`);
  }

  // ── Come si usa ──
  function help() {
    open(`<h2>Come si usa IsoLR</h2>
      <ol style="margin:0;padding-left:20px;display:grid;gap:8px">
        <li><b>Trascina una canzone</b> nella finestra (o «Scegli un file»). Più canzoni insieme vanno in coda: un album intero, anche di notte.</li>
        <li><b>Scegli la qualità</b>: Veloce per provare, Massima per quasi tutto, Studio quando conta il massimo. Poi <b>Separa</b>.</li>
        <li><b>Ascolta e mescola</b>: volume, muto (altoparlante) e solo (cuffie) per traccia; Tutto, Karaoke, Solo voce; «Senza…» toglie uno strumento.</li>
        <li><b>Esercitati</b>: velocità e tono, ripetizione di un passaggio (A e B, o un clic su una parte della canzone), rampa, metronomo, conteggio, accordi, registrati sopra la base e confronta.</li>
        <li><b>Scarica</b> quello che ti serve dal riquadro a destra: una traccia, le spuntate, tutte, il mix che senti, il passaggio A–B, il file per DJ.</li>
      </ol>
      <table class="plain"><tr><th>Tasti</th><th></th></tr>
        <tr><td>Spazio</td><td>Suona / pausa</td></tr><tr><td>Ctrl+[ · Ctrl+]</td><td>Inizio e fine del passaggio (A e B)</td></tr><tr><td>Ctrl+O</td><td>Scegli una canzone</td></tr></table>
      <p class="muted">La prima volta Massima e Studio scaricano i loro modelli (una volta sola); poi IsoLR funziona anche senza internet. Le canzoni non lasciano mai il computer.</p>
      <div class="actions"><button class="btn prominent" data-close>Fatto</button></div>`);
  }

  // ── Segnala (come BugReportView in Help.swift) ──
  const KINDS = [["bug", "Qualcosa non funziona"], ["sound", "Problema di suono"], ["slow", "Troppo lenta"], ["idea", "Idea o richiesta"]];

  /** Versione, Windows, processori, memoria, scheda grafica, impostazioni, ultimo errore e ultimi passi. */
  async function systemInfo(job) {
    const ua = navigator.userAgentData;
    let win = "Windows";
    try { if (ua) { const h = await ua.getHighEntropyValues(["platformVersion"]); win = +h.platformVersion.split(".")[0] >= 13 ? "Windows 11" : "Windows 10"; } } catch (e) { /* resta «Windows» */ }
    let gpu = "nessuna (WebGPU assente)";
    try { const a = navigator.gpu && await navigator.gpu.requestAdapter(); if (a) { const i = a.info || {}; gpu = [i.vendor, i.architecture, i.description].filter(Boolean).join(" · ") || "presente"; } } catch (e) { /* resta com'è */ }
    const lines = [
      `IsoLR per Windows ${await Bridge.version()}`,
      win,
      `Processori: ${navigator.hardwareConcurrency || "?"} · memoria: ${navigator.deviceMemory ? "almeno " + navigator.deviceMemory + " GB" : "?"}`,
      `Scheda grafica: ${gpu}`,
      `Qualità: ${(Separation.QUALITY[Prefs.get("quality", "best")] || {}).title || "?"} · solo processore: ${Prefs.get("forceCpu", false) || job.cpu ? "sì" : "no"}`,
    ];
    if (job.current && job.current.meta) lines.push(`Ultima canzone: ${job.current.meta.engine || job.current.meta.backend || "?"} · ${IsoApp.fmt(job.current.meta.duration || 0)}`);
    if (job.error) lines.push(`Ultimo errore: ${job.error}`);
    if (Separation.Job.lines.length) lines.push("Registro (ultimi passi):\n" + Separation.Job.lines.slice(-20).join("\n"));
    return lines.join("\n");
  }

  async function report(job) {
    const system = await systemInfo(job);
    open(`<div style="display:flex;gap:12px;align-items:center"><span class="bug-badge">${Icon("bug")}</span>
        <div><h2>Segnala un problema</h2><div class="muted">Più dettagli dai, più in fretta si sistema</div></div></div>
      <label class="setting"><span>Tipo</span><select class="pop" id="r-kind">${KINDS.map(([k, t]) => `<option value="${k}">${t}</option>`).join("")}</select></label>
      <label class="field"><span>Cosa è successo</span><textarea id="r-sum" rows="3" placeholder="Es. la voce si sente nella batteria">${job.error ? esc("Si è fermata con: " + job.error) : ""}</textarea></label>
      <label class="field"><span>Come rifarlo</span><textarea id="r-steps" rows="3" placeholder="Es. Studio, canzone MP3 di 3 min, al minuto 1:20"></textarea></label>
      <label class="setting"><span>Includi le informazioni del computer<small>Nessuna canzone, nessun nome di file personale: solo versione, computer e impostazioni.</small></span><input type="checkbox" id="r-sys" checked></label>
      <pre class="sysinfo" id="r-info">${esc(system)}</pre>
      <div class="actions"><button class="btn" id="r-copy">Copia il rapporto</button><span style="flex:1"></span><button class="btn" data-close>Annulla</button><button class="btn prominent" id="r-send">Invia su GitHub…</button></div>`, (sheet, close) => {
      const v = (id) => sheet.querySelector(id);
      const kindTitle = () => KINDS.find(([k]) => k === v("#r-kind").value)[1];
      const title = () => { const s = v("#r-sum").value.trim(); return `[${kindTitle()}] ` + (s ? s.slice(0, 80) : "senza titolo"); };
      const body = () => `### Cosa è successo\n${v("#r-sum").value.trim() || "—"}\n\n### Come rifarlo\n${v("#r-steps").value.trim() || "—"}\n`
        + (v("#r-sys").checked ? `\n### Il computer\n\`\`\`\n${system}\n\`\`\`\n` : "");
      const ready = () => { v("#r-send").disabled = !v("#r-sum").value.trim(); v("#r-info").hidden = !v("#r-sys").checked; };
      sheet.addEventListener("input", ready); ready();
      v("#r-copy").addEventListener("click", async () => {
        try { await navigator.clipboard.writeText(title() + "\n\n" + body()); v("#r-copy").textContent = "Copiato"; } catch (e) { v("#r-copy").textContent = "Copia non riuscita"; }
      });
      v("#r-send").addEventListener("click", async () => {
        const q = new URLSearchParams({ title: title(), body: body().slice(0, 6000), labels: v("#r-kind").value === "idea" ? "enhancement" : "bug" });
        await Bridge.openReport("https://github.com/LR-apps609/AudioLR/issues/new?" + q.toString());
        close();
      });
    });
  }

  // ── Cronologia ──
  function history(list, openEntry) {
    open(`<h2>Cronologia</h2>
      ${list.length ? `<table class="plain"><tr><th>Canzone</th><th>Qualità</th><th>Durata</th><th>BPM · tonalità</th><th>Data</th></tr>
        ${list.map((e, i) => { const a = e.meta.analysis || {}; return `<tr data-h="${i}" style="cursor:pointer"><td>${esc(e.meta.title)}</td><td>${esc(Separation.QUALITY[e.meta.quality] ? Separation.QUALITY[e.meta.quality].title : "")}</td><td>${IsoApp.fmt(e.meta.duration)}</td><td>${a.bpm ? Math.round(a.bpm) + " BPM · " + IsoApp.KEY_NAMES[a.keyRoot] + (a.minor ? "m" : "") : "—"}</td><td>${new Date(e.meta.created).toLocaleDateString("it-IT")}</td></tr>`; }).join("")}</table>`
        : `<p class="muted">Ancora nessuna canzone separata.</p>`}
      <div class="actions"><button class="btn prominent" data-close>Fatto</button></div>`, (sheet, close) => {
      sheet.addEventListener("click", (e) => { const r = e.target.closest("[data-h]"); if (r) { close(); openEntry(list[+r.dataset.h]); } });
    });
  }

  // ── Confronto con l'originale ──
  async function compare(cur, takePath, key) {
    const stem = cur.meta.stems.find((s) => s.key === key);
    const mono = (ch) => { const o = new Float32Array(ch[0].length); for (let i = 0; i < o.length; i++) o[i] = (ch[0][i] + ch[1][i]) / 2; return o; };
    const take = mono(Encode.readWav(await Bridge.readFile(takePath))), orig = mono(Encode.readWav(await Bridge.readFile(cur.folder + "/" + stem.file)));
    let r;
    try { r = IsoLR.Compare.run(take, orig); } catch (e) {
      throw new Error(e.code === "silent" ? "Nella registrazione o nella traccia scelta non c'è abbastanza suono da confrontare." : e.message || String(e));
    }
    const cents = Math.abs(r.cents) < 10 ? ["Centrata", "in media sei sulla nota giusta"] : [`${Math.round(Math.abs(r.cents))} cent ${r.cents > 0 ? "crescente" : "calante"}`, r.cents > 0 ? "in media un filo sopra la nota" : "in media un filo sotto la nota"];
    const time = Math.abs(r.offsetMs) < 15 ? ["A tempo", "gli attacchi combaciano"] : [`${Math.round(Math.abs(r.offsetMs))} ms ${r.offsetMs > 0 ? "in ritardo" : "in anticipo"}`, "gli attacchi in media rispetto all'originale"];
    open(`<div style="display:flex;align-items:baseline;gap:8px"><span style="font:700 26px var(--font-display);color:var(--brass)">${esc(r.verdict)}</span><span style="font-size:15px;font-weight:500">· ${Math.round(r.inTune * 100)}% intonato rispetto a «${esc(stem.name)}»</span></div>
      <div class="facts"><div><small>Intonazione</small><b>${cents[0]}</b><span>${cents[1]}</span></div><div><small>Tempo</small><b>${time[0]}</b><span>${time[1]}</span></div><div><small>Confrontati</small><b>${Math.round(r.seconds)} s</b><span>da ${IsoApp.fmt(r.start)} a ${IsoApp.fmt(r.end)}</span></div></div>
      <canvas class="pitch" id="pitch"></canvas>
      <div style="display:flex;gap:16px;align-items:center;font-size:11px"><span><i style="display:inline-block;width:14px;height:3px;background:var(--brass);vertical-align:middle"></i> Originale</span><span><i style="display:inline-block;width:14px;height:3px;background:var(--red);vertical-align:middle"></i> Tu</span><span class="faint">Un'ottava sopra o sotto conta come la stessa nota</span><div class="grow"></div><button class="btn prominent" data-close>Fatto</button></div>`, (sheet) => {
      const c = $("#pitch", sheet), g = c.getContext("2d"), cs = getComputedStyle(document.documentElement);
      const w = (c.width = c.clientWidth * devicePixelRatio), h = (c.height = c.clientHeight * devicePixelRatio);
      const all = [...r.original, ...r.mine].filter((v) => v != null);
      if (!all.length) return;
      const lo = Math.min(...all) - 2, hi = Math.max(Math.min(...all) + 12, Math.max(...all) + 2), n = r.original.length;
      const X = (i) => 10 + ((w - 20) * i) / Math.max(1, n - 1), Y = (m) => h - 10 - ((h - 20) * (m - lo)) / (hi - lo);
      for (let m = Math.ceil(lo); m <= hi; m++) { g.fillStyle = m % 12 === 0 ? "rgba(128,128,128,.25)" : "rgba(128,128,128,.08)"; g.fillRect(10, Y(m), w - 20, 1); }
      const line = (v, color, follow) => {
        g.strokeStyle = color; g.lineWidth = 2 * devicePixelRatio; g.beginPath(); let open_ = false;
        v.forEach((m, i) => { if (m == null) { open_ = false; return; } let y = m; if (follow && r.original[i] != null) y -= 12 * Math.round((m - r.original[i]) / 12); if (open_) g.lineTo(X(i), Y(y)); else { g.moveTo(X(i), Y(y)); open_ = true; } });
        g.stroke();
      };
      line(r.original, cs.getPropertyValue("--brass").trim(), false);
      line(r.mine, cs.getPropertyValue("--red").trim(), true);
    });
  }

  // ── Note, spartito e tab ──
  async function notes(cur, key, busy, shift = 0) {
    busy(key);
    try {
      const { Midi, Sheet } = IsoLR;
      const stem = cur.meta.stems.find((s) => s.key === key);
      const ch = Encode.readWav(await Bridge.readFile(cur.folder + "/" + stem.file));
      // Basic Pitch nel lavoratore; con il Transpose le note si spostano di tanti semitoni
      const list = (await IsoApp.job.transcribe(ch)).map((n) => ({ ...n, pitch: Math.max(0, Math.min(127, n.pitch + shift)) }));
      const a = cur.meta.analysis || {}, bpm = a.bpm || 120, name = `${cur.meta.title} – ${stem.name}${Transpose.suffix(shift)}`;
      const files = [];
      const mid = `${cur.folder}/${name}.mid`;
      await Bridge.writeFile(mid, Midi.data(list, { bpm, program: Midi.program(key), name }));
      files.push(mid);
      // Spartito (MusicXML) sulle battute vere della canzone; per chitarra e basso anche la tablatura
      const kind = Sheet.MusicXML.kind(key, list);
      const score = Sheet.Score.build(list, { structure: a.structure || null, bpm, keyRoot: (((a.keyRoot || 0) + shift) % 12 + 12) % 12, minor: !!a.minor,
        monophonic: ["bass", "vocals", "lead", "male", "female"].includes(key) });
      if (score.bars.length) {
        const xml = `${cur.folder}/${name}.musicxml`;
        await Bridge.writeText(xml, Sheet.MusicXML.data(score, kind, name, stem.name, Midi.program(key)));
        files.push(xml);
        const tuning = Sheet.MusicXML.tuning(kind);
        if (tuning) { const tab = `${cur.folder}/${name} (tab).txt`; await Bridge.writeText(tab, Sheet.Tab.text(score, tuning, name)); files.push(tab); }
      }
      Bridge.reveal(files[files.length > 1 ? 1 : 0]);
    } catch (e) { IsoApp.toast("Note non riuscite: " + (e.message || e)); }
    busy(null);
  }

  // ── Transpose: tonalità, − e +, porta alla mia voce, capotasto ──
  async function transpose(cur, player, by) {
    const a = cur.meta.analysis || {}, has = a.keyRoot != null;
    let range = null;
    const draw = (sheet) => {
      const s = player.semitones, my = Prefs.get("myTopNote", 0);
      const c = Transpose.capo(a.chords, s);
      const sug = range && my ? Transpose.suggest(range.high, my) : null;
      sheet.querySelector("#tp").innerHTML = `
        <div class="label">Tonalità</div>
        ${has ? `<div style="display:flex;gap:8px;align-items:baseline"><span style="font-size:15px;${s ? "color:var(--muted)" : "font-weight:600"}">${Transpose.keyName(a.keyRoot, a.minor, 0)}</span>
          ${s ? `<span class="muted">→</span><b style="font:700 18px var(--font-display);color:var(--brass)">${Transpose.keyName(a.keyRoot, a.minor, s)}</b>` : ""}</div>`
          : `<div class="muted">Tonalità non misurata</div>`}
        <div class="form-line"><button class="btn icon" data-tp="-1" ${s <= Transpose.RANGE[0] ? "disabled" : ""}>−</button>
          <b style="min-width:110px;text-align:center">${s ? Transpose.label(s) + " semitoni" : "Originale"}</b>
          <button class="btn icon" data-tp="1" ${s >= Transpose.RANGE[1] ? "disabled" : ""}>+</button><div class="grow"></div>
          <button class="btn" data-tp="0" ${s ? "" : "disabled"}>Originale</button></div>
        <p class="muted" style="margin:0">Cambia solo il tono: la velocità resta quella. Anche i file scaricati e gli accordi seguono la tonalità scelta.</p>
        <hr style="border:0;border-top:1px solid var(--stroke);width:100%">
        <b>Per chi canta</b>
        ${range ? `<span class="muted">La voce della canzone va da ${Transpose.noteName(Math.round(range.low))} a ${Transpose.noteName(Math.round(range.high))}</span>
          <div class="form-line"><select class="pop" id="mytop"><option value="0">La tua nota più alta comoda…</option>${Array.from({ length: 37 }, (_, i) => 84 - i).map((m) => `<option value="${m}" ${m === my ? "selected" : ""}>${Transpose.noteName(m)}</option>`).join("")}</select>
          ${sug != null ? `<button class="btn prominent" data-tp-set="${sug}" ${sug === s ? "disabled" : ""}>${sug === 0 ? "È già giusta" : "Porta alla mia voce (" + Transpose.label(sug) + ")"}</button>` : ""}</div>
          <span class="faint" style="font-size:11px">Do4 è il Do centrale. Una voce maschile arriva in genere a Sol4–La4, una femminile a Do5–Mi5.</span>`
          : `<span class="muted">${range === null ? "Misuro la voce…" : "Serve la traccia della voce con abbastanza canto"}</span>`}
        ${c ? `<hr style="border:0;border-top:1px solid var(--stroke);width:100%"><b>Per la chitarra</b><span>Capotasto al ${c.capo}° tasto: suoni le forme di ${c.shapes.join(" · ")}</span>` : ""}`;
    };
    open(`<h2>Transpose</h2><div id="tp" style="display:grid;gap:10px"></div><div class="actions"><button class="btn prominent" data-close>Fatto</button></div>`, async (sheet) => {
      sheet.style.width = "min(440px, 92vw)";
      draw(sheet);
      sheet.addEventListener("click", (e) => {
        const b = e.target.closest("[data-tp],[data-tp-set]"); if (!b) return;
        if (b.dataset.tpSet != null) by(+b.dataset.tpSet - player.semitones);
        else if (+b.dataset.tp === 0) by(-player.semitones); else by(+b.dataset.tp);
        draw(sheet);
      });
      sheet.addEventListener("change", (e) => { if (e.target.id === "mytop") { Prefs.set("myTopNote", +e.target.value); draw(sheet); } });
      // L'estensione della voce, misurata adesso (qualche secondo)
      const v = cur.meta.stems.find((x) => x.key === "vocals") || cur.meta.stems.find((x) => x.key === "lead");
      if (v) {
        const ch = Encode.readWav(await Bridge.readFile(cur.folder + "/" + v.file));
        const mono = new Float32Array(ch[0].length); for (let i = 0; i < mono.length; i++) mono[i] = (ch[0][i] + ch[1][i]) / 2;
        range = Transpose.vocalRange(mono) || false;
      } else range = false;
      if (sheet.isConnected) draw(sheet);
    });
  }

  window.Sheets = { settings, details, help, report, history, compare, notes, transpose, applyAppearance };
  applyAppearance();
})();
