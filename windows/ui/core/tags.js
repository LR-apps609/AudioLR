// ════════════════════════════════════════════════════════════════════
//  Tempo e tonalità dentro i file scaricati, come Sources/Tags.swift sul
//  Mac: dove li leggono Rekordbox, Serato, Traktor, Ableton.
//  • WAV: blocchi LIST/INFO e «id3 » (ID3v2.3: TBPM, TKEY, TIT2, TPE1);
//  • FLAC: commenti Vorbis BPM, INITIALKEY, TITLE, ARTIST;
//  • M4A: atomi iTunes in moov › udta (tmpo, ©nam, ©ART, ©cmt).
//  Titolo e artista dal nome («Artista - Titolo») quando c'è.
// ════════════════════════════════════════════════════════════════════
(function (root) {
  "use strict";
  const NS = (root.IsoLR = root.IsoLR || {});
  const KEYS = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"];
  const mod12 = (x) => ((x % 12) + 12) % 12;
  const keyName = (rootNote, minor) => KEYS[mod12(rootNote)] + (minor ? "m" : "");

  /** «Eminem - Till I Collapse» → { artist: "Eminem", title: "Till I Collapse" }. */
  function split(name) {
    for (const sep of [" – ", " - ", " — "]) {
      const i = name.indexOf(sep);
      if (i > 0) {
        const artist = name.slice(0, i).trim(), title = name.slice(i + sep.length).trim();
        if (artist && title) return { artist, title };
      }
    }
    return { artist: null, title: name };
  }

  /** I dati da scrivere, dal nome della canzone e dalla sua analisi (con il tono cambiato da Transpose). */
  function info(song, analysis, shift = 0) {
    const { artist, title } = split(song);
    const out = { title, artist, bpm: null, key: null };
    if (analysis && analysis.bpm) out.bpm = Math.round(analysis.bpm);
    if (analysis && analysis.keyRoot != null) out.key = keyName(analysis.keyRoot + shift, analysis.minor);
    return out;
  }
  const comment = (t) => [t.bpm ? `${t.bpm} BPM` : null, t.key].filter(Boolean).join(" · ");

  const enc = new TextEncoder();
  const latin1 = (s) => { const a = []; for (const ch of s) { const c = ch.codePointAt(0); if (c > 255) return null; a.push(c); } return a; };
  const le32 = (v) => [v & 255, (v >>> 8) & 255, (v >>> 16) & 255, (v >>> 24) & 255];
  const be32 = (v) => [(v >>> 24) & 255, (v >>> 16) & 255, (v >>> 8) & 255, v & 255];
  const ascii = (s) => [...s].map((c) => c.charCodeAt(0));
  const readLE32 = (b, i) => (b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24)) >>> 0;

  function chunk(id, body) {
    const out = [...ascii(id), ...le32(body.length), ...body];
    if (body.length % 2) out.push(0);
    return out;
  }

  /** ID3v2.3 con i frame di testo (Latin-1 se basta, altrimenti UTF-16 con BOM). */
  function id3(t) {
    const frame = (id, text) => {
      const l = latin1(text);
      let body;
      if (l) body = [0, ...l];
      else { body = [1, 0xff, 0xfe]; for (let i = 0; i < text.length; i++) { const c = text.charCodeAt(i); body.push(c & 255, c >> 8); } }
      return [...ascii(id), ...be32(body.length), 0, 0, ...body];
    };
    let frames = frame("TIT2", t.title);
    if (t.artist) frames = frames.concat(frame("TPE1", t.artist));
    if (t.bpm) frames = frames.concat(frame("TBPM", String(t.bpm)));
    if (t.key) frames = frames.concat(frame("TKEY", t.key));
    const n = frames.length;
    return [...ascii("ID3"), 3, 0, 0, (n >> 21) & 127, (n >> 14) & 127, (n >> 7) & 127, n & 127, ...frames];
  }

  /** Il WAV con LIST/INFO e «id3 » nuovi in fondo (quelli vecchi si tolgono) e la misura RIFF giusta. */
  function wav(bytes, t) {
    const parts = [bytes.subarray(0, 12)];
    let i = 12;
    while (i + 8 <= bytes.length) {
      const id = String.fromCharCode(...bytes.subarray(i, i + 4)), size = readLE32(bytes, i + 4);
      const end = Math.min(bytes.length, i + 8 + size + (size % 2));
      const isInfo = id === "LIST" && String.fromCharCode(...bytes.subarray(i + 8, i + 12)) === "INFO";
      if (id !== "id3 " && id !== "ID3 " && !isInfo) parts.push(bytes.subarray(i, end));
      i = end;
    }
    const z = (s) => [...(latin1(s) || enc.encode(s)), 0];
    let list = ascii("INFO").concat(chunk("INAM", z(t.title)));
    if (t.artist) list = list.concat(chunk("IART", z(t.artist)));
    if (comment(t)) list = list.concat(chunk("ICMT", z(comment(t))));
    parts.push(Uint8Array.from(chunk("LIST", list)), Uint8Array.from(chunk("id3 ", id3(t))));
    const total = parts.reduce((s, p) => s + p.length, 0);
    const out = new Uint8Array(total);
    let o = 0;
    for (const p of parts) { out.set(p, o); o += p.length; }
    out.set(le32(total - 8), 4);
    return out;
  }

  function readID3(b) {
    const out = {};
    let i = 10;
    while (i + 10 <= b.length) {
      const id = String.fromCharCode(...b.subarray(i, i + 4));
      const n = (b[i + 4] << 24) | (b[i + 5] << 16) | (b[i + 6] << 8) | b[i + 7];
      if (!n || i + 10 + n > b.length) break;
      const body = b.subarray(i + 10, i + 10 + n);
      if (body[0] === 1) { let s = ""; for (let k = 3; k + 1 < body.length; k += 2) s += String.fromCharCode(body[k] | (body[k + 1] << 8)); out[id] = s; }
      else out[id] = String.fromCharCode(...body.subarray(1));
      i += 10 + n;
    }
    return out;
  }
  /** I frame del blocco «id3 » di un WAV (per le prove). */
  function readWav(bytes) {
    let i = 12;
    while (i + 8 <= bytes.length) {
      const id = String.fromCharCode(...bytes.subarray(i, i + 4)), size = readLE32(bytes, i + 4);
      if (id === "id3 ") return readID3(bytes.subarray(i + 8, i + 8 + size));
      i += 8 + size + (size % 2);
    }
    return {};
  }

  /** Il FLAC con un blocco VORBIS_COMMENT nuovo dopo STREAMINFO (i commenti vecchi e il riempimento si tolgono). */
  function flac(bytes, t) {
    if (String.fromCharCode(...bytes.subarray(0, 4)) !== "fLaC") throw new Error("non è un file FLAC");
    const blocks = [];
    let i = 4, last = false;
    while (!last && i + 4 <= bytes.length) {
      last = (bytes[i] & 0x80) !== 0;
      const type = bytes[i] & 0x7f, n = (bytes[i + 1] << 16) | (bytes[i + 2] << 8) | bytes[i + 3];
      if (type !== 4 && type !== 1) blocks.push({ type, body: bytes.subarray(i + 4, i + 4 + n) });
      i += 4 + n;
    }
    const fields = [`TITLE=${t.title}`];
    if (t.artist) fields.push(`ARTIST=${t.artist}`);
    if (t.bpm) fields.push(`BPM=${t.bpm}`);
    if (t.key) fields.push(`INITIALKEY=${t.key}`);
    if (comment(t)) fields.push(`COMMENT=${comment(t)}`);
    const vendor = enc.encode("IsoLR");
    let vc = [...le32(vendor.length), ...vendor, ...le32(fields.length)];
    for (const f of fields) { const b = enc.encode(f); vc = vc.concat(le32(b.length), [...b]); }
    const si = Math.max(0, blocks.findIndex((b) => b.type === 0));
    blocks.splice(si + 1, 0, { type: 4, body: Uint8Array.from(vc) });
    const head = blocks.reduce((s, b) => s + 4 + b.body.length, 4);
    const out = new Uint8Array(head + bytes.length - i);
    out.set(ascii("fLaC"), 0);
    let o = 4;
    blocks.forEach((b, k) => {
      const n = b.body.length;
      out.set([b.type | (k === blocks.length - 1 ? 0x80 : 0), (n >> 16) & 255, (n >> 8) & 255, n & 255], o);
      out.set(b.body, o + 4);
      o += 4 + n;
    });
    out.set(bytes.subarray(i), o);
    return out;
  }
  /** I commenti Vorbis di un FLAC (per le prove). */
  function readFlac(bytes) {
    let i = 4, last = false;
    while (!last && i + 4 <= bytes.length) {
      last = (bytes[i] & 0x80) !== 0;
      const type = bytes[i] & 0x7f, n = (bytes[i + 1] << 16) | (bytes[i + 2] << 8) | bytes[i + 3];
      if (type === 4) {
        const b = bytes.subarray(i + 4, i + 4 + n), dec = new TextDecoder();
        let j = 4 + readLE32(b, 0);
        const count = readLE32(b, j); j += 4;
        const out = {};
        for (let k = 0; k < count; k++) {
          const len = readLE32(b, j); j += 4;
          const s = dec.decode(b.subarray(j, j + len)); j += len;
          const eq = s.indexOf("=");
          if (eq > 0) out[s.slice(0, eq).toUpperCase()] = s.slice(eq + 1);
        }
        return out;
      }
      i += 4 + n;
    }
    return {};
  }

  /** Gli atomi iTunes per moov › udta di un M4A: meta (hdlr mdir) › ilst con titolo, artista, tmpo e commento. */
  function m4aUdta(t) {
    const box = (type, ...parts) => { const body = parts.flat(Infinity); return [...be32(8 + body.length), ...ascii(type), ...body]; };
    const text = (s) => box("data", be32(1), be32(0), [...enc.encode(s)]);
    const items = [box("©nam", text(t.title))];
    if (t.artist) items.push(box("©ART", text(t.artist)));
    if (t.bpm) items.push(box("tmpo", box("data", be32(21), be32(0), [(t.bpm >> 8) & 255, t.bpm & 255])));
    if (comment(t)) items.push(box("©cmt", text(comment(t))));
    const hdlr = box("hdlr", [0, 0, 0, 0], be32(0), ascii("mdir"), ascii("appl"), be32(0), be32(0), [0]);
    // L'atomo «©» è un byte solo (0xA9): ascii() lo scrive giusto perché charCodeAt(0) = 169
    return box("meta", [0, 0, 0, 0], hdlr, box("ilst", ...items));
  }
  /** I testi e il tempo negli atomi iTunes di un M4A (per le prove). */
  function readM4a(bytes) {
    const out = {};
    const walk = (s, e, inIlst) => {
      let i = s;
      while (i + 8 <= e) {
        const n = ((bytes[i] << 24) | (bytes[i + 1] << 16) | (bytes[i + 2] << 8) | bytes[i + 3]) >>> 0;
        const type = String.fromCharCode(...bytes.subarray(i + 4, i + 8));
        if (n < 8 || i + n > e) break;
        if (inIlst) {
          const d = i + 8;                               // l'atomo «data» dentro
          const kind = ((bytes[d + 8] << 24) | (bytes[d + 9] << 16) | (bytes[d + 10] << 8) | bytes[d + 11]) >>> 0;
          const val = bytes.subarray(d + 16, i + n);
          out[type] = kind === 21 ? (val[0] << 8) | val[1] : new TextDecoder().decode(val);
        } else if (["moov", "udta", "ilst"].includes(type)) walk(i + 8, i + n, type === "ilst");
        else if (type === "meta") walk(i + 12, i + n, false);
        i += n;
      }
    };
    walk(0, bytes.length, false);
    return out;
  }

  const api = { info, split, keyName, wav, readWav, flac, readFlac, m4aUdta, readM4a };
  NS.Tags = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : globalThis);
