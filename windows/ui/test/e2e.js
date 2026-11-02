// Prova completa dell'interfaccia Windows nel Chromium del server: una canzone vera separata in Rapida
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
  // «Annulla» a metà separazione: entro un secondo la canzone torna pronta, senza errori
  await page.evaluate(() => { IsoApp.job.start("fast"); });
  // Attese con page.evaluate a giro (waitForFunction nella pagina dell'app è bloccato dalla sua CSP)
  const until = async (fn, ms, every) => { const end = Date.now() + ms; while (Date.now() < end) { if (await page.evaluate(fn)) return true; await page.waitForTimeout(every); } return false; };
  await until(() => IsoApp.job.stage === "separating" && IsoApp.job.progress > 0.05, 5 * 60 * 1000, 200);
  const c0 = Date.now();
  await page.click('[data-act="cancel"]');
  await until(() => IsoApp.job.phase === "pending", 5000, 50);
  const cancelled = await page.evaluate(() => ({ phase: IsoApp.job.phase, error: IsoApp.job.error }));
  check(cancelled.phase === "pending" && !cancelled.error, `Annulla risponde in ${Date.now() - c0} ms (fase ${cancelled.phase})`);
  // Anteprima di 20 s: si separa un tratto, non va in libreria, «Indietro» riporta la canzone pronta
  const p0 = Date.now();
  await page.evaluate(() => { IsoApp.job.startPreview("fast"); });
  await until(() => ["done", "failed"].includes(IsoApp.job.phase) && !IsoApp.job.busy, 10 * 60 * 1000, 500);
  const pv = await page.evaluate(async () => {
    const j = IsoApp.job, out = { phase: j.phase, error: j.error, preview: !!j.preview, duration: j.current && j.current.meta.duration, banner: !!document.querySelector(".preview-banner") };
    await IsoApp.refreshLibrary();
    out.inLibrary = IsoApp.ui.library.some((e) => /[\\/]\.anteprima$/.test(e.folder));
    j.backFromPreview();
    out.after = j.phase;
    return out;
  });
  check(pv.phase === "done" && pv.preview && pv.banner && pv.duration <= 20.1, `anteprima in ${Math.round((Date.now() - p0) / 1000)} s (durata ${pv.duration && pv.duration.toFixed(1)} s) ${pv.error || ""}`);
  check(!pv.inLibrary && pv.after === "pending", `anteprima fuori dalla libreria, poi la canzone torna pronta (${pv.after})`);
  const t0 = Date.now();
  await page.evaluate(() => IsoApp.job.start("fast"));
  await page.waitForFunction(() => ["done", "failed"].includes(IsoApp.job.phase) && !IsoApp.job.busy, null, { timeout: 15 * 60 * 1000, polling: 1000 });
  const r = await page.evaluate(() => ({ phase: IsoApp.job.phase, error: IsoApp.job.error, meta: IsoApp.job.current && IsoApp.job.current.meta }));
  // BPM e tonalità dentro un WAV scaricato
  const tg = await page.evaluate(async () => {
    const m = IsoApp.job.current.meta, ch = Encode.readWav(await Bridge.readFile(IsoApp.job.current.folder + "/" + m.stems[0].file));
    const bytes = await Encode.encode(ch, "wav24", 1, IsoLR.Tags.info("Artista - " + m.title, m.analysis, 0));
    return IsoLR.Tags.readWav(bytes);
  });
  check(tg.TPE1 === "Artista" && (!tg.TBPM || /^\d+$/.test(tg.TBPM)), `tag nel WAV: ${JSON.stringify(tg)}`);
  check(r.phase === "done", `separazione Rapida (${Math.round((Date.now() - t0) / 1000)} s) ${r.error || ""}`);
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

    // Warp: colpi sulle ancore stirati a 100 BPM cadono dove dice la mappa (±10 ms), lunghezza esatta
    const wp = await page.evaluate(async () => {
      const W = IsoLR.Warp, RATE = 44100;
      const marks = W.downbeats(IsoApp.job.current.meta.analysis.structure);
      const dur = IsoApp.player.duration, map = W.WarpMap.toTempo(marks, 100, 4), n = Math.round(dur * RATE);
      const ch = [new Float32Array(n), new Float32Array(n)];
      for (const m of marks) for (let i = 0; i < 1500; i++) { const j = Math.round(m * RATE) + i; if (j < n) { const v = 0.8 * Math.sin(i * 0.3) * Math.exp(-i / 300); ch[0][j] = v; ch[1][j] = v; } }
      const out = await Editors.renderWarp(ch, map, dur), d = out[0], off = map.map(0);
      let worst = 0;
      for (const m of marks.slice(1, -1)) {
        const t = map.map(m) - off; let best = 0, top = 0;
        for (let i = Math.round((t - 0.1) * RATE); i < Math.round((t + 0.1) * RATE); i++) if (Math.abs(d[i]) > top) { top = Math.abs(d[i]); best = i; }
        worst = Math.max(worst, Math.abs(best / RATE - t - 0.0001));
      }
      return { marks: marks.length, len: d.length, want: Math.round(map.length(dur) * RATE), worst };
    });
    check(wp.marks >= 3 && wp.len === wp.want, `Warp a 100 BPM: ${wp.marks} segnaposto, ${wp.len} campioni (attesi ${wp.want})`);
    check(wp.worst < 0.01, `Warp: i colpi cadono sulle ancore (scarto massimo ${(wp.worst * 1000).toFixed(1)} ms)`);
    // Dall'editor: versione a tempo nella libreria
    await page.click('[data-act="warp"]');
    await page.waitForTimeout(500);
    await page.screenshot({ path: path.join(out, "win-e2e-warp.png") });
    await page.fill("#w-bpm", "100");
    await page.evaluate(() => document.querySelector(".sheet").api.makeTempo());
    await page.waitForFunction(() => /\(100 BPM\)$/.test(IsoApp.job.current.meta.title), null, { timeout: 5 * 60 * 1000, polling: 500 });
    const wv = await page.evaluate(async () => {
      const c = IsoApp.job.current, a = c.meta.analysis, b = a.structure.beats;
      const gaps = b.slice(1).map((x, i) => x - b[i]).filter((g, i) => b[i] > 0.6 && b[i + 1] < c.meta.duration - 0.6);
      const v = Encode.readWav(await Bridge.readFile(c.folder + "/" + c.meta.stems.find((s) => s.key === "drums").file));
      return { bpm: a.bpm, dur: c.meta.duration, len: v[0].length / 44100, spread: Math.max(...gaps) - Math.min(...gaps), stems: c.meta.stems.length, lib: IsoApp.ui.library.length };
    });
    check(wv.bpm === 100 && Math.abs(wv.len - wv.dur) < 0.01 && wv.spread < 0.002, `versione a tempo: ${wv.bpm} BPM, ${wv.dur.toFixed(2)} s, battiti regolari (±${(wv.spread * 1000).toFixed(1)} ms), ${wv.stems} tracce`);

    // Rimonta: togliere un blocco accorcia la canzone proprio della sua durata
    await page.evaluate(async () => { await IsoApp.openEntry(IsoApp.ui.library.find((e) => !e.meta.derivedFrom)); });
    await page.click('[data-act="arrange"]');
    await page.waitForTimeout(500);
    const rm = await page.evaluate(async () => {
      const A = IsoLR.Arrange, api = document.querySelector(".sheet").api, dur = IsoApp.player.duration;
      let b = api.blocks;
      if (b.length < 2) b = A.split(b, 0, dur / 2, IsoLR.Warp.downbeats(IsoApp.job.current.meta.analysis.structure));
      const cut = b[0].srcEnd - b[0].srcStart;
      api.set(A.remove(b, 0));
      await new Promise((r) => setTimeout(r, 300));
      return { dur, cut, blocks: b.length };
    });
    await page.screenshot({ path: path.join(out, "win-e2e-rimonta.png") });
    await page.evaluate(() => document.querySelector(".sheet").api.make());
    await page.waitForFunction(() => /\(rimontata\)$/.test(IsoApp.job.current.meta.title), null, { timeout: 5 * 60 * 1000, polling: 500 });
    const rv = await page.evaluate(async () => {
      const c = IsoApp.job.current, v = Encode.readWav(await Bridge.readFile(c.folder + "/" + c.meta.stems.find((s) => s.key === "vocals").file));
      return { dur: c.meta.duration, len: v[0].length / 44100, parts: c.meta.analysis.structure.sections.length };
    });
    check(Math.abs(rv.dur - (rm.dur - rm.cut)) < 0.001 && Math.abs(rv.len - rv.dur) < 0.001, `Rimonta: tolto un blocco di ${rm.cut.toFixed(2)} s, da ${rm.dur.toFixed(2)} a ${rv.dur.toFixed(2)} s (${rv.parts} parti)`);

    // Slice to MIDI: la batteria della canzone di prova (un colpo ogni mezzo secondo) in fette, esportate in WAV + MID
    await page.evaluate(async () => { await IsoApp.openEntry(IsoApp.ui.library.find((e) => !e.meta.derivedFrom)); await window.Slicer.open(IsoApp.job.current, IsoApp.player, "drums"); });
    const sl = await page.evaluate(async () => {
      const api = document.querySelector(".sheet").api;
      await api.ready;
      const n = api.slices.length;
      await api.exportAll();
      const dir = api.lastExport;
      const has = async (f) => Bridge.exists(`${dir}/${f}`);
      const files = await Promise.all(["Slice 01.wav", "LEGGIMI.txt"].map(has));
      const mid = dir ? await Bridge.exists(`${dir}/${dir.split("/").pop()}.mid`) : false;
      return { n, dir, wav: files[0], readme: files[1], mid, first: api.slices[0] && api.slices[0].start / 44100 };
    });
    check(sl.n >= 10 && sl.wav && sl.mid && sl.readme, `Slice: ${sl.n} fette della batteria (la prima a ${sl.first && sl.first.toFixed(2)} s), esportate WAV + MID + LEGGIMI`);
    await page.screenshot({ path: path.join(out, "win-e2e-slice.png") });
    await page.keyboard.press("Escape");

    // Piano roll: note finte (Basic Pitch non c'è qui), una spostata e allungata; il file MIDI le usa
    const pr = await page.evaluate(async () => {
      const cur = IsoApp.job.current;
      const notes = [0, 1, 2, 3].map((i) => ({ start: 0.5 + i * 0.5, end: 0.8 + i * 0.5, pitch: 57 + i * 2, velocity: 90 }));
      await Bridge.writeText(`${cur.folder}/isolr-note-bass.json`, JSON.stringify({ version: 1, detected: notes, edited: null }));
      window.PianoRoll.open(cur, IsoApp.player, "bass");
      for (let k = 0; k < 50 && !document.querySelector(".sheet").api.editor; k++) await new Promise((r) => setTimeout(r, 100));
      const api = document.querySelector(".sheet").api, ed = api.editor;
      const id = ed.notes[0].id;
      api.edit((e) => { e.move([id], 0.25, 12, null); e.resize(id, e.find(id).end + 0.5, null); });
      await new Promise((r) => setTimeout(r, 700));               // il salvataggio arriva dopo 0,4 s
      const saved = await window.PianoRoll.edited(cur, "bass");
      return { count: ed.notes.length, saved: saved && saved.find((n) => n.pitch === 69), len: saved && saved.find((n) => n.pitch === 69) };
    });
    check(pr.count === 4 && pr.saved && Math.abs(pr.len.end - pr.len.start - 0.8) < 1e-6, `Piano roll: ${pr.count} note, una spostata di un'ottava e allungata, salvata con la canzone`);
    await page.screenshot({ path: path.join(out, "win-e2e-note.png") });
    await page.keyboard.press("Escape");

    // «Progetto per…» › Ableton Live: cartella con le tracce allineate, il set .als (gzip di XML) e il MIDI del tempo
    await page.selectOption('select[data-input="project"]', "ableton");
    for (let k = 0; k < 600 && !(await page.evaluate(() => IsoApp.ui.lastProject)); k++) await page.waitForTimeout(100);
    const pj = await page.evaluate(async () => {
      const dir = IsoApp.ui.lastProject, m = IsoApp.job.current.meta;
      if (!dir) return {};
      const title = IsoLR.Daw.safe(m.title);
      const xml = new TextDecoder().decode(await IsoLR.Daw.gunzip(await Bridge.readFile(`${dir}/${title}.als`)));
      const doc = new DOMParser().parseFromString(xml, "application/xml");
      const paths = [...doc.querySelectorAll("SampleRef RelativePath")].map((e) => e.getAttribute("Value"));
      const lens = [];
      for (const p of paths) lens.push(Encode.readWav(await Bridge.readFile(`${dir}/${p}`))[0].length);
      const mid = await Bridge.readFile(`${dir}/Tempo e marcatori.mid`);
      return { ok: !doc.querySelector("parsererror"), tracks: doc.querySelectorAll("AudioTrack").length, paths, lens,
        tempo: +doc.querySelector("Tempo Manual").getAttribute("Value"), mid: String.fromCharCode(...mid.slice(0, 4)) };
    });
    check(pj.ok && pj.tracks === 4 && pj.lens && pj.lens.every((l) => l === pj.lens[0]) && pj.mid === "MThd" && pj.tempo > 40,
      `Progetto Ableton: ${pj.tracks} tracce allineate (${pj.paths && pj.paths[0]}), tempo ${pj.tempo && pj.tempo.toFixed(1)}, MIDI del tempo`);
  }
  // Transpose: +2 semitoni sposta davvero il tono, la lunghezza resta e il colpo resta al suo posto
  const tp = await page.evaluate(async () => {
    const n = 44100 * 3, a = [new Float32Array(n), new Float32Array(n)];
    for (let i = 0; i < n; i++) { const v = 0.4 * Math.sin((2 * Math.PI * 440 * i) / 44100); a[0][i] = v; a[1][i] = v; }
    const up = await Transpose.apply(a, 2);
    const C = IsoLR.Compare, x = C.decimate(up[0]), hz = [];
    for (let t = Math.floor(x.length / 4); t < (3 * x.length) / 4; t += 200) { const h = C.yin(x, t, C.rate / C.down); if (h) hz.push(h); }
    hz.sort((p, q) => p - q);
    const b = [new Float32Array(88200), new Float32Array(88200)];
    for (let i = 0; i < 2000; i++) { const v = 0.8 * Math.sin(i * 0.2) * Math.exp(-i / 400); b[0][44100 + i] = v; b[1][44100 + i] = v; }
    const s = await Transpose.apply(b, 3);
    let best = 0, m = 0; for (let i = 0; i < s[0].length; i++) if (Math.abs(s[0][i]) > m) { m = Math.abs(s[0][i]); best = i; }
    return { len: up[0].length === n, hz: hz[Math.floor(hz.length / 2)], at: best / 44100,
      capo: JSON.stringify(Transpose.capo([{ start: 0, end: 2, root: 11, minor: false }, { start: 2, end: 4, root: 6, minor: false }, { start: 4, end: 6, root: 8, minor: true }, { start: 6, end: 8, root: 4, minor: false }], 0)),
      key: Transpose.keyName(0, false, 2) };
  });
  check(tp.len && Math.abs(tp.hz - 493.88) < 6, `Transpose +2: ${tp.hz && tp.hz.toFixed(1)} Hz (atteso 493,9), stessa lunghezza`);
  check(Math.abs(tp.at - 1) < 0.03, `Transpose allineato: colpo a ${tp.at.toFixed(3)} s`);
  check(tp.capo === '{"capo":4,"shapes":["G","D","Em","C"]}' && tp.key === "Re maggiore", `capotasto ${tp.capo}, ${tp.key}`);
  // Testo sincronizzato con un testo finto: si salva con la canzone, si apre l'editor, .lrc giusto;
  // video karaoke (solo immagine: qui non c'è l'AAC) che il lettore del browser rilegge
  const ly = await page.evaluate(async () => {
    const cur = IsoApp.job.current;
    const words = [{ text: "Ciao", start: 0.5, end: 1 }, { text: "mondo.", start: 1, end: 1.8 }, { text: "Di", start: 2.5, end: 2.8 }, { text: "nuovo", start: 2.8, end: 3.5 }];
    await window.LyricsUI.save(cur.folder, { version: 1, language: "it", words, edited: false });
    window.LyricsUI.cache.clear();
    const back = await window.LyricsUI.load(cur.folder);
    window.LyricsUI.open(cur, IsoApp.player);
    await new Promise((r) => setTimeout(r, 600));
    const rows = document.querySelectorAll(".sheet .lyr-line").length;
    document.querySelector(".sheet [data-close]").click();
    const lrc = IsoLR.Lyrics.lrc(IsoLR.Lyrics.lines(back.words), "Prova");
    const n = 44100 * 3, ch = [new Float32Array(n), new Float32Array(n)];
    // Il Chromium del server può non avere l'H.264 (WebView2 di Windows sì): allora la prova del video si salta
    const h264 = typeof VideoEncoder !== "undefined" && (await VideoEncoder.isConfigSupported({ codec: "avc1.640028", width: 1080, height: 1920, bitrate: 6_000_000, framerate: 30, avc: { format: "avc" } })).supported;
    if (!h264) return { words: back.words.length, rows, lrc, meta: null };
    const mp4 = await KaraokeVideo.render({ lyrics: back, title: "Prova", audio: ch, shape: "portrait", withAudio: false });
    const v = document.createElement("video"); v.muted = true; v.src = URL.createObjectURL(new Blob([mp4], { type: "video/mp4" }));
    const meta = await new Promise((ok) => { v.onloadedmetadata = () => ok({ w: v.videoWidth, h: v.videoHeight, d: v.duration }); v.onerror = () => ok({ err: true }); setTimeout(() => ok({ timeout: true }), 8000); });
    return { words: back.words.length, rows, lrc, meta };
  });
  check(ly.words === 4 && ly.rows === 2 && ly.lrc.includes("[00:00.50]Ciao mondo.") && ly.lrc.includes("[00:02.50]Di nuovo"), `testo: ${ly.words} parole, ${ly.rows} righe nell'editor, .lrc giusto`);
  if (ly.meta) check(ly.meta.w === 1080 && ly.meta.h === 1920 && Math.abs(ly.meta.d - 3) < 0.1, `video karaoke verticale ${ly.meta.w}×${ly.meta.h}, ${ly.meta.d} s`);
  else console.log("::notice::video karaoke non provato: questo Chromium non ha l'H.264 (WebView2 di Windows sì)");
  const errBefore = errors.length;
  // Pulisci la voce: rumore e riverbero (calcoli senza modelli), dal tasto, al posto della voce nel mixer
  if (r.meta) {
    const c0 = Date.now();
    await page.evaluate(async () => {
      Prefs.set("cleanNoise", true); Prefs.set("cleanReverb", true);
      await IsoApp.openEntry(IsoApp.ui.library.find((e) => !e.meta.derivedFrom));
    });
    await page.waitForTimeout(500);
    await page.click('[data-split="clean"]');
    for (let k = 0; k < 600 && await page.evaluate(() => !!IsoApp.job.splitting || !IsoApp.job.current.meta.stems.some((s) => s.key === "clean")); k++) await page.waitForTimeout(250);
    const cl = await page.evaluate(async () => {
      const c = IsoApp.job.current, st = c.meta.stems, s = st.find((x) => x.key === "clean");
      if (!s) return { error: IsoApp.job.splitError, keys: st.map((x) => x.key).join(",") };
      const read = async (k) => Encode.readWav(await Bridge.readFile(c.folder + "/" + st.find((x) => x.key === k).file));
      const v = await read("vocals"), w = await read("clean");
      let ev = 0, ew = 0, bad = 0;
      for (let i = 0; i < v[0].length; i++) { ev += v[0][i] ** 2; ew += w[0][i] ** 2; if (!Number.isFinite(w[0][i])) bad++; }
      const rows = [...document.querySelectorAll(".rows .row b")].map((b) => b.textContent);
      return { rows, len: w[0].length === v[0].length, ratio: 10 * Math.log10(ew / (ev || 1e-12)), bad };
    });
    await page.waitForTimeout(800);
    await page.screenshot({ path: path.join(out, "win-e2e-pulizia.png") });
    check((cl.rows || []).includes("Voce pulita") && !(cl.rows || []).includes("Voce"), `nel mixer la «Voce pulita» al posto della voce: ${(cl.rows || []).join(", ")}`);
    check(cl.len && cl.bad === 0 && cl.ratio < 0.5 && cl.ratio > -40,
      `Pulisci la voce (rumore e riverbero) in ${Math.round((Date.now() - c0) / 1000)} s: «Voce pulita» ${cl.ratio != null ? cl.ratio.toFixed(1) : "?"} dB rispetto alla voce ${cl.error || ""} ${cl.keys || ""}`);
  }
  if (errors.length) console.log(`::notice::errori nella pagina prima della pulizia: ${errBefore}, dopo: ${errors.length - errBefore}`);
  check(errors.length === 0, "nessun errore nella pagina " + errors.join(" | ").slice(0, 300));
  await browser.close();
  server.close();
})().catch((e) => { console.log("::error::" + e.message); process.exit(1); });
