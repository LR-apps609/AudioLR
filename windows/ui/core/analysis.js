// ════════════════════════════════════════════════════════════════════
//  Tempo e tonalità della canzone, calcolati sulle tracce separate:
//  il tempo dalla batteria (gli attacchi sono netti, senza voce e
//  accordi di mezzo), la tonalità da tutto tranne batteria e voce.
//  Solo calcoli sul segnale, niente modelli da scaricare.
//  Copia di Sources/Analysis.swift: se lì cambia qualcosa, va cambiato anche qui.
// ════════════════════════════════════════════════════════════════════
(function (root) {
  "use strict";

  const NS = (root.IsoLR = root.IsoLR || {});
  // Gli altri file si cercano al momento dell'uso: nel browser l'ordine dei <script> non conta
  const need = (file, name) => (typeof module !== "undefined" && module.exports ? require("./" + file) : NS[name]);
  const STFT = () => need("stft.js", "STFT");

  const names = ["Do", "Do♯", "Re", "Mi♭", "Mi", "Fa", "Fa♯", "Sol", "La♭", "La", "Si♭", "Si"];
  const english = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"];

  class SongAnalysis {
    constructor({ bpm, keyRoot, minor, keyConfidence, structure = null, chords = null }) {
      /// Battiti al minuto.
      this.bpm = bpm;
      /// 0 = Do, 1 = Do♯ … 11 = Si.
      this.keyRoot = keyRoot;
      this.minor = minor;
      /// Quanto la tonalità è netta (0…1): sotto 0,5 la canzone cambia spesso tonalità o è poco tonale.
      this.keyConfidence = keyConfidence;
      /// Battiti, battute e parti della canzone (nelle separazioni vecchie manca).
      this.structure = structure;
      /// Gli accordi, uno per tratto.
      this.chords = chords;
    }
    /// Da JSON (salvato dall'app o da qui).
    static from(o) { return o instanceof SongAnalysis ? o : new SongAnalysis(o); }

    /// «La minore»
    get keyName() { return names[this.keyRoot] + (this.minor ? " minore" : " maggiore"); }
    /// «Am», come lo scrivono i musicisti
    get keyShort() { return english[this.keyRoot] + (this.minor ? "m" : ""); }
    /// Notazione Camelot dei DJ («8A»): tonalità vicine hanno numeri vicini.
    get camelot() {
      // Do maggiore = 8B, La minore = 8A; ogni quinta in su è +1
      const major = this.minor ? (this.keyRoot + 3) % 12 : this.keyRoot;
      const n = (((major * 7) % 12) + 7) % 12 + 1;
      return `${n}${this.minor ? "A" : "B"}`;
    }
    get bpmText() { return `${STFT().round(this.bpm)} BPM`; }
  }
  SongAnalysis.names = names;
  SongAnalysis.english = english;

  const rate = 44100;

  function energy(x) {
    let s = 0;
    for (let i = 0; i < x.length; i++) s += x[i] * x[i];
    return s;
  }

  /// Le tracce come coppie [chiave, canali]: da un oggetto {chiave: [sinistra, destra]} o da una Map.
  function entries(stems) {
    if (stems instanceof Map) return [...stems.entries()];
    return Object.keys(stems).map((k) => [k, stems[k]]);
  }

  /// Tempo e tonalità da una separazione: `stems` = {chiave: [Float32Array sinistra, destra]}.
  function analyze(stems) {
    const list = entries(stems);
    const n = list.length && list[0][1].length ? list[0][1][0].length : 0;
    if (!(n > rate * 4)) return null;
    const mono = (keys) => {
      const m = new Float32Array(n);
      for (const [k, chans] of list) {
        if (!keys(k)) continue;
        for (let c = 0; c < Math.min(2, chans.length); c++) {
          const ch = chans[c], len = Math.min(n, ch.length);
          for (let i = 0; i < len; i++) m[i] += ch[i];
        }
      }
      return m;
    };
    const voices = need("mix.js", "Mix").MixState.voices;
    const drums = mono((k) => k === "drums");
    const everything = mono(() => true);
    const eAll = energy(everything);
    const rhythm = list.some(([k]) => k === "drums") && energy(drums) > 1e-3 * eAll ? drums : everything;
    const harmonic = mono((k) => k !== "drums" && k !== "vocals");
    const eHarm = energy(harmonic);
    const k = key(eHarm > 1e-4 * eAll ? harmonic : everything);
    const bpm = tempo(rhythm);
    const bass = mono((k) => k === "bass");
    const eBass = energy(bass);
    const vocal = mono((k) => voices.has(k));
    const Rhythm = need("rhythm.js", "Rhythm"), Chords = need("chords.js", "Chords");
    const structure = Rhythm.structure({
      rhythm, low: eBass > 1e-4 * eAll ? bass : rhythm, harmonic: eHarm > 1e-4 * eAll ? harmonic : everything,
      vocal, all: everything, bpm });
    const chords = Chords.detect({
      harmonic: eHarm > 1e-4 * eAll ? harmonic : everything, bass: eBass > 1e-4 * eAll ? bass : new Float32Array(0),
      beats: structure ? structure.beats : null, key: { root: k.root, minor: k.minor } });
    return new SongAnalysis({ bpm, keyRoot: k.root, minor: k.minor, keyConfidence: k.confidence, structure,
                              chords: chords.length ? chords : null });
  }

  // ── Tempo ──────────────────────────────────────────────────────────

  // Tempo e battiti chiedono gli attacchi della stessa traccia: si calcolano una volta sola
  const onsetCache = new WeakMap();

  /// Forza degli attacchi: quanto cresce l'energia in ogni banda da un istante al successivo.
  /// Il risultato si condivide tra chi chiede la stessa onda: non va modificato.
  function onsetEnvelope(x, hop = 441, fft = 1024) {
    const key = hop + ":" + fft;
    let byArgs = onsetCache.get(x);
    if (byArgs && byArgs.has(key)) return byArgs.get(key);
    const out = computeOnsets(x, hop, fft);
    if (!byArgs) onsetCache.set(x, (byArgs = new Map()));
    byArgs.set(key, out);
    return out;
  }

  function computeOnsets(x, hop, fft) {
    const s = STFT().PlainSTFT.shared(fft, hop);
    const F = s.bins, T = s.frames(x.length);
    const prev = new Float32Array(F);
    const env = new Float32Array(T);
    s.magnitudes(x, (t, mag) => {
      let flux = 0;
      for (let f = 1; f < F; f++) {
        const m = Math.fround(Math.log1p(1000 * mag[f]));
        const d = m - prev[f];
        if (d > 0) flux += d;
        prev[f] = m;
      }
      env[t] = flux;
    });
    // Si toglie la media mobile: restano solo gli attacchi
    const w = 16;
    const out = new Float32Array(T);
    for (let t = 0; t < T; t++) {
      const a = Math.max(0, t - w), b = Math.min(T, t + w + 1);
      let m = 0;
      for (let i = a; i < b; i++) m += env[i];
      out[t] = Math.max(0, env[t] - m / (b - a));
    }
    return out;
  }

  /// Battiti al minuto tra 70 e 180, dall'autocorrelazione degli attacchi.
  function tempo(x) {
    const hop = 441;
    const env = onsetEnvelope(x, hop);
    const fps = rate / hop;                       // 100 colonne al secondo
    const minLag = Math.trunc((fps * 60) / 180), maxLag = Math.trunc((fps * 60) / 70);
    if (!(env.length > maxLag * 4)) return 120;
    const ac = (lag) => {
      let s = 0;
      const m = env.length - lag;
      for (let i = 0; i < m; i++) s += env[i] * env[i + lag];
      return s / m;
    };
    const acs = new Float64Array(maxLag * 2 + 1);
    for (let l = 0; l <= maxLag * 2; l++) acs[l] = l >= Math.trunc(minLag / 2) ? ac(l) : 0;
    let best = minLag, bestScore = -Infinity;
    for (let lag = minLag; lag <= maxLag; lag++) {
      // Il battito vero si ripete anche al doppio: si premiano i ritardi che tornano
      const bpm = (fps * 60) / lag;
      const prior = Math.exp(-0.5 * Math.pow(Math.log2(bpm / 120) / 0.9, 2));
      const score = (acs[lag] + 0.5 * acs[Math.min(lag * 2, acs.length - 1)]) * prior;
      if (score > bestScore) { bestScore = score; best = lag; }
    }
    // Precisione sotto la colonna: parabola sui tre punti attorno al massimo
    const y0 = acs[best - 1], y1 = acs[best], y2 = acs[best + 1];
    const d = y0 - 2 * y1 + y2;
    const shift = d !== 0 ? Math.max(-0.5, Math.min(0.5, (0.5 * (y0 - y2)) / d)) : 0;
    return (fps * 60) / (best + shift);
  }

  // ── Tonalità ───────────────────────────────────────────────────────

  /// Profili di Krumhansl-Kessler: quanto ogni grado «suona» in una tonalità maggiore e minore.
  const majorProfile = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88];
  const minorProfile = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17];

  /// Energia di ogni nota (Do…Si) in tutta la canzone, tra 55 Hz e 5 kHz.
  function chroma(x, fft = 8192) {
    const { PlainSTFT, pitchClasses } = STFT();
    const s = PlainSTFT.shared(fft, fft);
    const F = s.bins, pc = pitchClasses(fft, rate, 55, 5000);
    const c = new Array(12).fill(0), frame = new Float64Array(12);
    s.magnitudes(x, (t, mag) => {
      frame.fill(0);
      let total = 0;
      for (let f = 1; f < F; f++) {
        const p = pc[f];
        if (p < 0) continue;
        frame[p] += mag[f];
        total += mag[f];
      }
      // Ogni istante conta uguale, forte o piano
      if (total > 1e-6) for (let i = 0; i < 12; i++) c[i] += frame[i] / total;
    });
    return c;
  }

  function corr(a, b) {
    let ma = 0, mb = 0;
    for (let i = 0; i < 12; i++) { ma += a[i]; mb += b[i]; }
    ma /= 12; mb /= 12;
    let num = 0, da = 0, db = 0;
    for (let i = 0; i < 12; i++) { num += (a[i] - ma) * (b[i] - mb); da += (a[i] - ma) ** 2; db += (b[i] - mb) ** 2; }
    return da > 0 && db > 0 ? num / Math.sqrt(da * db) : 0;
  }

  /// {root, minor, confidence}
  function key(x) {
    const c = chroma(x);
    const scores = [];
    for (let r = 0; r < 12; r++) {
      const rotated = c.map((_, i) => c[(i + r) % 12]);
      scores.push({ root: r, minor: false, r: corr(rotated, majorProfile) });
      scores.push({ root: r, minor: true, r: corr(rotated, minorProfile) });
    }
    scores.sort((a, b) => b.r - a.r);
    const best = scores[0];
    // Netta se la migliore stacca le altre (la relativa minore/maggiore è sempre vicina: si guarda la terza)
    const gap = best.r - scores[2].r;
    return { root: best.root, minor: best.minor, confidence: Math.max(0, Math.min(1, best.r * 0.6 + gap * 2)) };
  }

  const api = { SongAnalysis, rate, analyze, onsetEnvelope, tempo, chroma, key, majorProfile, minorProfile };
  NS.Analysis = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : globalThis);
