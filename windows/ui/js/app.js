// IsoLR per Windows: la finestra, disposta come l'app per Mac (ContentView.swift, Library.swift).
// A sinistra le canzoni; in alto il nome, l'aggiornamento, Aiuto e Impostazioni; al centro: trascina una
// canzone → scegli la qualità → Separa → il mixer con le tracce, «Esercitati» e il riquadro «Scarica».
/* global Bridge, Prefs, Encode, Separation, MixPlayer, Icon, IconFill, Recorder, IsoChords, IsoCompare, IsoSheet */
(function () {
  "use strict";
  const $ = (s, r = document) => r.querySelector(s);
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  const fmt = (t) => { t = Math.max(0, t || 0); const m = Math.floor(t / 60), s = Math.floor(t % 60); return `${m}:${String(s).padStart(2, "0")}`; };
  const ICON = { vocals: "mic", lead: "mic", backing: "people", male: "user", female: "user", drums: "drum", kick: "drum", snare: "drum", toms: "drum", hh: "sparkle", ride: "drum", crash: "sparkle", bass: "bass", guitar: "guitar", piano: "piano", other: "other", instrumental: "headphones" };
  const KEY_NAMES = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"], IT_NAMES = ["Do", "Do♯", "Re", "Mi♭", "Mi", "Fa", "Fa♯", "Sol", "La♭", "La", "Si♭", "Si"];

  const job = new Separation.Job();
  const player = new MixPlayer.Player();
  const ui = {
    quality: Prefs.get("quality", "best"), library: [], search: "", showLibrary: Prefs.get("showLibrary", true),
    practice: Prefs.get("showPractice", false), unselected: new Set(), update: null, updating: null, toast: null,
    italian: Prefs.get("italianChords", false), takes: [], comparing: false, downloadTransposed: true,
  };

  // ── Testata ──
  function header() {
    const u = ui.update;
    $("#header").innerHTML = `
      <img class="logo" src="img/logo.png" alt="">
      <div class="brand"><b>IsoLR</b><span>Separa voce e strumenti di qualsiasi canzone</span></div>
      <div class="grow"></div>
      ${u ? `<button class="btn round update" data-act="update">${Icon("up")}${ui.updating != null ? `Aggiorno… ${Math.round(ui.updating * 100)}%` : `Aggiornamento disponibile · ${esc(u.version)}`}</button>` : ""}
      <button class="btn round icon" data-act="library" title="Mostra o nascondi le tue canzoni">${Icon("sidebar")}</button>
      <button class="btn round" data-act="help">${Icon("help")}Aiuto</button>
      <button class="btn round" data-act="report" title="Segnala un problema o un'idea (Ctrl+Alt+B): il rapporto è già compilato con il computer e l'ultimo errore">${Icon("bug")}Segnala</button>
      <button class="btn round" data-act="settings">${Icon("gear")}Impostazioni</button>`;
  }

  // ── Libreria ──
  function library() {
    $("#app").classList.toggle("no-library", !ui.showLibrary);
    const list = ui.library.filter((e) => !ui.search || e.meta.title.toLowerCase().includes(ui.search.toLowerCase()));
    const cur = job.current && job.current.folder;
    $("#library").innerHTML = `
      <button class="btn new" data-act="new" ${job.busy || job.phase === "idle" ? "disabled" : ""}>${Icon("plus")}Nuova canzone</button>
      <div class="lib-head"><span>LE TUE CANZONI</span><button class="btn borderless icon small" data-act="open-root" title="Apri la cartella Musica › IsoLR">${Icon("folder")}</button></div>
      <input class="lib-search" placeholder="Cerca" value="${esc(ui.search)}" data-input="search">
      ${list.length ? `<div class="lib-list">${list.map((e, i) => `
        <div class="lib-item ${e.folder === cur ? "on" : ""}" data-open="${i}" title="${esc(e.meta.title)}">
          <span class="ic">${Icon("note")}</span><b>${esc(e.meta.title)}</b>
          <span>${Separation.QUALITY[e.meta.quality] ? Separation.QUALITY[e.meta.quality].title : ""} · ${fmt(e.meta.duration)}${e.meta.analysis && e.meta.analysis.bpm ? " · " + Math.round(e.meta.analysis.bpm) + " BPM" : ""}</span>
        </div>`).join("")}</div>`
        : `<div class="lib-empty">${Icon("note", "i")}<span>Le canzoni che separi compaiono qui</span></div>`}
      <div class="lib-foot">
        <div class="count">${Icon("note")}${ui.library.length} ${ui.library.length === 1 ? "canzone separata" : "canzoni separate"}</div>
        <div style="display:flex;gap:8px"><button class="btn small" data-act="history">${Icon("clock")}Cronologia</button></div>
      </div>`;
    ui.libList = list;
  }

  // ── Riquadro centrale ──
  function panel() {
    const p = $("#panel");
    if (job.phase === "working") return work(p);
    if (job.phase === "done" && job.current) return results(p);
    return start(p);
  }

  function waveBars() {
    const order = ["--c-vocals", "--c-drums", "--c-bass", "--c-other"];
    return Array.from({ length: 34 }, (_, i) => { const env = Math.sin((i / 33) * Math.PI); return `<i style="--c:var(${order[Math.floor((i * 4) / 34)]});--h:${Math.round(14 + 52 * env)}px;--d:${(i * 0.07).toFixed(2)}s"></i>`; }).join("");
  }

  function start(p) {
    const f = job.pending, q = ui.quality;
    const keys = Separation.QUALITY[q].keys.filter((k) => Prefs.get("splitGuitarPiano", true) || !["guitar", "piano"].includes(k));
    if (Prefs.get("makeInstrumental", true)) keys.push("instrumental");
    p.innerHTML = `<div class="drop" id="drop">
      <div class="wave">${waveBars()}</div>
      ${f ? `<div class="label">Canzone pronta</div>
        <div class="picked">${Icon("note")}${esc(f.name.replace(/\.[^.]+$/, ""))}<button class="btn borderless icon small" data-act="clear-pending" title="Togli">${Icon("x")}</button></div>
        <div class="muted">Scegli la qualità, poi premi «Separa»</div>`
      : `<h2>Trascina qui una canzone</h2><div class="muted">MP3, WAV, FLAC, M4A… oppure <button class="btn small" data-act="choose">Scegli un file</button></div>`}
      ${job.error ? `<div class="rec">Non riuscito: ${esc(job.error)} <button class="btn round" data-act="report">${Icon("bug")}Segnala il problema…</button></div>` : ""}
      <div class="label">Come la vuoi?</div>
      <div class="cards">${Object.entries(Separation.QUALITY).map(([k, v]) => `
        <button class="qcard ${k === q ? "on" : ""}" data-quality="${k}"><b>${Icon(v.icon)}${v.title}</b><span>${v.line}</span><span>${Separation.estimate(k)}</span></button>`).join("")}</div>
      <button class="btn prominent round" data-act="separate" ${f ? "" : "disabled"}>${IconFill("play").replace("<svg", '<svg class="i" style="fill:currentColor;stroke:none"')}Separa · ${Separation.QUALITY[q].title === "Massima" ? "Massima qualità" : Separation.QUALITY[q].title}</button>
      <div class="label">Riceverai</div>
      <div class="chips">${keys.map((k) => `<span class="chip" style="--c:var(--c-${k})">${Icon(ICON[k])}${Separation.NAMES[k]}</span>`).join("")}</div>
      ${job.queue.length ? `<div class="queue">In coda: ${job.queue.length} ${job.queue.length === 1 ? "canzone" : "canzoni"}</div>` : ""}
    </div>`;
    const drop = $("#drop");
    drop.ondragover = (e) => { e.preventDefault(); drop.classList.add("over"); };
    drop.ondragleave = () => drop.classList.remove("over");
    drop.ondrop = (e) => { e.preventDefault(); drop.classList.remove("over"); job.add(e.dataTransfer.files); };
  }

  function work(p) {
    p.innerHTML = `<div class="work">
      <div class="wave" style="justify-content:center">${waveBars()}</div>
      <h2 style="margin:0;font:700 19px var(--font-display)">${esc(job.title || "")}</h2>
      <div class="muted">${esc(job.step)} · ${Separation.QUALITY[ui.quality].title}</div>
      <div class="bar" style="margin:0 auto"><i style="width:${Math.round(job.progress * 100)}%"></i></div>
      ${job.queue.length ? `<div class="queue">Dopo: ${job.queue.length} ${job.queue.length === 1 ? "canzone" : "canzoni"} in coda</div>` : ""}
      <div><button class="btn" data-act="cancel">Annulla</button></div>
    </div>`;
  }

  // ── Risultati ──
  function infoLine(m) {
    const parts = [fmt(m.duration), Separation.QUALITY[m.quality] ? Separation.QUALITY[m.quality].title : ""];
    if (m.took) parts.push(`fatta in ${m.took < 90 ? Math.round(m.took) + " s" : Math.round(m.took / 60) + " min"}`);
    const a = m.analysis;
    if (a && a.bpm) parts.push(`${Math.round(a.bpm)} BPM`);
    if (a && a.keyRoot != null) parts.push(`${IT_NAMES[a.keyRoot]} ${a.minor ? "minore" : "maggiore"}`);
    return parts.join(" · ");
  }

  function results(p) {
    const cur = job.current, m = cur.meta;
    const stems = m.stems.filter((s) => s.key !== "instrumental"), base = m.stems.find((s) => s.key === "instrumental");
    const keys = m.stems.map((s) => s.key);
    const splits = Object.entries(Separation.EXTRA).filter(([k, x]) => keys.includes(x.source) && !Object.values(Separation.EXTRA).filter((y) => y.source === x.source).some((y) => y.parts.some((pp) => keys.includes(pp))));
    const sel = m.stems.filter((s) => !ui.unselected.has(s.key));
    p.innerHTML = `<div class="results">
      <div class="col">
        <div class="song"><span class="ic">${Icon("note")}</span><div style="min-width:0"><b>${esc(m.title)}</b><span>${esc(infoLine(m))}</span></div></div>
        <div class="transport" id="transport"></div>
        <div class="rows">
          ${stems.map((s) => row(s)).join("")}
          ${splits.map(([k, x]) => `<div class="split">${Icon(x.icon)}<div style="flex:1"><b>${x.title}</b><span>${x.detail}</span>
            ${job.splitError && job.splitting == null && ui.lastSplit === k ? `<span class="rec">Non riuscito: ${esc(job.splitError)}</span>` : ""}</div>
            ${job.splitting === k ? `<div class="bar"><i style="width:${Math.round((job.splitProgress || 0) * 100)}%"></i></div>` : `<button class="btn" data-split="${k}" ${job.splitting ? "disabled" : ""} title="La prima volta scarica il modello (${x.size})">${k === "drums" ? "Dividi" : "Separa"}</button>`}</div>`).join("")}
          ${base ? `<div style="border-top:1px solid var(--stroke);margin:4px 0"></div>${row(base, true)}` : ""}
        </div>
        <div class="hint">Clic sull'onda per ascoltare da quel punto · le tracce si possono anche trascinare nel tuo programma musicale da Esplora file</div>
      </div>
      <div class="side">
        <div class="box"><h3>Scarica</h3>
          <div class="form-line">Formato <select class="pop" data-input="format">${Object.entries(Encode.FORMATS).map(([k, f]) => `<option value="${k}" ${k === Prefs.get("downloadFormat", "wav24") ? "selected" : ""}>${f.title}</option>`).join("")}</select></div>
          ${player.semitones ? `<label class="form-line" style="font-size:12px"><input type="checkbox" data-act="dl-transposed" ${ui.downloadTransposed ? "checked" : ""}> ${esc(m.analysis && m.analysis.keyRoot != null ? "In " + Transpose.keyName(m.analysis.keyRoot, m.analysis.minor, player.semitones) : "Nella tonalità scelta")} (${Transpose.label(player.semitones)})</label>` : ""}
          <button class="btn" data-act="dl-all">${Icon("download")}Tutte le tracce</button>
          <button class="btn" data-act="dl-sel" ${sel.length && sel.length < m.stems.length ? "" : "disabled"}>Le ${sel.length} selezionate</button>
          <button class="btn" data-act="dl-mix">Il mix che senti</button>
          <button class="btn" data-act="dl-ab" ${player.isLooping ? "" : "disabled"} title="${player.isLooping ? "Solo il passaggio tra A e B, con il mix che senti" : "Prima segna A e B in «Esercitati»"}">Il passaggio A–B</button>
          <button class="btn" data-act="dl-stem">File per DJ (.stem.mp4)</button>
          <p>Scegli tu dove salvare. Le tracce restano anche in Musica › IsoLR.</p>
        </div>
        <div class="box"><h3>Vai più a fondo</h3>
          <div class="pair">
            <button class="btn" data-act="warp" title="Warp: correggi i segnaposto sulle battute e metti la canzone a tempo fisso">${Icon("warp")}Warp</button>
            <button class="btn" data-act="arrange" title="Rimonta: taglia sulle battute, sposta, duplica o togli le parti">${Icon("scissors")}Rimonta</button>
          </div>
          <select class="pop" data-input="midi" ${ui.midi ? "disabled" : ""}><option value="">${ui.midi ? "Note di " + esc(Separation.NAMES[ui.midi].toLowerCase()) + "…" : "Note, spartito e tab"}</option>
            ${m.stems.filter((s) => ["vocals", "lead", "backing", "male", "female", "bass", "guitar", "piano", "other"].includes(s.key)).map((s) => `<option value="${s.key}">${esc(s.name)}</option>`).join("")}</select>
          <button class="btn" data-act="details">Dettagli della separazione</button>
          <button class="btn" data-act="reveal">Apri la cartella delle tracce</button>
        </div>
      </div>
    </div>`;
    transport();
    drawWaves();
  }

  function row(s, isBase) {
    const k = s.key, on = !ui.unselected.has(k), muted = player.effectiveGain(k) === 0 && !isBase;
    const share = s.share != null ? `${Math.round(s.share * 100)}% della canzone` : (isBase ? Encode.FORMATS[Prefs.get("outputFormat", "wav24")].title.split(" ")[0] : "");
    return `<div class="row ${muted ? "muted" : ""}" style="--c:var(--c-${k})">
      <input type="checkbox" ${on ? "checked" : ""} data-sel="${k}" title="Tra le tracce da scaricare">
      <span class="stem-ic">${Icon(ICON[k] || "note")}</span>
      <div class="name"><b>${esc(s.name)}</b><span>${share}</span></div>
      ${isBase ? `<span></span><span></span>` : `<div class="ms">
        <button class="btn mute ${player.muted.has(k) ? "on" : ""}" data-mute="${k}" title="Silenzia ${esc(s.name)}">${Icon(player.muted.has(k) ? "speakerOff" : "speaker")}</button>
        <button class="btn solo ${player.solo.has(k) ? "on" : ""}" data-solo="${k}" title="Ascolta solo ${esc(s.name)}">${Icon("headphones")}</button></div>
        <input type="range" min="0" max="2" step="0.01" value="${player.gains[k] ?? 1}" data-gain="${k}" title="Volume" aria-label="Volume ${esc(s.name)}">`}
      <canvas data-wave="${k}" height="26"></canvas>
      <button class="btn small" data-dl="${k}">${Icon("download")}Scarica</button>
    </div>`;
  }

  function drawWaves() {
    const cs = getComputedStyle(document.documentElement);
    for (const c of document.querySelectorAll("canvas[data-wave]")) {
      const s = job.current.meta.stems.find((x) => x.key === c.dataset.wave);
      if (!s || !s.peaks) continue;
      const w = (c.width = c.clientWidth * devicePixelRatio), h = (c.height = 26 * devicePixelRatio), g = c.getContext("2d");
      g.fillStyle = cs.getPropertyValue("--c-" + s.key).trim() || cs.getPropertyValue("--brass");
      const bars = Math.floor(w / (3 * devicePixelRatio)), step = s.peaks.length / bars;
      for (let i = 0; i < bars; i++) {
        const v = s.peaks[Math.floor(i * step)] || 0, bh = Math.max(2, v * h * 0.9);
        g.fillRect(i * 3 * devicePixelRatio, (h - bh) / 2, 2 * devicePixelRatio, bh);
      }
    }
  }

  // Il trasporto: suona, tempo, scorciatoie, «Senza…», Esercitati; sotto, quando è aperto, la Sala prove
  function transport() {
    const t = $("#transport");
    if (!t) return;
    const p = player.currentPreset, hasLead = player.keys.includes("lead");
    const w = player.withoutNow;
    const insts = Object.keys(MixPlayer.INSTRUMENTS).filter((k) => MixPlayer.INSTRUMENTS[k].some((x) => player.keys.includes(x)));
    t.innerHTML = `<div class="trow">
        <button class="play" data-act="play" title="${player.playing ? "Pausa (spazio)" : "Suona tutte le tracce insieme (spazio)"}">${IconFill(player.playing ? "pause" : "play")}</button>
        <span class="time" id="time">${fmt(player.position)} / ${fmt(player.duration)}</span>
        <div class="seg">${[["all", "Tutto"], ["karaoke", "Karaoke"], ...(hasLead ? [["backing", "Karaoke con cori"]] : []), ["voice", "Solo voce"]].map(([k, l]) => `<button class="${p === k ? "on" : ""}" data-preset="${k}">${l}</button>`).join("")}</div>
        <select class="pop" data-input="without" title="Togli uno strumento"><option value="">${w ? "Senza " + Separation.NAMES[w].toLowerCase() : "Senza…"}</option>${insts.map((k) => `<option value="${k}">Senza ${Separation.NAMES[k].toLowerCase()}</option>`).join("")}</select>
        <button class="btn" data-act="transpose" title="Transpose: la canzone in un'altra tonalità, senza cambiare la velocità (Ctrl+Alt+↑ e ↓)">${Icon("up")}${esc(transposeTitle())}</button>
        <div class="tools">
          <button class="btn ${ui.practice ? "on" : ""}" data-act="practice" title="Esercitati: velocità, tono, ripetizione, metronomo, accordi, registrazione">${Icon("note")}Esercitati</button></div>
      </div>
      ${ui.practice ? practice() : ""}`;
  }

  function practice() {
    const s = player.structure, d = player.duration;
    const parts = (s && s.sections) || [];
    const chords = job.current.meta.analysis && job.current.meta.analysis.chords;
    const sectionsHtml = parts.length && d > 0
      ? `<div class="sections" id="sections">${parts.map((x, i) => {
          const end = Math.min(d, x.end), on = Math.abs((player.loopA ?? -9) - x.start) < 0.05 && Math.abs((player.loopB ?? -9) - end) < 0.05;
          return `<button class="${on ? "on" : ""}" data-section="${i}" style="left:${(100 * x.start) / d}%;width:calc(${(100 * (end - x.start)) / d}% - 1px);background:${on ? "" : `color-mix(in srgb, var(--brass) ${10 + 7 * (x.group % 4)}%, transparent)`}" title="Ripeti «${esc(x.label)}» (${fmt(x.start)}–${fmt(end)})">${esc(x.label)}</button>`;
        }).join("")}<span class="head" id="head"></span></div>`
      : `<span class="hint" style="flex:1">${s ? "Parti della canzone non riconosciute: segna A e B a mano" : "Le parti della canzone (strofa, ritornello…) compaiono nelle canzoni separate da questa versione"}</span>`;
    return `<div class="practice">
      <div class="trow">${sectionsHtml}
        <button class="btn small ${player.metronome ? "on" : ""}" data-act="metronome" ${s && s.beats ? "" : "disabled"} title="Un clic su ogni battito della canzone, più forte sul primo della battuta">${Icon("metronome")}Metronomo</button>
        <button class="btn small ${player.countIn ? "on" : ""}" data-act="count" ${player.bpm || s ? "" : "disabled"} title="Prima di partire, una battuta di clic al tempo della canzone">${Icon("count")}Conteggio</button></div>
      ${chords && chords.length ? `<div class="trow" id="chords"></div>` : ""}
      <div class="trow">
        ${Icon("tortoise")}<input type="range" min="0.5" max="1.5" step="0.05" value="${player.rate}" data-input="rate" style="width:120px" aria-label="Velocità">${Icon("hare")}
        <span class="time" style="width:38px">${Math.round(player.rate * 100)}%</span>
        <span>Tono ${player.semitones > 0 ? "+" : ""}${player.semitones}</span>
        <button class="btn small icon" data-act="pitch-down" title="Un semitono sotto">−</button><button class="btn small icon" data-act="pitch-up" title="Un semitono sopra">+</button>
        <button class="btn small" data-act="mark-a" title="Inizio del passaggio da ripetere">${player.loopA != null ? "A " + fmt(player.loopA) : "A"}</button>
        <button class="btn small" data-act="mark-b" title="Fine del passaggio: da qui si torna ad A">${player.loopB != null ? "B " + fmt(player.loopB) : "B"}</button>
        ${player.loopA != null || player.loopB != null ? `<button class="btn small icon borderless" data-act="clear-loop" title="Togli la ripetizione">${Icon("x")}</button>` : ""}
        <button class="btn small ${player.ramp ? "on" : ""}" data-act="ramp" ${player.isLooping ? "" : "disabled"} title="Il passaggio A-B riparte ogni volta un po' più veloce: dal 70% al 100%, +5% a giro">${player.ramp ? "Rampa 70→100%" : "Rampa"}</button>
        <div class="grow"></div>
        ${player.rate !== 1 || player.semitones || player.loopA != null ? `<button class="btn small" data-act="normal">Normale</button>` : ""}
      </div>
      <div class="trow" id="recrow">${recordRow()}</div>
    </div>`;
  }

  function recordRow() {
    const R = window.Recorder;
    if (R && R.recording) return `<button class="btn small" data-act="rec-stop">${Icon("stop")}Ferma</button><span class="meter"><i id="meter"></i></span><span class="muted">Registrazione in corso…</span>`;
    const t = player.take;
    if (t) {
      const name = (p) => p.split(/[\\/]/).pop().replace(/\.wav$/i, "");
      return `<button class="btn small rec" data-act="rec">${Icon("record")}Registrati</button>
        <select class="pop" data-input="take">${ui.takes.map((p) => `<option value="${esc(p)}" ${p === t ? "selected" : ""}>${esc(name(p))}</option>`).join("")}</select>
        <button class="btn small ${player.takeOn ? "on" : ""}" data-act="take-on" title="Senti la registrazione insieme alla base">${Icon(player.takeOn ? "speaker" : "speakerOff")}</button>
        <input type="range" min="0" max="2" step="0.01" value="${player.takeVolume}" data-input="take-volume" style="width:80px" aria-label="Volume della registrazione">
        <select class="pop" data-input="compare" ${ui.comparing ? "disabled" : ""}><option value="">${ui.comparing ? "Confronto…" : "Confronta"}</option>${MixPlayer.mixable(job.current.meta.stems).map((s) => `<option value="${s.key}">${esc(s.name)}</option>`).join("")}</select>
        <button class="btn small" data-act="take-dl">Scarica</button>
        <button class="btn small icon borderless" data-act="take-del" title="Sposta la registrazione nel Cestino">${Icon("trash")}</button>`;
    }
    return `<button class="btn small rec" data-act="rec" title="Registra dal microfono o dalla scheda audio mentre suona la base">${Icon("record")}Registrati</button>
      <span class="hint">Suona o canta sopra la base: la registrazione si mette a tempo da sola</span>`;
  }

  // Accordi: quello di adesso e i prossimi tre, spostati con il tono
  function chordName(c) {
    if (c.root == null) return "—";
    const k = (((c.root + player.semitones) % 12) + 12) % 12;
    return (ui.italian ? IT_NAMES : KEY_NAMES)[k] + (c.minor ? "m" : "");
  }
  function updateLive() {
    const t = player.position;
    const tm = $("#time"); if (tm) tm.textContent = `${fmt(t)} / ${fmt(player.duration)}`;
    const head = $("#head"); if (head && player.duration) head.style.left = `calc(${(100 * t) / player.duration}% - 1px)`;
    const box = $("#chords"), chords = job.current && job.current.meta.analysis && job.current.meta.analysis.chords;
    if (box && chords) {
      let i = chords.findIndex((c) => t < c.end); if (i < 0) i = chords.length - 1;
      const next = chords.slice(i + 1).filter((c) => c.root != null).slice(0, 3);
      const html = `<span class="muted" style="font-size:11px;font-weight:600">Accordi</span><span class="chord-now">${chordName(chords[i])}</span>
        ${next.map((c, k) => `<span class="chord-next" style="${k ? "" : "color:var(--ink);opacity:.75"}">${chordName(c)}</span>`).join("")}
        ${next[0] ? `<span class="hint">tra ${Math.max(0, Math.ceil((next[0].start - t) / Math.max(0.25, player.rate)))} s</span>` : ""}
        <div class="grow"></div><div class="seg"><button class="${ui.italian ? "" : "on"}" data-chordnames="en">C D E</button><button class="${ui.italian ? "on" : ""}" data-chordnames="it">Do Re Mi</button></div>`;
      if (box.dataset.last !== html) { box.innerHTML = html; box.dataset.last = html; }
    }
    const meter = $("#meter"); if (meter && window.Recorder) meter.style.width = Math.round(Math.min(1, window.Recorder.level) * 100) + "%";
  }

  function render() { header(); library(); panel(); }

  // ── Azioni ──
  function toast(msg) {
    const t = document.createElement("div"); t.className = "toast"; t.textContent = msg; document.body.appendChild(t);
    setTimeout(() => t.remove(), 3500);
  }
  async function refreshLibrary() { ui.library = await Separation.library(); library(); }

  /** Di quanti semitoni spostare i file scaricati (0 = tonalità originale). */
  const shift = () => (ui.downloadTransposed ? player.semitones : 0);
  function transposeBy(d) {
    player.setSemitones(Math.max(Transpose.RANGE[0], Math.min(Transpose.RANGE[1], player.semitones + d)));
    panel();
  }
  function transposeTitle() {
    const s = player.semitones, a = job.current && job.current.meta.analysis;
    if (!a || a.keyRoot == null) return s ? Transpose.label(s) : "Tonalità";
    const k = Transpose.keyShort(a.keyRoot, a.minor, s);
    return s ? `${k} · ${Transpose.label(s)}` : k;
  }

  async function downloadStems(list) {
    const f = Prefs.get("downloadFormat", "wav24"), sh = shift(), title = job.current.meta.title, sx = Transpose.suffix(sh);
    try {
      if (list.length === 1) {
        const s = list[0], ext = Encode.FORMATS[f].ext;
        const path = await Bridge.askFile(`${title} – ${s.name}${sx}.${ext}`, ext);
        if (!path) return;
        const ch = await Transpose.apply(Encode.readWav(await Bridge.readFile(job.current.folder + "/" + s.file)), sh);
        await Bridge.writeFile(path, await Encode.encode(ch, f));
        Bridge.reveal(path);
      } else {
        const dir = await Bridge.askFolder();
        if (!dir) return;
        const tag = sh ? " " + Transpose.label(sh) : "";
        let target = `${dir}/${title} (IsoLR${tag})`, n = 2;
        while (await Bridge.exists(target)) target = `${dir}/${title} (IsoLR${tag} ${n++})`;
        for (const s of list) {
          const ch = await Transpose.apply(Encode.readWav(await Bridge.readFile(job.current.folder + "/" + s.file)), sh);
          await Bridge.writeFile(`${target}/${title} – ${s.name}${sx}.${Encode.FORMATS[f].ext}`, await Encode.encode(ch, f));
        }
        Bridge.reveal(target);
      }
    } catch (e) { toast("Download non riuscito: " + (e.message || e)); }
  }
  async function downloadMix(range) {
    const f = Prefs.get("downloadFormat", "wav24"), ext = Encode.FORMATS[f].ext, sh = shift();
    const name = player.exportName(job.current.meta.title) + Transpose.suffix(sh) + (range ? ` (${fmt(range[0])}–${fmt(range[1])})` : "");
    const path = await Bridge.askFile(`${name}.${ext}`.replace(/:/g, "."), ext);
    if (!path) return;
    try {
      const m = player.mixdown(range);
      await Bridge.writeFile(path, await Encode.encode(await Transpose.apply(m.channels, sh), f, m.gain));
      Bridge.reveal(path);
    } catch (e) { toast("Download non riuscito: " + (e.message || e)); }
  }
  async function downloadStemFile() {
    const sh = shift();
    const path = await Bridge.askFile(`${job.current.meta.title}${Transpose.suffix(sh)}.stem.mp4`, "mp4");
    if (!path) return;
    try {
      toast("Preparo il file per DJ…");
      const tracks = {};
      for (const s of MixPlayer.mixable(job.current.meta.stems)) tracks[s.key] = await Transpose.apply(Encode.readWav(await Bridge.readFile(job.current.folder + "/" + s.file)), sh);
      await Bridge.writeFile(path, await Encode.stemMp4(tracks));
      Bridge.reveal(path);
    } catch (e) { toast("File per DJ non riuscito: " + (e.message || e)); }
  }

  async function openEntry(e) {
    await job.open(e);
    ui.unselected = new Set();
    await player.load(e);
    ui.takes = await Bridge.listFiles(e.folder + "/Registrazioni", "wav");
    if (ui.takes[0]) await player.loadTake(ui.takes[0]);
    render();
  }

  document.addEventListener("click", async (ev) => {
    const el = ev.target.closest("[data-act],[data-quality],[data-open],[data-preset],[data-mute],[data-solo],[data-dl],[data-split],[data-section],[data-chordnames],[data-tab]");
    if (!el) {
      const c = ev.target.closest("canvas[data-wave]");
      if (c) { const r = c.getBoundingClientRect(); player.seek((ev.clientX - r.left) / r.width); if (!player.playing) player.play(player.position); }
      return;
    }
    const d = el.dataset;
    if (d.quality) { ui.quality = d.quality; Prefs.set("quality", d.quality); return panel(); }
    if (d.open != null) return openEntry(ui.libList[+d.open]);
    if (d.preset) { player.preset(d.preset); return panel(); }
    if (d.mute) { player.toggleMute(d.mute); return panel(); }
    if (d.solo) { player.toggleSolo(d.solo); return panel(); }
    if (d.dl) return downloadStems(job.current.meta.stems.filter((s) => s.key === d.dl));
    if (d.split) { ui.lastSplit = d.split; player.stop(); await job.split(d.split); await player.load(job.current); return render(); }
    if (d.section != null) { const x = player.structure.sections[+d.section]; player.practice(x.start, x.end); return transport(); }
    if (d.chordnames) { ui.italian = d.chordnames === "it"; Prefs.set("italianChords", ui.italian); const b = $("#chords"); if (b) b.dataset.last = ""; return; }
    if (d.tab) return window.Sheets && window.Sheets.tab(d.tab);
    switch (d.act) {
      case "library": ui.showLibrary = !ui.showLibrary; Prefs.set("showLibrary", ui.showLibrary); return library();
      case "new": player.stop(); job.reset(); return render();
      case "choose": { const p = await Bridge.askOpen(); if (p) { const bytes = await Bridge.readFile(p); job.add([new File([bytes], p.split(/[\\/]/).pop())]); } return; }
      case "clear-pending": return job.clearPending();
      case "separate": player.stop(); return job.start(ui.quality);
      case "cancel": return job.cancel();
      case "open-root": return Bridge.reveal(await Bridge.outputDir());
      case "reveal": return Bridge.reveal(job.current.folder + "/isolr.json");
      case "play": player.toggle(); return transport();
      case "practice": ui.practice = !ui.practice; Prefs.set("showPractice", ui.practice); return transport();
      case "metronome": player.metronome = !player.metronome; return transport();
      case "count": player.countIn = !player.countIn; return transport();
      case "pitch-down": transposeBy(-1); return;
      case "pitch-up": transposeBy(1); return;
      case "transpose": return window.Sheets.transpose(job.current, player, transposeBy);
      case "warp": return window.Editors.warp(job.current, player);
      case "arrange": return window.Editors.arrange(job.current, player);
      case "dl-transposed": ui.downloadTransposed = !ui.downloadTransposed; return panel();
      case "mark-a": player.markA(); return transport();
      case "mark-b": player.markB(); return panel();
      case "clear-loop": player.clearLoop(); return panel();
      case "ramp": player.setRamp(!player.ramp); return transport();
      case "normal": player.resetPractice(); if (player.playing) player.play(player.position, { counting: false }); return panel();
      case "dl-all": return downloadStems(job.current.meta.stems);
      case "dl-sel": return downloadStems(job.current.meta.stems.filter((s) => !ui.unselected.has(s.key)));
      case "dl-mix": return downloadMix(null);
      case "dl-ab": return downloadMix([player.loopA, player.loopB]);
      case "dl-stem": return downloadStemFile();
      case "details": return window.Sheets.details(job.current);
      case "settings": return window.Sheets.settings();
      case "help": return window.Sheets.help();
      case "report": return window.Sheets.report(job);
      case "history": return window.Sheets.history(ui.library, openEntry);
      case "update": if (ui.update && ui.updating == null) { ui.updating = 0; header(); try { await Bridge.installUpdate(ui.update.url, (p) => { ui.updating = p; header(); }); } catch (e) { ui.updating = null; toast("Aggiornamento non riuscito: " + (e.message || e)); header(); } } return;
      case "rec": return window.Recorder.start(player, job.current, async (path) => { ui.takes = await Bridge.listFiles(job.current.folder + "/Registrazioni", "wav"); await player.loadTake(path); transport(); }, (msg) => toast(msg), () => transport());
      case "rec-stop": return window.Recorder.stop();
      case "take-on": player.takeOn = !player.takeOn; player.applyGains(); return transport();
      case "take-dl": { const s = { name: player.take.split(/[\\/]/).pop().replace(/\.wav$/i, ""), file: null }; const f = Prefs.get("downloadFormat", "wav24"), ext = Encode.FORMATS[f].ext; const path = await Bridge.askFile(`${s.name}.${ext}`, ext); if (path) { await Bridge.writeFile(path, await Encode.encode(Encode.readWav(await Bridge.readFile(player.take)), f)); Bridge.reveal(path); } return; }
      case "take-del": await Bridge.remove(player.take); ui.takes = await Bridge.listFiles(job.current.folder + "/Registrazioni", "wav"); await player.loadTake(ui.takes[0] || null); return transport();
    }
  });

  document.addEventListener("input", async (ev) => {
    const el = ev.target, d = el.dataset;
    if (d.gain) { player.setGain(d.gain, +el.value); return; }
    if (d.sel) { el.checked ? ui.unselected.delete(d.sel) : ui.unselected.add(d.sel); const st = job.current.meta.stems; const sel = st.filter((s) => !ui.unselected.has(s.key)); const b = $('[data-act="dl-sel"]'); if (b) { b.textContent = `Le ${sel.length} selezionate`; b.disabled = !(sel.length && sel.length < st.length); } return; }
    switch (d.input) {
      case "search": ui.search = el.value; { const pos = el.selectionStart; library(); const s = $('[data-input="search"]'); s.focus(); s.setSelectionRange(pos, pos); } return;
      case "format": Prefs.set("downloadFormat", el.value); return;
      case "rate": player.setRate(+el.value); el.nextElementSibling.nextElementSibling.textContent = Math.round(player.rate * 100) + "%"; return;
      case "take-volume": player.takeVolume = +el.value; player.applyGains(); return;
    }
  });
  document.addEventListener("change", async (ev) => {
    const el = ev.target, d = el.dataset;
    if (d.input === "without" && el.value) { player.without(el.value); return panel(); }
    if (d.input === "take") { await player.loadTake(el.value); return transport(); }
    if (d.input === "midi" && el.value) return window.Sheets.notes(job.current, el.value, (k) => { ui.midi = k; panel(); }, shift());
    if (d.input === "compare" && el.value) {
      ui.comparing = true; transport();
      try { await window.Sheets.compare(job.current, player.take, el.value); } catch (e) { toast(e.message || String(e)); }
      ui.comparing = false; transport();
    }
  });

  // Spazio = suona/pausa; ⌘[ e ⌘] (qui Ctrl) = A e B; Ctrl+N = nuova canzone
  document.addEventListener("keydown", (e) => {
    if (e.target.matches("input[type=text],input:not([type]),select,textarea")) return;
    // Con una finestra aperta sopra (Warp, Rimonta…) i tasti sono suoi
    if ($("#overlay").childElementCount) return;
    if (e.code === "Space" && job.phase === "done") { e.preventDefault(); player.toggle(); transport(); }
    if (e.ctrlKey && e.key === "[") { player.markA(); transport(); }
    if (e.ctrlKey && e.key === "]") { player.markB(); panel(); }
    if (e.ctrlKey && e.altKey && e.key === "ArrowUp") { e.preventDefault(); transposeBy(1); }
    if (e.ctrlKey && e.altKey && e.key === "ArrowDown") { e.preventDefault(); transposeBy(-1); }
    // Come sul Mac (⌥⌘G e ⌥⌘X): Warp e Rimonta
    if (e.ctrlKey && e.altKey && e.key.toLowerCase() === "g" && job.current) { e.preventDefault(); $('[data-act="warp"]') && $('[data-act="warp"]').click(); }
    if (e.ctrlKey && e.altKey && e.key.toLowerCase() === "x" && job.current) { e.preventDefault(); $('[data-act="arrange"]') && $('[data-act="arrange"]').click(); }
    if (e.ctrlKey && e.altKey && e.key.toLowerCase() === "b") { e.preventDefault(); window.Sheets.report(job); }
    if (e.ctrlKey && e.key.toLowerCase() === "o") { e.preventDefault(); $('[data-act="choose"]') && $('[data-act="choose"]').click(); }
  });
  // Una canzone trascinata ovunque nella finestra
  document.addEventListener("dragover", (e) => e.preventDefault());
  document.addEventListener("drop", (e) => { e.preventDefault(); if (e.dataTransfer.files.length) { player.stop(); job.add(e.dataTransfer.files); } });

  let lastPhase = null;
  job.addEventListener("change", async () => {
    if (job.phase !== lastPhase) {
      lastPhase = job.phase;
      if (job.phase === "done" && job.current) { await refreshLibrary(); await openEntry(job.current); return; }
      render(); return;
    }
    if (job.phase === "working") return panel();
    if (job.splitting) panel();
  });
  player.addEventListener("change", () => { const b = $(".play"); if (b) b.innerHTML = IconFill(player.playing ? "pause" : "play"); });
  window.addEventListener("resize", () => { if (job.phase === "done") drawWaves(); });

  (function loop() { player.tick(); updateLive(); requestAnimationFrame(loop); })();

  // Avvio: le canzoni, poi (in silenzio) se c'è un aggiornamento; di nuovo ogni 3 ore
  async function checkUpdate() { try { ui.update = await Bridge.checkUpdate(); header(); } catch {} }
  render();
  refreshLibrary();
  setTimeout(checkUpdate, 3000);
  setInterval(checkUpdate, 3 * 3600 * 1000);

  window.IsoApp = { job, player, ui, render, toast, fmt, esc, refreshLibrary, openEntry, transport, IT_NAMES, KEY_NAMES };
})();
