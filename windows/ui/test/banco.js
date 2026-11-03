// Banco dei tempi di IsoLR per Windows: l'app vera installata (isolr.exe + WebView2), guidata da fuori con il
// protocollo di debug di WebView2 (WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS), senza toccare il codice dell'app:
// così la stessa prova gira identica sulla versione di prima e su quella di adesso.
// Per ogni qualità: avvio (dal lancio a interfaccia pronta), separazione (secondi e passi), memoria massima
// (isolr.exe + processi WebView2), fluidità (blocchi lunghi della finestra e salti dei fotogrammi).
// In più «Annulla»: durante lo scaricamento di un modello e durante il calcolo nativo (quanto risponde, e quanto
// processore consuma ancora dopo). Niente esce dal computer: il risultato è un file JSON.
// Uso: node banco.js <isolr.exe> <canzone.wav> <cartella risultati> <cartella modelli dell'app> <copia dei modelli>
const { chromium } = require(process.env.PW || "playwright");
const fs = require("fs"), path = require("path"), cp = require("child_process");
const [exe, songPath, outDir, modelsDir, modelsBackup] = process.argv.slice(2);
fs.mkdirSync(outDir, { recursive: true });
const PORT = 9333;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const ps = (cmd) => cp.execFileSync("powershell", ["-NoProfile", "-Command", cmd], { encoding: "utf8" }).trim();

/** La canzone (WAV 16 bit stereo) tagliata ai primi `seconds` secondi, come byte di un WAV nuovo. */
function clip(seconds) {
  const buf = fs.readFileSync(songPath);
  let p = 12, fmt = null, data = null;
  while (p + 8 <= buf.length) {
    const id = buf.toString("ascii", p, p + 4), size = buf.readUInt32LE(p + 4);
    if (id === "fmt ") fmt = buf.subarray(p + 8, p + 8 + size);
    if (id === "data") { data = buf.subarray(p + 8, p + 8 + size); break; }
    p += 8 + size + (size & 1);
  }
  const rate = fmt.readUInt32LE(4), block = fmt.readUInt16LE(12);
  const body = data.subarray(0, Math.min(data.length, Math.round(seconds * rate) * block));
  const head = Buffer.alloc(44);
  head.write("RIFF", 0); head.writeUInt32LE(36 + body.length, 4); head.write("WAVE", 8); head.write("fmt ", 12);
  head.writeUInt32LE(16, 16); fmt.copy(head, 20, 0, 16); head.write("data", 36); head.writeUInt32LE(body.length, 40);
  return Buffer.concat([head, body]);
}

/** Chiude IsoLR e i suoi processi WebView2, e aspetta che siano spariti davvero (altrimenti la copia nuova
 *  troverebbe la vecchia ancora aperta e si chiuderebbe subito: si misurerebbe la finestra di prima). */
function kill() {
  for (let i = 0; i < 40; i++) {
    let left = "";
    try { left = ps("Get-Process isolr,msedgewebview2 -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }"); } catch {}
    if (!left) return;
    try { ps("Get-Process isolr,msedgewebview2 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue"); } catch {}
    cp.execSync("powershell -NoProfile -Command Start-Sleep -Milliseconds 500");
  }
  console.log("::warning::IsoLR non si chiude del tutto");
}

/** Memoria massima (picco del working set) in MB: isolr.exe e i processi WebView2, separati e insieme. */
function memory() {
  const out = ps("Get-Process isolr,msedgewebview2 -ErrorAction SilentlyContinue | ForEach-Object { \"$($_.ProcessName) $($_.PeakWorkingSet64) $($_.TotalProcessorTime.TotalSeconds)\" }");
  const r = { app: 0, webview: 0, cpuApp: 0, cpuWebview: 0 };
  for (const line of out.split(/\r?\n/).filter(Boolean)) {
    const [name, peak, cpu] = line.split(" ");
    if (/isolr/i.test(name)) { r.app += +peak; r.cpuApp += +cpu; } else { r.webview += +peak; r.cpuWebview += +cpu; }
  }
  return { appMB: Math.round(r.app / 1048576), webviewMB: Math.round(r.webview / 1048576), totalMB: Math.round((r.app + r.webview) / 1048576), cpu: r.cpuApp + r.cpuWebview };
}

/** Apre l'app, si collega alla sua finestra e aspetta l'interfaccia pronta. Torna { browser, page, startup }. */
async function launch() {
  kill();
  const t0 = Date.now();
  const child = cp.spawn(exe, [], { env: { ...process.env, WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS: `--remote-debugging-port=${PORT}` }, detached: true, stdio: "ignore" });
  child.unref();
  let browser = null;
  while (!browser && Date.now() - t0 < 120000) {
    try { browser = await chromium.connectOverCDP(`http://127.0.0.1:${PORT}`); } catch { await sleep(100); }
  }
  if (!browser) throw new Error("non riesco a collegarmi alla finestra di IsoLR");
  let page = null;
  while (Date.now() - t0 < 120000) {
    for (const c of browser.contexts()) for (const p of c.pages()) {
      // Solo una finestra nuova: quella di un avvio precedente ha il segno __bancoVisto
      try { if (await p.evaluate(() => typeof IsoApp === "object" && document.readyState === "complete" && !window.__bancoVisto)) page = p; } catch {}
    }
    if (page) break;
    await sleep(50);
  }
  if (!page) throw new Error("l'interfaccia non è pronta dopo 2 minuti");
  const startup = (Date.now() - t0) / 1000;
  await page.evaluate(() => { window.__bancoVisto = true; });
  if (child.exitCode != null) console.log(`::warning::isolr.exe è uscita subito (codice ${child.exitCode}): c'era ancora la copia di prima?`);
  page.on("pageerror", (e) => console.log("::warning::Errore nella pagina: " + e.message));
  // Dentro l'avvio: quanto pesa la pagina (script letti ed eseguiti) rispetto al resto (processo, WebView2)
  const pageTiming = await page.evaluate(() => {
    const n = performance.getEntriesByType("navigation")[0] || {};
    const scripts = performance.getEntriesByType("resource").filter((r) => r.initiatorType === "script");
    return { domReadyMs: Math.round(n.domContentLoadedEventEnd || 0), loadMs: Math.round(n.loadEventEnd || 0), scripts: scripts.length,
      scriptKB: Math.round(scripts.reduce((a, r) => a + (r.decodedBodySize || 0), 0) / 1024) };
  }).catch(() => null);
  return { browser, page, startup, pageTiming };
}

/** Misuratori nella pagina: blocchi lunghi (longtask), salti dei fotogrammi, passi della separazione. */
async function meters(page) {
  await page.evaluate(() => {
    const b = window.__banco = { long: [], gaps: 0, worstGap: 0, steps: [], t0: performance.now() };
    try { new PerformanceObserver((l) => { for (const e of l.getEntries()) b.long.push({ d: e.duration, stage: IsoApp.job.stage || IsoApp.job.phase }); }).observe({ type: "longtask" }); } catch {}
    let last = performance.now();
    const frame = (t) => { const g = t - last; last = t; if (g > 50) b.gaps++; if (g > b.worstGap) b.worstGap = g; if (!b.stop) requestAnimationFrame(frame); };
    requestAnimationFrame(frame);
    let prev = "";
    b.timer = setInterval(() => {
      const j = IsoApp.job, key = `${j.stage}|${String(j.step || "").replace(/\d+%|\d+\/\d+/g, "")}`;
      if (key !== prev) { prev = key; b.steps.push({ t: (performance.now() - b.t0) / 1000, stage: j.stage, step: j.step }); }
    }, 100);
  });
}

async function readMeters(page) {
  return page.evaluate(() => {
    const b = window.__banco; b.stop = true; clearInterval(b.timer);
    const long = b.long.map((x) => x.d), byStage = {};
    for (const x of b.long) { const s = byStage[x.stage] || (byStage[x.stage] = { n: 0, ms: 0, max: 0 }); s.n++; s.ms += Math.round(x.d); s.max = Math.max(s.max, Math.round(x.d)); }
    return { byStage, longTasks: long.length, longestTask: Math.round(Math.max(0, ...long)), longTotal: Math.round(long.reduce((a, x) => a + x, 0)),
      frameGaps: b.gaps, worstFrameGap: Math.round(b.worstGap), steps: b.steps };
  });
}

async function addSong(page, bytes, name, quality) {
  await page.evaluate(({ data, name, quality }) => {
    const raw = Uint8Array.from(atob(data), (c) => c.charCodeAt(0));
    IsoApp.ui.quality = quality;
    IsoApp.job.add([new File([raw], name)]);
  }, { data: bytes.toString("base64"), name, quality });
}

const until = async (page, fn, ms, every = 500) => {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (await page.evaluate(fn)) return true; await sleep(every); }
  return false;
};

/** Una separazione vera dall'inizio alla fine, con l'app appena aperta. */
async function separate(quality, seconds) {
  const { browser, page, startup, pageTiming } = await launch();
  await sleep(3000);                             // l'avvio si assesta (controllo aggiornamenti, libreria)
  await meters(page);
  await addSong(page, clip(seconds), `Banco ${quality}.wav`, quality);
  const t0 = Date.now();
  await page.evaluate((q) => IsoApp.job.start(q), quality);
  const ok = await until(page, () => ["done", "failed"].includes(IsoApp.job.phase) && !IsoApp.job.busy, 90 * 60 * 1000, 1000);
  const wall = (Date.now() - t0) / 1000;
  const m = await readMeters(page);
  const mem = memory();
  const r = await page.evaluate(() => {
    const j = IsoApp.job, c = j.current;
    return { phase: j.phase, error: j.error, folder: c && c.folder, meta: c && { took: c.meta.took, backend: c.meta.engine || c.meta.backend, stems: c.meta.stems.map((s) => ({ key: s.key, file: s.file })) } };
  });
  // Le tracce, per il confronto numerico prima/dopo
  const dest = path.join(outDir, "tracce", quality);
  fs.mkdirSync(dest, { recursive: true });
  if (r.meta) for (const s of r.meta.stems) {
    const src = path.join(r.folder, s.file);
    if (fs.existsSync(src)) fs.copyFileSync(src, path.join(dest, `${s.key}.wav`));
  }
  await browser.close().catch(() => {});
  kill();
  const res = { quality, seconds, ok: ok && r.phase === "done", error: r.error, wall, took: r.meta && r.meta.took, backend: r.meta && r.meta.backend,
    startup, pageTiming, memory: mem, fluidity: { longTasks: m.longTasks, longestTask: m.longestTask, longTotal: m.longTotal, frameGaps: m.frameGaps, worstFrameGap: m.worstFrameGap, byStage: m.byStage }, steps: m.steps };
  console.log(`::notice::${quality} ${seconds} s: ${wall.toFixed(1)} s (${res.backend || "?"}) · avvio ${startup.toFixed(1)} s · memoria ${mem.totalMB} MB · blocchi ${m.longTasks} (max ${m.longestTask} ms) per fase ${JSON.stringify(m.byStage)} ${r.error || ""}`);
  return res;
}

/** Processore usato dall'app nei `ms` successivi (secondi di CPU). */
const state = (page) => page.evaluate(() => ({ phase: IsoApp.job.phase, stage: IsoApp.job.stage, step: IsoApp.job.step, progress: IsoApp.job.progress, error: IsoApp.job.error })).catch((e) => ({ error: String(e) }));

async function cpuAfter(ms) { const a = memory().cpu; await sleep(ms); return +(memory().cpu - a).toFixed(1); }

/** «Annulla» durante lo scaricamento di un modello e durante il calcolo nativo di Studio; poi si riparte. */
async function cancelTest() {
  const out = {};
  const model = "VoceRevive.onnx";
  // Il modello voce di Studio sparisce: l'app lo deve riscaricare (610 MB)
  for (const f of fs.readdirSync(modelsDir)) if (f.startsWith("VoceRevive")) fs.rmSync(path.join(modelsDir, f));
  const { browser, page } = await launch();
  await sleep(3000);
  await addSong(page, clip(5), "Banco annulla.wav", "studio");
  await page.evaluate(() => IsoApp.job.start("studio"));
  const sawDownload = await until(page, () => /Scarico/.test(IsoApp.job.step || "") && IsoApp.job.progress > 0.02, 5 * 60 * 1000, 100);
  await sleep(1500);
  const st0 = await state(page);
  let c0 = Date.now();
  await page.evaluate(() => IsoApp.job.cancel());
  await until(page, () => IsoApp.job.phase !== "working", 15 * 60 * 1000, 50);
  const st1 = await state(page);
  out.download = { sawDownload, before: st0, after: st1, responseMs: Date.now() - c0, partial: fs.readdirSync(modelsDir).filter((f) => f.startsWith("VoceRevive")) };
  // Si riparte subito: il modello deve finire di scaricarsi (ripreso, se possibile) e poi si annulla nel calcolo
  const steps = [];
  const t1 = Date.now();
  await page.evaluate(() => IsoApp.job.start("studio"));
  const end = Date.now() + 20 * 60 * 1000;
  while (Date.now() < end) {
    const s = await page.evaluate(() => ({ stage: IsoApp.job.stage, step: IsoApp.job.step, p: IsoApp.job.progress, phase: IsoApp.job.phase }));
    if (!steps.length || steps[steps.length - 1].step !== s.step) steps.push({ t: (Date.now() - t1) / 1000, step: s.step });
    if (s.phase !== "working" || (s.stage === "separating" && s.p > 0.03)) break;
    await sleep(200);
  }
  out.restart = { downloadSeconds: (Date.now() - t1) / 1000, steps: steps.filter((s) => /Scarico|riprend|riprovo|connessione/i.test(s.step || "")).slice(0, 6).concat(steps.slice(-2)) };
  await sleep(2000);
  const st2 = await state(page);
  c0 = Date.now();
  await page.evaluate(() => IsoApp.job.cancel());
  await until(page, () => IsoApp.job.phase !== "working", 5 * 60 * 1000, 50);
  out.native = { before: st2, responseMs: Date.now() - c0, after: await state(page), cpuSecondsIn8s: await cpuAfter(8000) };
  // Dopo Annulla una nuova separazione parte e arriva in fondo (Rapida, 5 s)
  const t2 = Date.now();
  await page.evaluate(() => { IsoApp.job.start("fast"); });
  const ok = await until(page, () => ["done", "failed"].includes(IsoApp.job.phase) && !IsoApp.job.busy, 10 * 60 * 1000, 500);
  out.after = { ok: ok && (await page.evaluate(() => IsoApp.job.phase)) === "done", seconds: (Date.now() - t2) / 1000 };
  await browser.close().catch(() => {});
  kill();
  // Il modello torna com'era (per le misure successive)
  for (const f of fs.readdirSync(modelsBackup)) if (f.startsWith("VoceRevive")) fs.copyFileSync(path.join(modelsBackup, f), path.join(modelsDir, f));
  for (const f of fs.readdirSync(modelsDir)) if (/\.parziale$/.test(f)) fs.rmSync(path.join(modelsDir, f));
  console.log("Annulla, dettagli: " + JSON.stringify(out));
  console.log(`::notice::Annulla: durante lo scaricamento ${out.download.responseMs} ms · nel calcolo nativo ${out.native.responseMs} ms, processore dopo ${out.native.cpuSecondsIn8s} s in 8 s · nuova separazione ${out.after.ok ? "ok" : "NO"}`);
  return out;
}

(async () => {
  const result = { runs: [], cancel: null };
  const plan = [["fast", 30], ["best", 10], ["studio", 5]];
  for (const [q, s] of plan) {
    try { result.runs.push(await separate(q, s)); } catch (e) { console.log(`::error::${q}: ${e.message}`); result.runs.push({ quality: q, seconds: s, ok: false, error: e.message }); kill(); }
  }
  try { result.cancel = await cancelTest(); } catch (e) { console.log(`::warning::Prova di Annulla: ${e.message}`); result.cancel = { error: e.message }; kill(); }
  fs.writeFileSync(path.join(outDir, "tempi.json"), JSON.stringify(result, null, 2));
})().catch((e) => { console.log("::error::" + e.message); process.exitCode = 1; });
