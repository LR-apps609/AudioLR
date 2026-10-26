// ════════════════════════════════════════════════════════════════════
//  Spartito e tablatura dalle note MIDI di una traccia.
//  • Le note si mettono sulle battute vere della canzone (i battiti trovati)
//    e si arrotondano ai sedicesimi; le note lunghe che passano la
//    stanghetta si legano.
//  • MusicXML: si apre in MuseScore, Guitar Pro, Sibelius, Finale, Dorico.
//    Per chitarra e basso c'è anche il pentagramma della tablatura.
//  • Tablatura di testo (.txt) per chitarra e basso: corde e tasti scelti
//    per muovere la mano il meno possibile, restando in basso sul manico.
//  Copia di Sources/Sheet.swift: se lì cambia qualcosa, va cambiato anche qui.
// ════════════════════════════════════════════════════════════════════
(function (root) {
  "use strict";

  const NS = (root.IsoLR = root.IsoLR || {});
  const round = (x) => (x < 0 ? -Math.floor(-x + 0.5) : Math.floor(x + 0.5));

  /// Una nota (o un accordo, o una pausa) dello spartito, in sedicesimi:
  /// {start, length, pitches (vuoto = pausa), tieOut, tieIn}.
  function event(start, length, pitches, tieOut = false, tieIn = false) {
    return { start, length, pitches, tieOut, tieIn };
  }

  const perBar = 16;          // 4/4, in sedicesimi

  /// Diesis (+) o bemolle (−) in chiave: Sol maggiore +1, Fa maggiore −1…
  function fifthsOf(keyRoot, minor) {
    const major = minor ? (keyRoot + 3) % 12 : keyRoot;
    return [0, -5, 2, -3, 4, -1, 6, 1, -4, 3, -2, 5][major];
  }

  class Score {
    constructor(bars, bpm, keyRoot = 0, minor = false) {
      this.bars = bars;
      this.bpm = bpm;
      /// Tonalità (per i diesis o i bemolle in chiave).
      this.keyRoot = keyRoot;
      this.minor = minor;
    }
    get fifths() { return fifthsOf(this.keyRoot, this.minor); }

    /// Mette le note ({start, end, pitch}) sulle battute: `structure` (battiti veri) se c'è, altrimenti un tempo fisso.
    static build(notes, { structure = null, bpm, keyRoot = 0, minor = false, monophonic }) {
      bpm = bpm > 0 ? bpm : 120;
      // Da secondi a battiti (con decimali), contati dal primo battito di una battuta
      let beatOf;
      if (structure && structure.beats.length >= 4) {
        const b = structure.beats, first = structure.firstDownbeat;
        const p0 = b[1] - b[0], p1 = b[b.length - 1] - b[b.length - 2];
        beatOf = (t) => {
          if (t <= b[0]) return (t - b[0]) / p0 - first;
          if (t >= b[b.length - 1]) return b.length - 1 + (t - b[b.length - 1]) / p1 - first;
          let lo = 0, hi = b.length - 1;
          while (hi - lo > 1) { const m = (lo + hi) >> 1; if (b[m] <= t) lo = m; else hi = m; }
          return lo + (t - b[lo]) / (b[hi] - b[lo]) - first;
        };
      } else {
        beatOf = (t) => (t * bpm) / 60;
      }
      // In sedicesimi, arrotondati
      let q = notes.map((n) => {
        const a = round(beatOf(n.start) * 4), e = round(beatOf(n.end) * 4);
        return { start: a, end: Math.max(a + 1, e), pitch: n.pitch };
      });
      if (!q.length) return new Score([], bpm, keyRoot, minor);
      // Si parte dalla battuta della prima nota
      const origin = Math.floor(Math.min(...q.map((x) => x.start)) / perBar) * perBar;
      q = q.map((x) => ({ start: x.start - origin, end: x.end - origin, pitch: x.pitch }));
      // Note che partono insieme = un accordo; una voce sola: ogni nota finisce dove parte la successiva
      const byStart = new Map();
      for (const x of q) { if (!byStart.has(x.start)) byStart.set(x.start, []); byStart.get(x.start).push(x); }
      const starts = [...byStart.keys()].sort((a, b) => a - b);
      const events = [];
      starts.forEach((start, k) => {
        const group = byStart.get(start);
        let end = Math.max(...group.map((x) => x.end));
        if (k + 1 < starts.length) end = Math.min(end, starts[k + 1]);
        let pitches = [...new Set(group.map((x) => x.pitch))].sort((a, b) => a - b);
        if (monophonic) pitches = [pitches[pitches.length - 1]];
        events.push({ start, end: Math.max(start + 1, end), pitches });
      });
      // Battute: pause dove non c'è niente, note lunghe spezzate sulla stanghetta e legate
      const total = events[events.length - 1].end;
      const count = Math.trunc((total + perBar - 1) / perBar);
      const bars = Array.from({ length: count }, () => []);
      let cursor = 0;
      const put = (a, b, p) => {
        let s = a;
        while (s < b) {
          const bar = Math.trunc(s / perBar), barEnd = (bar + 1) * perBar;
          const e = Math.min(b, barEnd);
          bars[bar].push(event(s - bar * perBar, e - s, p, p.length > 0 && e < b, p.length > 0 && s > a));
          s = e;
        }
      };
      for (const ev of events) {
        if (ev.start > cursor) put(cursor, ev.start, []);
        put(ev.start, ev.end, ev.pitches);
        cursor = ev.end;
      }
      if (cursor < count * perBar) put(cursor, count * perBar, []);
      return new Score(bars, bpm, keyRoot, minor);
    }

    /// Una durata qualsiasi in figure legate (5 = 4 + 1).
    static split(n) {
      let left = n;
      const out = [];
      while (left > 0) {
        const f = Score.figures.find((x) => x.length <= left);
        out.push(f);
        left -= f.length;
      }
      return out;
    }
  }
  Score.perBar = perBar;
  /// Le durate che si scrivono con una figura sola (in sedicesimi): semibreve, minima puntata… sedicesimo.
  Score.figures = [
    { length: 16, type: "whole", dot: false }, { length: 12, type: "half", dot: true }, { length: 8, type: "half", dot: false },
    { length: 6, type: "quarter", dot: true }, { length: 4, type: "quarter", dot: false }, { length: 3, type: "eighth", dot: true },
    { length: 2, type: "eighth", dot: false }, { length: 1, type: "16th", dot: false }];

  // ── Tablatura ─────────────────────────────────────────────────────

  const Tab = {
    /// Accordature, dalla corda più acuta: chitarra Mi La Re Sol Si Mi, basso Mi La Re Sol.
    guitar: [64, 59, 55, 50, 45, 40],
    bass: [43, 38, 33, 28],
    names: ["E", "B", "G", "D", "A", "E"],
    frets: 20,

    /// Corda (0 = la più acuta) e tasto per ogni nota di ogni accordo, muovendo la mano il meno possibile:
    /// [battuta][evento] → [{string, fret}].
    positions(score, tuning) {
      const frets = Tab.frets;
      const low = Math.min(...tuning), high = Math.max(...tuning) + frets;
      const fit = (p) => { while (p < low) p += 12; while (p > high) p -= 12; return p; };
      const cost = (fret, hand) => (fret === 0 ? 1 : Math.abs(fret - hand) + 0.15 * fret);
      let hand = 3;                                     // dove sta la mano (tasto)
      return score.bars.map((bar) => bar.map((ev) => {
        const used = new Set(), out = [];
        for (const p of ev.pitches.map(fit).sort((a, b) => b - a)) {
          // Vicino alla mano, e meglio in basso sul manico (le corde vuote vanno bene)
          let s = -1;
          for (let i = 0; i < tuning.length; i++) {
            if (used.has(i) || p - tuning[i] < 0 || p - tuning[i] > frets) continue;
            if (s < 0 || cost(p - tuning[i], hand) < cost(p - tuning[s], hand)) s = i;
          }
          if (s < 0) continue;
          used.add(s);
          out.push({ string: s, fret: p - tuning[s] });
        }
        const fretted = out.map((x) => x.fret).filter((f) => f > 0);
        if (fretted.length) hand = fretted.reduce((a, b) => a + b, 0) / fretted.length;
        return out;
      }));
    },

    /// La tablatura in testo, quattro battute per riga, un trattino per sedicesimo.
    text(score, tuning, title) {
      const pos = Tab.positions(score, tuning);
      const strings = tuning.length;
      const labels = strings === 6 ? Tab.names : ["G", "D", "A", "E"];
      let out = `${title}\nAccordatura: ${strings === 6 ? "Mi La Re Sol Si Mi" : "Mi La Re Sol"} · ${round(score.bpm)} BPM · 4/4\n`;
      out += "Un trattino = un sedicesimo. Tablatura stimata da IsoLR: controllala a orecchio.\n\n";
      for (let row = 0; row < score.bars.length; row += 4) {
        const lines = labels.slice(0, strings).map((l) => `${l}|`);
        for (let b = row; b < Math.min(row + 4, score.bars.length); b++) {
          const cells = Array.from({ length: strings }, () => new Array(perBar).fill("--"));
          score.bars[b].forEach((ev, k) => {
            if (ev.tieIn) return;
            for (const { string, fret } of pos[b][k]) cells[string][ev.start] = String(fret).length === 1 ? `${fret}-` : `${fret}`;
          });
          for (let s = 0; s < strings; s++) lines[s] += cells[s].join("") + "|";
        }
        out += `Battuta ${row + 1}\n` + lines.join("\n") + "\n\n";
      }
      return out;
    },
  };

  // ── MusicXML ──────────────────────────────────────────────────────

  const sharpNames = ["C", "C", "D", "D", "E", "F", "F", "G", "G", "A", "A", "B"];
  const sharpAlter = [0, 1, 0, 1, 0, 0, 1, 0, 1, 0, 1, 0];
  const flatNames = ["C", "D", "D", "E", "E", "F", "G", "G", "A", "A", "B", "B"];
  const flatAlter = [0, -1, 0, -1, 0, 0, -1, 0, -1, 0, -1, 0];

  const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

  const MusicXML = {
    /// Che tipo di pentagramma: "treble", "bass", "guitar", "bassGuitar" (chiave e, per chitarra e basso, la tablatura sotto).
    tuning(kind) { return kind === "guitar" ? Tab.guitar : kind === "bassGuitar" ? Tab.bass : null; },

    kind(stem, notes) {
      if (stem === "guitar") return "guitar";
      if (stem === "bass") return "bassGuitar";
      const pitches = notes.map((n) => n.pitch).sort((a, b) => a - b);
      const median = pitches.length ? pitches[Math.trunc(pitches.length / 2)] : 60;
      return median < 57 ? "bass" : "treble";
    },

    /// Il documento MusicXML (testo UTF-8).
    data(score, kind, title, instrument, program) {
      const tuning = MusicXML.tuning(kind);
      const tab = tuning ? Tab.positions(score, tuning) : null;
      let x = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">
<score-partwise version="4.0">
  <work><work-title>${esc(title)}</work-title></work>
  <identification><encoding><software>IsoLR</software></encoding></identification>
  <part-list>
    <score-part id="P1"><part-name>${esc(instrument)}</part-name>
      <midi-instrument id="P1-I1"><midi-program>${program + 1}</midi-program></midi-instrument></score-part>
`;
      if (tab) x += `    <score-part id="P2"><part-name>${esc(instrument)} (tab)</part-name></score-part>\n`;
      x += "  </part-list>\n";
      x += part("P1", score, kind, null);
      if (tab) x += part("P2", score, kind, { pos: tab, tuning });
      x += "</score-partwise>\n";
      return x;
    },
  };

  function part(id, score, kind, tab) {
    const flats = score.fifths < 0;
    const bpm = round(score.bpm);
    let x = `  <part id="${id}">\n`;
    score.bars.forEach((bar, b) => {
      x += `    <measure number="${b + 1}">\n`;
      if (b === 0) {
        x += `      <attributes><divisions>4</divisions><key><fifths>${score.fifths}</fifths></key>`;
        x += "<time><beats>4</beats><beat-type>4</beat-type></time>";
        if (tab) {
          x += `<clef><sign>TAB</sign><line>5</line></clef><staff-details><staff-lines>${tab.tuning.length}</staff-lines>`;
          tab.tuning.slice().reverse().forEach((p, i) => {
            const step = sharpNames[p % 12], alter = sharpAlter[p % 12];
            x += `<staff-tuning line="${i + 1}"><tuning-step>${step}</tuning-step>${alter !== 0 ? `<tuning-alter>${alter}</tuning-alter>` : ""}<tuning-octave>${Math.trunc(p / 12) - 1}</tuning-octave></staff-tuning>`;
          });
          x += "</staff-details>";
        } else {
          switch (kind) {
            case "treble": x += "<clef><sign>G</sign><line>2</line></clef>"; break;
            case "bass": x += "<clef><sign>F</sign><line>4</line></clef>"; break;
            // Chitarra e basso si scrivono un'ottava sopra di come suonano
            case "guitar": x += "<clef><sign>G</sign><line>2</line><clef-octave-change>-1</clef-octave-change></clef>"; break;
            case "bassGuitar": x += "<clef><sign>F</sign><line>4</line><clef-octave-change>-1</clef-octave-change></clef>"; break;
          }
        }
        x += "</attributes>\n";
        x += `      <direction placement="above"><direction-type><metronome><beat-unit>quarter</beat-unit><per-minute>${bpm}</per-minute></metronome></direction-type><sound tempo="${bpm}"/></direction>\n`;
      }
      bar.forEach((ev, k) => {
        const pieces = Score.split(ev.length);
        pieces.forEach((f, i) => {
          const tieIn = ev.tieIn || i > 0, tieOut = ev.tieOut || i < pieces.length - 1;
          if (!ev.pitches.length) {
            x += `      <note><rest/><duration>${f.length}</duration><type>${f.type}</type>${f.dot ? "<dot/>" : ""}</note>\n`;
            return;
          }
          const frets = tab ? tab.pos[b][k] : null;
          ev.pitches.forEach((p, j) => {
            const pc = p % 12;
            const step = flats ? flatNames[pc] : sharpNames[pc], alter = flats ? flatAlter[pc] : sharpAlter[pc];
            x += `      <note>${j > 0 ? "<chord/>" : ""}<pitch><step>${step}</step>${alter !== 0 ? `<alter>${alter}</alter>` : ""}<octave>${Math.trunc(p / 12) - 1}</octave></pitch>`;
            x += `<duration>${f.length}</duration>`;
            if (tieIn) x += '<tie type="stop"/>';
            if (tieOut) x += '<tie type="start"/>';
            x += `<type>${f.type}</type>${f.dot ? "<dot/>" : ""}`;
            let notations = "";
            if (tieIn) notations += '<tied type="stop"/>';
            if (tieOut) notations += '<tied type="start"/>';
            // Corda e tasto: la corda 1 è la più acuta. Le note fuori dalla chitarra restano senza
            const sf = frets ? frets.find((q) => (tab.tuning[q.string] + q.fret) % 12 === pc) : null;
            if (sf) notations += `<technical><string>${sf.string + 1}</string><fret>${sf.fret}</fret></technical>`;
            if (notations) x += `<notations>${notations}</notations>`;
            x += "</note>\n";
          });
        });
      });
      x += "    </measure>\n";
    });
    return x + "  </part>\n";
  }

  const api = { Score, Tab, MusicXML, event, fifthsOf };
  NS.Sheet = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : globalThis);
