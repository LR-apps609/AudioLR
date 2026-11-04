// L'interfaccia Windows alle misure degli schermi veri (punti effettivi = risoluzione / scala, meno la barra delle
// applicazioni e la barra del titolo), nel Chromium del server (lo stesso motore di WebView2).
// Per ogni schermo: foto di inizio, lavoro, risultati e impostazioni, e un controllo automatico:
//  - niente scorrimento orizzontale della pagina;
//  - ogni pulsante visibile sta dentro la finestra (non sotto la barra delle applicazioni, non fuori a destra);
//  - la finestra di partenza (1280×820 + barra del titolo) ci sta nello spazio utile, altrimenti si segnala.
// Uso: node windows/ui/test/dispositivi.js <cartella dist> <cartella uscita>   (serve playwright)
// Uscita: foto, risultati.json e riepilogo.md. Esce con 1 se un controllo fallisce.
const { chromium } = require(process.env.PW || "playwright");
const http = require("http"), fs = require("fs"), path = require("path");
const { fakeSong } = require("./finta.js");

const [dist, out] = process.argv.slice(2);
fs.mkdirSync(out, { recursive: true });
const TITLE = 32;               // barra del titolo di Windows 11 (punti effettivi)
const START = { w: 1280, h: 820 }, MIN = { w: 930, h: 640 };   // come tauri.conf.json
// [nome, larghezza, altezza, scala %, barra delle applicazioni]
const SCREENS = [
  ["1920x1080-100", 1920, 1080, 100, 48], ["1920x1080-125", 1920, 1080, 125, 48], ["1920x1080-150", 1920, 1080, 150, 48],
  ["1366x768-100", 1366, 768, 100, 48], ["1366x768-100-win10", 1366, 768, 100, 40],
  ["2560x1440-100", 2560, 1440, 100, 48], ["2560x1440-125", 2560, 1440, 125, 48], ["2560x1440-150", 2560, 1440, 150, 48],
  ["2560x1440-175", 2560, 1440, 175, 48], ["2560x1440-200", 2560, 1440, 200, 48],
];
const types = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css", ".png": "image/png", ".json": "application/json", ".wasm": "application/wasm" };
const server = http.createServer((req, res) => {
  const p = path.join(path.resolve(dist), decodeURIComponent(req.url.split("?")[0]).replace(/^\/$/, "/index.html"));
  if (!p.startsWith(path.resolve(dist)) || !fs.existsSync(p)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { "Content-Type": types[path.extname(p)] || "application/octet-stream" });
  fs.createReadStream(p).pipe(res);
}).listen(0);

// Il controllo dentro la pagina: pulsanti fuori dalla finestra e scorrimento orizzontale
async function check(page) {
  return page.evaluate(() => {
    const W = innerWidth, H = innerHeight, out = [];
    if (document.documentElement.scrollWidth > W + 1) out.push(`la pagina scorre in orizzontale (${document.documentElement.scrollWidth} > ${W})`);
    // Un elemento dentro un contenitore che scorre (elenchi, mixer) può stare fuori: si raggiunge scorrendo
    const scrolls = (el) => { for (let p = el.parentElement; p; p = p.parentElement) { const s = getComputedStyle(p); if (/(auto|scroll)/.test(s.overflowY + s.overflowX) && (p.scrollHeight > p.clientHeight + 1 || p.scrollWidth > p.clientWidth + 1)) return true; } return false; };
    for (const el of document.querySelectorAll("button, [role=button], input, select, [data-act]")) {
      const r = el.getBoundingClientRect(), s = getComputedStyle(el);
      if (r.width < 2 || r.height < 2 || s.visibility === "hidden" || s.display === "none" || +s.opacity === 0) continue;
      if ((r.bottom > H + 1 || r.right > W + 1 || r.left < -1 || r.top < -1) && !scrolls(el)) {
        const name = (el.getAttribute("aria-label") || el.title || el.textContent || el.dataset.act || el.tagName).trim().replace(/\s+/g, " ").slice(0, 40);
        out.push(`«${name}» fuori dalla finestra (${Math.round(r.left)},${Math.round(r.top)}–${Math.round(r.right)},${Math.round(r.bottom)})`);
      }
    }
    return out;
  });
}

(async () => {
  const browser = await chromium.launch();
  const base = `http://127.0.0.1:${server.address().port}/`;
  const results = [];
  let failed = false;
  for (const [name, rw, rh, scale, bar] of SCREENS) {
    const ew = Math.floor(rw * 100 / scale), eh = Math.floor(rh * 100 / scale);
    const work = { w: ew, h: eh - bar };
    const fits = START.w <= work.w && START.h + TITLE <= work.h;
    const minFits = MIN.w <= work.w && MIN.h + TITLE <= work.h;
    // L'area della pagina come la vede chi usa l'app: la finestra di partenza, tagliata dallo spazio utile
    const vw = Math.min(START.w, work.w), vh = Math.min(START.h, work.h - TITLE);
    const row = { schermo: name, effettivo: `${ew}×${eh}`, utile: `${work.w}×${work.h}`, finestra: `${vw}×${vh}`, ci_sta: fits, minima_ci_sta: minFits, problemi: [], foto: [] };
    if (!fits) row.problemi.push(`la finestra di partenza (1280×${START.h + TITLE} con la barra del titolo) è più alta dello spazio utile (${work.h}): la parte bassa finisce sotto la barra delle applicazioni`);
    if (!minFits) row.problemi.push(`anche la misura minima (${MIN.w}×${MIN.h + TITLE}) non ci sta`);
    const page = await browser.newPage({ viewport: { width: vw, height: vh }, deviceScaleFactor: scale / 100 });
    const errs = [];
    page.on("pageerror", (e) => errs.push(e.message));
    await page.goto(base);
    await page.waitForTimeout(700);
    const shoot = async (tag) => {
      await page.waitForTimeout(350);
      const f = `win-${name}-${tag}.png`;
      await page.screenshot({ path: path.join(out, f) });
      row.foto.push(f);
      for (const p of await check(page)) row.problemi.push(`${tag}: ${p}`);
    };
    await shoot("1-inizio");
    await page.evaluate(() => {
      const j = IsoApp.job; j.phase = "working"; j.quality = "studio"; j.title = "Nicolò De Santis – L'ultima canzone 🎸"; j.setStage("separating");
      const p = new Float32Array(240); for (let i = 0; i < 240; i++) p[i] = 0.25 + 0.7 * Math.abs(Math.sin(i / 7) * Math.cos(i / 19));
      j.peaks = p; j.stageStarted = Date.now() - 95000; j.step = "Voce 2 di 2 e strumenti"; j.progress = 0.46; j.emit();
    });
    await shoot("2-lavoro");
    await page.evaluate(() => { const j = IsoApp.job; j.phase = "idle"; j.peaks = null; j.stage = null; j.progress = 0; j.emit(); IsoApp.render(); });
    await page.evaluate(() => IsoApp.job.add([new File([new Uint8Array(1000)], "L'ultima canzone 🎸 è qui.mp3")]));
    await shoot("3-pronta");
    await fakeSong(page);
    await page.evaluate(async () => { const e = IsoApp.ui.library[0]; await IsoApp.job.open(e); });
    await page.waitForTimeout(1200);
    await shoot("4-risultati");
    await page.click('[data-act="settings"]').catch(() => row.problemi.push("impostazioni: il pulsante non si raggiunge"));
    await shoot("5-impostazioni");
    await page.keyboard.press("Escape");
    for (const e of errs) row.problemi.push("errore nella pagina: " + e.slice(0, 200));
    await page.close();
    // La finestra che non ci sta è un avviso finché la correzione non c'è; i pulsanti fuori e gli errori bloccano
    if (row.problemi.some((p) => !p.startsWith("la finestra di partenza"))) failed = true;
    results.push(row);
    console.log(`${name}: finestra ${row.finestra} · ${row.problemi.length ? row.problemi.length + " problemi" : "ok"}`);
  }
  await browser.close();
  server.close();
  fs.writeFileSync(path.join(out, "risultati.json"), JSON.stringify(results, null, 1));
  const md = ["| Schermo | Punti effettivi | Spazio utile | Finestra | Esito | Foto |", "|---|---|---|---|---|---|"];
  for (const r of results) md.push(`| ${r.schermo} | ${r.effettivo} | ${r.utile} | ${r.finestra} | ${r.problemi.length ? "❌ " + r.problemi.join("<br>") : "✅"} | ${r.foto.map((f) => `[${f.split("-").pop().replace(".png", "")}](${f})`).join(" ")} |`);
  fs.writeFileSync(path.join(out, "riepilogo.md"), md.join("\n") + "\n");
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.log("::error::" + e.message); process.exit(1); });
