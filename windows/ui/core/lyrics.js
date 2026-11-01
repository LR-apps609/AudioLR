// ════════════════════════════════════════════════════════════════════
//  Il testo sincronizzato, le regole (come Sources/Lyrics.swift sul Mac):
//  parole con i tempi → righe da cantare, la parola sotto la testina,
//  .lrc e .srt, modifiche a mano (riscrivi una riga, spostala nel tempo)
//  e pulizia di quello che dà Whisper. Salvato come «isolr-testo.json».
// ════════════════════════════════════════════════════════════════════
(function (root) {
  "use strict";

  const FILE = "isolr-testo.json";

  /** Le parole in righe: a capo a fine frase (. ? ! …), dopo una pausa lunga, o se la riga è troppo lunga. */
  function lines(words, { maxGap = 1.2, maxWords = 8, maxChars = 42 } = {}) {
    const out = [];
    let first = 0, chars = 0;
    const close = (end) => {
      if (end <= first) return;
      const text = words.slice(first, end).map((w) => w.text.trim()).join(" ");
      out.push({ from: first, to: end, text, start: words[first].start, end: words[end - 1].end });
      first = end; chars = 0;
    };
    for (let i = 0; i < words.length; i++) {
      const w = words[i].text.trim();
      if (i > first) {
        const gap = words[i].start - words[i - 1].end;
        const tooLong = i - first >= maxWords || chars + w.length + 1 > maxChars;
        if (gap > maxGap || tooLong) close(i);
      }
      chars += w.length + 1;
      if (/[.?!…]$/.test(w)) close(i + 1);
    }
    close(words.length);
    return out;
  }

  /** La riga e la parola sotto la testina; null prima del canto o tra due righe lontane. */
  function current(ls, words, t) {
    let lo = 0, hi = ls.length - 1, found = -1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (ls[mid].start <= t) { found = mid; lo = mid + 1; } else hi = mid - 1;
    }
    if (found < 0 || t > ls[found].end + 1.5) return null;
    let word = null;
    for (let i = ls[found].from; i < ls[found].to; i++) if (words[i].start <= t) word = i;
    return { line: found, word };
  }

  const pad = (n, w = 2) => String(n).padStart(w, "0");
  function lrcTime(s) {
    const cs = Math.round(Math.max(0, s) * 100);
    return `[${pad(Math.floor(cs / 6000))}:${pad(Math.floor(cs / 100) % 60)}.${pad(cs % 100)}]`;
  }
  function srtTime(s) {
    const ms = Math.round(Math.max(0, s) * 1000);
    return `${pad(Math.floor(ms / 3600000))}:${pad(Math.floor(ms / 60000) % 60)}:${pad(Math.floor(ms / 1000) % 60)},${pad(ms % 1000, 3)}`;
  }
  const lrc = (ls, title) => `[ti:${title}]\n[re:IsoLR]\n` + ls.map((l) => lrcTime(l.start) + l.text + "\n").join("");
  const srt = (ls) => ls.map((l, i) => `${i + 1}\n${srtTime(l.start)} --> ${srtTime(l.end)}\n${l.text}\n\n`).join("");

  /** Riscrive una riga: stesso numero di parole → ognuna tiene il suo tempo; altrimenti il tempo della riga
   *  si divide in proporzione alla lunghezza delle parole nuove. */
  function rewrite(words, line, text) {
    const parts = text.split(/\s+/).filter(Boolean);
    const out = words.map((w) => ({ ...w }));
    if (parts.length === line.to - line.from) {
      parts.forEach((p, k) => { out[line.from + k].text = p; });
      return out;
    }
    const total = Math.max(1, parts.reduce((s, p) => s + p.length + 1, 0));
    const span = line.end - line.start;
    let t = line.start;
    const fresh = parts.map((p) => { const d = (span * (p.length + 1)) / total; const w = { text: p, start: t, end: t + d }; t += d; return w; });
    out.splice(line.from, line.to - line.from, ...fresh);
    return out;
  }

  /** Sposta una riga nel tempo (secondi, in anticipo se negativo). */
  function shift(words, line, dt) {
    return words.map((w, i) => {
      if (i < line.from || i >= line.to) return w;
      const start = Math.max(0, w.start + dt);
      return { ...w, start, end: Math.max(start, w.end + dt) };
    });
  }

  /** Pulisce quello che dà Whisper: spazi, parole vuote, tempi al contrario, ripetizioni infinite nei silenzi. */
  function clean(raw) {
    const out = [];
    for (const r of raw) {
      const text = String(r.text || "").trim();
      if (!text) continue;
      const start = Number(r.start) || 0;
      out.push({ text, start, end: Math.max(start, Number(r.end) || start) });
    }
    const kept = [];
    let run = 0;
    for (const w of out) {
      const last = kept[kept.length - 1];
      run = last && last.text.toLowerCase() === w.text.toLowerCase() ? run + 1 : 0;
      if (run < 4) kept.push(w);
    }
    return kept;
  }

  const api = { FILE, lines, current, lrcTime, srtTime, lrc, srt, rewrite, shift, clean };
  (root.IsoLR = root.IsoLR || {}).Lyrics = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : globalThis);
