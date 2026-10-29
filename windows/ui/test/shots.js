// Schermate di prova dell'interfaccia Windows, nel Chromium del server (lo stesso motore di WebView2):
// inizio, canzone pronta, risultati, Esercitati, impostazioni, in chiaro e in scuro, a due misure.
// Una canzone finta (tracce sintetiche, battiti, parti, accordi) nei file «in memoria» del ponte.
// Uso: node windows/ui/test/shots.js <cartella dist> <cartella schermate>   (serve playwright)
const { chromium } = require(process.env.PW || "playwright");
const http = require("http"), fs = require("fs"), path = require("path");

const [dist, out] = process.argv.slice(2);
fs.mkdirSync(out, { recursive: true });
const types = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css", ".png": "image/png", ".json": "application/json", ".wasm": "application/wasm" };
const server = http.createServer((req, res) => {
  const p = path.join(path.resolve(dist), decodeURIComponent(req.url.split("?")[0]).replace(/^\/$/, "/index.html"));
  if (!p.startsWith(path.resolve(dist)) || !fs.existsSync(p)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { "Content-Type": types[path.extname(p)] || "application/octet-stream" });
  fs.createReadStream(p).pipe(res);
}).listen(0);

async function fakeSong(page) {
  await page.evaluate(async () => {
    const n = 44100 * 8, keys = ["vocals", "drums", "bass", "guitar", "piano", "other", "instrumental"];
    const shares = [0.28, 0.22, 0.16, 0.12, 0.09, 0.13, null];
    const folder = "C:/Users/prova/Music/IsoLR/TENDER_WIP_2 versione lunga del titolo";
    const stems = [];
    for (let i = 0; i < keys.length; i++) {
      const ch = [new Float32Array(n), new Float32Array(n)], f = 110 * (i + 1), w = 0.7 + i * 0.3;
      for (let j = 0; j < n; j++) { const t = j / 44100, v = 0.3 * Math.sin(2 * Math.PI * f * t) * (0.5 + 0.5 * Math.sin(2 * Math.PI * w * t)); ch[0][j] = v; ch[1][j] = v; }
      const file = `TENDER – ${Separation.NAMES[keys[i]]}.wav`;
      await Bridge.writeFile(`${folder}/${file}`, Encode.wav(ch, 24));
      stems.push({ key: keys[i], name: Separation.NAMES[keys[i]], file, export: file, share: shares[i], peakDB: -3, peaks: Separation.measure(ch).peaks });
    }
    const beats = []; for (let t = 0; t < 8; t += 0.25) beats.push(t);
    const meta = { version: 1, title: "TENDER_WIP_2 versione lunga del titolo", created: new Date().toISOString(), quality: "studio", duration: 280, took: 480,
      engine: "Scheda grafica (WebGPU)", gainDB: 0, source: "TENDER_WIP_2.mp3", stems,
      analysis: { bpm: 115, keyRoot: 0, minor: false, keyConfidence: 0.8,
        structure: { beats, firstDownbeat: 0, beatsPerBar: 4, sections: [
          { start: 0, end: 0.8, label: "Intro", group: 0 }, { start: 0.8, end: 2.4, label: "Strofa", group: 1 }, { start: 2.4, end: 3.7, label: "Ritornello", group: 2 },
          { start: 3.7, end: 5.3, label: "Strofa", group: 1 }, { start: 5.3, end: 7.2, label: "Ritornello", group: 2 }, { start: 7.2, end: 8, label: "Finale", group: 3 }] },
        chords: [{ start: 0, end: 2, root: 9, minor: true }, { start: 2, end: 4, root: 5, minor: false }, { start: 4, end: 6, root: 0, minor: false }, { start: 6, end: 8, root: 7, minor: false }] } };
    await Bridge.writeText(`${folder}/isolr.json`, JSON.stringify(meta));
    await IsoApp.refreshLibrary();
  });
}

(async () => {
  const browser = await chromium.launch();
  const base = `http://127.0.0.1:${server.address().port}/`;
  const errors = [];
  for (const scheme of ["light", "dark"]) {
    for (const [w, h, tag] of [[1280, 820, ""], [1180, 720, "-stretta"]]) {
      const page = await browser.newPage({ viewport: { width: w, height: h }, colorScheme: scheme, deviceScaleFactor: 1 });
      page.on("pageerror", (e) => errors.push(`[${scheme}${tag}] ${e.message}`));
      page.on("console", (m) => { if (m.type() === "error") errors.push(`[${scheme}${tag}] console: ${m.text()}`); });
      await page.goto(base);
      await page.waitForTimeout(800);
      // Di serie IsoLR è scura: per le schermate «chiaro/scuro» l'aspetto segue quello simulato
      await page.evaluate(() => { Prefs.set("appearance", "auto"); Sheets.applyAppearance(); });
      const shot = async (name) => { await page.waitForTimeout(400); await page.screenshot({ path: path.join(out, `win-${name}${tag}-${scheme === "light" ? "chiaro" : "scuro"}.png`) }); };
      await shot("1-inizio");
      // Il lavoro in corso (Studio di notte): onda d'oro con testina, equalizzatori, REC, percentuale
      await page.evaluate(() => {
        const j = IsoApp.job; j.phase = "working"; j.quality = "studio"; j.title = "Eminem – Till I Collapse"; j.setStage("separating");
        const p = new Float32Array(240); for (let i = 0; i < 240; i++) p[i] = 0.25 + 0.7 * Math.abs(Math.sin(i / 7) * Math.cos(i / 19));
        j.peaks = p; j.stageStarted = Date.now() - 95000; j.step = "Voce 2 di 2 e strumenti"; j.progress = 0.46; j.emit();
      });
      await shot("0-lavoro");
      await page.evaluate(() => { const j = IsoApp.job; j.phase = "idle"; j.peaks = null; j.stage = null; j.progress = 0; j.emit(); IsoApp.render(); });
      // Una canzone trascinata: pronta, con le schede della qualità
      await page.evaluate(() => IsoApp.job.add([new File([new Uint8Array(1000)], "Canzone di prova.mp3")]));
      await shot("2-pronta");
      await fakeSong(page);
      await page.evaluate(async () => { const e = IsoApp.ui.library[0]; await IsoApp.job.open(e); });
      await page.waitForTimeout(1500);
      await shot("3-risultati");
      await page.click('[data-act="practice"]');
      await shot("4-esercitati");
      await page.click('[data-act="practice"]');
      await page.evaluate(() => IsoApp.player.setSemitones(2));
      await page.evaluate(() => IsoApp.render());
      await page.click('[data-act="transpose"]');
      await page.waitForTimeout(1200);
      await shot("7-transpose");
      await page.keyboard.press("Escape");
      await page.evaluate(() => { IsoApp.player.setSemitones(0); IsoApp.render(); });
      // Warp: segnaposto sulle battute (uno spostato, scelto) e Rimonta: blocchi (uno spostato e uno diviso)
      await page.click('[data-act="warp"]');
      await page.waitForTimeout(600);
      await page.evaluate(() => { const a = document.querySelector(".sheet").api; const m = a.marks.slice(); m[3] += 0.12; a.set(m); });
      await page.click("#w-canvas", { position: { x: 300, y: 120 } });
      await shot("9-warp");
      await page.keyboard.press("Escape");
      await page.click('[data-act="arrange"]');
      await page.waitForTimeout(600);
      await page.evaluate(() => { const a = document.querySelector(".sheet").api; const b = IsoLR.Arrange; a.set(b.split(b.move(a.blocks, 2, 0), 1, 0.5, [0, 1, 2, 3, 4, 5, 6, 7])); });
      await shot("10-rimonta");
      await page.keyboard.press("Escape");
      // Piano roll: note finte di una melodia di basso (Basic Pitch non c'è nelle prove), una scelta
      await page.evaluate(async () => {
        const cur = IsoApp.job.current, notes = [];
        const line = [45, 45, 52, 50, 45, 43, 48, 47, 45, 52, 55, 53, 52, 50, 48, 47];
        line.forEach((p, i) => notes.push({ start: 0.12 + i * 0.5, end: 0.12 + i * 0.5 + (i % 4 === 3 ? 0.45 : 0.24), pitch: p, velocity: 60 + (i * 23) % 60 }));
        await Bridge.writeText(`${cur.folder}/isolr-note-bass.json`, JSON.stringify({ version: 1, detected: notes, edited: null }));
        window.PianoRoll.open(cur, IsoApp.player, "bass");
      });
      await page.waitForTimeout(900);
      await page.evaluate(() => { const a = document.querySelector(".sheet").api; a.select([a.editor.notes[2].id, a.editor.notes[3].id]); });
      await shot("11-note");
      await page.keyboard.press("Escape");
      await page.evaluate(() => window.Slicer.open(IsoApp.job.current, IsoApp.player, "drums"));
      await page.waitForTimeout(1200);
      await page.evaluate(() => document.querySelector(".sheet").api.play(2));
      await shot("12-slice");
      await page.keyboard.press("Escape");
      await page.click('[data-act="report"]');
      await page.fill("#r-sum", "Studio si ferma a metà");
      await shot("8-segnala");
      await page.keyboard.press("Escape");
      await page.click('[data-act="settings"]');
      await shot("5-impostazioni");
      await page.click('[data-t="motore"]');
      await shot("5b-motore");
      await page.keyboard.press("Escape");
      await page.click('[data-act="details"]');
      await shot("6-dettagli");
      await page.close();
    }
  }
  await browser.close();
  server.close();
  fs.writeFileSync(path.join(out, "errori.txt"), errors.join("\n"));
  for (const e of errors) console.log("::warning::" + e.slice(0, 300));
  console.log(`::notice::Schermate Windows: ${fs.readdirSync(out).filter((f) => f.endsWith(".png")).length} · errori nella pagina: ${errors.length}`);
})().catch((e) => { console.log("::error::" + e.message); process.exit(1); });
