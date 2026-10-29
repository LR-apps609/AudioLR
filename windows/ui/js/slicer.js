// Slice to MIDI, come Sources/SliceView.swift sul Mac: una traccia (di serie la batteria) tagliata sui suoi
// colpi. Le fette si vedono sulla forma d'onda (segnaposto da trascinare; doppio clic divide, «Unisci» unisce),
// si suonano con 16 pad (clic, o i tasti 1 2 3 4 / Q W E R / A S D F / Z X C V) e si esportano in una
// cartella: le fette in WAV, un file MIDI che le suona nel ritmo originale (nota 36 = fetta 1) e un LEGGIMI.
// Le regole sono in core/slice.js.
/* global Bridge, Encode, Separation, IsoLR, IsoApp, Icon, IconFill */
(function () {
  "use strict";
  const S = IsoLR.Slice, RATE = 44100;
  const KEYS = ["1", "2", "3", "4", "q", "w", "e", "r", "a", "s", "d", "f", "z", "x", "c", "v"];
  const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  const fmt = (t) => IsoApp.fmt(t), esc = (s) => IsoApp.esc(s);

  /** Le tracce che si possono tagliare: quelle della canzone tranne la base, batteria per prima. */
  function sliceable(cur) {
    const list = cur.meta.stems.filter((s) => s.key !== "instrumental");
    return list.sort((a, b) => (b.key === "drums") - (a.key === "drums"));
  }

  function open(cur, player, startKey) {
    if (!cur || !player.keys.length) return;
    player.pause();
    const stems = sliceable(cur);
    if (!stems.length) return;
    let key = startKey && stems.some((s) => s.key === startKey) ? startKey : stems[0].key;
    let ch = null, env = null, list = [], sel = -1, page = 0, sens = 0.5, drag = -1, raf = 0, busy = false;
    const view = { t0: 0, span: 0 }, lit = new Map();
    let ctx = null;
    const audio = () => { if (!ctx) ctx = new AudioContext({ sampleRate: RATE }); if (ctx.state === "suspended") ctx.resume(); return ctx; };

    const html = `<div class="ed-head"><div><h2>Slice to MIDI</h2><div class="muted">La traccia tagliata sui suoi colpi. Trascina un segnaposto per spostarlo, doppio clic divide una fetta. Suona le fette con i pad o con i tasti 1–4, Q–R, A–F, Z–V.</div></div></div>
      <div class="ed-bar">
        <select class="pop" id="s-stem" aria-label="Traccia da tagliare">${stems.map((s) => `<option value="${s.key}" ${s.key === key ? "selected" : ""}>${esc(s.name)}</option>`).join("")}</select>
        <label class="ed-bar" style="gap:6px"><span class="muted">Sensibilità</span><input type="range" id="s-sens" min="0" max="1" step="0.05" value="${sens}" aria-label="Sensibilità: più alta, più fette"></label>
        <div class="grow"></div>
        <button class="btn small" data-s="merge" title="Unisce la fetta scelta con la successiva">Unisci</button>
        <button class="btn small icon" data-s="zoom-out" title="Allontana">${Icon("zoomOut")}</button>
        <button class="btn small icon" data-s="zoom-in" title="Avvicina">${Icon("zoomIn")}</button>
      </div>
      <canvas class="wcanvas" id="s-canvas" tabindex="0" aria-label="Forma d'onda della traccia con le fette"></canvas>
      <input type="range" id="s-scroll" min="0" max="0" step="0.01" value="0" aria-label="Scorri la traccia">
      <div class="pads-wrap"><button class="btn small icon" data-s="prev" title="Pad precedenti">‹</button><div class="pads" id="s-pads"></div><button class="btn small icon" data-s="next" title="Pad successivi">›</button></div>
      <div class="ed-foot">
        <span id="s-info" class="muted"></span>
        <div class="grow"></div>
        <button class="btn" data-close>Chiudi</button>
        <button class="btn prominent" data-s="export" title="Una cartella con le fette in WAV, il file MIDI e le istruzioni per Ableton e Logic">${Icon("download")}Esporta fette e MIDI</button>
      </div>
      <div class="ed-status" id="s-status"></div>`;

    window.Sheets.open(html, async (sheet, close) => {
      sheet.classList.add("wide");
      const cv = sheet.querySelector("#s-canvas"), scroll = sheet.querySelector("#s-scroll"), pads = sheet.querySelector("#s-pads");
      const status = (t) => { sheet.querySelector("#s-status").textContent = t || ""; };
      const duration = () => (ch ? ch[0].length / RATE : 0);
      const xOf = (t) => ((t - view.t0) / view.span) * cv.clientWidth;
      const tOf = (x) => view.t0 + (x / cv.clientWidth) * view.span;
      const clampView = () => { view.span = Math.max(0.5, Math.min(duration(), view.span)); view.t0 = Math.max(0, Math.min(duration() - view.span, view.t0)); };
      const color = () => css(`--c-${key}`) || css("--brass");

      async function loadStem() {
        busy = true; status("Leggo la traccia…");
        const stem = cur.meta.stems.find((s) => s.key === key);
        ch = Encode.readWav(await Bridge.readFile(cur.folder + "/" + stem.file));
        env = envelope(ch);
        view.t0 = 0; view.span = Math.min(duration(), 20);
        detect();
        busy = false; status("");
      }
      function detect() {
        list = S.slices(S.onsets(ch, RATE, { sensitivity: sens }), ch[0].length, RATE);
        sel = -1; page = 0;
        render();
      }
      function render() { renderPads(); info(); draw(); }

      function info() {
        sheet.querySelector("#s-info").textContent = ch ? `${list.length} fette${sel >= 0 ? ` · scelta la ${sel + 1} (${fmt(list[sel].start / RATE)}, ${Math.round(((list[sel].end - list[sel].start) / RATE) * 1000)} ms)` : ""}` : "";
        sheet.querySelector('[data-s="merge"]').disabled = sel < 0 || sel >= list.length - 1;
        sheet.querySelector('[data-s="prev"]').disabled = page === 0;
        sheet.querySelector('[data-s="next"]').disabled = (page + 1) * 16 >= list.length;
      }

      function renderPads() {
        const c = color();
        pads.innerHTML = Array.from({ length: 16 }, (_, k) => {
          const i = page * 16 + k, ok = i < list.length;
          return `<button class="pad ${i === sel ? "on" : ""}" data-pad="${i}" ${ok ? "" : "disabled"} style="--c:${c}" aria-label="${ok ? `Fetta ${i + 1}` : "Vuoto"}">
            <b>${ok ? i + 1 : ""}</b><small>${ok ? KEYS[k].toUpperCase() : ""}</small></button>`;
        }).join("");
      }

      function play(i) {
        if (!ch || i < 0 || i >= list.length) return;
        const a = audio(), part = S.render(ch, list[i], RATE);
        const b = a.createBuffer(2, part[0].length || 1, RATE);
        b.getChannelData(0).set(part[0]); b.getChannelData(1).set(part[1] || part[0]);
        const src = a.createBufferSource(); src.buffer = b; src.connect(a.destination); src.start();
        lit.set(i, performance.now() + Math.min(400, b.duration * 1000));
        sel = i; if (Math.floor(i / 16) !== page) { page = Math.floor(i / 16); renderPads(); }
        // La fetta in vista sulla forma d'onda
        const t = list[i].start / RATE;
        if (t < view.t0 || t > view.t0 + view.span) { view.t0 = t - view.span * 0.1; clampView(); }
        info();
      }

      function draw() {
        const dpr = devicePixelRatio || 1, w = cv.clientWidth, h = cv.clientHeight;
        if (!w) return;
        if (cv.width !== Math.round(w * dpr) || cv.height !== Math.round(h * dpr)) { cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr); }
        const c = cv.getContext("2d");
        c.setTransform(dpr, 0, 0, dpr, 0, 0);
        c.clearRect(0, 0, w, h);
        if (!env) return;
        const col = color(), mid = h / 2;
        // Fette alterne leggermente colorate, la scelta più piena
        list.forEach((s, i) => {
          const x0 = xOf(s.start / RATE), x1 = xOf(s.end / RATE);
          if (x1 < 0 || x0 > w) return;
          c.fillStyle = col; c.globalAlpha = i === sel ? 0.22 : i % 2 ? 0.07 : 0.03;
          c.fillRect(x0, 0, x1 - x0, h); c.globalAlpha = 1;
        });
        // Forma d'onda
        c.fillStyle = col;
        const per = env.rate, a0 = view.t0 * per, a1 = (view.t0 + view.span) * per;
        for (let x = 0; x < w; x += 2) {
          const i0 = Math.floor(a0 + ((a1 - a0) * x) / w), i1 = Math.max(i0 + 1, Math.floor(a0 + ((a1 - a0) * (x + 2)) / w));
          let m = 0; for (let i = i0; i < i1 && i < env.data.length; i++) if (env.data[i] > m) m = env.data[i];
          const bh = Math.max(1, m * (h - 24));
          c.fillRect(x, mid - bh / 2, 1.5, bh);
        }
        // Segnaposto all'inizio di ogni fetta, numerati
        c.font = "600 10px system-ui";
        list.forEach((s, i) => {
          const x = xOf(s.start / RATE);
          if (x < -2 || x > w + 2) return;
          c.fillStyle = i === sel ? css("--ink") : css("--brass");
          c.fillRect(Math.round(x) - 1, 0, 2, h);
          if (lit.has(i) && lit.get(i) > performance.now()) { c.globalAlpha = 0.5; c.fillRect(Math.round(x) - 3, 0, 6, h); c.globalAlpha = 1; }
          c.fillText(String(i + 1), x + 4, 11);
        });
        scroll.max = String(Math.max(0, duration() - view.span)); scroll.value = String(view.t0);
        // I pad accesi
        pads.querySelectorAll(".pad").forEach((p) => { const i = +p.dataset.pad; p.classList.toggle("lit", lit.has(i) && lit.get(i) > performance.now()); });
      }
      function loop() { draw(); raf = requestAnimationFrame(loop); }

      // Il segnaposto vicino al puntatore (entro 6 px); il primo non si sposta
      const near = (x) => { let best = -1, d = 7; list.forEach((s, i) => { const dx = Math.abs(xOf(s.start / RATE) - x); if (i > 0 && dx < d) { d = dx; best = i; } }); return best; };
      const sliceAt = (t) => list.findIndex((s) => t * RATE >= s.start && t * RATE < s.end);
      cv.addEventListener("pointerdown", (e) => {
        if (!ch) return;
        cv.focus(); cv.setPointerCapture(e.pointerId);
        const x = e.clientX - cv.getBoundingClientRect().left, m = near(x);
        if (m > 0) { drag = m; sel = m; info(); return; }
        const i = sliceAt(tOf(x));
        if (i >= 0) play(i);
      });
      cv.addEventListener("pointermove", (e) => {
        const x = e.clientX - cv.getBoundingClientRect().left;
        if (drag < 0) { cv.style.cursor = near(x) > 0 ? "ew-resize" : "pointer"; return; }
        list = S.move(list, drag, tOf(x) * RATE, RATE); draw();
      });
      cv.addEventListener("pointerup", () => { if (drag >= 0) { drag = -1; info(); } });
      cv.addEventListener("dblclick", (e) => {
        if (!ch) return;
        const t = tOf(e.clientX - cv.getBoundingClientRect().left);
        list = S.split(list, t * RATE, RATE); sel = sliceAt(t) + 1; render();
      });
      cv.addEventListener("wheel", (e) => {
        e.preventDefault();
        if (e.ctrlKey) { zoom(e.deltaY > 0 ? 1.25 : 0.8, tOf(e.clientX - cv.getBoundingClientRect().left)); return; }
        view.t0 += (e.deltaY / 400) * view.span; clampView(); draw();
      }, { passive: false });
      scroll.addEventListener("input", () => { view.t0 = +scroll.value; draw(); });
      function zoom(f, at) {
        const t = at == null ? view.t0 + view.span / 2 : at, k = (t - view.t0) / view.span;
        view.span *= f; clampView(); view.t0 = t - k * view.span; clampView(); draw();
      }
      pads.addEventListener("pointerdown", (e) => { const p = e.target.closest(".pad"); if (p && !p.disabled) play(+p.dataset.pad); });
      sheet.querySelector("#s-stem").addEventListener("change", async (e) => { key = e.target.value; await loadStem(); });
      let sensTimer = 0;
      sheet.querySelector("#s-sens").addEventListener("input", (e) => { sens = +e.target.value; clearTimeout(sensTimer); sensTimer = setTimeout(() => ch && detect(), 150); });
      sheet.addEventListener("click", (e) => {
        const b = e.target.closest("[data-s]");
        if (!b) return;
        const act = b.dataset.s;
        if (act === "merge" && sel >= 0) { list = S.merge(list, sel); render(); }
        else if (act === "zoom-in") zoom(0.5);
        else if (act === "zoom-out") zoom(2);
        else if (act === "prev" && page > 0) { page--; render(); }
        else if (act === "next" && (page + 1) * 16 < list.length) { page++; render(); }
        else if (act === "export") exportAll();
      });

      async function exportAll() {
        if (!ch || busy || !list.length) return;
        busy = true;
        try {
          const stem = cur.meta.stems.find((s) => s.key === key);
          const dir = await Bridge.newSongDir(`${cur.meta.title} – Slice ${stem.name}`);
          for (let i = 0; i < list.length; i++) {
            status(`Salvo le fette… ${i + 1} di ${list.length}`);
            await Bridge.writeFile(`${dir}/${S.fileName(i)}`, Encode.wav(S.render(ch, list[i], RATE), 24));
          }
          const bpm = (cur.meta.analysis && cur.meta.analysis.bpm) || 120, name = `${cur.meta.title} – Slice ${stem.name}`;
          await Bridge.writeFile(`${dir}/${name}.mid`, S.midi(list, RATE, { bpm, name }));
          await Bridge.writeText(`${dir}/LEGGIMI.txt`, S.readme(cur.meta.title, stem.name, list.length, bpm));
          Bridge.reveal(`${dir}/${name}.mid`);
          status(`Esportate ${list.length} fette, il file MIDI e il LEGGIMI in «${dir.split("/").pop()}».`);
          sheet.lastExport = dir;
        } catch (e) { status("Esportazione non riuscita: " + (e.message || e)); }
        busy = false;
      }

      const keys = (e) => {
        if (e.target.closest("input, select, textarea") || e.ctrlKey || e.altKey || e.metaKey) return;
        const k = KEYS.indexOf(e.key.toLowerCase());
        if (k >= 0) { e.preventDefault(); e.stopPropagation(); play(page * 16 + k); }
        else if (e.key === "ArrowRight" && list.length) { e.preventDefault(); play(Math.min(list.length - 1, sel + 1)); }
        else if (e.key === "ArrowLeft" && list.length) { e.preventDefault(); play(Math.max(0, sel - 1)); }
      };
      document.addEventListener("keydown", keys, true);
      const ro = new ResizeObserver(() => draw()); ro.observe(cv);
      cleanup = () => { cancelAnimationFrame(raf); ro.disconnect(); document.removeEventListener("keydown", keys, true); if (ctx) ctx.close(); };
      sheet.api = { get slices() { return list; }, get key() { return key; }, exportAll, play, get lastExport() { return sheet.lastExport; }, ready: null };
      loop();
      sheet.api.ready = loadStem().catch((e) => status("Non riesco a leggere la traccia: " + (e.message || e)));
      await sheet.api.ready;
    }, () => { if (cleanup) cleanup(); cleanup = null; IsoApp.transport(); });
  }
  let cleanup = null;

  /** Il massimo ogni 220 campioni (200 al secondo), normalizzato. */
  function envelope(ch) {
    const H = 220, n = Math.floor(ch[0].length / H), data = new Float32Array(n);
    let top = 0;
    for (let p = 0; p < n; p++) {
      let m = 0;
      for (let i = p * H, e = i + H; i < e; i++) { const v = Math.abs(ch[0][i]) + Math.abs((ch[1] || ch[0])[i]); if (v > m) m = v; }
      data[p] = m; if (m > top) top = m;
    }
    if (top > 0) for (let p = 0; p < n; p++) data[p] /= top;
    return { data, rate: RATE / H };
  }

  window.Slicer = { open, sliceable };
})();
