// Prove di regressione dell'interfaccia Windows: i bug trovati il 07/11 dai 20 tester su dispositivi diversi
// (tastiera, finestre sopra, A–B e rampa, misure piccole, contrasto elevato, «Riduci movimento», file vuoti).
// Ognuno ha la sua prova: se torna, la prova lo dice. Senza separare: canzone finta (finta.js) nel ponte in memoria.
// Uso: node windows/ui/test/regressioni.js <cartella dist> [cartella schermate]
const { chromium } = require(process.env.PW || "playwright");
const http = require("http"), fs = require("fs"), path = require("path");
const { fakeSong } = require("./finta.js");

const [dist, out = "risultati-regressioni"] = process.argv.slice(2);
fs.mkdirSync(out, { recursive: true });
const root = path.resolve(dist);
const types = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css", ".png": "image/png", ".json": "application/json", ".wasm": "application/wasm" };
const server = http.createServer((req, res) => {
  const p = path.join(root, decodeURIComponent(req.url.split("?")[0]).replace(/^\/$/, "/index.html"));
  if (!p.startsWith(root) || !fs.existsSync(p)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { "Content-Type": types[path.extname(p)] || "application/octet-stream" });
  fs.createReadStream(p).pipe(res);
}).listen(0);
let failed = 0;
const check = (ok, msg) => { console.log((ok ? "::notice::OK " : "::error::NO ") + msg); if (!ok) failed++; };

async function fresh(browser, opts = {}) {
  const page = await browser.newPage({ viewport: { width: 1280, height: 820 }, ...opts });
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  await page.waitForTimeout(700);
  await fakeSong(page);
  page.errors = errors;
  return page;
}
// Apre la canzone finta come una persona: Tab fino alla voce della libreria e Invio
async function openSong(page) {
  await page.evaluate(async () => { await IsoApp.openEntry(IsoApp.ui.libList[0] || IsoApp.ui.library[0]); });
  await page.waitForTimeout(300);
}
const active = (page) => page.evaluate(() => { const a = document.activeElement; return a ? a.tagName + (a.dataset.mute ? ":mute" : a.dataset.solo ? ":solo" : a.dataset.sel ? ":sel" : "") : null; });

(async () => {
  const browser = await chromium.launch();

  // ── Tastiera ──
  {
    const page = await fresh(browser);
    // Le canzoni della libreria si raggiungono con Tab e si aprono con Invio
    const libFocus = await page.evaluate(() => { const it = document.querySelector(".lib-item[data-open]"); return it && it.tabIndex === 0 && it.getAttribute("role") === "button"; });
    check(libFocus, "le canzoni della libreria si raggiungono con Tab (tabindex 0, role button)");
    await page.focus(".lib-item[data-open]");
    await page.keyboard.press("Enter");
    await page.waitForTimeout(500);
    check(await page.evaluate(() => IsoApp.job.phase === "done" && !!IsoApp.job.current), "Invio su una canzone della libreria la apre");
    // Spazio su una casella della traccia: si spunta/toglie, la canzone non parte
    await page.focus('[data-sel="drums"]');
    const before = await page.evaluate(() => document.querySelector('[data-sel="drums"]').checked);
    await page.keyboard.press("Space");
    await page.waitForTimeout(200);
    const sp = await page.evaluate(() => ({ checked: document.querySelector('[data-sel="drums"]').checked, playing: IsoApp.player.playing }));
    check(sp.checked !== before && !sp.playing, `Spazio sulla casella della batteria la cambia e non fa suonare (${JSON.stringify(sp)})`);
    // Invio su «solo»: il fuoco resta sul pulsante, il secondo Invio lo toglie
    await page.focus('[data-solo="vocals"]');
    await page.keyboard.press("Enter");
    await page.waitForTimeout(150);
    const a1 = await active(page);
    await page.keyboard.press("Enter");
    await page.waitForTimeout(150);
    const solo = await page.evaluate(() => [...IsoApp.player.solo]);
    check(a1 === "BUTTON:solo" && solo.length === 0, `dopo Invio su «solo» il fuoco resta lì e il secondo Invio lo toglie (fuoco ${a1}, solo ${JSON.stringify(solo)})`);
    // Spazio con il fuoco sul pulsante «muto»: silenzia, non fa suonare
    await page.focus('[data-mute="bass"]');
    await page.keyboard.press("Space");
    await page.waitForTimeout(150);
    const mu = await page.evaluate(() => ({ muted: IsoApp.player.muted.has("bass"), playing: IsoApp.player.playing }));
    check(mu.muted && !mu.playing, `Spazio su «Silenzia Basso» lo silenzia e non fa suonare (${JSON.stringify(mu)})`);
    // Spazio fuori dai controlli: suona/pausa come prima
    await page.evaluate(() => document.activeElement && document.activeElement.blur());
    await page.keyboard.press("Space");
    await page.waitForTimeout(200);
    check(await page.evaluate(() => IsoApp.player.playing), "Spazio fuori dai controlli fa ancora suonare");
    await page.keyboard.press("Space");
    // «Progetto per…» con la freccia: non parte nessuna esportazione finché non si preme Invio
    await page.evaluate(() => { IsoApp.ui.lastProject = null; window.__exp = 0; const o = IsoApp.exportProject; IsoApp.__exp = o; });
    await page.focus('[data-input="project"]');
    await page.keyboard.press("ArrowDown");
    await page.waitForTimeout(400);
    check(await page.evaluate(() => !IsoApp.ui.lastProject), "la freccia su «Progetto per…» non fa partire l'esportazione");
    // Ctrl+O sui risultati apre la scelta del file
    const asked = await page.evaluate(async () => { let n = 0; const o = Bridge.askOpen; Bridge.askOpen = async () => { n++; return null; }; document.dispatchEvent(new KeyboardEvent("keydown", { key: "o", ctrlKey: true, bubbles: true })); await new Promise((r) => setTimeout(r, 100)); Bridge.askOpen = o; return n; });
    check(asked === 1, `Ctrl+O sui risultati apre la scelta della canzone (${asked} chiamate)`);
    check(page.errors.length === 0, "nessun errore nella pagina (tastiera): " + page.errors.join(" | "));
    await page.close();
  }

  // ── Finestre sopra: il fuoco entra, Tab resta dentro, Esc lo riporta al pulsante ──
  {
    const page = await fresh(browser);
    await openSong(page);
    const opener = await page.evaluate(() => { const b = [...document.querySelectorAll("button")].find((x) => /Impostazioni/.test(x.title || x.textContent)); if (b) { b.focus(); b.click(); } return !!b; });
    await page.waitForTimeout(400);
    const inside = await page.evaluate(() => { const s = document.querySelector("#overlay .sheet"); return !!s && s.contains(document.activeElement) && s.getAttribute("aria-modal") === "true"; });
    check(opener && inside, "aprendo Impostazioni il fuoco entra nella finestra (aria-modal)");
    let out = 0;
    for (let i = 0; i < 30; i++) { await page.keyboard.press("Tab"); if (!(await page.evaluate(() => document.querySelector("#overlay .sheet").contains(document.activeElement)))) out++; }
    check(out === 0, `30 Tab restano dentro la finestra (${out} fuori)`);
    await page.keyboard.press("Escape");
    await page.waitForTimeout(200);
    const back = await page.evaluate(() => { const a = document.activeElement; return !!a && a !== document.body && /Impostazioni/.test(a.title || a.textContent); });
    check(back, "con Esc il fuoco torna al pulsante Impostazioni");
    // Una finestra che ne sostituisce un'altra chiude per bene la prima (Warp → Aiuto: lo Spazio deve suonare)
    await page.evaluate(() => { document.querySelector('[data-act="warp"]').click(); });
    await page.waitForTimeout(600);
    await page.evaluate(() => window.Sheets.help ? window.Sheets.help() : null);
    await page.waitForTimeout(300);
    await page.evaluate(() => { const c = document.querySelector("#overlay [data-close]"); if (c) c.click(); });
    await page.waitForTimeout(200);
    await page.evaluate(() => document.activeElement && document.activeElement.blur());
    const metroBefore = await page.evaluate(() => IsoApp.player.metronome);
    await page.keyboard.press("Space");
    await page.waitForTimeout(250);
    const after = await page.evaluate(() => ({ playing: IsoApp.player.playing, metronome: IsoApp.player.metronome }));
    check(after.playing && after.metronome === metroBefore, `dopo Warp sostituita dall'Aiuto lo Spazio suona e non tocca il metronomo (${JSON.stringify(after)})`);
    check(page.errors.length === 0, "nessun errore nella pagina (finestre): " + page.errors.join(" | "));
    await page.close();
  }

  // ── A–B e rampa ──
  {
    const page = await fresh(browser);
    await openSong(page);
    const r = await page.evaluate(async () => {
      const p = IsoApp.player, wait = (ms) => new Promise((x) => setTimeout(x, ms));
      p.play(1); await wait(300); p.markA(); await wait(1200); p.markB(); await wait(200);
      const a0 = p.loopA; await wait(300); p.markA(); await wait(150);
      const src = p.nodes.find((n) => n.src && n.src.loop);
      const moved = { loopA: p.loopA, loopStart: src ? src.src.loopStart : null, a0 };
      // A vicino alla fine: B tolto, e le tracce non ripetono più il vecchio passaggio
      p.practice(2, 3); await wait(150); p.seek(2.9 / p.duration); p.play(2.9); await wait(50); p.markA(); await wait(150);
      const loopingNodes = p.nodes.filter((n) => n.src && n.src.loop).length;
      // Il passaggio A–B da scaricare con B tolto: errore chiaro, non «Invalid typed array length»
      let err = ""; try { p.mixdown([p.loopA, p.loopB]); } catch (e) { err = e.message; }
      const dlab = document.querySelector('[data-act="dl-ab"]');
      // Rampa: mentre suona va anche nelle tracce; togliendo il passaggio si spegne
      p.practice(2, 4); await wait(150); p.setRamp(true); await wait(100);
      const rateNodes = p.nodes.filter((n) => n.src && n.src.playbackRate).map((n) => n.src.playbackRate.value);
      const rampOn = p.ramp; p.clearLoop(); await wait(100);
      const rampAfter = { ramp: p.ramp, rate: p.rate };
      p.pause();
      return { moved, loopingNodes, loopB: p.loopB, err, dlabDisabled: dlab ? dlab.disabled : null, rateNodes, rampOn, rampAfter };
    });
    check(r.moved.loopStart != null && Math.abs(r.moved.loopStart - r.moved.loopA) < 0.05, `rimarcando A mentre suona le tracce ripetono da A nuovo (${JSON.stringify(r.moved)})`);
    check(r.loopingNodes === 0, `A vicino a B toglie B e le tracce smettono di ripetere (${r.loopingNodes} ancora in ripetizione)`);
    check(/non è completo/.test(r.err), `scaricare il passaggio A–B senza B dà un errore chiaro («${r.err}»)`);
    check(r.rampOn && (r.rateNodes.length === 0 || r.rateNodes.every((v) => Math.abs(v - 0.7) < 0.01)), `la rampa accesa mentre suona va anche nelle tracce (${JSON.stringify(r.rateNodes)})`);
    check(!r.rampAfter.ramp && r.rampAfter.rate === 1, `togliendo il passaggio la rampa si spegne e la velocità torna normale (${JSON.stringify(r.rampAfter)})`);
    check(page.errors.length === 0, "nessun errore nella pagina (A–B): " + page.errors.join(" | "));
    await page.close();
  }

  // ── Misure piccole ──
  for (const [w, h] of [[930, 640], [1000, 700], [1050, 700]]) {
    const page = await fresh(browser, { viewport: { width: w, height: h } });
    await openSong(page);
    const m = await page.evaluate(() => {
      const rows = document.querySelector(".rows"), r = rows.getBoundingClientRect();
      const dl = document.querySelector('[data-dl="vocals"]'), d = dl.getBoundingClientRect();
      const hit = document.elementFromPoint(d.left + d.width / 2, d.top + d.height / 2);
      return { sw: rows.scrollWidth, cw: rows.clientWidth, h: r.height, dlOk: !!hit && dl.contains(hit) };
    });
    check(m.sw <= m.cw + 1 && m.dlOk, `${w}×${h}: le righe del mixer stanno nel loro riquadro e «Scarica» della Voce si clicca (${JSON.stringify(m)})`);
    await page.evaluate(() => { const b = document.querySelector('[data-act="practice"]'); if (b) b.click(); });
    await page.waitForTimeout(300);
    const ph = await page.evaluate(() => { const rows = document.querySelector(".rows"); rows.scrollIntoView(); return rows.getBoundingClientRect().height; });
    check(ph >= 100, `${w}×${h}: con «Esercitati» aperto il mixer si vede ancora (altezza ${Math.round(ph)} px)`);
    await page.screenshot({ path: path.join(out, `regressioni-${w}x${h}.png`) });
    check(page.errors.length === 0, `nessun errore nella pagina (${w}×${h}): ` + page.errors.join(" | "));
    await page.close();
  }
  {
    // Finestra bassa durante il lavoro: «Annulla» si raggiunge scorrendo
    const page = await fresh(browser, { viewport: { width: 930, height: 500 } });
    const c = await page.evaluate(async () => {
      const j = IsoApp.job; j.phase = "working"; j.quality = "studio"; j.title = "Prova"; j.setStage("separating"); j.progress = 0.3; j.emit(); IsoApp.render();
      await new Promise((r) => setTimeout(r, 200));
      const b = document.querySelector('[data-act="cancel"]'); if (!b) return { found: false };
      b.scrollIntoView(); const r = b.getBoundingClientRect(); const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
      return { found: true, ok: r.bottom <= innerHeight && !!hit && b.contains(hit) };
    });
    check(c.found && c.ok, `930×500: durante il lavoro «Annulla» si raggiunge (${JSON.stringify(c)})`);
    await page.close();
  }

  // ── Contrasto elevato e «Riduci movimento» ──
  {
    const page = await fresh(browser, { forcedColors: "active", colorScheme: "dark" });
    await openSong(page);
    await page.evaluate(() => { document.querySelector('[data-solo="bass"]').click(); });
    await page.waitForTimeout(200);
    const st = await page.evaluate(() => {
      const on = getComputedStyle(document.querySelector('[data-solo="bass"]')), off = getComputedStyle(document.querySelector('[data-solo="drums"]'));
      return { on: on.backgroundColor + "|" + on.outlineStyle, off: off.backgroundColor + "|" + off.outlineStyle, pressed: document.querySelector('[data-solo="bass"]').getAttribute("aria-pressed") };
    });
    check(st.on !== st.off && st.pressed === "true", `contrasto elevato: «solo» acceso diverso da spento e aria-pressed (${JSON.stringify(st)})`);
    await page.close();
    const p2 = await browser.newPage({ viewport: { width: 1280, height: 820 }, reducedMotion: "reduce" });
    await p2.goto(`http://127.0.0.1:${server.address().port}/`);
    await p2.waitForTimeout(700);
    const anim = await p2.evaluate(() => document.getAnimations().filter((a) => a.playState === "running" && a.effect && a.effect.getTiming().iterations === Infinity).length);
    check(anim === 0, `«Riduci movimento»: nessuna animazione infinita nella schermata iniziale (${anim})`);
    // File vuoto: un avviso invece del silenzio
    const toast = await p2.evaluate(async () => { IsoApp.job.add([new File([], "Vuota 0 byte.mp3")]); await new Promise((r) => setTimeout(r, 150)); const t = document.querySelector(".toast"); return t ? t.textContent : ""; });
    check(/vuoto/.test(toast), `un file vuoto trascinato dà un avviso («${toast}»)`);
    await p2.close();
  }

  // ── Transpose: mai silenzio (prima circa una volta su tre il calcolo partiva prima del tono e usciva muto) ──
  {
    const page = await fresh(browser);
    const peaks = await page.evaluate(async () => {
      const n = 44100 * 2, a = [new Float32Array(n), new Float32Array(n)];
      for (let i = 0; i < n; i++) { const v = 0.4 * Math.sin((2 * Math.PI * 440 * i) / 44100); a[0][i] = v; a[1][i] = v; }
      const out = [];
      for (let k = 0; k < 8; k++) { const up = await Transpose.apply(a, k % 2 ? 2 : -3); let m = 0; for (const v of up[0]) m = Math.max(m, Math.abs(v)); out.push(+m.toFixed(3)); }
      return out;
    });
    check(peaks.every((m) => m > 0.1), `Transpose 8 volte di fila, mai silenzio (picchi ${peaks.join(", ")})`);
    await page.close();
  }

  await browser.close();
  server.close();
  console.log(failed ? `::error::${failed} prove di regressione non passate` : "::notice::Tutte le prove di regressione passate");
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
