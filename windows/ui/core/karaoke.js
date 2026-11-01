// Il video karaoke, le regole (come KaraokeVideo.frame sul Mac): cosa si vede in un istante. All'inizio il
// titolo; poco prima di una riga la si mostra già in grigio; mentre si canta, le parole già cantate in bianco,
// quella in corso in oro, le altre in grigio; sotto, la riga dopo.
(function (root) {
  "use strict";
  const TITLE = 3, FPS = 30;
  const SHAPES = { landscape: { w: 1920, h: 1080, title: "Orizzontale 1920×1080 (YouTube)" },
    portrait: { w: 1080, h: 1920, title: "Verticale 1080×1920 (Instagram, TikTok)" } };

  function frame(t, lines, words) {
    const L = (root.IsoLR && root.IsoLR.Lyrics) || require("./lyrics.js");
    const now = L.current(lines, words, t);
    const upcoming = lines.findIndex((l) => l.start > t);
    const f = { showTitle: t < TITLE && (lines.length ? lines[0].start : Infinity) > t, line: null, sung: null, lineWords: [], next: null };
    const wordsOf = (l) => words.slice(l.from, l.to).map((w) => w.text.trim());
    if (now) {
      const l = lines[now.line];
      f.line = l.text; f.lineWords = wordsOf(l);
      if (now.word != null) f.sung = now.word - l.from;
      if (now.line + 1 < lines.length) f.next = lines[now.line + 1].text;
    } else if (upcoming >= 0 && lines[upcoming].start - t < 2) {
      f.line = lines[upcoming].text; f.lineWords = wordsOf(lines[upcoming]);
      if (upcoming + 1 < lines.length) f.next = lines[upcoming + 1].text;
    }
    return f;
  }

  const api = { TITLE, FPS, SHAPES, frame };
  (root.IsoLR = root.IsoLR || {}).Karaoke = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : globalThis);
