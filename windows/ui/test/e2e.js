// Prova completa dell'interfaccia Windows nel Chromium del server: una canzone vera separata in Veloce
// (HTDemucs nel processore), tracce salvate, tempo e tonalità, mixer, download in WAV e FLAC.
// Uso: node windows/ui/test/e2e.js <cartella dist> <canzone.wav> <cartella schermate>
const { chromium } = require(process.env.PW || "playwright");
const http = require("http"), fs = require("fs"), path = require("path");
const [dist, song, out] = process.argv.slice(2);
fs.mkdirSync(out, { recursive: true });
const root = path.resolve(dist);
const types = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css", ".png": "image/png", ".json": "application/json", ".wasm": "application/wasm" };
const server = http.createServer((req, res) => {
  const p = path.join(root, decodeURIComponent(req.url.split("?")[0]).replace(/^\/$/, "/index.html"));
  if (!p.startsWith(root) || !fs.existsSync(p)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { "Content-Type": types[path.extname(p)] || "application/octet-stream" });
  fs.createReadStream(p).pipe(res);
}).listen(0);
const check = (ok, msg) => { console.log((ok ? "::notice::OK " : "::error::NO ") + msg); if (!ok) process.exitCode = 1; };

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1280, height: 820 } });
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  await page.waitForTimeout(800);
  const b64 = fs.readFileSync(song).toString("base64");
  await page.evaluate((data) => {
    const bytes = Uint8Array.from(atob(data), (c) => c.charCodeAt(0));
    IsoApp.ui.quality = "fast";
    IsoApp.job.add([new File([bytes], "Canzone di prova.wav")]);
  }, b64);
  const t0 = Date.now();
  await page.evaluate(() => IsoApp.job.start("fast"));
  await page.waitForFunction(() => ["done", "failed"].includes(IsoApp.job.phase) && !IsoApp.job.busy, null, { timeout: 15 * 60 * 1000, polling: 1000 });
  const r = await page.evaluate(() => ({ phase: IsoApp.job.phase, error: IsoApp.job.error, meta: IsoApp.job.current && IsoApp.job.current.meta }));
  check(r.phase === "done", `separazione Veloce (${Math.round((Date.now() - t0) / 1000)} s) ${r.error || ""}`);
  if (r.meta) {
    const keys = r.meta.stems.map((s) => s.key).join(",");
    check(keys === "vocals,drums,bass,other,instrumental", "tracce: " + keys);
    const a = r.meta.analysis || {};
    check(a.bpm > 40 && a.bpm < 250, `tempo ${a.bpm && a.bpm.toFixed(1)} BPM, tonalità ${a.keyRoot} ${a.minor ? "minore" : "maggiore"}, battiti ${a.structure ? a.structure.beats.length : 0}, accordi ${a.chords ? a.chords.length : 0}`);
    const shares = r.meta.stems.filter((s) => s.share != null).reduce((s, x) => s + x.share, 0);
    check(Math.abs(shares - 1) < 0.02, "quote delle tracce sommano a 1");
    await page.waitForTimeout(1500);
    await page.screenshot({ path: path.join(out, "win-e2e-risultati.png") });
    // Voce + base ridanno la canzone
    const sum = await page.evaluate(async () => {
      const c = IsoApp.job.current, read = async (k) => Encode.readWav(await Bridge.readFile(c.folder + "/" + c.meta.stems.find((s) => s.key === k).file));
      const v = await read("vocals"), b = await read("instrumental"), d = await read("drums"), ba = await read("bass"), o = await read("other");
      let e = 0, n = 0;
      for (let i = 0; i < v[0].length; i += 7) { const s4 = d[0][i] + ba[0][i] + o[0][i] + v[0][i], s2 = v[0][i] + b[0][i]; e += (s4 - s2) ** 2; n += s2 * s2; }
      return 10 * Math.log10(n / (e || 1e-12));
    });
    check(sum > 10, `voce + base contro la somma delle 4 tracce: ${sum.toFixed(1)} dB`);
    // Mixer: suona, karaoke, mix scaricato in FLAC
    const mix = await page.evaluate(async () => {
      const p = IsoApp.player;
      await p.play(0); await new Promise((r) => setTimeout(r, 600)); const pos = p.position; p.preset("karaoke"); const pre = p.currentPreset; p.pause();
      const m = p.mixdown(null); const flac = Encode.flac(m.channels, m.gain);
      return { pos, pre, flac: flac.length, name: p.exportName("Canzone") };
    });
    check(mix.pos > 0.2, `il mixer suona (posizione ${mix.pos.toFixed(2)} s)`);
    check(mix.pre === "karaoke" && mix.name === "Canzone – Karaoke", `karaoke: ${mix.name}`);
    check(mix.flac > 1000, `mix in FLAC: ${mix.flac} byte`);
  }
  check(errors.length === 0, "nessun errore nella pagina " + errors.join(" | ").slice(0, 300));
  await browser.close();
  server.close();
})().catch((e) => { console.log("::error::" + e.message); process.exit(1); });
