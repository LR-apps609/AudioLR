// Prova nel browser vero (Chromium senza schermo): il sito separa una canzone di prova dall'inizio alla fine,
// senza errori e senza violare la regola di sicurezza (nessuna richiesta fuori dal sito).
//   node site/test/browser.test.js http://127.0.0.1:8080/
const { chromium } = require("playwright");
const fs = require("fs"), os = require("os"), path = require("path");

function testSong(seconds = 4) {
  // Accordi, basso e colpi: un WAV a 44,1 kHz stereo
  const rate = 44100, n = rate * seconds, data = Buffer.alloc(44 + n * 4);
  data.write("RIFF", 0); data.writeUInt32LE(36 + n * 4, 4); data.write("WAVE", 8); data.write("fmt ", 12);
  data.writeUInt32LE(16, 16); data.writeUInt16LE(1, 20); data.writeUInt16LE(2, 22); data.writeUInt32LE(rate, 24);
  data.writeUInt32LE(rate * 4, 28); data.writeUInt16LE(4, 32); data.writeUInt16LE(16, 34); data.write("data", 36); data.writeUInt32LE(n * 4, 40);
  for (let i = 0; i < n; i++) {
    const t = i / rate;
    let v = 0.1 * Math.sin(2 * Math.PI * 220 * t) + 0.1 * Math.sin(2 * Math.PI * 277 * t) + 0.15 * Math.sin(2 * Math.PI * 55 * t);
    v += 0.12 * Math.sin(2 * Math.PI * (440 + 60 * Math.sin(t)) * t);
    if (i % (rate / 2) < 3000) v += (Math.random() - 0.5) * 0.6 * Math.exp(-(i % (rate / 2)) / 500);
    const s = Math.max(-32767, Math.min(32767, Math.round(v * 32767)));
    data.writeInt16LE(s, 44 + i * 4); data.writeInt16LE(s, 46 + i * 4);
  }
  const file = path.join(os.tmpdir(), "Canzone di prova.wav");
  fs.writeFileSync(file, data);
  return file;
}

(async () => {
  const url = process.argv[2];
  const browser = await chromium.launch();
  const page = await browser.newPage();
  const problems = [], requests = [];
  page.on("console", (m) => { if (m.type() === "error") problems.push(m.text()); });
  page.on("pageerror", (e) => problems.push(String(e)));
  page.on("request", (r) => requests.push(r.url()));
  await page.goto(url);
  await page.setInputFiles("#file", testSong());
  const t0 = Date.now();
  await page.waitForSelector("#results:not([hidden])", { timeout: 15 * 60 * 1000 });
  const rows = await page.$$eval("#stems .stem b", (els) => els.map((e) => e.textContent));
  const backend = await page.textContent("#backend");
  console.log(`Tracce: ${rows.join(", ")} · ${backend} · ${((Date.now() - t0) / 1000).toFixed(0)} s`);
  const outside = requests.filter((u) => !u.startsWith(url) && !u.startsWith("blob:") && !u.startsWith("data:"));
  if (rows.length !== 5) throw new Error("dovevano esserci 5 tracce, ce ne sono " + rows.length);
  if (outside.length) throw new Error("richieste fuori dal sito: " + outside.join(", "));
  const csp = problems.filter((p) => /Content Security Policy|Refused/.test(p));
  if (csp.length) throw new Error("regola di sicurezza violata: " + csp.join(" | "));
  // Scorciatoie e salvataggio WAV
  await page.click('[data-preset="karaoke"]');
  const [download] = await Promise.all([page.waitForEvent("download"), page.click("#stems .stem:first-child .btn")]);
  console.log("WAV:", download.suggestedFilename());
  if (problems.length) console.log("Avvisi nella console:", problems.slice(0, 5).join(" | "));
  await page.screenshot({ path: "sito-risultati.png", fullPage: false });
  await browser.close();
  console.log("OK");
})().catch((e) => { console.error(String(e)); process.exit(1); });
