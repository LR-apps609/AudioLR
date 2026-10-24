// Prove approfondite del sito in un browser vero (Chromium, Firefox o WebKit, il motore di Safari):
// file sbagliati, canzoni corte, mono a 48 kHz, annulla, seconda canzone, WAV giusti (24 bit, lunghezza,
// voce + base = canzone), barra spaziatrice, telefono senza scorrimento laterale, tema scuro.
//   BROWSER=firefox LUNGA=40 node site/test/browser-full.test.js http://127.0.0.1:8080/
const pw = require("playwright");
const fs = require("fs"), os = require("os"), path = require("path");

const NAME = process.env.BROWSER || "chromium";
const LONG = Number(process.env.LUNGA || 0); // secondi della canzone lunga (0 = salta)
const MIN = 60 * 1000;

function wav({ seconds, rate = 44100, channels = 2, file }) {
  const n = Math.round(rate * seconds), bytes = n * channels * 2, data = Buffer.alloc(44 + bytes);
  data.write("RIFF", 0); data.writeUInt32LE(36 + bytes, 4); data.write("WAVE", 8); data.write("fmt ", 12);
  data.writeUInt32LE(16, 16); data.writeUInt16LE(1, 20); data.writeUInt16LE(channels, 22); data.writeUInt32LE(rate, 24);
  data.writeUInt32LE(rate * channels * 2, 28); data.writeUInt16LE(channels * 2, 32); data.writeUInt16LE(16, 34);
  data.write("data", 36); data.writeUInt32LE(bytes, 40);
  let seed = 7;
  const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647) - 0.5;
  for (let i = 0; i < n; i++) {
    const t = i / rate, beat = i % Math.round(rate / 2);
    let v = 0.1 * Math.sin(2 * Math.PI * 220 * t) + 0.1 * Math.sin(2 * Math.PI * 277 * t) + 0.15 * Math.sin(2 * Math.PI * 55 * t);
    v += 0.12 * Math.sin(2 * Math.PI * (440 + 60 * Math.sin(t)) * t);
    if (beat < 3000) v += rnd() * 0.6 * Math.exp(-beat / 500);
    for (let c = 0; c < channels; c++) {
      const s = Math.max(-32767, Math.min(32767, Math.round(v * (c ? 0.9 : 1) * 32767)));
      data.writeInt16LE(s, 44 + (i * channels + c) * 2);
    }
  }
  // In memoria e con il nome vero (accenti compresi): con i percorsi accentati Playwright non carica il file
  return { name: file, mimeType: "audio/wav", buffer: data };
}

// Legge un WAV PCM (16 o 24 bit) come canali di numeri tra −1 e 1
function readWav(p) {
  const b = Buffer.isBuffer(p) ? p : p.buffer || fs.readFileSync(p);
  if (b.toString("ascii", 0, 4) !== "RIFF" || b.toString("ascii", 8, 12) !== "WAVE") throw new Error(p + " non è un WAV");
  let o = 12, fmt = null, data = null;
  while (o + 8 <= b.length) {
    const id = b.toString("ascii", o, o + 4), size = b.readUInt32LE(o + 4);
    if (id === "fmt ") fmt = { channels: b.readUInt16LE(o + 10), rate: b.readUInt32LE(o + 12), bits: b.readUInt16LE(o + 22) };
    if (id === "data") data = b.subarray(o + 8, o + 8 + size);
    o += 8 + size + (size & 1);
  }
  const bps = fmt.bits / 8, n = data.length / (bps * fmt.channels);
  const ch = Array.from({ length: fmt.channels }, () => new Float64Array(n));
  for (let i = 0; i < n; i++) for (let c = 0; c < fmt.channels; c++) {
    const k = (i * fmt.channels + c) * bps;
    ch[c][i] = fmt.bits === 16 ? data.readInt16LE(k) / 32768 : data.readIntLE(k, 3) / 8388608;
  }
  return { ...fmt, n, ch };
}

// Quanto `b` somiglia ad `a` (dB) dopo il miglior guadagno comune
function match(a, b) {
  let ab = 0, bb = 0;
  for (let i = 0; i < a.length; i++) { ab += a[i] * b[i]; bb += b[i] * b[i]; }
  const g = bb ? ab / bb : 0;
  let s = 0, e = 0;
  for (let i = 0; i < a.length; i++) { s += a[i] * a[i]; const d = a[i] - g * b[i]; e += d * d; }
  return 10 * Math.log10(s / Math.max(e, 1e-20));
}

const check = (ok, msg) => { if (!ok) throw new Error(msg); };
let step = "";
const log = (...a) => console.log(`[${NAME}]`, ...a);

(async () => {
  const url = process.argv[2];
  const browser = await pw[NAME].launch();
  const context = await browser.newContext({ acceptDownloads: true });
  const page = await context.newPage();
  const problems = [], requests = [];
  page.on("console", (m) => { if (m.type() === "error" || m.type() === "warning") problems.push(m.text()); });
  page.on("worker", (w) => { w.on("close", () => problems.push("lavoratore chiuso")); });
  page.on("requestfailed", (r) => problems.push("richiesta fallita: " + r.url() + " " + (r.failure() || {}).errorText));
  globalThis.__diag = async () => {
    const state = await page.evaluate(() => ({
      step: document.getElementById("step").textContent, percent: document.getElementById("percent").textContent,
      error: document.getElementById("error").textContent, backend: document.getElementById("backend").textContent,
      gpu: "gpu" in navigator, isolated: self.crossOriginIsolated, caches: "caches" in self,
    })).catch((e) => String(e));
    return JSON.stringify(state) + " | console: " + problems.slice(-8).join(" | ");
  };
  page.on("pageerror", (e) => problems.push(String(e)));
  page.on("request", (r) => requests.push(r.url()));
  const visible = (sel) => page.isVisible(sel);
  const results = () => page.waitForSelector("#results:not([hidden])", { timeout: (NAME === "chromium" ? 20 : NAME === "firefox" ? 12 : 5) * MIN });
  const errorShown = async (re) => {
    await page.waitForSelector("#error:not([hidden])", { timeout: 2 * MIN });
    const t = await page.textContent("#error");
    check(re.test(t), `messaggio sbagliato: «${t}»`);
    check(await visible("#drop"), "dopo l'errore deve tornare l'inizio");
    return t;
  };
  await page.goto(url);

  step = "file che non è audio";
  await page.setInputFiles("#file", { name: "Non è audio.mp3", mimeType: "audio/mpeg", buffer: Buffer.from("questo non è un mp3") });
  log("File sbagliato:", await errorShown(/non si apre/));

  step = "canzone troppo corta";
  await page.setInputFiles("#file", wav({ seconds: 0.5, file: "Corta.wav" }));
  log("Troppo corta:", await errorShown(/troppo corta/));

  step = "canzone di 4 s";
  const song = wav({ seconds: 4, file: "Perché – canzone di prova.wav" });
  let t0 = Date.now();
  await page.setInputFiles("#file", song);
  check(await visible("#working"), "durante il lavoro si deve vedere la barra");
  await results();
  const first = (Date.now() - t0) / 1000;
  const names = await page.$$eval("#stems .stem b", (els) => els.map((e) => e.textContent));
  log(`4 s: ${names.join(", ")} · ${await page.textContent("#backend")} · ${first.toFixed(0)} s (con il modello)`);
  check(names.length === 5, "dovevano esserci 5 tracce, ce ne sono " + names.length);
  for (const id of ["#drop", "#working", "#error"]) check(!(await visible(id)), id + " visibile insieme ai risultati");

  step = "WAV delle tracce";
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "wav-"));
  const files = {};
  const rows = await page.$$("#stems .stem");
  for (let i = 0; i < rows.length; i++) {
    const [d] = await Promise.all([page.waitForEvent("download"), rows[i].$(".btn").then((b) => b.click())]);
    const p = path.join(dir, d.suggestedFilename());
    await d.saveAs(p);
    files[names[i]] = readWav(p);
  }
  const mix = readWav(song);
  for (const [k, w] of Object.entries(files)) {
    check(w.bits === 24 && w.rate === 44100 && w.channels === 2, `${k}: formato ${w.bits} bit ${w.rate} Hz ${w.channels} canali`);
    check(w.n === mix.n, `${k}: ${w.n} campioni invece di ${mix.n}`);
  }
  const voc = files["Voce"], base = files["Base (senza voce)"];
  const sum = voc.ch[0].map((v, i) => v + base.ch[0][i]);
  const back = match(mix.ch[0], sum);
  const parts = files["Batteria"].ch[0].map((v, i) => v + files["Basso"].ch[0][i] + files["Altri strumenti"].ch[0][i]);
  const inner = match(base.ch[0], parts); // la rete non somma esattamente: solo un controllo di buon senso
  log(`WAV a 24 bit giusti · voce + base = canzone ${back.toFixed(1)} dB · batteria + basso + altro ≈ base ${inner.toFixed(1)} dB`);
  check(back > 60, "voce + base devono ridare la canzone");
  check(inner > 12, "batteria + basso + altro devono somigliare alla base");

  step = "mixer e barra spaziatrice";
  await page.click('[data-preset="karaoke"]');
  check((await page.getAttribute('[data-preset="karaoke"]', "aria-pressed")) === "true", "Karaoke non selezionato");
  await page.locator("#title").click();
  await page.keyboard.press("Space");
  await page.waitForTimeout(400);
  check((await page.getAttribute("#play", "aria-label")) === "Pausa", "la barra spaziatrice non fa partire la canzone");
  await page.keyboard.press("Space");
  check((await page.getAttribute("#play", "aria-label")) === "Suona", "la barra spaziatrice non mette in pausa");
  log("Mixer, Karaoke e barra spaziatrice OK");

  step = "seconda canzone (mono, 48 kHz)";
  await page.click("#again");
  check(await visible("#drop"), "«Un'altra canzone» deve riportare all'inizio");
  t0 = Date.now();
  await page.setInputFiles("#file", wav({ seconds: 3, rate: 48000, channels: 1, file: "Mono 48k.wav" }));
  await results();
  log(`Mono a 48 kHz: ${(await page.$$("#stems .stem")).length} tracce in ${((Date.now() - t0) / 1000).toFixed(0)} s (modello già pronto)`);
  const [d2] = await Promise.all([page.waitForEvent("download"), page.click("#stems .stem:first-child .btn")]);
  const p2 = path.join(dir, "mono.wav");
  await d2.saveAs(p2);
  const w2 = readWav(p2);
  check(Math.abs(w2.n - 3 * 44100) <= 2, `mono 48 kHz: ${w2.n} campioni invece di ${3 * 44100}`);

  step = "annulla";
  await page.click("#again");
  await page.setInputFiles("#file", wav({ seconds: 30, file: "Da annullare.wav" }));
  // Senza waitForFunction: la regola di sicurezza del sito (giustamente) vieta eval
  for (const end = Date.now() + 10 * MIN; parseInt(await page.textContent("#percent")) === 0; ) {
    check(Date.now() < end, "la barra non si muove");
    await page.waitForTimeout(300);
  }
  await page.click("#cancel");
  await page.waitForSelector("#drop:not([hidden])", { timeout: 5 * MIN });
  check(!(await visible("#error")), "annullare non deve mostrare un errore");
  log("Annulla OK");

  if (LONG) {
    step = `canzone di ${LONG} s`;
    t0 = Date.now();
    await page.setInputFiles("#file", wav({ seconds: LONG, file: "Lunga.wav" }));
    await results();
    log(`${LONG} s separati in ${((Date.now() - t0) / 1000).toFixed(0)} s`);
  }

  step = "telefono e tema scuro";
  await page.setViewportSize({ width: 390, height: 844 });
  await page.emulateMedia({ colorScheme: "dark" });
  await page.waitForTimeout(300);
  const wide = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  check(wide <= 1, `sul telefono la pagina scorre di lato di ${wide} px`);
  const bg = await page.evaluate(() => getComputedStyle(document.body).backgroundColor);
  log("Telefono senza scorrimento laterale · sfondo scuro", bg);
  await page.screenshot({ path: `sito-telefono-${NAME}.png`, fullPage: false });
  await page.click("#again").catch(() => {});
  await page.goto(url);
  const wide2 = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  check(wide2 <= 1, `pagina iniziale sul telefono: scorre di lato di ${wide2} px`);
  await page.screenshot({ path: `sito-telefono-inizio-${NAME}.png`, fullPage: true });

  step = "privacy";
  const outside = requests.filter((u) => !u.startsWith(url) && !u.startsWith("blob:") && !u.startsWith("data:"));
  check(!outside.length, "richieste fuori dal sito: " + outside.join(", "));
  const csp = problems.filter((p) => /Content Security Policy|Refused|CSP/.test(p));
  check(!csp.length, "regola di sicurezza violata: " + csp.join(" | "));
  const other = problems.filter((p) => !/Non ci sono riuscito|annullato|decod|Unable to decode|EncodingError/i.test(p));
  if (other.length) log("Avvisi nella console:", other.slice(0, 5).join(" | "));
  log(`Nessuna richiesta fuori dal sito (${requests.length} richieste in tutto)`);
  await browser.close();
  log("TUTTO OK");
})().catch(async (e) => {
  console.error(`[${NAME}] NON RIUSCITA («${step}»): ${String(e).split("\n")[0]}`);
  if (globalThis.__diag) console.error(`[${NAME}] Stato: ${await globalThis.__diag()}`);
  process.exit(1);
});
