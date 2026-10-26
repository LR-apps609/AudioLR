// I formati dei file, come sul Mac (Sources/Preferences.swift OutputFormat, StemFile.swift):
// WAV 24 e 16 bit, FLAC (senza perdita, circa metà dello spazio), AAC 256 kbps in M4A (leggero),
// e il file per DJ .stem.mp4 di Native Instruments (cinque tracce AAC più l'atomo «stem»).
// Tutto scritto qui, senza librerie: il FLAC con predittori fissi e codici di Rice, l'MP4 a mano;
// l'AAC lo comprime Windows (WebCodecs).
(function () {
  "use strict";
  const RATE = 44100;

  const FORMATS = {
    wav24: { title: "WAV 24 bit", ext: "wav", note: "Qualità da studio, per ogni programma musicale" },
    wav16: { title: "WAV 16 bit", ext: "wav", note: "Qualità CD, file un po' più piccoli" },
    flac: { title: "FLAC", ext: "flac", note: "Senza perdita, circa metà dello spazio" },
    aac: { title: "AAC 256 kbps (M4A, leggero)", ext: "m4a", note: "Compresso, circa un decimo dello spazio: per ascoltare e condividere" },
  };

  const clamp = (v) => (v > 1 ? 1 : v < -1 ? -1 : v);

  // ── WAV ──
  function wav(ch, bits = 24, gain = 1) {
    const n = ch[0].length, C = ch.length, bps = bits / 8;
    const buf = new ArrayBuffer(44 + n * C * bps), v = new DataView(buf);
    const s = (o, t) => { for (let i = 0; i < t.length; i++) v.setUint8(o + i, t.charCodeAt(i)); };
    s(0, "RIFF"); v.setUint32(4, 36 + n * C * bps, true); s(8, "WAVE"); s(12, "fmt ");
    v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, C, true); v.setUint32(24, RATE, true);
    v.setUint32(28, RATE * C * bps, true); v.setUint16(32, C * bps, true); v.setUint16(34, bits, true);
    s(36, "data"); v.setUint32(40, n * C * bps, true);
    const out = new Uint8Array(buf);
    let o = 44;
    const max = bits === 24 ? 8388607 : 32767;
    for (let i = 0; i < n; i++) for (let c = 0; c < C; c++) {
      const x = Math.round(clamp(ch[c][i] * gain) * max);
      out[o++] = x & 255; out[o++] = (x >> 8) & 255;
      if (bits === 24) out[o++] = (x >> 16) & 255;
    }
    return out;
  }

  // ── FLAC ──
  class Bits {
    constructor(size) { this.b = new Uint8Array(size); this.p = 0; this.acc = 0; this.n = 0; }
    grow(extra) { if (this.p + extra + 16 > this.b.length) { const nb = new Uint8Array((this.b.length + extra) * 2); nb.set(this.b); this.b = nb; } }
    put(v, bits) {                         // fino a 32 bit, senza segno (si spezza in parti da 16)
      if (bits > 16) { this.put(Math.floor(v / 65536), bits - 16); this.put(v % 65536, 16); return; }
      this.acc = (this.acc << bits) | v; this.n += bits;
      this.grow(4);
      while (this.n >= 8) { this.n -= 8; this.b[this.p++] = (this.acc >> this.n) & 255; }
      this.acc &= (1 << this.n) - 1;
    }
    signed(v, bits) { this.put(v < 0 ? v + 2 ** bits : v, bits); }
    unary(q) { for (; q >= 16; q -= 16) this.put(0, 16); this.put(1, q + 1); }
    align() { if (this.n) this.put(0, 8 - this.n); }
    bytes() { return this.b.subarray(0, this.p); }
  }
  const CRC8 = new Uint8Array(256), CRC16 = new Uint16Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i; for (let k = 0; k < 8; k++) c = c & 0x80 ? ((c << 1) ^ 0x07) & 255 : (c << 1) & 255; CRC8[i] = c;
    let d = i << 8; for (let k = 0; k < 8; k++) d = d & 0x8000 ? ((d << 1) ^ 0x8005) & 0xffff : (d << 1) & 0xffff; CRC16[i] = d;
  }
  const crc8 = (a, s, e) => { let c = 0; for (let i = s; i < e; i++) c = CRC8[c ^ a[i]]; return c; };
  const crc16 = (a, s, e) => { let c = 0; for (let i = s; i < e; i++) c = ((c << 8) & 0xffff) ^ CRC16[(c >> 8) ^ a[i]]; return c; };

  // Residui con i predittori fissi di ordine 0…4 (quelli del formato FLAC): si sceglie il più piccolo
  function residual(x, order) {
    const n = x.length, r = new Int32Array(n - order);
    for (let i = order; i < n; i++) {
      let p = 0;
      if (order === 1) p = x[i - 1];
      else if (order === 2) p = 2 * x[i - 1] - x[i - 2];
      else if (order === 3) p = 3 * x[i - 1] - 3 * x[i - 2] + x[i - 3];
      else if (order === 4) p = 4 * x[i - 1] - 6 * x[i - 2] + 4 * x[i - 3] - x[i - 4];
      r[i - order] = x[i] - p;
    }
    return r;
  }
  function riceCost(r) {
    let sum = 0;
    for (let i = 0; i < r.length; i++) { const v = r[i]; sum += v >= 0 ? 2 * v : -2 * v - 1; }
    const mean = sum / Math.max(1, r.length);
    let k = mean > 0 ? Math.max(0, Math.min(30, Math.floor(Math.log2(mean)))) : 0;   // RICE2: parametro a 5 bit (31 = fuga)
    let bits = 0;
    for (let i = 0; i < r.length; i++) { const v = r[i], u = v >= 0 ? 2 * v : -2 * v - 1; bits += 1 + k + Math.floor(u / 2 ** k); }
    return { k, bits };
  }
  function subframe(w, x, bps) {
    let best = null;
    for (let order = 0; order <= 4 && order < x.length; order++) {
      const r = residual(x, order), c = riceCost(r);
      const total = c.bits + order * bps;
      if (!best || total < best.total) best = { order, r, k: c.k, total };
    }
    w.put(0, 1); w.put(0b001000 | best.order, 6); w.put(0, 1);     // FIXED, ordine; nessun bit «wasted»
    for (let i = 0; i < best.order; i++) w.signed(x[i], bps);
    w.put(1, 2); w.put(0, 4);                                       // RICE2 (per l'audio a 24 bit), partizione unica
    const k = best.k; w.put(k, 5);
    for (let i = 0; i < best.r.length; i++) {
      const v = best.r[i], u = v >= 0 ? 2 * v : -2 * v - 1;
      const q = Math.floor(u / 2 ** k);
      w.unary(q); if (k) w.put(u % 2 ** k, k);
    }
  }
  function flac(ch, gain = 1) {
    const n = ch[0].length, BS = 4096, BPS = 24, max = 8388607;
    const w = new Bits(n * 4 + 1024);
    w.put(0x664c6143, 32);                                          // «fLaC»
    w.put(0x80, 8); w.put(34, 24);                                  // STREAMINFO, ultimo blocco
    w.put(BS, 16); w.put(BS, 16); w.put(0, 24); w.put(0, 24);
    w.put(RATE, 20); w.put(1, 3); w.put(BPS - 1, 5); w.put(Math.floor(n / 2 ** 32), 4); w.put(n % 2 ** 32, 32);
    for (let i = 0; i < 16; i++) w.put(0, 8);                       // MD5 sconosciuto (permesso)
    const L = new Int32Array(BS), R = new Int32Array(BS);
    for (let f = 0, start = 0; start < n; f++, start += BS) {
      const len = Math.min(BS, n - start);
      for (let i = 0; i < len; i++) {
        L[i] = Math.round(clamp(ch[0][start + i] * gain) * max);
        R[i] = Math.round(clamp(ch[ch.length > 1 ? 1 : 0][start + i] * gain) * max);
      }
      const head = w.p;
      w.put(0b11111111111110, 14); w.put(0, 1); w.put(0, 1);        // sincronia, blocchi fissi
      w.put(len === BS ? 0b1100 : 0b0111, 4);                       // 4096, oppure «16 bit alla fine»
      w.put(0b1001, 4);                                             // 44,1 kHz
      w.put(0b1000, 4);                                             // sinistra/lato (stereo)
      w.put(0b110, 3); w.put(0, 1);                                 // 24 bit
      // Numero del blocco in UTF-8
      if (f < 0x80) w.put(f, 8);
      else if (f < 0x800) { w.put(0xc0 | (f >> 6), 8); w.put(0x80 | (f & 63), 8); }
      else if (f < 0x10000) { w.put(0xe0 | (f >> 12), 8); w.put(0x80 | ((f >> 6) & 63), 8); w.put(0x80 | (f & 63), 8); }
      else { w.put(0xf0 | (f >> 18), 8); w.put(0x80 | ((f >> 12) & 63), 8); w.put(0x80 | ((f >> 6) & 63), 8); w.put(0x80 | (f & 63), 8); }
      if (len !== BS) w.put(len - 1, 16);
      w.put(crc8(w.b, head, w.p), 8);
      const l = L.subarray(0, len), side = new Int32Array(len);
      for (let i = 0; i < len; i++) side[i] = L[i] - R[i];
      subframe(w, l, BPS);
      subframe(w, side, BPS + 1);
      w.align();
      w.put(crc16(w.b, head, w.p), 16);
    }
    return w.bytes().slice();
  }

  // ── MP4 / AAC ──
  const u32 = (v) => [(v >>> 24) & 255, (v >>> 16) & 255, (v >>> 8) & 255, v & 255];
  const u16 = (v) => [(v >> 8) & 255, v & 255];
  const str = (s) => [...s].map((c) => c.charCodeAt(0));
  function box(type, ...parts) {
    const body = parts.flat(Infinity);
    return [...u32(8 + body.length), ...str(type), ...body];
  }
  const full = (type, version, flags, ...parts) => box(type, version, (flags >> 16) & 255, (flags >> 8) & 255, flags & 255, ...parts);

  /** Comprime in AAC con WebCodecs: { chunks: [Uint8Array], config: Uint8Array (AudioSpecificConfig) }. */
  async function aacEncode(ch, gain = 1, bitrate = 256000) {
    if (typeof AudioEncoder === "undefined") throw new Error("questo Windows non sa comprimere in AAC: scegli WAV o FLAC");
    const support = await AudioEncoder.isConfigSupported({ codec: "mp4a.40.2", sampleRate: RATE, numberOfChannels: 2, bitrate });
    if (!support.supported) throw new Error("AAC non disponibile su questo computer: scegli WAV o FLAC");
    const chunks = [];
    let config = null, failed = null;
    const enc = new AudioEncoder({
      output: (chunk, meta) => {
        const b = new Uint8Array(chunk.byteLength); chunk.copyTo(b); chunks.push(b);
        if (meta && meta.decoderConfig && meta.decoderConfig.description) config = new Uint8Array(meta.decoderConfig.description);
      },
      error: (e) => { failed = e; },
    });
    enc.configure({ codec: "mp4a.40.2", sampleRate: RATE, numberOfChannels: 2, bitrate });
    const n = ch[0].length, step = 44100;
    for (let s = 0; s < n; s += step) {
      const len = Math.min(step, n - s), planar = new Float32Array(len * 2);
      for (let c = 0; c < 2; c++) { const src = ch[Math.min(c, ch.length - 1)]; for (let i = 0; i < len; i++) planar[c * len + i] = clamp(src[s + i] * gain); }
      enc.encode(new AudioData({ format: "f32-planar", sampleRate: RATE, numberOfFrames: len, numberOfChannels: 2, timestamp: Math.round((s / RATE) * 1e6), data: planar }));
      if (enc.encodeQueueSize > 8) await new Promise((r) => setTimeout(r, 0));
    }
    await enc.flush();
    enc.close();
    if (failed) throw failed;
    // Se Windows non dà la configurazione: AAC-LC, 44,1 kHz, stereo
    if (!config) config = new Uint8Array([0x12, 0x10]);
    return { chunks, config };
  }

  function esds(config, bitrate) {
    const dsi = [0x05, config.length, ...config];
    const dcd = [0x04, 13 + dsi.length, 0x40, 0x15, 0, 0x18, 0, ...u32(bitrate), ...u32(bitrate), ...dsi];
    const es = [0x03, 3 + dcd.length + 3, ...u16(1), 0, ...dcd, 0x06, 1, 2];
    return full("esds", 0, 0, es);
  }

  function trak(id, enc, offsets, enabled, bitrate) {
    const n = enc.chunks.length, dur = n * 1024;
    const stsd = full("stsd", 0, 0, u32(1), box("mp4a", [0, 0, 0, 0, 0, 0], u16(1), [0, 0, 0, 0, 0, 0, 0, 0], u16(2), u16(16), u16(0), u16(0), u32(RATE << 16), esds(enc.config, bitrate)));
    const stts = full("stts", 0, 0, u32(1), u32(n), u32(1024));
    const stsc = full("stsc", 0, 0, u32(1), u32(1), u32(1), u32(1));
    const stsz = full("stsz", 0, 0, u32(0), u32(n), enc.chunks.map((c) => u32(c.length)));
    const stco = full("stco", 0, 0, u32(n), offsets.map((o) => u32(o)));
    const tkhd = full("tkhd", 0, enabled ? 3 : 2, u32(0), u32(0), u32(id), u32(0), u32(dur), [0, 0, 0, 0, 0, 0, 0, 0], u16(0), u16(id === 1 ? 0 : 1), u16(0x0100), u16(0),
      [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x40, 0, 0, 0], u32(0), u32(0));
    const mdhd = full("mdhd", 0, 0, u32(0), u32(0), u32(RATE), u32(dur), u16(0x55c4), u16(0));
    const hdlr = full("hdlr", 0, 0, u32(0), str("soun"), u32(0), u32(0), u32(0), str("SoundHandler"), 0);
    const minf = box("minf", full("smhd", 0, 0, u32(0)), box("dinf", full("dref", 0, 0, u32(1), full("url ", 0, 1))), box("stbl", stsd, stts, stsc, stsz, stco));
    return box("trak", tkhd, box("mdia", mdhd, hdlr, minf));
  }

  /** MP4 con una o più tracce AAC (la prima attiva). `extraUdta` = atomi da mettere in moov › udta. */
  function mp4(encs, bitrate, extraUdta) {
    const ftyp = box("ftyp", str("M4A "), u32(0), str("M4A "), str("mp42"), str("isom"));
    const mdatSize = encs.reduce((s, e) => s + e.chunks.reduce((a, c) => a + c.length, 0), 0);
    const out = new Uint8Array(ftyp.length + 8 + mdatSize + 4096 + encs.reduce((s, e) => s + e.chunks.length * 16, 0) + (extraUdta ? extraUdta.length : 0));
    out.set(ftyp, 0);
    let o = ftyp.length;
    out.set([...u32(8 + mdatSize), ...str("mdat")], o); o += 8;
    // Le tracce intrecciate a pezzi di un secondo circa: i lettori leggono senza saltare avanti e indietro
    const offsets = encs.map(() => []);
    const per = 43, max = Math.max(...encs.map((e) => e.chunks.length));
    for (let start = 0; start < max; start += per) {
      encs.forEach((e, t) => {
        for (let i = start; i < Math.min(start + per, e.chunks.length); i++) { offsets[t].push(o); out.set(e.chunks[i], o); o += e.chunks[i].length; }
      });
    }
    const dur = max * 1024;
    const mvhd = full("mvhd", 0, 0, u32(0), u32(0), u32(RATE), u32(dur), u32(0x00010000), u16(0x0100), [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x40, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], u32(encs.length + 1));
    const traks = encs.map((e, t) => trak(t + 1, e, offsets[t], t === 0, bitrate));
    const moov = box("moov", mvhd, ...traks, ...(extraUdta ? [box("udta", extraUdta)] : []));
    const res = new Uint8Array(o + moov.length);
    res.set(out.subarray(0, o), 0);
    res.set(moov, o);
    return res;
  }

  async function m4a(ch, gain = 1) { return mp4([await aacEncode(ch, gain)], 256000); }

  // Il file per DJ: canzone intera, batteria, basso, altro, voce (nomi e colori come Native Instruments)
  const STEM_LAYOUT = [
    { name: "Drums", color: "#C48E2C", keys: ["drums", "kick", "snare", "toms", "hh", "ride", "crash"] },
    { name: "Bass", color: "#8C6AAF", keys: ["bass"] },
    { name: "Other", color: "#3C978C", keys: ["guitar", "piano", "other"] },
    { name: "Vocals", color: "#CF6F57", keys: ["vocals", "lead", "backing", "male", "female"] },
  ];
  async function stemMp4(tracks) {
    const n = Math.max(...Object.values(tracks).map((t) => t[0].length));
    const parts = STEM_LAYOUT.map((l) => {
      const out = [new Float32Array(n), new Float32Array(n)];
      for (const k of l.keys) if (tracks[k]) for (let c = 0; c < 2; c++) { const s = tracks[k][Math.min(c, tracks[k].length - 1)]; for (let i = 0; i < s.length; i++) out[c][i] += s[i]; }
      return out;
    });
    const master = [new Float32Array(n), new Float32Array(n)];
    for (const p of parts) for (let c = 0; c < 2; c++) for (let i = 0; i < n; i++) master[c][i] += p[c][i];
    // Un solo guadagno per tutte: nel programma DJ le tracce sommate ridanno la canzone, senza tagli
    let top = 0;
    for (const t of [master, ...parts]) for (const c of t) for (let i = 0; i < c.length; i++) top = Math.max(top, Math.abs(c[i]));
    const gain = top > 0.98 ? 0.98 / top : 1;
    const encs = [];
    for (const t of [master, ...parts]) encs.push(await aacEncode(t, gain, 320000));
    const meta = JSON.stringify({ mastering_dsp: { compressor: { attack: 0.003, dry_wet: 50, enabled: false, hp_cutoff: 300, input_gain: 0.5, output_gain: 0.5, ratio: 3, release: 0.3, threshold: 0 }, limiter: { ceiling: -0.35, enabled: false, release: 0.05, threshold: 0 } }, stems: STEM_LAYOUT.map((l) => ({ color: l.color, name: l.name })), version: 1 });
    return mp4(encs, 320000, box("stem", str(meta)));
  }

  /** Un file nel formato scelto. */
  async function encode(ch, format, gain = 1) {
    if (format === "wav16") return wav(ch, 16, gain);
    if (format === "flac") return flac(ch, gain);
    if (format === "aac") return m4a(ch, gain);
    return wav(ch, 24, gain);
  }

  /** Legge un WAV a 16 o 24 bit (le tracce salvate da IsoLR) come canali Float32. */
  function readWav(bytes) {
    const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    let o = 12, C = 2, bits = 24, data = 0, len = 0;
    while (o + 8 <= v.byteLength) {
      const id = String.fromCharCode(v.getUint8(o), v.getUint8(o + 1), v.getUint8(o + 2), v.getUint8(o + 3)), size = v.getUint32(o + 4, true);
      if (id === "fmt ") { C = v.getUint16(o + 10, true); bits = v.getUint16(o + 22, true); }
      if (id === "data") { data = o + 8; len = size; break; }
      o += 8 + size + (size & 1);
    }
    const bps = bits / 8, n = Math.floor(len / (bps * C)), out = Array.from({ length: C }, () => new Float32Array(n));
    let p = data;
    for (let i = 0; i < n; i++) for (let c = 0; c < C; c++) {
      let x;
      if (bits === 24) { x = v.getUint8(p) | (v.getUint8(p + 1) << 8) | (v.getInt8(p + 2) << 16); x /= 8388608; p += 3; }
      else if (bits === 32) { x = v.getFloat32(p, true); p += 4; }
      else { x = v.getInt16(p, true) / 32768; p += 2; }
      out[c][i] = x;
    }
    if (C === 1) out.push(out[0]);
    return out.slice(0, 2);
  }

  window.Encode = { FORMATS, encode, wav, flac, m4a, stemMp4, readWav, RATE };
  if (typeof module !== "undefined") module.exports = window.Encode;
})();
