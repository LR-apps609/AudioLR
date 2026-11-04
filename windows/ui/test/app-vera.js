// La prova sull'app VERA installata (non nel browser): IsoLR parte con WebView2 aperto al debug
// (WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=9222), qui ci si collega con Playwright.
//   node app-vera.js foto <cartella> <nome>          foto della finestra + controllo che tutto stia dentro
//   node app-vera.js percorso <cartella> <canzone>   la canzone (già passata dal clic destro) separata in Rapida
// Esce con 1 se qualcosa non va; scrive <cartella>/<nome>.json con i dettagli.
const { chromium } = require(process.env.PW || "playwright");
const fs = require("fs"), path = require("path");

const [mode, out, arg] = process.argv.slice(2);
fs.mkdirSync(out, { recursive: true });

async function connect() {
  for (let i = 0; i < 60; i++) {
    try {
      const b = await chromium.connectOverCDP("http://127.0.0.1:9222");
      const page = b.contexts()[0]?.pages()[0];
      if (page) return { b, page };
      await b.close();
    } catch { /* non ancora pronta */ }
    await new Promise((r) => setTimeout(r, 1000));
  }
  throw new Error("la finestra di IsoLR non risponde al collegamento di prova (WebView2 senza debug?)");
}

async function check(page) {
  return page.evaluate(() => {
    const W = innerWidth, H = innerHeight, out = [];
    if (document.documentElement.scrollWidth > W + 1) out.push(`la pagina scorre in orizzontale (${document.documentElement.scrollWidth} > ${W})`);
    const scrolls = (el) => { for (let p = el.parentElement; p; p = p.parentElement) { const s = getComputedStyle(p); if (/(auto|scroll)/.test(s.overflowY + s.overflowX) && (p.scrollHeight > p.clientHeight + 1 || p.scrollWidth > p.clientWidth + 1)) return true; } return false; };
    for (const el of document.querySelectorAll("button, [role=button], input, select, [data-act]")) {
      const r = el.getBoundingClientRect(), s = getComputedStyle(el);
      if (r.width < 2 || r.height < 2 || s.visibility === "hidden" || s.display === "none" || +s.opacity === 0) continue;
      if ((r.bottom > H + 1 || r.right > W + 1 || r.left < -1 || r.top < -1) && !scrolls(el)) {
        out.push(`«${(el.getAttribute("aria-label") || el.title || el.textContent || el.tagName).trim().replace(/\s+/g, " ").slice(0, 40)}» fuori dalla finestra`);
      }
    }
    return { problemi: out, finestra: `${W}×${H}`, scala: devicePixelRatio, schermo: `${screen.width}×${screen.height}`, utile: `${screen.availWidth}×${screen.availHeight}` };
  });
}

(async () => {
  const { b, page } = await connect();
  const res = { ok: true, problemi: [] };
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.waitForTimeout(1500);
  if (mode === "foto") {
    Object.assign(res, await check(page));
    // La domanda del rapporto (dopo una chiusura brusca) è attesa solo quando lo dice chi chiama
    res.domandaRapporto = await page.evaluate(() => !!document.querySelector("#h-save"));
    await page.screenshot({ path: path.join(out, `${arg}.png`) });
  } else if (mode === "percorso") {
    // La canzone del clic destro arriva da sola; si sceglie Rapida e si separa
    const t0 = Date.now();
    await page.waitForFunction(() => IsoApp.job.phase === "pending" && document.querySelector('[data-act="separate"]'), null, { timeout: 90000 });
    await page.screenshot({ path: path.join(out, "percorso-1-pronta.png") });
    await page.evaluate(() => { Prefs.set("quality", "fast"); IsoApp.ui.quality = "fast"; IsoApp.render(); });
    await page.click('[data-act="separate"]');
    let last = -1, still = 0;
    // Ogni 10 s: l'avanzamento deve muoversi (o almeno il testo del passo), mai fermo per più di 5 minuti
    while (true) {
      await page.waitForTimeout(10000);
      const s = await page.evaluate(() => ({ phase: IsoApp.job.phase, p: IsoApp.job.progress, step: IsoApp.job.step, error: IsoApp.job.error }));
      if (s.phase !== "working") { res.fine = s; break; }
      const sig = `${Math.round((s.p || 0) * 1000)} ${s.step}`;
      still = sig === last ? still + 10 : 0;
      last = sig;
      if (still >= 300) { res.problemi.push(`avanzamento fermo da 5 minuti: ${sig}`); break; }
      if (Date.now() - t0 > 25 * 60000) { res.problemi.push("Rapida non è finita in 25 minuti"); break; }
      if (Date.now() - t0 > 60000 && !res.fotoLavoro) { res.fotoLavoro = true; await page.screenshot({ path: path.join(out, "percorso-2-lavoro.png") }); }
    }
    res.secondi = Math.round((Date.now() - t0) / 1000);
    await page.waitForTimeout(2000);
    await page.screenshot({ path: path.join(out, "percorso-3-risultati.png") });
    const stems = await page.evaluate(() => (IsoApp.job.current?.meta?.stems || []).map((s) => s.key));
    res.tracce = stems;
    if (res.fine?.error) res.problemi.push("errore: " + res.fine.error);
    if (stems.length < 4) res.problemi.push(`tracce ricevute: ${stems.length} (attese almeno 4)`);
    // Ascolto: Play per un secondo
    try { await page.evaluate(() => IsoApp.player.play && IsoApp.player.play(0)); await page.waitForTimeout(1500); await page.evaluate(() => IsoApp.player.pause && IsoApp.player.pause()); } catch (e) { res.problemi.push("ascolto: " + e.message); }
    Object.assign(res, { layout: await check(page) });
    res.problemi.push(...res.layout.problemi);
  }
  for (const e of errors) res.problemi.push("errore nella pagina: " + e.slice(0, 200));
  res.ok = res.problemi.length === 0;
  fs.writeFileSync(path.join(out, `${mode === "foto" ? arg : "percorso"}.json`), JSON.stringify(res, null, 1));
  console.log(JSON.stringify(res));
  await b.close().catch(() => {});
  process.exit(res.ok ? 0 : 1);
})().catch((e) => { console.log("::error::" + e.message); fs.writeFileSync(path.join(out, `${mode}-errore.txt`), String(e.stack || e)); process.exit(1); });
