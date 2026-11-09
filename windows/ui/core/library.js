// ════════════════════════════════════════════════════════════════════
//  Filtri della libreria e della Cronologia, come Sources/LibraryFilter.swift
//  sul Mac: testo, tonalità (anche le «compatibili» per mixare: stessa
//  casella Camelot, ±1, relativa), BPM (anche a metà o al doppio), strumento
//  presente, qualità; e l'ordine. Le canzoni senza analisi restano visibili
//  solo finché non si filtra per tonalità o BPM.
//  Una voce della libreria: { meta: { title, created, quality, analysis, stems: [{ key }] } }.
// ════════════════════════════════════════════════════════════════════
(function (root) {
  "use strict";
  const NS = (root.IsoLR = root.IsoLR || {});
  const mod12 = (x) => ((x % 12) + 12) % 12;
  const NAMES = ["Do", "Do♯", "Re", "Mi♭", "Mi", "Fa", "Fa♯", "Sol", "La♭", "La", "Si♭", "Si"];
  const SORTS = { recent: "Più recenti", title: "Titolo", bpm: "BPM", key: "Tonalità (Camelot)" };

  const empty = () => ({ text: "", keyRoot: null, minor: false, compatible: false, bpmMin: null, bpmMax: null, halfDouble: false, instrument: null, quality: null, sort: "recent" });

  /** Numero e lettera Camelot. */
  function camelot(r, minor) {
    const major = minor ? (r + 3) % 12 : mod12(r);
    return { number: (((major * 7) % 12) + 7) % 12 + 1, minor };
  }
  /** Stessa casella, una accanto (stessa lettera), o la relativa. */
  function compatible(a, b) {
    const x = camelot(a[0], a[1]), y = camelot(b[0], b[1]);
    if (x.minor === y.minor) { const d = Math.abs(x.number - y.number); return d === 0 || d === 1 || d === 11; }
    return x.number === y.number;
  }

  const active = (f) => f.keyRoot != null || f.bpmMin != null || f.bpmMax != null || f.instrument != null || f.quality != null;

  function matchesKey(f, a) {
    if (f.keyRoot == null) return true;
    if (!a || a.keyRoot == null) return false;
    return f.compatible ? compatible([f.keyRoot, f.minor], [a.keyRoot, !!a.minor]) : a.keyRoot === mod12(f.keyRoot) && !!a.minor === f.minor;
  }
  function matchesBpm(f, a) {
    if (f.bpmMin == null && f.bpmMax == null) return true;
    if (!a || !a.bpm) return false;
    const lo = f.bpmMin ?? 0, hi = f.bpmMax ?? Infinity;
    return (f.halfDouble ? [a.bpm, a.bpm / 2, a.bpm * 2] : [a.bpm]).some((b) => b >= lo - 0.5 && b <= hi + 0.5);
  }

  /** Le voci che passano i filtri, nell'ordine scelto. */
  function apply(items, f) {
    // Senza badare ad accenti e maiuscole, e uguale per i titoli in forma decomposta (NFD, nomi da macOS):
    // «ancora» trova «àncora», «perche» trova «perché» (prima no: trovato dai tester del 07/11)
    const fold = (s) => String(s || "").normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();
    const q = fold((f.text || "").trim());
    const kept = items.filter((e) => {
      const m = e.meta || {};
      return (!q || fold(m.title).includes(q)) && matchesKey(f, m.analysis) && matchesBpm(f, m.analysis)
        && (!f.quality || m.quality === f.quality)
        && (!f.instrument || (m.stems || []).some((s) => s.key === f.instrument));
    });
    const code = (e) => { const a = e.meta.analysis; if (!a || a.keyRoot == null) return Infinity; const c = camelot(a.keyRoot, !!a.minor); return c.number * 2 + (c.minor ? 0 : 1); };
    const bpm = (e) => (e.meta.analysis && e.meta.analysis.bpm) || Infinity;
    const sorters = {
      recent: (a, b) => new Date(b.meta.created || 0) - new Date(a.meta.created || 0),
      title: (a, b) => (a.meta.title || "").localeCompare(b.meta.title || "", "it", { numeric: true }),
      bpm: (a, b) => bpm(a) - bpm(b),
      key: (a, b) => code(a) - code(b),
    };
    return kept.slice().sort(sorters[f.sort] || sorters.recent);
  }

  /** I chip dei filtri accesi. `names` = nomi degli strumenti, `qualities` = titoli delle qualità. */
  function chips(f, names = {}, qualities = {}) {
    const out = [];
    if (f.keyRoot != null) { const n = NAMES[mod12(f.keyRoot)] + (f.minor ? " minore" : " maggiore"); out.push({ id: "key", text: f.compatible ? `${n} e compatibili` : n }); }
    if (f.bpmMin != null || f.bpmMax != null) out.push({ id: "bpm", text: `${f.bpmMin ?? "…"}–${f.bpmMax ?? "…"} BPM${f.halfDouble ? " (anche ½ e ×2)" : ""}` });
    if (f.instrument) out.push({ id: "instrument", text: "con " + (names[f.instrument] || f.instrument).toLowerCase() });
    if (f.quality) out.push({ id: "quality", text: qualities[f.quality] || f.quality });
    return out;
  }
  function clear(f, id) {
    const g = { ...f };
    if (id === "key") { g.keyRoot = null; g.compatible = false; }
    if (id === "bpm") { g.bpmMin = null; g.bpmMax = null; g.halfDouble = false; }
    if (id === "instrument") g.instrument = null;
    if (id === "quality") g.quality = null;
    return g;
  }

  /** Il tratto dell'anteprima: 20 s centrati sul punto scelto (0…1), dentro la canzone. */
  function previewRange(duration, at = 0.5, length = 20) {
    if (duration <= length) return [0, duration];
    const start = Math.min(Math.max(0, duration * Math.min(1, Math.max(0, at)) - length / 2), duration - length);
    return [start, start + length];
  }

  /** Il passaggio A–B nel nome di un file, con i decimi: «0m05,0s–0m12,5s» (prima «0.05–0.12», e i passaggi
   *  brevi diventavano «0.00–0.00»). Niente «:», che Windows non accetta nei nomi. */
  function passageLabel(a, b) {
    const one = (t) => { const d = Math.round(Math.max(0, t) * 10), m = Math.floor(d / 600), s = (d % 600) / 10;
      return `${m}m${s.toFixed(1).padStart(4, "0").replace(".", ",")}s`; };
    return `${one(a)}–${one(b)}`;
  }

  const api = { NAMES, SORTS, empty, camelot, compatible, active, apply, chips, clear, previewRange, passageLabel };
  NS.Library = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : globalThis);
