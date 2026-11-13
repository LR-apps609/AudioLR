// Prove di regressione del sito: i bug trovati l'08/11 dai tester t17 (iPhone) e t18 (Android, rete lenta).
// Ognuno ha la sua prova: Annulla mentre si legge la canzone, nomi lunghi sul telefono, «Altri strumenti» intero,
// etichette sotto la barra in alto, tabella del confronto, download che riparte dopo un errore, offline con la cache.
// Dal giro 2 (tester t10, t1, t2): riquadro «Trascina qui» e Terminale a 320/360 px, nomi delle tracce a 320/360 px,
// niente «Scarico il modello…» con il modello già nella cache; tester t5: «Scegli una canzone…» con la tastiera,
// nomi delle tracce sui pulsanti del mixer, onda della Base spenta in «Solo voce»; tester t6: la pagina nella copia
// offline dalla prima visita, impronta del modello controllata quando cambia.
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
    // Telefoni più stretti (iPhone SE 320, Android 360): prima «V…», «B…», «B…» e «Altri strumenti» sopra il pulsante M
    for (const w of [320, 360]) {
      await page.setViewportSize({ width: w, height: 640 });
      const r = await page.$$eval("#stems .stem", (rows) => rows.map((row) => {
        const b = row.querySelector("b"), m = row.querySelector(".ms.m"), rb = b.getBoundingClientRect(), rm = m && m.getBoundingClientRect();
        const over = rm && rb.right > rm.left + 1 && rb.left < rm.right && rb.bottom > rm.top + 1 && rb.top < rm.bottom;
        return { name: b.textContent, cut: b.scrollWidth > b.clientWidth + 1, over };
      }));
      const bad = r.filter((x) => x.cut || x.over).map((x) => x.name + (x.cut ? " tagliato" : "") + (x.over ? " sopra M" : ""));
      check(bad.length === 0, `a ${w} px i nomi delle tracce si leggono interi e non coprono M (${bad.join(", ") || "tutti interi"})`);
    }
    // Dal tester t5: ogni pulsante del mixer dice di quale traccia è, per il lettore di schermo
    const labels = await page.$$eval("#stems .stem", (rows) => rows.map((row) => {
      const name = row.querySelector("b").textContent;
      return [...row.querySelectorAll("button")].map((x) => x.getAttribute("aria-label") || x.textContent).filter((l) => !l.includes(name));
    }).flat());
    const all = await page.$$eval("#stems button", (bs) => bs.map((x) => x.getAttribute("aria-label") || x.textContent));
    check(labels.length === 0 && new Set(all).size === all.length, `i pulsanti M, S e WAV hanno il nome della traccia (${labels.join(", ") || all.slice(0, 3).join(", ")})`);
    // Dal tester t5: in «Solo voce» la Base non si sente, quindi la sua onda si spegne come le tracce mute
    const baseAlpha = () => page.evaluate(() => {
      const row = [...document.querySelectorAll("#stems .stem")].find((r) => r.querySelector(".ph")), c = row.querySelector("canvas");
      const d = c.getContext("2d").getImageData(0, 0, c.width, c.height).data;
      let m = 0; for (let i = 3; i < d.length; i += 4) m = Math.max(m, d[i]);
      return m;
    });
    await page.click('[data-preset="voice"]'); await page.waitForTimeout(200);
    const aVoice = await baseAlpha();
    await page.click('[data-preset="all"]'); await page.waitForTimeout(200);
    const aAll = await baseAlpha();
    check(aVoice < 100 && aAll > 200, `onda della Base: spenta in «Solo voce» (${aVoice}), piena con «Tutto» (${aAll})`);
    check(errors.length === 0, "nessun errore nella pagina (telefono): " + errors.join(" | "));
    await context.close();
  }

  // ── Dal tester t5: «Scegli una canzone…» si raggiunge con Tab e si apre con Invio o Spazio ──
  {
    const context = await browser.newContext();
    const page = await context.newPage();
    await page.goto(url);
    let reached = false;
    for (let i = 0; i < 40 && !reached; i++) { await page.keyboard.press("Tab"); reached = await page.evaluate(() => document.activeElement && document.activeElement.getAttribute("for") === "file"); }
    check(reached, "con Tab il fuoco arriva su «Scegli una canzone…»");
    const ring = await page.evaluate(() => getComputedStyle(document.activeElement).outlineStyle);
    check(reached && ring !== "none", `il fuoco su «Scegli una canzone…» si vede (contorno ${ring})`);
    for (const key of ["Enter", " "]) {
      const chooser = page.waitForEvent("filechooser", { timeout: 3000 }).then(() => true, () => false);
      if (reached) await page.keyboard.press(key);
      check(await chooser, `${key === " " ? "Spazio" : "Invio"} su «Scegli una canzone…» apre la scelta del file`);
    }
    await context.close();
  }

  // ── Telefoni stretti (dal tester t10): il riquadro «Trascina qui» e il comando del Terminale restano nella pagina ──
  for (const [w, h, scale] of [[320, 568, 2], [360, 640, 2], [640, 360, 2]]) {
    const context = await browser.newContext({ viewport: { width: w, height: h }, deviceScaleFactor: scale });
    const page = await context.newPage();
    await page.goto(url);
    const drop = await page.evaluate(() => {
      const d = document.getElementById("drop"), r = d.getBoundingClientRect();
      const out = [...d.children].filter((e) => e.offsetParent).filter((e) => { const c = e.getBoundingClientRect(); return c.left < r.left - 0.5 || c.right > r.right + 0.5; });
      return { sw: document.documentElement.scrollWidth, out: out.map((e) => e.className || e.tagName) };
    });
    check(drop.sw <= w && drop.out.length === 0, `a ${w} px «Trascina qui una canzone» sta nel suo riquadro (pagina ${drop.sw} px, fuori: ${drop.out.join(", ") || "niente"})`);
    await page.evaluate(() => { document.querySelector("details.alt").open = true; });
    const term = await page.evaluate(() => {
      const [mac, win] = document.querySelectorAll("#scarica .grid2 > .card");
      return { sw: document.documentElement.scrollWidth, mac: Math.round(mac.getBoundingClientRect().top), win: Math.round(win.getBoundingClientRect().top), two: getComputedStyle(mac.parentElement).gridTemplateColumns.split(" ").length };
    });
    check(term.sw <= w && (term.two < 2 || term.mac === term.win), `a ${w} px «Preferisci il Terminale?» aperto: pagina larga ${term.sw} px, schede Mac e Windows ${term.two > 1 ? "affiancate: " + (term.mac === term.win ? "sì" : "no") : "una sotto l'altra"}`);
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

    // Offline con il modello in cache: dopo un Annulla (lavoratore nuovo) senza internet si separa lo stesso.
    // Con il modello già nella cache non deve comparire «Scarico il modello…» (dal tester t2: «166 di 166 MB»)
    await page.evaluate(() => { window.__steps = []; new MutationObserver(() => window.__steps.push(document.getElementById("step").textContent)).observe(document.getElementById("step"), { childList: true, characterData: true, subtree: true }); });
    await page.click("#again");
    await page.setInputFiles("#file", short);
    await page.waitForTimeout(300);
    await page.click("#cancel");
    await context.setOffline(true);
    await page.setInputFiles("#file", short);
    const off = await until(page, (x) => x.view === "results" || x.error, 5 * 60 * 1000);
    const s3 = await state(page);
    check(off && s3.view === "results", `senza internet, con il modello nella cache, il sito separa (${s3.view} ${s3.error})`);
    const steps = await page.evaluate(() => window.__steps.filter((t) => /Scarico/.test(t)));
    check(steps.length === 0, `con il modello nella cache non dice che lo scarica (${steps[0] || "nessun «Scarico…»"})`);
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

  // ── Dal tester t6: dopo UNA visita la pagina e i suoi file sono già nella copia per l'offline (sw.js) ──
  {
    const context = await browser.newContext();
    const page = await context.newPage();
    await page.goto(url);
    const keys = await page.evaluate(async () => {
      await navigator.serviceWorker.ready;
      const c = await caches.open("isolr-sito-v1");
      return (await c.keys()).map((r) => new URL(r.url).pathname);
    });
    const want = ["/", "/style.css", "/app/app.js"].map((p) => new URL(p, url).pathname);
    const missing = want.filter((p) => !keys.includes(p));
    check(missing.length === 0, `dopo una sola visita la copia offline ha la pagina, lo stile e app.js (mancano: ${missing.join(", ") || "niente"})`);
    await context.close();
  }

  // ── Dal tester t6: un modello aggiornato con la stessa dimensione (impronta diversa nel JSON) non resta quello vecchio ──
  {
    const crypto = require("crypto");
    const json = await (await fetch(new URL("models/HTDemucsWeb.json", url))).json();
    const h = crypto.createHash("sha256");
    for (const part of json.parts) h.update(Buffer.from(await (await fetch(new URL("models/" + part, url))).arrayBuffer()));
    let sha = h.digest("hex");
    const context = await browser.newContext();
    await context.route(/HTDemucsWeb\.json/, async (r) => r.fulfill({ contentType: "application/json", body: JSON.stringify({ ...json, sha256: sha }) }));
    let parts = 0;
    context.on("request", (r) => { if (/HTDemucsWeb\.onnx\.part/.test(r.url())) parts++; });
    const page = await context.newPage();
    await page.goto(url);
    await page.setInputFiles("#file", short);
    const first = await until(page, (s) => s.view === "results" || s.error, 10 * 60 * 1000);
    const s1 = await state(page);
    check(first && s1.view === "results", `con l'impronta giusta nel JSON il modello si scarica e si separa (${s1.view} ${s1.error})`);
    // L'impronta controllata resta salvata: alle visite dopo non si ricalcola su 166 MB
    const sealed = await page.evaluate(async () => (await (await caches.open("audiolr-modelli-v1")).keys()).some((r) => /\?impronta$/.test(r.url)));
    check(sealed, "l'impronta controllata resta nella cache accanto ai pezzi");
    // Il «sito si aggiorna»: stessa dimensione, impronta diversa. Pagina ricaricata = lavoratore nuovo
    sha = "0".repeat(64); parts = 0;
    await page.reload();
    await page.setInputFiles("#file", short);
    await until(page, (s) => s.view === "results" || s.error, 10 * 60 * 1000);
    const s2 = await state(page);
    check(parts > 0 || /rovinato/.test(s2.error), `con un'impronta nuova i pezzi in cache non si usano senza controllo (pezzi richiesti di nuovo: ${parts}, ${s2.view} ${s2.error})`);
    await context.close();
  }

  await browser.close();
  console.log(failed ? `::error::${failed} prove di regressione del sito non passate` : "::notice::Tutte le prove di regressione del sito passate");
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
