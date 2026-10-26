// ════════════════════════════════════════════════════════════════════
//  Le regole del mixer, separate dal suono così si possono provare:
//  muto, solo e volume per traccia, le scorciatoie (karaoke, solo voce…),
//  «senza il mio strumento», il nome del mix esportato; e i calcoli della
//  sala prove: clic del metronomo, durata di un battito per il conteggio,
//  rampa di velocità, e il secondo della canzone di una registrazione.
//  Copia delle parti senza audio di Sources/Mixer.swift e Sources/Recorder.swift.
// ════════════════════════════════════════════════════════════════════
(function (root) {
  "use strict";

  const NS = (root.IsoLR = root.IsoLR || {});
  const round = (x) => (x < 0 ? -Math.floor(-x + 0.5) : Math.floor(x + 0.5));

  /// I pezzi della batteria divisa (DrumSplitter.parts).
  const drumParts = ["kick", "snare", "toms", "hh", "ride", "crash"];

  /// Tutte le tracce di voce (intera, oppure solista e cori, o uomo e donna, se è stata divisa).
  const voices = new Set(["vocals", "lead", "backing", "male", "female"]);

  /// Scorciatoie: tutto, karaoke (senza voce), karaoke con i cori (se la voce è divisa), solo voce.
  const Preset = {
    all: { id: "all", title: "Tutto" },
    karaoke: { id: "karaoke", title: "Karaoke" },
    backing: { id: "backing", title: "Con i cori" },
    voice: { id: "voice", title: "Solo voce" },
  };

  /// «Senza il mio strumento»: la propria parte via dal mix, per suonarci sopra.
  const instrumentTitles = { drums: "Batteria", bass: "Basso", guitar: "Chitarra", piano: "Pianoforte" };
  const Instrument = {};
  for (const id of Object.keys(instrumentTitles)) {
    Instrument[id] = {
      id,
      title: instrumentTitles[id],
      /// «Senza batteria», «Senza basso»…
      without: "Senza " + instrumentTitles[id].toLowerCase(),
      /// Le tracce di questo strumento (la batteria anche divisa nei suoi pezzi).
      keys: new Set(id === "drums" ? ["drums", ...drumParts] : [id]),
    };
  }

  const sameSet = (a, b) => a.size === b.size && [...a].every((x) => b.has(x));
  const subset = (a, b) => [...a].every((x) => b.has(x));

  class MixState {
    constructor({ gain = {}, muted = [], solo = [] } = {}) {
      /// Volume per traccia (manca = 1).
      this.gain = Object.assign({}, gain);
      this.muted = new Set(muted);
      this.solo = new Set(solo);
    }

    /// Il volume che una traccia ha davvero: zero se è muta, o se altre sono in «solo» e lei no.
    effectiveGain(key) {
      if (this.muted.has(key)) return 0;
      if (this.solo.size && !this.solo.has(key)) return 0;
      return key in this.gain ? this.gain[key] : 1;
    }

    applyWithout(i) {
      const inst = typeof i === "string" ? Instrument[i] : i;
      this.muted = new Set(inst.keys);
      this.solo = new Set();
    }

    /// Lo strumento tolto ("drums", "bass"…), se il mix è «senza» uno strumento e basta; altrimenti null.
    get without() {
      if (this.solo.size || !this.muted.size) return null;
      const i = Object.values(Instrument).find((x) => sameSet(this.muted, x.keys));
      return i ? i.id : null;
    }

    /// p: "all", "karaoke", "backing", "voice".
    apply(p) {
      this.muted = new Set();
      this.solo = new Set();
      switch (p) {
        case "all": break;
        case "karaoke": this.muted = new Set(voices); break;
        case "backing": this.muted = new Set(["lead"]); break;
        case "voice": this.solo = new Set(voices); break;
      }
    }

    /// Quale scorciatoia corrisponde allo stato attuale (se una corrisponde, altrimenti null).
    get preset() {
      // «Tutta la voce»: la voce intera, oppure solista e cori insieme (o uomo e donna)
      const allVoice = (s) => s.size > 0 && subset(s, voices) &&
        (s.has("vocals") || (s.has("lead") && s.has("backing")) || (s.has("male") && s.has("female")));
      const m = this.muted, s = this.solo;
      if (!m.size && !s.size) return "all";
      if (m.size === 1 && m.has("lead") && !s.size) return "backing";
      if (allVoice(m) && !s.size) return "karaoke";
      if (allVoice(s) && !m.size) return "voice";
      return null;
    }

    /// Somma delle tracce con i volumi del mixer: tracks = [{key, audio: [canali]}] → [sinistra, destra].
    static mix(tracks, state) {
      let n = 0;
      for (const t of tracks) n = Math.max(n, t.audio.length ? t.audio[0].length : 0);
      const out = [new Float32Array(n), new Float32Array(n)];
      for (const t of tracks) {
        const g = Math.fround(state.effectiveGain(t.key));
        if (!(g > 0)) continue;
        for (let c = 0; c < 2; c++) {
          const ch = t.audio[Math.min(c, t.audio.length - 1)], o = out[c];
          for (let i = 0; i < ch.length; i++) o[i] += ch[i] * g;
        }
      }
      return out;
    }
  }
  MixState.voices = voices;
  MixState.Preset = Preset;
  MixState.Instrument = Instrument;

  /// Le tracce che si mescolano (chiavi): la base senza voce è già un mix, quindi resta fuori; se una traccia
  /// è stata divisa (batteria, voce), al suo posto ci sono le sue parti.
  function mixable(keys) {
    const splits = [
      { source: "vocals", parts: ["lead", "backing"] },
      { source: "vocals", parts: ["male", "female"] },
      { source: "drums", parts: drumParts }];
    const replaced = splits.filter((s) => keys.some((k) => s.parts.includes(k))).map((s) => s.source);
    return keys.filter((k) => k !== "instrumental" && !replaced.includes(k));
  }

  // ── Sala prove ────────────────────────────────────────────────────

  const rampStart = 0.7;
  const rampStep = 0.05;
  const rampTarget = 1.0;
  /// La velocità del giro successivo: un passo in più, senza superare il traguardo.
  function rampNext(r, step = rampStep, target = rampTarget) {
    return Math.min(target, round((r + step) * 100) / 100);
  }

  /// I clic tra `from` e `to` (secondi della canzone): [{time, strong}], strong = primo della battuta.
  function clicks(s, from, to) {
    const out = [];
    s.beats.forEach((t, i) => {
      if (!(t >= from - 0.001 && t < to)) return;
      const k = (((i - s.firstDownbeat) % s.beatsPerBar) + s.beatsPerBar) % s.beatsPerBar;
      out.push({ time: t, strong: k === 0 });
    });
    return out;
  }

  /// La durata di un battito vicino a `at`: dai battiti trovati se ci sono, altrimenti dal tempo medio.
  function beatPeriod(s, bpm, at) {
    const b = s ? s.beats : null;
    if (b && b.length >= 3) {
      let idx = b.findIndex((x) => x >= at);
      if (idx < 0) idx = b.length - 1;
      const i = Math.min(b.length - 2, Math.max(0, idx - 1));
      const lo = Math.max(0, i - 4), hi = Math.min(b.length - 1, i + 4);
      const gaps = [];
      for (let j = lo; j < hi; j++) gaps.push(b[j + 1] - b[j]);
      gaps.sort((x, y) => x - y);
      const m = gaps.length ? gaps[Math.trunc(gaps.length / 2)] : null;
      if (m !== null && m > 0.2 && m < 2) return m;
    }
    return bpm > 0 ? 60 / bpm : 0.5;
  }

  /// La parte della canzone in cui si trova `t`.
  function sectionAt(s, t) {
    return (s && s.sections.find((x) => t >= x.start && t < x.end)) || null;
  }

  /// «Canzone – Karaoke», «Canzone – Solo voce» o «Canzone – Mix».
  function exportName(state, title) {
    switch (state.preset) {
      case "karaoke": return `${title} – Karaoke`;
      case "voice": return `${title} – Solo voce`;
      case "backing": return `${title} – Karaoke con cori`;
      default: {
        const w = state.without;
        if (w) return `${title} – ${Instrument[w].without}`;
        return `${title} – Mix`;
      }
    }
  }

  // ── Registrazione ─────────────────────────────────────────────────

  /// L'orologio di una registrazione (TakeClock): quando il lettore è partito e da dove.
  class TakeClock {
    constructor({ startHost, at, lead, rate, semitones = 0, outputLatency = 0 }) {
      /// Istante (secondi) in cui il lettore ha cominciato: il primo clic del conteggio, o la musica.
      this.startHost = startHost;
      /// Secondo della canzone da cui la musica parte, e quanto conteggio c'era prima (in secondi di canzone).
      this.at = at;
      this.lead = lead;
      this.rate = rate;
      this.semitones = semitones;
      /// Ritardo dell'uscita (altoparlanti o cuffie), secondi.
      this.outputLatency = outputLatency;
    }
    /// Il secondo della canzone che si sentiva quando il suono `host` (secondi) è entrato nel microfono.
    songTime(host) {
      return this.at - this.lead + (host - this.outputLatency - this.startHost) * this.rate;
    }
  }

  const api = { MixState, Preset, Instrument, voices, drumParts, mixable, rampStart, rampStep, rampTarget, rampNext,
                clicks, beatPeriod, sectionAt, exportName, TakeClock };
  NS.Mix = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : globalThis);
