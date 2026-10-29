// Le note di una traccia nell'app (piano roll), come Sources/PianoRollView.swift sul Mac: tastiera a sinistra,
// note colorate (più forti = più piene), griglia sulle battute vere, testina del mixer. Si ascoltano con un
// suono dell'app (Piano, Synth, Basso), da sole, con la traccia vera o insieme; seguono velocità, tono e A–B
// del mixer. Si modificano (sposta, allunga, aggiungi, togli, selezione a rettangolo, annulla, ripristina) e
// si salvano con la canzone: i download MIDI, spartito e tab usano le note modificate.
// Le regole sono in core/notes.js.
/* global Bridge, Encode, Separation, IsoLR, IsoApp, Icon, IconFill, Transpose */
(function () {
  "use strict";
  const N = IsoLR.Notes;
  const KEYW = 46, MIN_ROW = 6;
  const BLACK = new Set([1, 3, 6, 8, 10]);
  const NAMES = ["Do", "Do♯", "Re", "Mi♭", "Mi", "Fa", "Fa♯", "Sol", "La♭", "La", "Si♭", "Si"];
  const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  const fmt = (t) => IsoApp.fmt(t), esc = (s) => IsoApp.esc(s);

  // ── Dove stanno le note di una canzone: rilevate (Basic Pitch) e modificate, accanto alle tracce ──
  const file = (cur, key) => `${cur.folder}/isolr-note-${key}.json`;
  async function load(cur, key) {
    try { if (await Bridge.exists(file(cur, key))) return JSON.parse(await Bridge.readText(file(cur, key))); } catch (e) { /* si rifanno */ }
    return null;
  }
  async function store(cur, key, data) { await Bridge.writeText(file(cur, key), JSON.stringify(data)); }

  /** Le note da usare per i file (MIDI, spartito, tab): quelle modificate se ci sono, altrimenti null. */
  async function edited(cur, key) {
    const d = await load(cur, key);
    return d && d.edited ? d.edited : null;
  }

  /** Le note rilevate (salvate la prima volta, poi riusate) e quelle modificate. */
  async function notesOf(cur, key, status) {
    const d = await load(cur, key);
    if (d && d.detected) return d;
    status("Cerco le note della traccia (Basic Pitch)…");
    const stem = cur.meta.stems.find((s) => s.key === key);
    const ch = Encode.readWav(await Bridge.readFile(cur.folder + "/" + stem.file));
    const detected = (await IsoApp.job.transcribe(ch)).map(({ start, end, pitch, velocity }) => ({ start, end, pitch, velocity }));
    const data = { version: 1, detected, edited: null };
    await store(cur, key, data);
    return data;
  }

  // ── Il suono delle note: un piccolo sintetizzatore WebAudio, tre timbri ──
  const SOUNDS = {
    piano: { title: "Piano", wave: "triangle", attack: 0.004, decay: 1.2, sustain: 0.0, release: 0.15, cutoff: 5000, gain: 0.35 },
    synth: { title: "Synth", wave: "sawtooth", attack: 0.01, decay: 0.3, sustain: 0.6, release: 0.12, cutoff: 2200, gain: 0.18 },
    bass: { title: "Basso", wave: "square", attack: 0.005, decay: 0.25, sustain: 0.5, release: 0.08, cutoff: 900, gain: 0.25 },
  };
  function voice(ctx, out, pitch, when, dur, velocity, sound) {
    const s = SOUNDS[sound] || SOUNDS.piano, f = 440 * Math.pow(2, (pitch - 69) / 12);
    const o = ctx.createOscillator(), filt = ctx.createBiquadFilter(), g = ctx.createGain();
    o.type = s.wave; o.frequency.value = f;
    filt.type = "lowpass"; filt.frequency.value = Math.min(s.cutoff, f * 8);
    const peak = s.gain * (0.3 + 0.7 * velocity / 127), hold = Math.max(0.02, dur);
    g.gain.setValueAtTime(0, when);
    g.gain.linearRampToValueAtTime(peak, when + s.attack);
    g.gain.setTargetAtTime(peak * s.sustain, when + s.attack, s.decay / 3);
    g.gain.setTargetAtTime(0, when + hold, s.release / 3);
    o.connect(filt); filt.connect(g); g.connect(out);
    o.start(when); o.stop(when + hold + s.release * 2);
    return o;
  }

  function open(cur, player, key) {
    if (!cur || !player.keys.length) return;
    player.pause();
    const stem = cur.meta.stems.find((s) => s.key === key);
    if (!stem) return;
    const a = cur.meta.analysis || {}, duration = player.duration;
    const grid16 = N.grid(a.structure, a.bpm, duration);
    const beats = a.structure && a.structure.beats && a.structure.beats.length ? a.structure.beats : null;
    const bpb = (a.structure && a.structure.beatsPerBar) || 4, first = (a.structure && a.structure.firstDownbeat) || 0;
    let ed = null, sel = new Set(), view = { t0: 0, span: Math.min(duration, 16), lo: 48, hi: 72 }, drag = null, raf = 0;
    let listen = "both", sound = Prefs.get("pianoSound", key === "bass" ? "bass" : "piano"), scheduled = new Set(), lastPos = -1, voices = [];
    const saved = { muted: new Set(player.muted), solo: new Set(player.solo) };
    const color = css(`--c-${key}`) || css("--brass");

    const html = `<div class="ed-head"><div><h2>Note · ${esc(stem.name)}</h2><div class="muted">Trascina una nota per spostarla, il bordo destro per allungarla. Doppio clic ne aggiunge una, Canc toglie le scelte. Alt: senza aggancio alla griglia.</div></div></div>
      <div class="ed-bar">
        <button class="play small" data-p="play" title="Suona dal cursore (spazio)">${IconFill("play")}</button>
        <span class="time" id="p-time"></span>
        <div class="seg" role="group" aria-label="Cosa ascoltare"><button data-p-listen="notes">Note</button><button data-p-listen="track">Traccia</button><button data-p-listen="both">Insieme</button></div>
        <select class="pop" id="p-sound" aria-label="Suono delle note">${Object.entries(SOUNDS).map(([k, s]) => `<option value="${k}" ${k === sound ? "selected" : ""}>${s.title}</option>`).join("")}</select>
        <div class="grow"></div>
        <button class="btn small icon" data-p="zoom-out" title="Allontana (Ctrl −)">${Icon("zoomOut")}</button>
        <button class="btn small icon" data-p="zoom-in" title="Avvicina (Ctrl +)">${Icon("zoomIn")}</button>
        <button class="btn small" data-p="undo" title="Annulla (Ctrl+Z)">${Icon("undo")}Annulla</button>
        <button class="btn small" data-p="reset" title="Torna alle note trovate da IsoLR">${Icon("reset")}Ripristina</button>
      </div>
      <canvas class="wcanvas proll" id="p-canvas" tabindex="0" aria-label="Le note della traccia: tastiera a sinistra, tempo da sinistra a destra"></canvas>
      <input type="range" id="p-scroll" min="0" max="0" step="0.01" value="0" aria-label="Scorri la canzone">
      <div class="ed-foot">
        <span id="p-info" class="muted"></span>
        <div class="grow"></div>
        <button class="btn" data-p="file" title="Salva il file MIDI con queste note e lo mostra in Esplora file: da lì si trascina in Ableton, FL Studio o Cubase">${Icon("download")}File MIDI per il tuo programma</button>
        <button class="btn prominent" data-close>Fatto</button>
      </div>
      <div class="ed-status" id="p-status"></div>`;

    window.Sheets.open(html, async (sheet, close) => {
      sheet.classList.add("wide");
      const cv = sheet.querySelector("#p-canvas"), scroll = sheet.querySelector("#p-scroll");
      const status = (t) => { sheet.querySelector("#p-status").textContent = t || ""; };
      const W = () => cv.clientWidth - KEYW, Hh = () => cv.clientHeight;
      const rows = () => view.hi - view.lo + 1, rowH = () => Hh() / rows();
      const xOf = (t) => KEYW + ((t - view.t0) / view.span) * W();
      const tOf = (x) => view.t0 + ((x - KEYW) / W()) * view.span;
      const yOf = (p) => (view.hi - p) * rowH();
      const pOf = (y) => view.hi - Math.floor(y / rowH());
      const clampView = () => {
        view.span = Math.max(1, Math.min(duration, view.span)); view.t0 = Math.max(0, Math.min(Math.max(0, duration - view.span), view.t0));
        const span = view.hi - view.lo; if (view.lo < 0) { view.lo = 0; view.hi = span; } if (view.hi > 127) { view.hi = 127; view.lo = 127 - span; }
      };

      function info() {
        const list = ed ? ed.notes : [];
        sheet.querySelector("#p-info").textContent = ed ? `${list.length} note${ed.edited ? " · modificate" : ""}${sel.size ? ` · ${sel.size} scelte` : ""}` : "";
        sheet.querySelectorAll("[data-p-listen]").forEach((b) => b.classList.toggle("on", b.dataset.pListen === listen));
        sheet.querySelector('[data-p="undo"]').disabled = !ed || !ed.history.length;
        sheet.querySelector('[data-p="play"]').innerHTML = IconFill(player.playing ? "pause" : "play");
      }

      function draw() {
        const dpr = devicePixelRatio || 1, w = cv.clientWidth, h = cv.clientHeight;
        if (!w) return;
        if (cv.width !== Math.round(w * dpr) || cv.height !== Math.round(h * dpr)) { cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr); }
        const c = cv.getContext("2d");
        c.setTransform(dpr, 0, 0, dpr, 0, 0);
        c.clearRect(0, 0, w, h);
        const rh = rowH(), ink = css("--ink"), stroke = css("--stroke"), muted = css("--muted");
        // Righe: i tasti neri un po' più scuri, ogni Do con una linea
        for (let p = view.lo; p <= view.hi; p++) {
          const y = yOf(p);
          if (BLACK.has(p % 12)) { c.fillStyle = css("--stroke"); c.globalAlpha = 0.35; c.fillRect(KEYW, y, w - KEYW, rh); c.globalAlpha = 1; }
          if (p % 12 === 0) { c.fillStyle = stroke; c.fillRect(KEYW, y + rh - 1, w - KEYW, 1); }
        }
        // Griglia: battute forti, battiti medi, sedicesimi tenui quando c'è spazio
        const sixteenth = view.span / W() * 6 < 0.12;
        if (sixteenth) { c.fillStyle = stroke; c.globalAlpha = 0.4; for (const t of grid16) if (t >= view.t0 && t <= view.t0 + view.span) c.fillRect(Math.round(xOf(t)), 0, 1, h); c.globalAlpha = 1; }
        if (beats) beats.forEach((t, i) => {
          if (t < view.t0 || t > view.t0 + view.span) return;
          const bar = (i - first) % bpb === 0;
          c.fillStyle = bar ? muted : stroke; c.globalAlpha = bar ? 0.55 : 0.8;
          c.fillRect(Math.round(xOf(t)), 0, 1, h); c.globalAlpha = 1;
        });
        // Le note: il colore della traccia, più pieno se suonata forte
        if (ed) for (const n of ed.notes) {
          if (n.end < view.t0 || n.start > view.t0 + view.span || n.pitch < view.lo || n.pitch > view.hi) continue;
          const x = Math.max(KEYW, xOf(n.start)), x2 = xOf(n.end), y = yOf(n.pitch);
          c.globalAlpha = 0.45 + 0.55 * (n.velocity / 127);
          c.fillStyle = color;
          c.beginPath(); c.roundRect(x, y + 1, Math.max(2, x2 - x), Math.max(2, rh - 2), Math.min(3, rh / 2)); c.fill();
          c.globalAlpha = 1;
          if (sel.has(n.id)) { c.strokeStyle = ink; c.lineWidth = 2; c.stroke(); }
        }
        // Rettangolo di selezione
        if (drag && drag.kind === "rect") {
          c.strokeStyle = css("--brass"); c.lineWidth = 1; c.setLineDash([4, 3]);
          c.strokeRect(Math.min(drag.x0, drag.x1), Math.min(drag.y0, drag.y1), Math.abs(drag.x1 - drag.x0), Math.abs(drag.y1 - drag.y0));
          c.setLineDash([]);
        }
        // Tastiera
        c.fillStyle = css("--card"); c.fillRect(0, 0, KEYW, h);
        for (let p = view.lo; p <= view.hi; p++) {
          const y = yOf(p);
          c.fillStyle = BLACK.has(p % 12) ? ink : css("--card"); c.globalAlpha = BLACK.has(p % 12) ? 0.8 : 1;
          c.fillRect(0, y, BLACK.has(p % 12) ? KEYW * 0.62 : KEYW, rh); c.globalAlpha = 1;
          c.fillStyle = stroke; c.fillRect(0, y + rh - 0.5, KEYW, 0.5);
          if (p % 12 === 0 && rh >= 7) { c.fillStyle = muted; c.font = `600 ${Math.min(10, rh)}px system-ui`; c.fillText(`Do${Math.floor(p / 12) - 1}`, KEYW * 0.66, y + rh - 2); }
        }
        c.fillStyle = stroke; c.fillRect(KEYW - 1, 0, 1, h);
        // Testina
        const pos = player.position;
        if (pos >= view.t0 && pos <= view.t0 + view.span) { c.fillStyle = css("--brass"); c.fillRect(Math.round(xOf(pos)) - 1, 0, 2, h); }
        sheet.querySelector("#p-time").textContent = `${fmt(pos)} / ${fmt(duration)}`;
        scroll.max = String(Math.max(0, duration - view.span)); scroll.value = String(view.t0);
      }

      // ── Ascolto ──
      function applyListen() {
        player.muted = new Set(); player.solo = new Set();
        if (listen === "notes") player.keys.forEach((k) => player.muted.add(k));
        else player.solo.add(key);
        player.applyGains(); player.emit();
      }
      function stopVoices() { for (const o of voices) { try { o.stop(); } catch (e) { /* già finita */ } } voices = []; scheduled = new Set(); }
      function schedule() {
        if (!player.playing || listen === "track" || !ed || !player.ctx) { lastPos = -1; return; }
        const pos = player.position;
        if (pos < lastPos - 0.05) { stopVoices(); }
        lastPos = pos;
        const now = player.ctx.currentTime, ahead = 0.3, out = player.master || player.ctx.destination;
        for (const n of ed.notes) {
          if (n.start < pos - 0.01 || n.start > pos + ahead || scheduled.has(n.id)) continue;
          scheduled.add(n.id);
          const when = now + Math.max(0, (n.start - pos) / player.rate);
          voices.push(voice(player.ctx, out, n.pitch + (player.semitones || 0), when, (n.end - n.start) / player.rate, n.velocity, sound));
        }
        if (voices.length > 400) voices = voices.slice(-200);
      }
      function loop() {
        schedule();
        // La testina in vista: se esce a destra, la vista la segue
        if (player.playing && !drag) { const p = player.position; if (p > view.t0 + view.span * 0.92 || p < view.t0) { view.t0 = p - view.span * 0.1; clampView(); } }
        draw();
        raf = requestAnimationFrame(loop);
      }
      function toggle() {
        if (player.playing) { player.pause(); stopVoices(); }
        else { stopVoices(); player.play(player.position >= duration - 0.05 ? 0 : player.position, { counting: false }); }
        info();
      }

      // ── Modifiche ──
      let saveTimer = 0;
      function changed() {
        info(); draw();
        clearTimeout(saveTimer);
        saveTimer = setTimeout(() => store(cur, key, { version: 1, detected: ed.detected, edited: ed.edited ? ed.list() : null }).catch(() => status("Non riesco a salvare le note")), 400);
      }
      const hit = (x, y) => {
        if (!ed) return null;
        const t = tOf(x), p = pOf(y);
        for (let i = ed.notes.length - 1; i >= 0; i--) {
          const n = ed.notes[i];
          if (n.pitch === p && t >= n.start && t <= n.end) return { n, edge: xOf(n.end) - x <= 6 };
        }
        return null;
      };
      cv.addEventListener("pointerdown", (e) => {
        if (!ed) return;
        cv.focus(); cv.setPointerCapture(e.pointerId);
        const r = cv.getBoundingClientRect(), x = e.clientX - r.left, y = e.clientY - r.top;
        if (x < KEYW) { if (player.ctx) voice(player.ctx, player.master || player.ctx.destination, pOf(y), player.ctx.currentTime, 0.4, 100, sound); return; }
        const h = hit(x, y);
        if (h) {
          if (!sel.has(h.n.id)) { if (!e.shiftKey) sel = new Set(); sel.add(h.n.id); }
          drag = { kind: h.edge ? "resize" : "move", id: h.n.id, x0: x, y0: y, t0: tOf(x), p0: pOf(y), before: ed.notes.map((n) => ({ ...n })), moved: false };
          if (player.ctx) voice(player.ctx, player.master || player.ctx.destination, h.n.pitch, player.ctx.currentTime, 0.25, h.n.velocity, sound);
        } else {
          if (!e.shiftKey) sel = new Set();
          drag = { kind: "rect", x0: x, y0: y, x1: x, y1: y };
        }
        info(); draw();
      });
      cv.addEventListener("pointermove", (e) => {
        const r = cv.getBoundingClientRect(), x = e.clientX - r.left, y = e.clientY - r.top;
        if (!drag) { const h = hit(x, y); cv.style.cursor = x < KEYW ? "pointer" : h ? (h.edge ? "ew-resize" : "grab") : "crosshair"; return; }
        if (drag.kind === "rect") { drag.x1 = x; drag.y1 = y; draw(); return; }
        // Durante il trascinamento si riparte sempre dalle note di prima: un solo passo per «Annulla»
        const g = e.altKey ? null : grid16;
        const hist = ed.history.slice();
        ed.notes = drag.before.map((n) => ({ ...n }));
        ed.history = hist;
        if (drag.kind === "move") ed.move([...sel], tOf(x) - drag.t0, pOf(y) - drag.p0, g);
        else ed.resize(drag.id, tOf(x), g);
        if (!drag.moved) drag.moved = true; else ed.history.pop();
        draw();
      });
      cv.addEventListener("pointerup", () => {
        if (!drag) return;
        if (drag.kind === "rect") {
          const ids = ed.within(tOf(drag.x0), tOf(drag.x1), pOf(drag.y0), pOf(drag.y1));
          ids.forEach((id) => sel.add(id));
          drag = null; info(); draw(); return;
        }
        const moved = drag.moved;
        drag = null;
        if (moved) changed(); else { info(); draw(); }
      });
      cv.addEventListener("dblclick", (e) => {
        if (!ed) return;
        const r = cv.getBoundingClientRect(), x = e.clientX - r.left, y = e.clientY - r.top;
        if (x < KEYW || hit(x, y)) return;
        const id = ed.add(tOf(x), pOf(y), e.altKey ? null : grid16);
        sel = new Set([id]);
        changed();
      });
      cv.addEventListener("wheel", (e) => {
        e.preventDefault();
        if (e.ctrlKey) { const r = cv.getBoundingClientRect(), t = tOf(e.clientX - r.left); zoom(e.deltaY > 0 ? 1.25 : 0.8, t); return; }
        if (e.shiftKey) { view.t0 += (e.deltaY / 400) * view.span; clampView(); draw(); return; }
        const d = Math.sign(e.deltaY) * 2; view.lo -= d; view.hi -= d; clampView(); draw();
      }, { passive: false });
      scroll.addEventListener("input", () => { view.t0 = +scroll.value; draw(); });
      function zoom(f, at) {
        const t = at == null ? view.t0 + view.span / 2 : at, k = (t - view.t0) / view.span;
        view.span *= f; clampView(); view.t0 = t - k * view.span; clampView(); draw();
      }
      sheet.addEventListener("click", (e) => {
        const b = e.target.closest("[data-p], [data-p-listen]");
        if (!b) return;
        if (b.dataset.pListen) { listen = b.dataset.pListen; applyListen(); if (listen === "track") stopVoices(); info(); return; }
        const act = b.dataset.p;
        if (act === "play") toggle();
        else if (act === "zoom-in") zoom(0.5);
        else if (act === "zoom-out") zoom(2);
        else if (act === "undo" && ed) { ed.undo(); sel = new Set(); changed(); }
        else if (act === "reset" && ed) { ed.reset(); sel = new Set(); changed(); }
        else if (act === "file") saveFile();
      });
      sheet.querySelector("#p-sound").addEventListener("change", (e) => { sound = e.target.value; Prefs.set("pianoSound", sound); });

      async function saveFile() {
        if (!ed) return;
        const shift = player.semitones || 0, name = `${cur.meta.title} – ${stem.name}${Transpose.suffix(shift)}`;
        const list = ed.list().map((n) => ({ ...n, pitch: Math.max(0, Math.min(127, n.pitch + shift)) }));
        const path = `${cur.folder}/${name}.mid`;
        await Bridge.writeFile(path, IsoLR.Midi.MidiFile.data(list, { bpm: a.bpm || 120, program: IsoLR.Midi.MidiFile.program(key), name }));
        Bridge.reveal(path);
        status(`Salvato «${name}.mid»: trascinalo da Esplora file nel tuo programma musicale.`);
      }

      const keys = (e) => {
        if (e.target.closest("input, select, textarea")) return;
        if (e.key === " ") { e.preventDefault(); e.stopPropagation(); toggle(); }
        else if ((e.key === "Delete" || e.key === "Backspace") && sel.size && ed) { e.preventDefault(); e.stopPropagation(); ed.remove([...sel]); sel = new Set(); changed(); }
        else if (e.ctrlKey && e.key.toLowerCase() === "z" && ed) { e.preventDefault(); e.stopPropagation(); ed.undo(); sel = new Set(); changed(); }
        else if (e.ctrlKey && e.key.toLowerCase() === "a" && ed) { e.preventDefault(); e.stopPropagation(); sel = new Set(ed.notes.map((n) => n.id)); info(); draw(); }
        else if (e.ctrlKey && (e.key === "+" || e.key === "=")) { e.preventDefault(); zoom(0.5); }
        else if (e.ctrlKey && e.key === "-") { e.preventDefault(); zoom(2); }
        else if ((e.key === "ArrowUp" || e.key === "ArrowDown") && sel.size && ed) { e.preventDefault(); ed.move([...sel], 0, e.key === "ArrowUp" ? (e.shiftKey ? 12 : 1) : (e.shiftKey ? -12 : -1)); changed(); }
      };
      document.addEventListener("keydown", keys, true);
      const ro = new ResizeObserver(() => draw()); ro.observe(cv);
      cleanup = () => { cancelAnimationFrame(raf); clearTimeout(saveTimer); ro.disconnect(); document.removeEventListener("keydown", keys, true); stopVoices(); };
      sheet.api = {
        get editor() { return ed; }, get listen() { return listen; },
        setListen: (l) => { listen = l; applyListen(); info(); }, saveFile,
        edit: (fn) => { fn(ed); changed(); },
        select: (ids) => { sel = new Set(ids); info(); draw(); },
      };
      applyListen();
      info(); draw(); loop();
      try {
        const d = await notesOf(cur, key, status);
        ed = new N.Editor(d.detected, d.edited);
        const [lo, hi] = N.range(ed.notes);
        view.lo = lo; view.hi = Math.max(hi, lo + Math.min(48, Math.max(24, Math.floor(cv.clientHeight / 9))));
        clampView();
        status(ed.notes.length ? "" : "Nessuna nota trovata in questa traccia: aggiungine con un doppio clic.");
        info(); draw();
      } catch (e) {
        status("Non riesco a trovare le note: " + (e.message || e));
      }
    }, () => {
      if (cleanup) cleanup();
      cleanup = null;
      player.pause();
      player.muted = saved.muted; player.solo = saved.solo; player.applyGains(); player.emit();
      IsoApp.transport();
    });
  }
  let cleanup = null;

  window.PianoRoll = { open, edited, SOUNDS };
})();
