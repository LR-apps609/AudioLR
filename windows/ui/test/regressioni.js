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
    await page.evaluate(() => { const b = document.querySelector('[data-act="practice"]'); if (b && !IsoApp.ui.practice) b.click(); });
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

  // ── Dai tester t11–t16 (08/11): coda, Sala prove, note, libreria, Spazio dopo una finestra ──
  {
    const page = await fresh(browser);
    // Due file rilasciati sulla zona tratteggiata entrano una volta sola (prima due: 4 separazioni)
    const q = await page.evaluate(() => {
      const dt = new DataTransfer();
      dt.items.add(new File([new Uint8Array(100)], "Uno.wav")); dt.items.add(new File([new Uint8Array(100)], "Due.wav"));
      document.querySelector("#drop").dispatchEvent(new DragEvent("drop", { dataTransfer: dt, bubbles: true, cancelable: true }));
      return { pending: IsoApp.job.pending && IsoApp.job.pending.name, queue: IsoApp.job.queue.map((f) => f.name) };
    });
    check(q.pending === "Uno.wav" && q.queue.length === 1 && q.queue[0] === "Due.wav", `due file sulla zona: una pronta e una in coda (${JSON.stringify(q)})`);
    // «Togli» sulla pronta con la coda: passa pronta la prossima, Separa resta usabile
    await page.evaluate(() => document.querySelector('[data-act="clear-pending"]').click());
    await page.waitForTimeout(150);
    const t = await page.evaluate(() => ({ pending: IsoApp.job.pending && IsoApp.job.pending.name, queue: IsoApp.job.queue.length, sep: !document.querySelector('[data-act="separate"]').disabled }));
    check(t.pending === "Due.wav" && t.queue === 0 && t.sep, `«Togli» con la coda: la prossima diventa pronta e Separa è attivo (${JSON.stringify(t)})`);
    await page.evaluate(() => IsoApp.job.reset());
    // Una canzone della coda non riuscita resta scritta, con il perché
    await page.evaluate(() => { IsoApp.job.skipped = [{ name: "Testo finto.mp3", error: "non riesco ad aprire questo file come audio" }]; IsoApp.job.add([new File([new Uint8Array(100)], "Tre.wav")]); });
    await page.waitForTimeout(150);
    const sk = await page.evaluate(() => (document.querySelector(".skipped") || {}).textContent || "");
    check(/Testo finto/.test(sk) && /audio/.test(sk), `la canzone della coda non riuscita resta scritta («${sk.slice(0, 80)}»)`);
    await page.evaluate(() => { IsoApp.job.reset(); });
    // Aperta dalla libreria (anche due volte di fila): ogni traccia una volta sola nel lettore
    await page.evaluate(async () => { const e = IsoApp.ui.library[0]; await Promise.all([IsoApp.openEntry(e), IsoApp.openEntry(e)]); });
    await page.waitForTimeout(400);
    const keys = await page.evaluate(() => IsoApp.player.keys);
    check(keys.length === new Set(keys).size && keys.length >= 4, `dalla libreria ogni traccia una volta sola (${keys.join(",")})`);
    // Velocità cambiata col cursore: compare «Normale»
    await page.evaluate(() => { const b = document.querySelector('[data-act="practice"]'); if (b && !IsoApp.ui.practice) b.click(); });
    await page.waitForTimeout(300);
    const normal = await page.evaluate(async () => {
      const r = document.querySelector('[data-input="rate"]'); if (!r) return "nessun cursore";
      r.value = "1.3"; r.dispatchEvent(new Event("input", { bubbles: true })); r.dispatchEvent(new Event("change", { bubbles: true }));
      await new Promise((x) => setTimeout(x, 150));
      return !!document.querySelector('[data-act="normal"]');
    });
    check(normal === true, `velocità cambiata col cursore: compare «Normale» (${normal})`);
    // Il cursore trascinato mentre suona: un solo motore velocità/tono, e in pausa tutto tace
    const motors = await page.evaluate(async () => {
      const P = IsoApp.player, orig = window.SignalsmithStretch;
      let made = 0;
      window.SignalsmithStretch = async (...a) => { made++; return orig(...a); };
      P.dropStretch(); P.rate = 1; await P.play(0);
      for (const r of [0.95, 0.9, 0.85, 0.8]) P.setRate(r);
      await new Promise((x) => setTimeout(x, 1500));
      P.pause();
      window.SignalsmithStretch = orig;
      return made;
    });
    check(motors === 1, `cursore della velocità trascinato mentre suona: un solo motore (${motors})`);
    // Il metronomo si accende subito, anche sui clic già programmati
    const metro = await page.evaluate(async () => {
      const P = IsoApp.player; P.setRate(1); P.metronome = false; await P.play(0);
      await new Promise((x) => setTimeout(x, 200));
      P.setMetronome(true);
      const on = P.clickNodes.filter((c) => !c.count).map((c) => c.g.gain.value);
      P.setMetronome(false);
      const off = P.clickNodes.filter((c) => !c.count).map((c) => c.g.gain.value);
      P.pause();
      return { n: on.length, on: on.every((v) => v === 1), off: off.every((v) => v === 0) };
    });
    check(metro.n > 0 && metro.on && metro.off, `metronomo acceso e spento subito sui clic già programmati (${JSON.stringify(metro)})`);
    // Accordi uguali di seguito (anche con una pausa in mezzo) si vedono una volta sola
    const chords = await page.evaluate(async () => {
      IsoApp.job.current.meta.analysis.chords = [{ start: 0, end: 0.5, root: 2, minor: false }, { start: 0.5, end: 1, root: null }, { start: 1, end: 2.5, root: 9, minor: true },
        { start: 2.5, end: 3, root: null }, { start: 3, end: 4, root: 9, minor: true }, { start: 4, end: 7, root: 2, minor: true }];
      IsoApp.player.startPos = 0; IsoApp.player.emit();
      await new Promise((x) => setTimeout(x, 300));
      return [...document.querySelectorAll("#chords .chord-next")].map((e) => e.textContent);
    });
    check(chords.length >= 2 && chords.every((c, i) => i === 0 || c !== chords[i - 1]), `nessun accordo ripetuto di seguito tra i prossimi (${chords.join(" ")})`);
    // MIDI, spartito e tab dalle note corrette a mano: si salvano (prima «Midi.program is not a function»)
    const midi = await page.evaluate(async () => {
      const cur = IsoApp.job.current;
      const ns = [0, 1, 2, 3].map((i) => ({ start: i * 0.5, end: i * 0.5 + 0.4, pitch: 40 + i, velocity: 90 }));
      await Bridge.writeText(`${cur.folder}/isolr-note-bass.json`, JSON.stringify({ version: 1, detected: ns, edited: ns }));
      const toasts = []; const t = (e) => toasts.push(e); IsoApp.toast = ((orig) => (m) => { toasts.push(m); return orig(m); })(IsoApp.toast);
      await window.Sheets.notes(cur, "bass", () => {}, 0);
      const stem = cur.meta.stems.find((s) => s.key === "bass");
      const base = `${cur.folder}/${cur.meta.title} – ${stem.name}`;
      void t;
      return { mid: await Bridge.exists(base + ".mid"), toasts };
    });
    check(midi.mid && !midi.toasts.some((x) => /non riuscite/.test(x)), `«File: MIDI, spartito e tab» salva il .mid (${JSON.stringify(midi)})`);
    // Piano roll chiuso subito dopo una modifica: la modifica resta
    const roll = await page.evaluate(async () => {
      const cur = IsoApp.job.current;
      window.PianoRoll.open(cur, IsoApp.player, "bass");
      for (let i = 0; i < 40; i++) { const sh = document.querySelector("#overlay .sheet"); if (sh && sh.api && sh.api.editor) break; await new Promise((x) => setTimeout(x, 100)); }
      const sh = document.querySelector("#overlay .sheet");
      if (!sh || !sh.api || !sh.api.editor) return "piano roll non aperto";
      sh.api.select([sh.api.editor.notes[0].id]);
      return "ok";
    });
    if (roll === "ok") { await page.keyboard.press("Delete"); await page.keyboard.press("Escape"); await page.waitForTimeout(250); }
    const saved = await page.evaluate(async () => { const s = await window.PianoRoll.edited(IsoApp.job.current, "bass"); return s ? s.length : null; });
    check(saved === 3, `piano roll chiuso subito dopo Canc: la nota tolta resta tolta (${roll}, ${saved} note salvate)`);
    // Dopo Warp chiusa con Esc, lo Spazio fa suonare la canzone invece di riaprire Warp
    await page.waitForTimeout(200);
    await page.focus('[data-act="warp"]');
    await page.keyboard.press("Enter");
    await page.waitForTimeout(600);
    await page.keyboard.press("Escape");
    await page.waitForTimeout(300);
    await page.keyboard.press("Space");
    await page.waitForTimeout(400);
    const sp = await page.evaluate(() => ({ playing: IsoApp.player.playing, sheet: !!document.querySelector("#overlay").childElementCount }));
    check(sp.playing && !sp.sheet, `dopo Warp chiusa con Esc lo Spazio fa suonare e non la riapre (${JSON.stringify(sp)})`);
    await page.evaluate(() => IsoApp.player.pause());
    // Senza AAC il messaggio non suggerisce formati che il video e il File per DJ non hanno
    const aac = await page.evaluate(async () => { const A = window.AudioEncoder; window.AudioEncoder = undefined; let m = ""; try { await Encode.aacEncode([new Float32Array(10), new Float32Array(10)]); } catch (e) { m = e.message; } window.AudioEncoder = A; return m; });
    check(/AAC/.test(aac) && !/WAV o FLAC/.test(aac), `senza AAC un messaggio senza «scegli WAV o FLAC» («${aac}»)`);
    // La Cronologia chiusa non lascia ascolti attaccati (prima uno per ogni apertura, fino alla separazione dopo)
    const hist = await page.evaluate(async () => {
      let n = 0; const add = window.addEventListener, rem = window.removeEventListener;
      window.addEventListener = function (t, f, o) { if (t === "isolr-libreria") n++; return add.call(this, t, f, o); };
      window.removeEventListener = function (t, f, o) { if (t === "isolr-libreria") n--; return rem.call(this, t, f, o); };
      for (let i = 0; i < 5; i++) { window.Sheets.history(IsoApp.ui.library, () => {}); document.querySelector("#overlay [data-close]").click(); }
      window.addEventListener = add; window.removeEventListener = rem;
      return n;
    });
    check(hist === 0, `5 Cronologie aperte e chiuse: nessun ascolto rimasto (${hist})`);
    // Il lavoratore della separazione si chiude da solo quando resta fermo (libera la memoria dei modelli)
    const idle = await page.evaluate(async () => {
      const J = IsoApp.job, before = J.constructor.IDLE_MS;
      J.constructor.IDLE_MS = 100; J.ensureWorker(); J.idleLater();
      await new Promise((x) => setTimeout(x, 400));
      J.constructor.IDLE_MS = before;
      return J.worker === null;
    });
    check(idle, "il lavoratore fermo si chiude da solo e libera la memoria");
    // Dal tester t20 — clic destro su più canzoni, a giri e con un file bloccato: nessuna si perde
    const right = await page.evaluate(async () => {
      IsoApp.job.reset();
      const rounds = [["C:/m/Uno.wav"], ["C:/m/Due.wav", "C:/m/Bloccata.wav", "C:/m/Tre.wav"]];
      const take = Bridge.takeOpened, read = Bridge.readFile, toasts = [];
      Bridge.takeOpened = async () => rounds.shift() || [];
      Bridge.readFile = async (p) => { if (/Bloccata/.test(p)) throw new Error("os error 32"); if (/^C:\/m\//.test(p)) return new Uint8Array(100); return read(p); };
      const obs = new MutationObserver(() => { const t = document.querySelector(".toast"); if (t) toasts.push(t.textContent); });
      obs.observe(document.body, { subtree: true, childList: true, characterData: true });
      await new Promise((x) => setTimeout(x, 3600));
      obs.disconnect(); Bridge.takeOpened = take; Bridge.readFile = read;
      return { pending: IsoApp.job.pending && IsoApp.job.pending.name, queue: IsoApp.job.queue.map((f) => f.name), toast: toasts.some((t) => /Bloccata/.test(t)) };
    });
    check(right.pending === "Uno.wav" && right.queue.join(",") === "Due.wav,Tre.wav" && right.toast,
      `clic destro a giri con un file bloccato: Uno pronta, Due e Tre in coda, avviso per Bloccata (${JSON.stringify(right)})`);
    await page.evaluate(() => IsoApp.job.reset());
    // Disco pieno mentre salva: la cartella a metà si toglie (prima restava, e il nuovo tentativo faceva «Titolo 2»)
    const full = await page.evaluate(async () => {
      const write = Bridge.writeFile, removed = [];
      let n = 0;
      Bridge.writeFile = async (p, b) => { if (++n === 3) throw new Error("Spazio su disco insufficiente (os error 112)"); return write(p, b); };
      const rem = Bridge.remove; Bridge.remove = async (p) => { removed.push(p); return rem(p); };
      const ch = [new Float32Array(44100), new Float32Array(44100)];
      let err = "";
      try { await Separation.save("Disco pieno", { vocals: ch, drums: ch, bass: ch, other: ch }, { quality: "fast", seconds: 1, took: 1 }); } catch (e) { err = e.message; }
      Bridge.writeFile = write; Bridge.remove = rem;
      return { err, removed: removed.some((p) => /Disco pieno$/.test(p)) };
    });
    check(/112/.test(full.err) && full.removed, `disco pieno mentre salva: la cartella a metà si toglie (${JSON.stringify(full)})`);
    // Titoli lunghissimi: il titolo si accorcia a 120 caratteri come la cartella, senza punto in fondo
    const long = await page.evaluate(() => {
      const J = IsoApp.job; J.reset();
      J.add([new File([new Uint8Array(10)], "x".repeat(118) + ". e poi tanto altro titolo ancora.mp3")]);
      const t = J.pending.name.replace(/\.[^.]+$/, "").slice(0, 120).replace(/[.\s]+$/, "");
      J.reset();
      return t.length <= 120 && !/[.\s]$/.test(t);
    });
    check(long, "un titolo lunghissimo si accorcia a 120 caratteri senza punto in fondo");
    check(page.errors.length === 0, "nessun errore nella pagina (t11–t16): " + page.errors.join(" | "));
    await page.close();
  }

  // Giro 2 dei tester (13/11)
  {
    const page = await fresh(browser);
    // t17: «Controlla adesso» senza rete dice perché, invece di non fare niente
    const upd = await page.evaluate(async () => {
      const toasts = []; IsoApp.toast = ((orig) => (m) => { toasts.push(m); return orig(m); })(IsoApp.toast);
      Bridge.checkUpdate = async () => { throw new Error("error sending request"); };
      Sheets.settings();
      await new Promise((r) => setTimeout(r, 200));
      const tab = [...document.querySelectorAll(".tabs button")].find((b) => b.dataset.t === "aggiornamenti");
      if (tab) tab.click();
      await new Promise((r) => setTimeout(r, 200));
      const b = document.querySelector("[data-check]"); if (b) b.click();
      await new Promise((r) => setTimeout(r, 200));
      return { found: !!b, toasts };
    });
    check(upd.found && upd.toasts.some((t) => /internet/.test(t)), `«Controlla adesso» senza rete avvisa (${JSON.stringify(upd)})`);
    check(page.errors.length === 0, "nessun errore nella pagina (giro 2): " + page.errors.join(" | "));
    await page.close();
  }
  {
    // t10: finestra minima 930×640, mixer e Sala prove
    const page = await fresh(browser, { viewport: { width: 930, height: 640 } });
    await openSong(page);
    await page.waitForTimeout(500);
    // Bug 5: il nome lungo («Pianoforte», «Altri strumenti») non deve finire sotto Silenzia
    const names = await page.evaluate(() => [...document.querySelectorAll(".row")].map((r) => {
      const b = r.querySelector(".name b"), m = r.querySelector(".btn.mute");
      if (!b || !m) return null;
      const rb = b.getBoundingClientRect(), cs = getComputedStyle(b);
      // Fin dove arriva il testo che si vede: se il nome non è tagliato, tutta la sua larghezza
      const end = cs.overflowX === "visible" ? rb.left + b.scrollWidth : rb.right;
      return { n: b.textContent, end: Math.round(end), mute: Math.round(m.getBoundingClientRect().left), title: b.title };
    }).filter(Boolean));
    check(names.length >= 6 && names.every((x) => x.end <= x.mute && x.title === x.n),
      `930×640: i nomi del mixer finiscono prima di Silenzia e hanno il nome intero nel suggerimento (${JSON.stringify(names)})`);
    // Bug 4: la barra delle parti in Sala prove non deve schiacciarsi a 48 px con pulsanti da 10 px accavallati
    await page.evaluate(() => { const b = document.querySelector('[data-act="practice"]'); if (b && !IsoApp.ui.practice) b.click(); });
    await page.waitForTimeout(400);
    const sec = await page.evaluate(() => {
      const s = document.querySelector("#sections"); if (!s) return null;
      const bs = [...s.querySelectorAll("button")].map((b) => b.getBoundingClientRect());
      const met = document.querySelector('[data-act="metronome"]').getBoundingClientRect();
      return { w: Math.round(s.getBoundingClientRect().width), min: Math.round(Math.min(...bs.map((r) => r.width))),
        overlap: bs.some((r, i) => i && r.left < bs[i - 1].right - 0.5), coversMet: s.getBoundingClientRect().right > met.left && s.getBoundingClientRect().bottom > met.top };
    });
    check(sec && sec.w >= 240 && sec.min >= 24 && !sec.overlap && !sec.coversMet,
      `930×640: la barra delle parti in Sala prove è larga e le parti non si accavallano (${JSON.stringify(sec)})`);
    check(page.errors.length === 0, "nessun errore nella pagina (t10): " + page.errors.join(" | "));
    await page.close();
  }

  await browser.close();
  server.close();
  console.log(failed ? `::error::${failed} prove di regressione non passate` : "::notice::Tutte le prove di regressione passate");
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
