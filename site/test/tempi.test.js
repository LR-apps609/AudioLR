// Banco dei tempi del sito (prima e dopo una modifica), in un Chromium vero senza schermo.
// Un piccolo server qui dentro serve la cartella del sito come GitHub Pages (Range, ETag, cache di 10 minuti)
// e conta i byte; nella pagina si registrano i cambi di testo dell'avanzamento e i blocchi lunghi (longtask).
//   node site/test/tempi.test.js <cartella-sito> <etichetta> <uscita.json> <cartella-wav> [secondi]
// Misura: peso e primo disegno della pagina (cache vuota e piena), apertura del modello a freddo e a caldo,
// separazione della stessa canzone, fluidità della pagina, memoria del browser e, a parte, un download che
// si interrompe a metà (il sito deve riprendere da solo). Nessun dato esce dal computer: solo 127.0.0.1.
const { chromium } = require("playwright");
const fs = require("fs"), os = require("os"), path = require("path"), http = require("http"), crypto = require("crypto");
const { execSync } = require("child_process");

const [ROOT, LABEL, OUT, WAVDIR, SECS] = process.argv.slice(2);
const SECONDS = Number(SECS || 30);

// ── La canzone di prova: sempre la stessa (numeri pseudo-casuali con seme fisso) ──
function testSong(seconds) {
  const rate = 44100, n = rate * seconds, data = Buffer.alloc(44 + n * 4);
  data.write("RIFF", 0); data.writeUInt32LE(36 + n * 4, 4); data.write("WAVE", 8); data.write("fmt ", 12);
  data.writeUInt32LE(16, 16); data.writeUInt16LE(1, 20); data.writeUInt16LE(2, 22); data.writeUInt32LE(rate, 24);
  data.writeUInt32LE(rate * 4, 28); data.writeUInt16LE(4, 32); data.writeUInt16LE(16, 34); data.write("data", 36); data.writeUInt32LE(n * 4, 40);
  let seed = 12345;
  const rnd = () => ((seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);
  for (let i = 0; i < n; i++) {
    const t = i / rate;
    let v = 0.1 * Math.sin(2 * Math.PI * 220 * t) + 0.1 * Math.sin(2 * Math.PI * 277 * t) + 0.15 * Math.sin(2 * Math.PI * 55 * t);
    // Una «voce» che sale e scende, con vibrato
    v += 0.12 * (0.5 + 0.5 * Math.sin(2 * Math.PI * 0.2 * t)) * Math.sin(2 * Math.PI * (440 + 60 * Math.sin(t)) * t);
    if (i % (rate / 2) < 3000) v += (rnd() - 0.5) * 0.6 * Math.exp(-(i % (rate / 2)) / 500);
    const l = Math.max(-32767, Math.min(32767, Math.round(v * 32767)));
    const r = Math.max(-32767, Math.min(32767, Math.round((v * 0.9 + 0.02 * Math.sin(2 * Math.PI * 330 * t)) * 32767)));
    data.writeInt16LE(l, 44 + i * 4); data.writeInt16LE(r, 46 + i * 4);
  }
  const file = path.join(os.tmpdir(), "Canzone di prova.wav");
  fs.writeFileSync(file, data);
  return file;
}

// ── Il server, come GitHub Pages ──
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css", ".json": "application/json",
  ".wasm": "application/wasm", ".png": "image/png", ".webp": "image/webp", ".svg": "image/svg+xml" };
let served = 0;           // byte mandati al browser
let cutOnce = null;       // per la prova di interruzione: nome del file da troncare una volta, e dopo quanti byte
function serve(port) {
  return new Promise((resolve) => {
    const srv = http.createServer((req, res) => {
      const rel = decodeURIComponent(new URL(req.url, "http://x").pathname);
      let file = path.join(ROOT, rel.endsWith("/") ? rel + "index.html" : rel);
      if (!file.startsWith(path.resolve(ROOT)) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) { res.writeHead(404); return res.end(); }
      const st = fs.statSync(file), etag = `"${st.size.toString(16)}-${Math.floor(st.mtimeMs).toString(16)}"`;
      const head = { "Content-Type": TYPES[path.extname(file)] || "application/octet-stream", "Cache-Control": "max-age=600",
        "ETag": etag, "Last-Modified": st.mtime.toUTCString(), "Accept-Ranges": "bytes" };
      if (req.headers["if-none-match"] === etag) { res.writeHead(304, head); return res.end(); }
      let start = 0, end = st.size - 1, status = 200;
      const m = /bytes=(\d+)-(\d*)/.exec(req.headers.range || "");
      if (m) { start = Number(m[1]); end = m[2] ? Number(m[2]) : end; status = 206; head["Content-Range"] = `bytes ${start}-${end}/${st.size}`; }
      head["Content-Length"] = end - start + 1;
      res.writeHead(status, head);
      const stream = fs.createReadStream(file, { start, end });
      let sent = 0;
      const cut = cutOnce && path.basename(file) === cutOnce.name && status === 200 ? cutOnce : null;
      stream.on("data", (chunk) => {
        if (cut && sent + chunk.length > cut.after) {
          // La connessione cade a metà: il browser riceve un pezzo e poi niente
          res.write(chunk.subarray(0, cut.after - sent)); served += cut.after - sent; cutOnce = null;
          stream.destroy(); res.socket.destroy(); return;
        }
        sent += chunk.length; served += chunk.length;
        if (!res.write(chunk)) { stream.pause(); res.once("drain", () => stream.resume()); }
      });
      stream.on("end", () => res.end());
    });
    srv.listen(port, "127.0.0.1", () => resolve(srv));
  });
}

// Memoria: la somma della memoria residente di tutti i processi di Chromium (pagina, lavoratore, GPU)
function chromeRSS() {
  try {
    const out = execSync("ps -eo rss=,comm=", { encoding: "utf8" });
    return out.split("\n").filter((l) => /chrom|headless/i.test(l)).reduce((s, l) => s + Number(l.trim().split(/\s+/)[0] || 0), 0) / 1024;
  } catch { return 0; }
}

// Nella pagina: i cambi di testo dell'avanzamento e i blocchi lunghi
const INIT = () => {
  window.__t = { steps: [], updates: 0, longtasks: [] };
  try { new PerformanceObserver((l) => { for (const e of l.getEntries()) window.__t.longtasks.push([e.startTime, e.duration]); }).observe({ type: "longtask", buffered: true }); } catch {}
  document.addEventListener("DOMContentLoaded", () => {
    const step = document.getElementById("step"), pct = document.getElementById("percent");
    if (step) new MutationObserver(() => window.__t.steps.push([performance.now(), step.textContent])).observe(step, { childList: true, characterData: true, subtree: true });
    if (pct) new MutationObserver(() => window.__t.updates++).observe(pct, { childList: true, characterData: true, subtree: true });
  });
};

async function visit(page, url) {
  served = 0;
  const t0 = Date.now();
  await page.goto(url, { waitUntil: "load" });
  await page.waitForTimeout(500);
  const fcp = await page.evaluate(() => (performance.getEntriesByName("first-contentful-paint")[0] || {}).startTime || null);
  return { byte_pagina: served, primo_disegno_ms: fcp && Math.round(fcp), caricata_ms: Date.now() - t0 };
}

async function separate(page, song) {
  served = 0;
  let peak = 0;
  const timer = setInterval(() => { peak = Math.max(peak, chromeRSS()); }, 250);
  const t0 = await page.evaluate(() => performance.now());
  await page.setInputFiles("#file", song);
  await page.waitForSelector("#results:not([hidden]), #error:not([hidden])", { timeout: 60 * 60 * 1000 });
  clearInterval(timer);
  const err = await page.isVisible("#error") ? await page.textContent("#error") : null;
  const t = await page.evaluate(() => window.__t);
  const t1 = await page.evaluate(() => performance.now());
  const sepAt = (t.steps.find((s) => /Separo/.test(s[1])) || [null])[0];
  const lt = t.longtasks.filter(([s]) => sepAt != null && s >= sepAt && s <= t1);
  const took = err ? null : await page.textContent("#took");
  const r = {
    errore: err,
    modello_pronto_s: sepAt != null ? +((sepAt - t0) / 1000).toFixed(2) : null,
    separazione_s: sepAt != null ? +((t1 - sepAt) / 1000).toFixed(2) : null,
    totale_s: +((t1 - t0) / 1000).toFixed(2),
    byte_rete: served,
    aggiornamenti_barra: t.updates,
    longtask: { numero: lt.length, totale_ms: Math.round(lt.reduce((s, x) => s + x[1], 0)), massimo_ms: Math.round(Math.max(0, ...lt.map((x) => x[1]))) },
    memoria_max_mb: Math.round(peak),
    testo: took,
    passi: [...new Set(t.steps.map((s) => s[1].replace(/\d+/g, "#")))].slice(0, 8),
  };
  await page.evaluate(() => { window.__t.steps = []; window.__t.updates = 0; window.__t.longtasks = []; });
  return r;
}

async function saveWavs(page, dir) {
  fs.mkdirSync(dir, { recursive: true });
  const rows = await page.$$("#stems .stem");
  for (const row of rows) {
    const name = await row.$eval("b", (e) => e.textContent);
    const [d] = await Promise.all([page.waitForEvent("download"), row.$eval(".btn", (b) => b.click())]);
    await d.saveAs(path.join(dir, name + ".wav"));
  }
  return rows.length;
}

(async () => {
  const song = testSong(SECONDS);
  const srv = await serve(8090);
  const url = "http://127.0.0.1:8090/";
  const browser = await chromium.launch();
  const result = { etichetta: LABEL, secondi_canzone: SECONDS, macchina: `${os.cpus().length} processori, ${Math.round(os.totalmem() / 2 ** 30)} GB` };

  // 1) Prima visita (cache vuota), canzone, WAV; 2) seconda visita (cache piena), stessa canzone
  const ctx = await browser.newContext({ acceptDownloads: true });
  await ctx.addInitScript(INIT);
  const page = await ctx.newPage();
  result.visita_fredda = await visit(page, url);
  result.separazione_fredda = await separate(page, song);
  console.log(LABEL, "fredda", JSON.stringify(result.separazione_fredda));
  if (!result.separazione_fredda.errore) result.tracce = await saveWavs(page, WAVDIR);
  result.visita_calda = await visit(page, url);
  result.separazione_calda = await separate(page, song);
  console.log(LABEL, "calda", JSON.stringify(result.separazione_calda));
  await ctx.close();

  // 3) La rete cade a metà del modello (cache vuota): il sito riparte da solo?
  const ctx2 = await browser.newContext();
  await ctx2.addInitScript(INIT);
  const p2 = await ctx2.newPage();
  await visit(p2, url);
  cutOnce = { name: "HTDemucsWeb.onnx.part0", after: 30 * 2 ** 20 };
  const short = testSong(5);
  result.interruzione = await separate(p2, short);
  result.interruzione.ripreso = !result.interruzione.errore;
  console.log(LABEL, "interruzione", JSON.stringify(result.interruzione));
  await ctx2.close();

  await browser.close();
  srv.close();
  fs.writeFileSync(OUT, JSON.stringify(result, null, 1));
  console.log("OK", OUT);
})().catch((e) => { console.error(String(e && e.stack || e)); process.exit(1); });
