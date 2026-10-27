// Warp e Rimonta, come Sources/WarpView.swift e Sources/ArrangeView.swift sul Mac.
// Warp: la forma d'onda con un segnaposto per battuta; si trascinano, se ne aggiungono (doppio clic) e
// tolgono (Canc), si ascolta con il metronomo; «Salva la griglia» li usa per metronomo, parti e A–B;
// «Crea versione a tempo» stira tutte le tracce (Signalsmith) a un BPM fisso in una canzone nuova.
// Rimonta: la canzone come fila di blocchi (le sue parti) da dividere sulle battute, spostare, duplicare,
// togliere; si ascolta il risultato e «Crea versione» lo salva come canzone nuova. Le regole sono in
// core/warp.js e core/arrange.js.
/* global Bridge, Encode, Separation, MixPlayer, SignalsmithStretch, IsoLR, IsoApp, Icon, IconFill */
(function () {
  "use strict";
  const RATE = 44100, HOP = 110;                    // inviluppo: un punto ogni 110 campioni (circa 400 al secondo)
  const ENV_RATE = RATE / HOP;
  const W = IsoLR.Warp, A = IsoLR.Arrange;
  const fmt = (t) => IsoApp.fmt(t), esc = (s) => IsoApp.esc(s);
  const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();

  /** Una traccia stirata con la mappa del tempo: Signalsmith, un tratto alla volta. Ogni tratto si programma
   *  quando il calcolo arriva al suo inizio (suspend): programmato prima, cancellerebbe quelli dopo. */
  async function renderWarp(ch, map, duration) {
    const segs = map.segments(duration), len = Math.max(1, Math.round(map.length(duration) * RATE));
    const off = new OfflineAudioContext(2, len, RATE);
    const node = await SignalsmithStretch(off);
    node.connect(off.destination);
    await node.addBuffers([ch[0], ch[1] || ch[0]]);
    await node.schedule({ active: true, input: segs[0].srcStart, outputTime: 0, rate: segs[0].rate });
    const quantum = 128 / RATE;
    let last = 0;
    for (const s of segs.slice(1)) {
      const at = Math.ceil(s.dstStart / quantum - 1e-9) * quantum;
      if (at <= last || at >= len / RATE) continue;
      last = at;
      off.suspend(at).then(async () => { await node.schedule({ active: true, input: s.srcStart, outputTime: s.dstStart, rate: s.rate }); off.resume(); });
    }
    const r = await off.startRendering();
    return [r.getChannelData(0), r.getChannelData(1)];
  }

  /** Le tracce del mixer sommate (con i volumi che si sentono), oppure solo quelle scelte. */
  function sumTracks(player, keys, withGains) {
    const n = Math.round(player.duration * RATE), out = [new Float32Array(n), new Float32Array(n)];
    for (const k of keys) {
      const b = player.buffers[k], g = withGains ? player.effectiveGain(k) : 1;
      if (!b || !g) continue;
      for (let c = 0; c < 2; c++) { const d = b.getChannelData(c), o = out[c]; for (let i = 0; i < Math.min(n, d.length); i++) o[i] += d[i] * g; }
    }
    return out;
  }
  /** Il massimo di ogni gruppo di HOP campioni, normalizzato a 1. */
  function envelope(ch) {
    const n = Math.floor(ch[0].length / HOP), env = new Float32Array(n);
    let top = 0;
    for (let p = 0; p < n; p++) {
      let m = 0;
      for (let i = p * HOP, e = i + HOP; i < e; i++) { const v = Math.max(Math.abs(ch[0][i]), Math.abs(ch[1][i])); if (v > m) m = v; }
      env[p] = m; if (m > top) top = m;
    }
    if (top > 0) for (let p = 0; p < n; p++) env[p] /= top;
    return env;
  }
  const envMax = (env, a, b) => { let m = 0; for (let i = Math.max(0, Math.floor(a)), e = Math.min(env.length, Math.max(Math.floor(a) + 1, Math.floor(b))); i < e; i++) if (env[i] > m) m = env[i]; return m; };

  async function readStem(cur, s) { return Encode.readWav(await Bridge.readFile(cur.folder + "/" + s.file)); }

  /** Salva la versione nuova, la apre e chiude l'editor. */
  async function finish(cur, title, tracks, info, close, what) {
    const saved = await Separation.saveVersion(cur, title, tracks, info);
    await IsoApp.refreshLibrary();
    close();
    await IsoApp.openEntry(saved);
    IsoApp.toast(`${what}: «${title}» è nella libreria`);
  }

  // ════════════════════════ Warp ════════════════════════
  function warp(cur, player) {
    if (!cur || !player.keys.length) return;
    player.pause();
    const a = cur.meta.analysis || {}, s0 = a.structure;
    const duration = player.duration, bpb = (s0 && s0.beatsPerBar) || 4;
    const initial = () => {
      const d = W.downbeats(s0);
      if (d.length >= 2) return d;
      const bar = (60 * bpb) / (a.bpm || 120), out = [];
      for (let t = 0; t < duration; t += bar) out.push(+t.toFixed(4));
      return out;
    };
    let marks = initial(), sel = -1, cursor = 0, drag = -1, busy = false;
    const drumKeys = player.keys.filter((k) => MixPlayer.INSTRUMENTS.drums.includes(k));
    const envs = {};
    let source = drumKeys.length ? "drums" : "mix";
    const env = () => (envs[source] = envs[source] || envelope(sumTracks(player, source === "drums" ? drumKeys : player.keys, false)));
    const view = { t0: 0, span: Math.min(duration, 30) };
    const saved = { structure: player.structure, metronome: player.metronome, bpm: player.bpm };
    const grid = () => Object.assign({}, s0 || { sections: [] }, W.beatsFromMarks(marks, bpb, duration), { beatsPerBar: bpb });
    let raf = 0;

    const html = `<div class="ed-head"><div><h2>Warp</h2><div class="muted">Trascina i segnaposto sul primo battito di ogni battuta. Doppio clic ne aggiunge uno, Canc toglie quello scelto.</div></div></div>
      <div class="ed-bar">
        <button class="play small" data-w="play" title="Ascolta dal cursore con il metronomo (spazio)">${IconFill("play")}</button>
        <span class="time" id="w-time"></span>
        <div class="seg" ${drumKeys.length ? "" : "hidden"}><button data-w-src="drums">Batteria</button><button data-w-src="mix">Mix</button></div>
        <div class="grow"></div>
        <button class="btn small icon" data-w="zoom-out" title="Allontana (Ctrl −)">${Icon("zoomOut")}</button>
        <button class="btn small icon" data-w="zoom-in" title="Avvicina (Ctrl +)">${Icon("zoomIn")}</button>
        <button class="btn small" data-w="all" title="Tutta la canzone">Tutta</button>
        <button class="btn small" data-w="reset" title="Torna ai segnaposto trovati da IsoLR">${Icon("reset")}Ripristina</button>
      </div>
      <canvas class="wcanvas" id="w-canvas" tabindex="0" aria-label="Forma d'onda con i segnaposto delle battute"></canvas>
      <input type="range" id="w-scroll" min="0" max="0" step="0.01" value="0" aria-label="Scorri la canzone">
      <div class="ed-bar"><span id="w-info" class="muted"></span></div>
      <div class="ed-foot">
        <div class="ed-bar"><b>Metti a tempo</b>
          <input type="number" class="num" id="w-bpm" min="40" max="240" step="1" value="${Math.round(a.bpm || W.bpmOf(marks, bpb) || 120)}" aria-label="BPM"> BPM
          <button class="btn" data-w="tempo" title="Una canzone nuova con ogni battuta lunga uguale (il tono non cambia)">Crea versione a tempo</button></div>
        <div class="grow"></div>
        <button class="btn" data-close>Chiudi</button>
        <button class="btn prominent" data-w="save" title="Metronomo, parti e passaggio A–B useranno questi segnaposto">Salva la griglia</button>
      </div>
      <div class="ed-status" id="w-status"></div>`;

    window.Sheets.open(html, (sheet, close) => {
      sheet.classList.add("wide");
      const cv = sheet.querySelector("#w-canvas"), scroll = sheet.querySelector("#w-scroll");
      const status = (t) => { sheet.querySelector("#w-status").textContent = t || ""; };
      const xOf = (t) => ((t - view.t0) / view.span) * cv.clientWidth;
      const tOf = (x) => view.t0 + (x / cv.clientWidth) * view.span;
      const clampView = () => { view.span = Math.max(2, Math.min(duration, view.span)); view.t0 = Math.max(0, Math.min(duration - view.span, view.t0)); };

      function info() {
        const bpm = +sheet.querySelector("#w-bpm").value;
        const now = W.bpmOf(marks, bpb);
        let txt = `${marks.length} segnaposto · ${now ? now.toFixed(1).replace(".", ",") + " BPM in media" : "—"}`;
        if (bpm >= 40 && marks.length >= 2) txt += ` · a ${bpm} BPM la canzone dura ${fmt(W.WarpMap.toTempo(marks, bpm, bpb).length(duration))} (ora ${fmt(duration)})`;
        sheet.querySelector("#w-info").textContent = txt;
        sheet.querySelectorAll("[data-w-src]").forEach((b) => b.classList.toggle("on", b.dataset.wSrc === source));
      }
      function draw() {
        const dpr = devicePixelRatio || 1, w = (cv.width = Math.max(1, cv.clientWidth * dpr)), h = (cv.height = cv.clientHeight * dpr);
        const g = cv.getContext("2d"), e = env(), top = 20 * dpr, bottom = 16 * dpr, mid = top + (h - top - bottom) / 2, amp = (h - top - bottom) * 0.48;
        g.clearRect(0, 0, w, h);
        g.fillStyle = css(source === "drums" ? "--c-drums" : "--brass");
        for (let px = 0; px < w; px += dpr) {
          const ta = view.t0 + (px / w) * view.span, tb = ta + (dpr / w) * view.span;
          const m = envMax(e, ta * ENV_RATE, tb * ENV_RATE), bh = Math.max(dpr, m * amp * 2);
          g.fillRect(px, mid - bh / 2, Math.max(1, dpr * 0.8), bh);
        }
        // I battiti (sottili) e le battute (i segnaposto)
        const beats = W.beatsFromMarks(marks, bpb, duration).beats;
        g.fillStyle = css("--stroke2");
        for (const t of beats) { const x = xOf(t) * dpr; if (x >= 0 && x <= w) g.fillRect(x, top, dpr, h - top - bottom); }
        const every = Math.max(1, Math.ceil(28 / Math.max(1, (W.bpmOf(marks, bpb) ? (60 * bpb) / W.bpmOf(marks, bpb) : 2) / view.span * cv.clientWidth)));
        g.font = `600 ${10 * dpr}px ${css("--font")}`; g.textBaseline = "middle"; g.textAlign = "center";
        marks.forEach((t, i) => {
          const x = xOf(t) * dpr;
          if (x < -20 * dpr || x > w + 20 * dpr) return;
          const color = i === sel ? css("--red") : css("--brass");
          g.fillStyle = color;
          g.fillRect(x - dpr, top, 2 * dpr, h - top - bottom);
          if (i % every === 0 || i === sel) {
            const label = String(i + 1), bw = Math.max(16 * dpr, g.measureText(label).width + 8 * dpr);
            const cx = Math.max(bw / 2, Math.min(w - bw / 2, x));        // l'etichetta resta dentro anche ai bordi
            g.beginPath(); g.roundRect(cx - bw / 2, 2 * dpr, bw, 15 * dpr, 4 * dpr); g.fill();
            g.fillStyle = "#fff"; g.fillText(label, cx, 9.5 * dpr);
          } else { g.beginPath(); g.moveTo(x - 4 * dpr, top - 6 * dpr); g.lineTo(x + 4 * dpr, top - 6 * dpr); g.lineTo(x, top); g.fill(); }
        });
        // Righello in basso
        const step = [0.5, 1, 2, 5, 10, 15, 30, 60].find((s) => (s / view.span) * cv.clientWidth >= 60) || 60;
        g.fillStyle = css("--muted"); g.textAlign = "left";
        for (let t = Math.ceil(view.t0 / step) * step; t <= view.t0 + view.span; t += step) {
          const x = xOf(t) * dpr;
          g.fillRect(x, h - bottom, dpr, 4 * dpr);
          g.fillText(step < 1 ? t.toFixed(1).replace(".", ",") + " s" : fmt(t), x + 3 * dpr, h - bottom / 2 + dpr);
        }
        // Il cursore (o la testina mentre suona)
        const pos = player.playing ? player.position : cursor;
        g.fillStyle = css("--ink");
        g.fillRect(xOf(pos) * dpr - dpr / 2, top - 4 * dpr, 1.5 * dpr, h - top - bottom + 4 * dpr);
        scroll.max = String(Math.max(0, duration - view.span)); scroll.value = String(view.t0);
        sheet.querySelector("#w-time").textContent = `${fmt(pos)} / ${fmt(duration)}`;
        const pb = sheet.querySelector('[data-w="play"]'); if (pb) pb.innerHTML = IconFill(player.playing ? "pause" : "play");
      }
      const changed = () => { if (player.playing) player.structure = grid(); draw(); info(); };
      function loop() {
        if (!sheet.isConnected) return;
        if (player.playing) {
          player.tick();
          const p = player.position;
          if (p > view.t0 + view.span * 0.92 || p < view.t0) { view.t0 = p - view.span * 0.1; clampView(); }
          draw();
        }
        raf = requestAnimationFrame(loop);
      }
      function play() {
        if (player.playing) { player.pause(); cursor = player.position; return draw(); }
        player.structure = grid(); player.metronome = true;
        player.play(cursor, { counting: false });
      }
      const nearMark = (x) => { let best = -1, d = 7; marks.forEach((t, i) => { const dd = Math.abs(xOf(t) - x); if (dd < d) { d = dd; best = i; } }); return best; };

      cv.addEventListener("pointerdown", (e) => {
        cv.focus();
        const x = e.offsetX, i = nearMark(x);
        if (i >= 0) { sel = i; drag = i; cv.setPointerCapture(e.pointerId); }
        else { sel = -1; cursor = Math.max(0, Math.min(duration, tOf(x))); if (player.playing) player.play(cursor, { counting: false }); }
        draw();
      });
      cv.addEventListener("pointermove", (e) => {
        if (drag < 0) { cv.style.cursor = nearMark(e.offsetX) >= 0 ? "ew-resize" : "crosshair"; return; }
        const lo = drag > 0 ? marks[drag - 1] + 0.1 : 0, hi = drag < marks.length - 1 ? marks[drag + 1] - 0.1 : duration;
        marks[drag] = +Math.max(lo, Math.min(hi, tOf(e.offsetX))).toFixed(4);
        changed();
      });
      cv.addEventListener("pointerup", () => { drag = -1; });
      cv.addEventListener("dblclick", (e) => {
        const t = tOf(e.offsetX);
        if (marks.some((m) => Math.abs(m - t) < 0.1)) return;
        marks.push(+t.toFixed(4)); marks.sort((x, y) => x - y); sel = marks.indexOf(+t.toFixed(4));
        changed();
      });
      cv.addEventListener("wheel", (e) => {
        e.preventDefault();
        if (e.ctrlKey) {
          const t = tOf(e.offsetX), f = Math.exp(e.deltaY * 0.002);
          view.span *= f; view.t0 = t - (e.offsetX / cv.clientWidth) * view.span;
        } else view.t0 += ((e.deltaX || e.deltaY) / cv.clientWidth) * view.span;
        clampView(); draw();
      }, { passive: false });
      scroll.addEventListener("input", () => { view.t0 = +scroll.value; clampView(); draw(); });
      const zoom = (f) => { const c = view.t0 + view.span / 2; view.span *= f; view.t0 = c - view.span / 2; clampView(); draw(); };

      sheet.addEventListener("click", async (e) => {
        const b = e.target.closest("[data-w],[data-w-src]");
        if (!b || busy) return;
        if (b.dataset.wSrc) { source = b.dataset.wSrc; draw(); info(); return; }
        switch (b.dataset.w) {
          case "play": return play();
          case "zoom-in": return zoom(0.5);
          case "zoom-out": return zoom(2);
          case "all": view.t0 = 0; view.span = duration; return draw();
          case "reset": marks = initial(); sel = -1; return changed();
          case "save": return saveGrid();
          case "tempo": return makeTempo();
        }
      });
      sheet.querySelector("#w-bpm").addEventListener("input", info);

      async function saveGrid() {
        if (marks.length < 2) return status("Servono almeno due segnaposto");
        cur.meta.analysis = W.withGrid(cur.meta.analysis || {}, marks, duration);
        await Bridge.writeText(`${cur.folder}/isolr.json`, JSON.stringify(cur.meta));
        saved.structure = cur.meta.analysis.structure; saved.bpm = cur.meta.analysis.bpm;
        close();
        IsoApp.render();
        IsoApp.toast("Griglia salvata: metronomo, parti e passaggio A–B la usano già");
      }
      async function makeTempo() {
        const bpm = Math.round(+sheet.querySelector("#w-bpm").value);
        if (!(bpm >= 40 && bpm <= 240)) return status("Scegli un tempo tra 40 e 240 BPM");
        if (marks.length < 2) return status("Servono almeno due segnaposto");
        busy = true; player.pause();
        sheet.querySelectorAll("button").forEach((x) => (x.disabled = true));
        try {
          const map = W.WarpMap.toTempo(marks, bpm, bpb), tracks = {};
          const stems = cur.meta.stems;
          for (let i = 0; i < stems.length; i++) {
            status(`Metto a tempo «${stems[i].name}»… ${i + 1}/${stems.length}`);
            tracks[stems[i].key] = await renderWarp(await readStem(cur, stems[i]), map, duration);
          }
          status("Salvo la versione a tempo…");
          const analysis = W.mapAnalysis(W.withGrid(cur.meta.analysis || {}, marks, duration), map, bpm, duration);
          await finish(cur, `${cur.meta.title} (${bpm} BPM)`, tracks, { duration: map.length(duration), analysis, kind: "warp" }, close, "Versione a tempo");
        } catch (err) {
          busy = false; sheet.querySelectorAll("button").forEach((x) => (x.disabled = false));
          status("Non riuscito: " + (err.message || err));
        }
      }

      const keys = (e) => {
        if (e.target.matches("input,select,textarea")) return;
        if (e.code === "Space") { e.preventDefault(); play(); }
        else if ((e.key === "Delete" || e.key === "Backspace") && sel >= 0 && marks.length > 2) { e.preventDefault(); marks.splice(sel, 1); sel = -1; changed(); }
        else if (e.ctrlKey && (e.key === "+" || e.key === "=")) { e.preventDefault(); zoom(0.5); }
        else if (e.ctrlKey && e.key === "-") { e.preventDefault(); zoom(2); }
        else if (e.key === "ArrowLeft" || e.key === "ArrowRight") {
          e.preventDefault();
          const d = (e.key === "ArrowLeft" ? -1 : 1) * (e.shiftKey ? 0.001 : 0.01);
          if (sel >= 0) { const lo = sel > 0 ? marks[sel - 1] + 0.1 : 0, hi = sel < marks.length - 1 ? marks[sel + 1] - 0.1 : duration; marks[sel] = +Math.max(lo, Math.min(hi, marks[sel] + d)).toFixed(4); changed(); }
        }
      };
      document.addEventListener("keydown", keys, true);
      const ro = new ResizeObserver(() => draw()); ro.observe(cv);
      warpCleanup = () => { cancelAnimationFrame(raf); ro.disconnect(); document.removeEventListener("keydown", keys, true); };
      sheet.api = { get marks() { return marks; }, set: (m) => { marks = m.slice(); changed(); }, makeTempo, saveGrid };
      draw(); info(); loop();
    }, () => {
      if (warpCleanup) warpCleanup();
      warpCleanup = null;
      player.pause();
      player.structure = saved.structure; player.metronome = saved.metronome; player.bpm = saved.bpm;
      IsoApp.transport();
    });
  }
  let warpCleanup = null;

  // ════════════════════════ Rimonta ════════════════════════
  function arrange(cur, player) {
    if (!cur || !player.keys.length) return;
    player.pause();
    const a = cur.meta.analysis || {}, s = a.structure;
    const duration = player.duration, downs = W.downbeats(s);
    const start = () => A.fromSections(s && s.sections, duration);
    let blocks = start(), sel = 0, undo = [], pos = 0, busy = false;
    const mix = sumTracks(player, player.keys, true), env = envelope(mix);
    const groupColor = (g) => (g < 0 ? "--faint" : ["--c-vocals", "--c-guitar", "--c-bass", "--c-piano", "--c-other", "--c-drums"][g % 6]);
    const pb = { src: null, buffer: null, startCtx: 0, startPos: 0, playing: false, dirty: true };
    let raf = 0;

    const html = `<div class="ed-head"><div><h2>Rimonta</h2><div class="muted">Trascina i blocchi per cambiare l'ordine. Dividi sulla battuta, duplica o togli una parte; poi crea la versione nuova.</div></div></div>
      <div class="ed-bar">
        <button class="play small" data-r="play" title="Ascolta la versione rimontata (spazio)">${IconFill("play")}</button>
        <span class="time" id="r-time"></span>
        <div class="grow"></div>
        <button class="btn small" data-r="split" title="Dividi il blocco scelto sulla battuta più vicina alla testina (S)">${Icon("scissors")}Dividi</button>
        <button class="btn small" data-r="dup" title="Duplica il blocco scelto (Ctrl+D)">${Icon("copy")}Duplica</button>
        <button class="btn small" data-r="del" title="Togli il blocco scelto (Canc)">${Icon("trash")}Togli</button>
        <button class="btn small" data-r="undo" title="Annulla (Ctrl+Z)">${Icon("undo")}Annulla</button>
        <button class="btn small" data-r="reset" title="Torna alla canzone com'era">${Icon("reset")}Ripristina</button>
      </div>
      <div class="arr-strip" id="r-strip"></div>
      <div class="ed-bar"><span id="r-info" class="muted"></span></div>
      <div class="ed-foot"><div class="grow"></div>
        <button class="btn" data-close>Chiudi</button>
        <button class="btn prominent" data-r="make" title="Una canzone nuova, con tutte le tracce rimontate così">Crea versione</button></div>
      <div class="ed-status" id="r-status"></div>`;

    window.Sheets.open(html, (sheet, close) => {
      sheet.classList.add("wide");
      const strip = sheet.querySelector("#r-strip");
      const status = (t) => { sheet.querySelector("#r-status").textContent = t || ""; };
      const total = () => A.total(blocks);
      const position = () => (pb.playing ? Math.min(total(), pb.startPos + player.ctx.currentTime - pb.startCtx) : pos);

      function edit(next, nextSel) {
        if (next === blocks) return;
        undo.push({ blocks, sel }); if (undo.length > 100) undo.shift();
        blocks = next; sel = Math.max(0, Math.min(blocks.length - 1, nextSel ?? sel));
        pos = Math.min(pos, total());
        pb.dirty = true;
        if (pb.playing) { const p = Math.min(position(), total() - 0.05); stop(); pos = p; play(); }
        drawStrip();
      }
      function drawStrip() {
        const l = A.layout(blocks);
        strip.innerHTML = l.map((b, i) => `<div class="arr-block ${i === sel ? "on" : ""}" draggable="true" data-i="${i}" style="--len:${(b.dstEnd - b.dstStart).toFixed(3)};--g:var(${groupColor(b.group)})" title="${esc(b.label)} · ${fmt(b.srcStart)}–${fmt(b.srcEnd)} dell'originale">
            <b>${esc(b.label)}</b><span>${fmt(b.dstEnd - b.dstStart)}</span><canvas></canvas></div>`).join("") + `<span class="arr-head" id="r-head"></span>`;
        const dpr = devicePixelRatio || 1, color = (g) => css(groupColor(g));
        strip.querySelectorAll(".arr-block").forEach((el, i) => {
          const c = el.querySelector("canvas"), b = blocks[i], w = (c.width = Math.max(1, c.clientWidth * dpr)), h = (c.height = c.clientHeight * dpr), g = c.getContext("2d");
          g.fillStyle = color(b.group);
          const span = b.srcEnd - b.srcStart;
          for (let px = 0; px < w; px += 2 * dpr) {
            const ta = b.srcStart + (px / w) * span, m = envMax(env, ta * ENV_RATE, (ta + (2 * dpr * span) / w) * ENV_RATE), bh = Math.max(dpr, m * h);
            g.fillRect(px, (h - bh) / 2, dpr, bh);
          }
        });
        const orig = duration, now = total();
        sheet.querySelector("#r-info").textContent = `${blocks.length} ${blocks.length === 1 ? "blocco" : "blocchi"} · ${fmt(now)}${Math.abs(now - orig) > 0.5 ? ` (prima ${fmt(orig)})` : ""} · i tagli cadono sul primo battito della battuta`;
        sheet.querySelector('[data-r="undo"]').disabled = !undo.length;
        sheet.querySelector('[data-r="del"]').disabled = blocks.length < 2;
        head();
      }
      function head() {
        const t = position(), l = A.layout(blocks);
        let i = l.findIndex((b) => t < b.dstEnd); if (i < 0) i = l.length - 1;
        const el = strip.querySelectorAll(".arr-block")[i], h = sheet.querySelector("#r-head");
        if (el && h) h.style.left = `${el.offsetLeft + ((t - l[i].dstStart) / Math.max(0.001, l[i].dstEnd - l[i].dstStart)) * el.offsetWidth}px`;
        sheet.querySelector("#r-time").textContent = `${fmt(t)} / ${fmt(total())}`;
        const b = sheet.querySelector('[data-r="play"]'); if (b) b.innerHTML = IconFill(pb.playing ? "pause" : "play");
      }
      function stop() { if (pb.src) try { pb.src.stop(); pb.src.disconnect(); } catch {} pb.src = null; pb.playing = false; }
      async function play() {
        await player.ensureCtx();
        if (pb.dirty || !pb.buffer) {
          const out = A.render(mix, blocks), b = player.ctx.createBuffer(2, Math.max(1, out[0].length), RATE);
          b.copyToChannel(out[0], 0); b.copyToChannel(out[1], 1);
          pb.buffer = b; pb.dirty = false;
        }
        if (pos >= total() - 0.05) pos = 0;
        const src = player.ctx.createBufferSource();
        src.buffer = pb.buffer; src.connect(player.master);
        const when = player.ctx.currentTime + 0.03;
        src.start(when, pos);
        Object.assign(pb, { src, startCtx: when, startPos: pos, playing: true });
        head();
      }
      function toggle() { if (pb.playing) { pos = position(); stop(); head(); } else play(); }
      function loop() {
        if (!sheet.isConnected) return;
        if (pb.playing) { if (position() >= total() - 0.01) { stop(); pos = 0; } head(); }
        raf = requestAnimationFrame(loop);
      }
      const split = () => { const l = A.layout(blocks), b = l[sel]; if (!b) return; const t = pos >= b.dstStart && pos < b.dstEnd ? pos : (b.dstStart + b.dstEnd) / 2; const next = A.split(blocks, sel, b.srcStart + t - b.dstStart, downs); if (next === blocks) return status("Qui non si può dividere: il taglio cadrebbe troppo vicino al bordo"); status(""); edit(next, sel + 1); };
      const dup = () => edit(A.duplicate(blocks, sel), sel + 1);
      const del = () => { if (blocks.length > 1) edit(A.remove(blocks, sel), Math.min(sel, blocks.length - 2)); };
      const back = () => { const u = undo.pop(); if (!u) return; blocks = u.blocks; sel = u.sel; pb.dirty = true; if (pb.playing) { stop(); } pos = Math.min(pos, total()); drawStrip(); };

      strip.addEventListener("click", (e) => {
        const el = e.target.closest(".arr-block"); if (!el) return;
        sel = +el.dataset.i;
        const l = A.layout(blocks)[sel], r = el.getBoundingClientRect();
        pos = l.dstStart + Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)) * (l.dstEnd - l.dstStart);
        if (pb.playing) { stop(); play(); }
        drawStrip();
      });
      let from = -1;
      strip.addEventListener("dragstart", (e) => { const el = e.target.closest(".arr-block"); if (!el) return; from = +el.dataset.i; e.dataTransfer.effectAllowed = "move"; e.dataTransfer.setData("text/plain", String(from)); });
      const dropAt = (e) => { const el = e.target.closest(".arr-block"); if (!el) return null; const r = el.getBoundingClientRect(); return { el, i: +el.dataset.i, after: e.clientX > r.left + r.width / 2 }; };
      strip.addEventListener("dragover", (e) => {
        const d = dropAt(e); if (!d || from < 0) return;
        e.preventDefault();
        strip.querySelectorAll(".drop-before,.drop-after").forEach((x) => x.classList.remove("drop-before", "drop-after"));
        d.el.classList.add(d.after ? "drop-after" : "drop-before");
      });
      strip.addEventListener("dragleave", (e) => { if (!strip.contains(e.relatedTarget)) strip.querySelectorAll(".drop-before,.drop-after").forEach((x) => x.classList.remove("drop-before", "drop-after")); });
      strip.addEventListener("drop", (e) => {
        e.preventDefault();
        const d = dropAt(e); if (!d || from < 0) return;
        let to = d.i + (d.after ? 1 : 0); if (from < to) to--;
        const f = from; from = -1;
        if (to !== f) edit(A.move(blocks, f, to), to); else drawStrip();
      });
      strip.addEventListener("dragend", () => { from = -1; strip.querySelectorAll(".drop-before,.drop-after").forEach((x) => x.classList.remove("drop-before", "drop-after")); });

      sheet.addEventListener("click", async (e) => {
        const b = e.target.closest("[data-r]"); if (!b || busy) return;
        switch (b.dataset.r) {
          case "play": return toggle();
          case "split": return split();
          case "dup": return dup();
          case "del": return del();
          case "undo": return back();
          case "reset": return edit(start(), 0);
          case "make": return make();
        }
      });
      async function make() {
        busy = true; stop();
        sheet.querySelectorAll("button").forEach((x) => (x.disabled = true));
        try {
          const tracks = {}, stems = cur.meta.stems;
          for (let i = 0; i < stems.length; i++) {
            status(`Rimonto «${stems[i].name}»… ${i + 1}/${stems.length}`);
            tracks[stems[i].key] = A.render(await readStem(cur, stems[i]), blocks);
            await new Promise((r) => setTimeout(r, 0));
          }
          status("Salvo la versione nuova…");
          await finish(cur, `${cur.meta.title} (rimontata)`, tracks, { duration: total(), analysis: A.mapAnalysis(cur.meta.analysis, blocks), kind: "arrange" }, close, "Versione rimontata");
        } catch (err) {
          busy = false; sheet.querySelectorAll("button").forEach((x) => (x.disabled = false)); drawStrip();
          status("Non riuscito: " + (err.message || err));
        }
      }
      const keys = (e) => {
        if (e.target.matches("input,select,textarea") || busy) return;
        const k = e.key.toLowerCase();
        if (e.code === "Space") { e.preventDefault(); toggle(); }
        else if (e.ctrlKey && k === "d") { e.preventDefault(); dup(); }
        else if (e.ctrlKey && k === "z") { e.preventDefault(); back(); }
        else if (e.key === "Delete" || e.key === "Backspace") { e.preventDefault(); del(); }
        else if (!e.ctrlKey && k === "s") { e.preventDefault(); split(); }
        else if (e.key === "ArrowLeft" || e.key === "ArrowRight") { e.preventDefault(); sel = Math.max(0, Math.min(blocks.length - 1, sel + (e.key === "ArrowLeft" ? -1 : 1))); drawStrip(); }
      };
      document.addEventListener("keydown", keys, true);
      arrangeCleanup = () => { cancelAnimationFrame(raf); stop(); document.removeEventListener("keydown", keys, true); };
      sheet.api = { get blocks() { return blocks; }, set: (b) => edit(b, 0), make };
      drawStrip(); loop();
    }, () => { if (arrangeCleanup) arrangeCleanup(); arrangeCleanup = null; IsoApp.transport(); });
  }
  let arrangeCleanup = null;

  window.Editors = { warp, arrange, renderWarp };
})();
