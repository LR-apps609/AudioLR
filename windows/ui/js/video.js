// Video karaoke, come Sources/KaraokeVideo.swift sul Mac: la base (o con la voce bassa) e il testo che si
// illumina parola per parola, sullo sfondo dello «Studio di notte» con l'onda che scorre. MP4 H.264 + AAC,
// orizzontale 1920×1080 o verticale 1080×1920. I fotogrammi si disegnano in un canvas e si comprimono con
// WebCodecs (VideoEncoder); l'AAC e i mattoni dell'MP4 sono quelli di js/encode.js.
/* global Encode, IsoLR */
(function () {
  "use strict";
  const K = IsoLR.Karaoke, RATE = 44100;
  const GOLD = "#D6AA62";

  /** Un fotogramma (anche per le schermate di prova). */
  function draw(g, f, { title, peaks, t, duration, w, h }) {
    g.fillStyle = "#0B0A10";
    g.fillRect(0, 0, w, h);
    const halo = g.createRadialGradient(w * 0.6, -h * 0.05, 0, w * 0.6, -h * 0.05, Math.max(w, h) * 0.75);
    halo.addColorStop(0, "#2A2140"); halo.addColorStop(1, "rgba(11,10,16,0)");
    g.fillStyle = halo; g.fillRect(0, 0, w, h);
    wave(g, peaks, t, duration, w, h);
    const small = Math.min(w, h);
    g.textAlign = "center"; g.textBaseline = "middle";
    const font = (px, weight = 700) => `${weight} ${Math.round(px)}px "Segoe UI Variable Display", "Segoe UI", system-ui, sans-serif`;
    if (f.showTitle) {
      g.font = font(small * 0.075); g.fillStyle = "#fff";
      wrap(g, title, w / 2, h * 0.45, w * 0.86, small * 0.09);
      g.font = font(small * 0.035, 600); g.fillStyle = GOLD;
      g.fillText("IsoLR · karaoke", w / 2, h * 0.56);
      return;
    }
    if (f.lineWords.length) {
      g.font = font(small * 0.07);
      const sp = g.measureText(" ").width;
      const widths = f.lineWords.map((x) => g.measureText(x).width);
      // A capo se la riga non ci sta: si dividono le parole in righe da al massimo l'88% della larghezza
      const rows = [[]]; let rw = 0;
      widths.forEach((ww, k) => { if (rw && rw + sp + ww > w * 0.88) { rows.push([]); rw = 0; } rows[rows.length - 1].push(k); rw += (rw ? sp : 0) + ww; });
      const lh = small * 0.085, y0 = h * 0.46 - ((rows.length - 1) * lh) / 2;
      g.textAlign = "left";
      rows.forEach((row, r) => {
        const total = row.reduce((s, k, i) => s + widths[k] + (i ? sp : 0), 0);
        let x = (w - total) / 2;
        for (const k of row) {
          g.fillStyle = f.sung == null ? "rgba(255,255,255,.55)" : k < f.sung ? "#fff" : k === f.sung ? GOLD : "rgba(255,255,255,.55)";
          g.fillText(f.lineWords[k], x, y0 + r * lh);
          x += widths[k] + sp;
        }
      });
      g.textAlign = "center";
    }
    if (f.next) {
      g.font = font(small * 0.045, 500); g.fillStyle = "rgba(255,255,255,.45)";
      g.fillText(f.next, w / 2, h * 0.6, w * 0.86);
    }
  }

  function wrap(g, text, x, y, max, lh) {
    const words = text.split(" "), rows = [];
    let cur = "";
    for (const wd of words) { const t = cur ? cur + " " + wd : wd; if (g.measureText(t).width > max && cur) { rows.push(cur); cur = wd; } else cur = t; }
    rows.push(cur);
    rows.forEach((r, i) => g.fillText(r, x, y + (i - (rows.length - 1) / 2) * lh));
  }

  function wave(g, peaks, t, duration, w, h) {
    if (!peaks || !peaks.length || !duration) return;
    const bars = 96, step = w / bars, centre = Math.floor((peaks.length * t) / duration), mid = h * 0.83;
    for (let b = 0; b < bars; b++) {
      const i = centre + b - bars / 2;
      if (i < 0 || i >= peaks.length) continue;
      const bh = Math.max(3, Math.sqrt(peaks[i]) * h * 0.12);
      g.fillStyle = b <= bars / 2 ? "rgba(214,170,98,.9)" : "rgba(255,255,255,.18)";
      g.fillRect(b * step + step * 0.25, mid - bh / 2, step * 0.5, bh);
    }
    g.fillStyle = "#F2C478";
    g.fillRect(w / 2 - 1.5, mid - h * 0.07, 3, h * 0.14);
  }

  function peaksOf(ch, count) {
    const n = ch[0].length, out = new Float32Array(count), step = Math.max(1, Math.floor(n / count));
    let top = 0;
    for (let p = 0; p < count; p++) {
      let m = 0;
      for (let i = p * step, e = Math.min(n, i + step); i < e; i++) { const v = Math.abs(ch[0][i]); if (v > m) m = v; }
      out[p] = m; if (m > top) top = m;
    }
    for (let p = 0; p < count; p++) out[p] /= top || 1;
    return out;
  }

  /** Il video: Uint8Array dell'MP4. `audio` = [L, R] a 44,1 kHz; `progress` 0…1; `cancelled()` per fermarsi. */
  // `withAudio` false: solo il video (le prove nel Chromium del server, che non ha l'AAC)
  async function render({ lyrics, title, audio, shape = "landscape", progress = () => {}, cancelled = () => false, withAudio = true }) {
    if (typeof VideoEncoder === "undefined") throw new Error("questo Windows non sa creare video (WebCodecs)");
    const { w, h } = K.SHAPES[shape];
    const duration = audio[0].length / RATE, total = Math.max(1, Math.floor(duration * K.FPS));
    const lines = IsoLR.Lyrics.lines(lyrics.words);
    const peaks = peaksOf(audio, Math.max(200, Math.floor(duration * 20)));
    const canvas = new OffscreenCanvas(w, h), g = canvas.getContext("2d");
    const codec = "avc1.640028";                  // H.264 High, livello 4.0: 1080p a 30 fotogrammi
    const config = { codec, width: w, height: h, bitrate: 6_000_000, framerate: K.FPS, avc: { format: "avc" } };
    const support = await VideoEncoder.isConfigSupported(config);
    if (!support.supported) throw new Error("H.264 non disponibile su questo computer");
    const chunks = [], keys = [];
    let description = null, failed = null;
    const enc = new VideoEncoder({
      output: (chunk, meta) => {
        const b = new Uint8Array(chunk.byteLength); chunk.copyTo(b);
        if (chunk.type === "key") keys.push(chunks.length + 1);
        chunks.push(b);
        if (meta && meta.decoderConfig && meta.decoderConfig.description) description = new Uint8Array(meta.decoderConfig.description);
      },
      error: (e) => { failed = e; },
    });
    enc.configure(config);
    for (let i = 0; i < total; i++) {
      if (cancelled()) { enc.close(); throw new Error("annullato"); }
      const t = i / K.FPS;
      draw(g, K.frame(t, lines, lyrics.words), { title, peaks, t, duration, w, h });
      const frame = new VideoFrame(canvas, { timestamp: Math.round((i * 1e6) / K.FPS), duration: Math.round(1e6 / K.FPS) });
      enc.encode(frame, { keyFrame: i % (K.FPS * 2) === 0 });
      frame.close();
      if (enc.encodeQueueSize > 6) await new Promise((r) => setTimeout(r, 0));
      if (i % 30 === 0) progress((0.9 * i) / total);
    }
    await enc.flush();
    enc.close();
    if (failed) throw failed;
    if (!description) throw new Error("il video non ha la configurazione H.264");
    progress(0.92);
    const aac = withAudio ? await Encode.aacEncode(audio, 1, 256000) : null;
    progress(0.98);
    return mux({ chunks, keys, description, w, h }, aac);
  }

  /** MP4 con una traccia video H.264 e una audio AAC. */
  function mux(v, aac) {
    const { box, full, u32, u16, str, audioTrak } = Encode.mp4parts;
    const ftyp = box("ftyp", str("isom"), u32(512), str("isom"), str("iso2"), str("avc1"), str("mp41"));
    const achunks = aac ? aac.chunks : [];
    const vSize = v.chunks.reduce((s, c) => s + c.length, 0), aSize = achunks.reduce((s, c) => s + c.length, 0);
    const head = ftyp.length + 8;
    const vOff = [], aOff = [];
    let o = head;
    for (const c of v.chunks) { vOff.push(o); o += c.length; }
    for (const c of achunks) { aOff.push(o); o += c.length; }
    const n = v.chunks.length, vDur = Math.round((n * RATE) / K.FPS), aDur = achunks.length * 1024;
    const matrix = [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x40, 0, 0, 0];
    const mvhd = full("mvhd", 0, 0, u32(0), u32(0), u32(RATE), u32(Math.max(vDur, aDur)), u32(0x00010000), u16(0x0100), new Array(10).fill(0),
      matrix, new Array(24).fill(0), u32(3));
    const avc1 = box("avc1", [0, 0, 0, 0, 0, 0], u16(1), new Array(16).fill(0), u16(v.w), u16(v.h), u32(0x00480000), u32(0x00480000), u32(0), u16(1),
      new Array(32).fill(0), u16(0x0018), u16(0xffff), box("avcC", Array.from(v.description)));
    const stbl = box("stbl", full("stsd", 0, 0, u32(1), avc1), full("stts", 0, 0, u32(1), u32(n), u32(1)),
      full("stss", 0, 0, u32(v.keys.length), v.keys.map(u32)), full("stsc", 0, 0, u32(1), u32(1), u32(1), u32(1)),
      full("stsz", 0, 0, u32(0), u32(n), v.chunks.map((c) => u32(c.length))), full("stco", 0, 0, u32(n), vOff.map(u32)));
    const vminf = box("minf", full("vmhd", 0, 1, u16(0), u16(0), u16(0), u16(0)), box("dinf", full("dref", 0, 0, u32(1), full("url ", 0, 1))), stbl);
    const vtrak = box("trak",
      full("tkhd", 0, 3, u32(0), u32(0), u32(1), u32(0), u32(vDur), new Array(8).fill(0), u16(0), u16(0), u16(0), u16(0), matrix, u32(v.w << 16), u32(v.h << 16)),
      box("mdia", full("mdhd", 0, 0, u32(0), u32(0), u32(K.FPS), u32(n), u16(0x55c4), u16(0)),
        full("hdlr", 0, 0, u32(0), str("vide"), u32(0), u32(0), u32(0), str("VideoHandler"), 0), vminf));
    const moov = box("moov", mvhd, vtrak, ...(aac ? [audioTrak(2, aac, aOff, true, 256000)] : []));
    const out = new Uint8Array(o + moov.length);
    out.set(ftyp, 0);
    out.set([...u32(8 + vSize + aSize), ...str("mdat")], ftyp.length);
    let p = head;
    for (const c of v.chunks) { out.set(c, p); p += c.length; }
    for (const c of achunks) { out.set(c, p); p += c.length; }
    out.set(moov, p);
    return out;
  }

  window.KaraokeVideo = { draw, render, mux, peaksOf };
})();
