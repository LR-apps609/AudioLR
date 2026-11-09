// Prove di regressione del sito: i bug trovati l'08/11 dai tester t17 (iPhone) e t18 (Android, rete lenta).
// Ognuno ha la sua prova: Annulla mentre si legge la canzone, nomi lunghi sul telefono, «Altri strumenti» intero,
// etichette sotto la barra in alto, tabella del confronto, download che riparte dopo un errore, offline con la cache.
//   node site/test/regressioni.test.js http://127.0.0.1:8080/
const { chromium, devices } = require(process.env.PW || "playwright");
const fs = require("fs"), os = require("os"), path = require("path");

function wav(seconds, name) {
  const rate = 44100, n = Math.round(rate * seconds), data = Buffer.alloc(44 + n * 4);
  data.write("RIFF", 0); data.writeUInt32LE(36 + n * 4, 4); data.write("WAVE", 8); data.write("fmt ", 12);
  data.writeUInt32LE(16, 16); data.writeUInt16LE(1, 20); data.writeUInt16LE(2, 22); data.writeUInt32LE(rate, 24);
  data.writeUInt32LE(rate * 4, 28); data.writeUInt16LE(4, 32); data.writeUInt16LE(16, 34); data.write("data", 36); data.writeUInt32LE(n * 4, 40);
  for (let i = 0; i < n; i++) {
    const t = i / rate, v = 0.2 * Math.sin(2 * Math.PI * 220 * t) + 0.15 * Math.sin(2 * Math.PI * 55 * t);
    const s = Math.round(v * 32767);
    data.writeInt16LE(s, 44 + i * 4); data.writeInt16LE(s, 46 + i * 4);
  }
  const file = path.join(os.tmpdir(), name);
  fs.writeFileSync(file, data);
  return file;
}

let failed = 0;
const check = (ok, msg) => { console.log((ok ? "::notice::OK " : "::error::NO ") + msg); if (!ok) failed++; };
const state = (page) => page.evaluate(() => {
  const $ = (i) => document.getElementById(i);
  return { view: ["drop", "working", "results"].filter((i) => !$(i).hidden).join(","), step: $("step").textContent,
           error: $("error").hidden ? "" : $("error").textContent, clock: $("clock").textContent };
});
async function until(page, fn, ms) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) { if (await fn(await state(page))) return true; await page.waitForTimeout(250); }
  return false;
}

(async () => {
  const url = process.argv[2];
  const browser = await chromium.launch();
  const short = wav(2, "Cortissima 2s.wav"), long = wav(40, "Lunga 40s.wav");
  const longName = wav(2, "Mio_brano_registrato_dal_vivo_al_concerto_di_capodanno_2025_master_finale_v3_DEFINITIVO.wav");

  // ── Telefono (iPhone 14): pagina che non si allarga, nomi interi, etichette, tabella ──
  {
    const context = await browser.newContext({ ...devices["iPhone 14"] });
    const page = await context.newPage();
    const errors = []; page.on("pageerror", (e) => errors.push(e.message));
    await page.goto(url);
    const margin = await page.evaluate(() => parseFloat(getComputedStyle(document.querySelector("section")).scrollMarginTop) >= document.querySelector("nav.top").offsetHeight);
    check(margin, "le sezioni non finiscono sotto la barra in alto (scroll-margin-top)");
    const table = await page.evaluate(() => { const c = document.querySelector(".compare"), t = c && c.querySelector("table"); return t ? { t: t.offsetWidth, c: c.clientWidth } : null; });
    check(table && table.t <= table.c + 1, `la tabella del confronto sta nella scheda (${JSON.stringify(table)})`);
    await page.setInputFiles("#file", longName);
    await page.waitForTimeout(500);
    const w1 = await page.evaluate(() => ({ s: document.documentElement.scrollWidth, w: innerWidth }));
    check(w1.s <= w1.w, `nome lungo senza spazi, al lavoro: la pagina resta larga ${w1.w} px (${w1.s})`);
    const done = await until(page, (s) => s.view === "results" || s.error, 10 * 60 * 1000);
    check(done, "la canzone col nome lungo si separa");
    const w2 = await page.evaluate(() => ({ s: document.documentElement.scrollWidth, w: innerWidth }));
    check(w2.s <= w2.w, `nome lungo senza spazi, risultati: la pagina resta larga ${w2.w} px (${w2.s})`);
    const cut = await page.$$eval("#stems .stem b", (els) => els.filter((e) => e.scrollWidth > e.clientWidth + 1).map((e) => e.textContent));
    check(cut.length === 0, `i nomi delle tracce si leggono interi (tagliati: ${cut.join(", ") || "nessuno"})`);
    check(errors.length === 0, "nessun errore nella pagina (telefono): " + errors.join(" | "));
    await context.close();
  }

  // ── Annulla mentre si legge la canzone, poi un'altra: si vede la canzone giusta ──
  {
    const context = await browser.newContext();
    const page = await context.newPage();
    await page.goto(url);
    await page.setInputFiles("#file", long);
    await page.click("#cancel");
    await page.setInputFiles("#file", short);
    const ok = await until(page, (s) => s.view === "results" || s.error, 10 * 60 * 1000);
    const s = await state(page);
    check(ok && /\/ 0:02$/.test(s.clock), `Annulla durante «Leggo la canzone…»: i risultati sono della canzone scelta dopo (${s.clock})`);
    await page.waitForTimeout(3000);
    const s2 = await state(page);
    check(s2.clock === s.clock, `la canzone annullata non arriva dopo a cambiare il mixer (${s2.clock})`);

    // Offline con il modello in cache: dopo un Annulla (lavoratore nuovo) senza internet si separa lo stesso
    await page.click("#again");
    await page.setInputFiles("#file", short);
    await page.waitForTimeout(300);
    await page.click("#cancel");
    await context.setOffline(true);
    await page.setInputFiles("#file", short);
    const off = await until(page, (x) => x.view === "results" || x.error, 5 * 60 * 1000);
    const s3 = await state(page);
    check(off && s3.view === "results", `senza internet, con il modello nella cache, il sito separa (${s3.view} ${s3.error})`);
    await context.setOffline(false);
    await context.close();
  }

  // ── Download del modello: dopo un errore si può riprovare (prima restava fermo su «Leggo la canzone… 0%») ──
  {
    const context = await browser.newContext();
    const page = await context.newPage();
    await context.route(/HTDemucsWeb\.onnx\.part/, (r) => r.abort("internetdisconnected"));
    await page.goto(url);
    await page.setInputFiles("#file", short);
    const err = await until(page, (s) => !!s.error, 90 * 1000);
    check(err, "senza i pezzi del modello compare l'errore");
    await context.unroute(/HTDemucsWeb\.onnx\.part/);
    await page.setInputFiles("#file", short);
    const moved = await until(page, (s) => s.view === "results" || /Scarico|Separo/.test(s.step), 30 * 1000);
    const s = await state(page);
    check(moved, `scegliendo di nuovo la canzone il download riparte («${s.step}» ${s.error})`);
    await context.close();
  }

  await browser.close();
  console.log(failed ? `::error::${failed} prove di regressione del sito non passate` : "::notice::Tutte le prove di regressione del sito passate");
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
