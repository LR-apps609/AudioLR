// ════════════════════════════════════════════════════════════════════
//  «Progetto per…»: le tracce separate pronte da aprire in un programma
//  musicale. Copia di Sources/DawExport.swift: se lì cambia qualcosa, va
//  cambiato anche qui.
//  • Ableton Live: un set .als (XML compresso con gzip) con una traccia
//    audio per strumento, il tempo della canzone, i locatori sulle parti
//    e, se ci sono i battiti, i segnaposto di warp sul primo battito di
//    ogni battuta (la griglia di Live segue la canzone).
//  • REAPER: un .rpp (testo) con tracce, colori, tempo e marcatori.
//  • Tutti gli altri (Logic, GarageBand, FL Studio, Cubase, Studio One):
//    le tracce numerate e allineate, un MIDI con la mappa del tempo e i
//    marcatori delle parti, e un LEGGIMI.
//  • DJ: un foglio .cue con le parti (formato CUE, documentato e letto da
//    molti programmi) e lo stesso elenco in testo semplice.
// ════════════════════════════════════════════════════════════════════
(function (root) {
  "use strict";

  const NS = (root.IsoLR = root.IsoLR || {});

  /// Colori delle tracce (gli stessi del tema scuro) e il colore più vicino della tavolozza di Ableton (0…69).
  const COLORS = {
    vocals: [0xFF7A66, 14], clean: [0xFF8F7D, 14], lead: [0xEC8A70, 14], backing: [0xF0B3A2, 2], male: [0xE07F66, 14], female: [0xF4B49B, 2],
    drums: [0xFFC24B, 4], bass: [0xB48CFF, 24], guitar: [0x8EE07A, 6], piano: [0x7FA8FF, 21], other: [0x43E0C2, 8],
    instrumental: [0x6CC3FF, 21],
  };
  const color = (key) => COLORS[key] || [0xC9C2D2, 13];

  const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  const num = (x) => (Math.round(x * 1e6) / 1e6).toString();
  /// «120 BPM» solo se il tempo è stato misurato davvero: altrimenti non si scrive nei nomi
  const bpmText = (p) => (p.measured === false ? "" : `${Math.round(p.bpm)} BPM`);
  const head = (p, sep) => [bpmText(p), p.key || ""].filter(Boolean).join(sep);

  /// Il progetto: le parti comuni a tutti i formati, dalla canzone separata.
  /// tracks: [{ key, name, file (percorso relativo nella cartella del progetto), seconds }]
  function project({ title, bpm, key, seconds, tracks, structure }) {
    const st = structure || {};
    const beats = Array.isArray(st.beats) ? st.beats.filter((b) => b >= 0 && b <= seconds) : [];
    return {
      title, key: key || null, seconds,
      bpm: Math.max(20, Math.min(300, bpm || 120)),
      measured: !!bpm,                                     // senza analisi (canzone cortissima) 120 è solo di serie
      tracks,
      beats, firstDownbeat: st.firstDownbeat || 0, beatsPerBar: st.beatsPerBar || 4,
      sections: (st.sections || []).filter((s) => s.start < seconds).map((s) => ({ start: Math.max(0, s.start), label: s.label })),
    };
  }

  /// I primi battiti di ogni battuta (secondi).
  function downbeats(p) {
    const out = [];
    for (let i = p.firstDownbeat; i < p.beats.length; i += p.beatsPerBar) out.push(p.beats[i]);
    return out;
  }

  /// I segnaposto di warp: [secondi, battito di Live]. Il primo battito di ogni battuta cade su un multiplo di
  /// beatsPerBar; prima del primo, il tempo della canzone. Vuoto senza battiti (la clip resta senza warp).
  function warpMarkers(p) {
    const d = downbeats(p);
    if (d.length < 2) return [];
    const start = (d[0] * p.bpm) / 60;                      // dove cade il primo battito della battuta, in battiti
    const first = Math.round(start / p.beatsPerBar) * p.beatsPerBar;
    return d.map((s, i) => [s, first + i * p.beatsPerBar]);
  }

  /// Da secondi a battiti di Live: lungo i segnaposto (se ci sono), altrimenti al tempo della canzone.
  function beatAt(p, sec, markers = warpMarkers(p)) {
    if (markers.length < 2) return (sec * p.bpm) / 60;
    let i = 0;
    while (i < markers.length - 2 && sec > markers[i + 1][0]) i++;
    const [s0, b0] = markers[i], [s1, b1] = markers[i + 1];
    return b0 + ((sec - s0) * (b1 - b0)) / (s1 - s0);
  }

  // ── Ableton Live ──
  /// Il set di Live come XML (schema di Live 11, che apre anche Live 12).
  function abletonXml(p) {
    const markers = warpMarkers(p), warped = markers.length >= 2;
    const end = beatAt(p, p.seconds, markers);
    let id = 100;
    const nid = () => ++id;
    const tracks = p.tracks.map((t, i) => {
      const [, col] = color(t.key);
      const warp = warped
        ? markers.map(([s, b]) => `<WarpMarker Id="${nid()}" SecTime="${num(s)}" BeatTime="${num(b)}" />`).join("")
        : `<WarpMarker Id="${nid()}" SecTime="0" BeatTime="0" /><WarpMarker Id="${nid()}" SecTime="${num(p.seconds)}" BeatTime="${num(end)}" />`;
      return `<AudioTrack Id="${i + 10}">
<LomId Value="0" /><LomIdView Value="0" /><IsContentSelectedInDocument Value="false" /><PreferredContentViewMode Value="0" />
<TrackDelay><Value Value="0" /><IsValueSampleBased Value="false" /></TrackDelay>
<Name><EffectiveName Value="${esc(t.name)}" /><UserName Value="${esc(t.name)}" /><Annotation Value="" /><MemorizedFirstClipName Value="" /></Name>
<Color Value="${col}" /><TrackGroupId Value="-1" /><TrackUnfolded Value="true" />
<DeviceChain>
<Mixer><Volume><Manual Value="1" /></Volume><Pan><Manual Value="0" /></Pan><Speaker><Manual Value="true" /></Speaker></Mixer>
<MainSequencer><Sample><ArrangerAutomation><Events>
<AudioClip Id="${nid()}" Time="0">
<LomId Value="0" /><CurrentStart Value="0" /><CurrentEnd Value="${num(end)}" />
<Loop><LoopStart Value="0" /><LoopEnd Value="${num(end)}" /><StartRelative Value="0" /><LoopOn Value="false" /><OutMarker Value="${num(end)}" /><HiddenLoopStart Value="0" /><HiddenLoopEnd Value="${num(end)}" /></Loop>
<Name Value="${esc(t.name)}" /><Annotation Value="" /><Color Value="${col}" /><Disabled Value="false" />
<SampleRef><FileRef><RelativePathType Value="3" /><RelativePath Value="${esc(t.file)}" /><Path Value="${esc(t.file)}" /><Type Value="1" /><LivePackName Value="" /><LivePackId Value="" /><OriginalFileSize Value="0" /><OriginalCrc Value="0" /></FileRef><LastModDate Value="0" /><DefaultDuration Value="${Math.round(p.seconds * 44100)}" /><DefaultSampleRate Value="44100" /></SampleRef>
<WarpMarkers>${warp}</WarpMarkers>
<MarkersGenerated Value="true" /><IsWarped Value="${warped}" /><WarpMode Value="4" /><GranularityTones Value="30" /><GranularityTexture Value="65" /><FluctuationTexture Value="25" /><ComplexProFormants Value="100" /><ComplexProEnvelope Value="128" />
<Fades><FadeInLength Value="0" /><FadeOutLength Value="0" /><ClipFadesAreInitialized Value="true" /><IsDefaultFadeIn Value="true" /><IsDefaultFadeOut Value="true" /></Fades>
<PitchCoarse Value="0" /><PitchFine Value="0" /><SampleVolume Value="1" />
</AudioClip>
</Events></ArrangerAutomation></Sample></MainSequencer>
</DeviceChain>
</AudioTrack>`;
    }).join("\n");
    const locators = p.sections.map((s, i) => `<Locator Id="${i}"><LomId Value="0" /><Time Value="${num(beatAt(p, s.start, markers))}" /><Name Value="${esc(s.label)}" /><Annotation Value="" /><IsSongStart Value="false" /></Locator>`).join("\n");
    return `<?xml version="1.0" encoding="UTF-8"?>
<Ableton MajorVersion="5" MinorVersion="11.0_433" SchemaChangeCount="3" Creator="IsoLR" Revision="">
<LiveSet>
<NextPointeeId Value="${id + 10}" /><OverwriteProtectionNumber Value="2816" /><LomId Value="0" /><LomIdView Value="0" />
<Tracks>
${tracks}
</Tracks>
<MasterTrack>
<Name><EffectiveName Value="Master" /><UserName Value="" /><Annotation Value="" /></Name>
<DeviceChain><Mixer>
<Tempo><LomId Value="0" /><Manual Value="${num(p.bpm)}" /><MidiControllerRange><Min Value="60" /><Max Value="200" /></MidiControllerRange><AutomationTarget Id="8"><LockEnvelope Value="0" /></AutomationTarget></Tempo>
<TimeSignature><LomId Value="0" /><Manual Value="${p.beatsPerBar === 3 ? 202 : 201}" /></TimeSignature>
</Mixer></DeviceChain>
</MasterTrack>
<Locators><Locators>
${locators}
</Locators></Locators>
<Annotation Value="${esc(p.title)}${p.key ? " · " + esc(p.key) : ""} · separata con IsoLR" />
</LiveSet>
</Ableton>
`;
  }

  /// Compressione gzip (il formato di un .als).
  async function gzip(bytes) {
    const cs = new CompressionStream("gzip");
    const out = new Response(new Blob([bytes]).stream().pipeThrough(cs));
    return new Uint8Array(await out.arrayBuffer());
  }
  async function gunzip(bytes) {
    const ds = new DecompressionStream("gzip");
    const out = new Response(new Blob([bytes]).stream().pipeThrough(ds));
    return new Uint8Array(await out.arrayBuffer());
  }
  async function als(p) { return gzip(new TextEncoder().encode(abletonXml(p))); }

  // ── REAPER ──
  function reaper(p) {
    const q = (s) => `"${String(s).replace(/"/g, "'")}"`;
    const lines = ["<REAPER_PROJECT 0.1 \"6.0\" 0", "  SAMPLERATE 44100 0 0", `  TEMPO ${num(p.bpm)} ${p.beatsPerBar} 4`];
    p.sections.forEach((s, i) => lines.push(`  MARKER ${i + 1} ${num(s.start)} ${q(s.label)} 0`));
    for (const t of p.tracks) {
      const [rgb] = color(t.key);
      // REAPER: rosso nei bit bassi, verde, blu; più il bit che dice «colore scelto»
      const peak = ((rgb >> 16) & 255) | (((rgb >> 8) & 255) << 8) | ((rgb & 255) << 16) | 0x1000000;
      lines.push("  <TRACK", `    NAME ${q(t.name)}`, `    PEAKCOL ${peak}`,
        "    <ITEM", "      POSITION 0", `      LENGTH ${num(t.seconds)}`, `      NAME ${q(t.name)}`,
        "      <SOURCE WAVE", `        FILE ${q(t.file)}`, "      >", "    >", "  >");
    }
    lines.push(">");
    return lines.join("\n") + "\n";
  }

  // ── MIDI: mappa del tempo e marcatori ──
  const PPQ = 480;
  function vlq(v) {
    v = Math.max(0, Math.round(v));
    const b = [v & 0x7f];
    v >>= 7;
    while (v > 0) { b.unshift((v & 0x7f) | 0x80); v >>= 7; }
    return b;
  }
  const be32 = (v) => [(v >>> 24) & 255, (v >>> 16) & 255, (v >>> 8) & 255, v & 255];
  const text = (s) => Array.from(new TextEncoder().encode(s)).slice(0, 120);

  /// Da secondi a tick: lungo i battiti (un battito = PPQ tick), al tempo della canzone fuori dai battiti.
  function tickAt(p, sec) {
    const b = p.beats;
    if (b.length < 2) return Math.round((sec * p.bpm * PPQ) / 60);
    if (sec <= b[0]) {
      const lead = (b[0] * p.bpm * PPQ) / 60, first = (b[0] - sec) * (PPQ / (b[1] - b[0]));
      return Math.max(0, Math.round(lead - first));
    }
    let i = 0;
    while (i < b.length - 2 && sec > b[i + 1]) i++;
    const lead = Math.round((b[0] * p.bpm * PPQ) / 60);
    return Math.round(lead + (i + (sec - b[i]) / (b[i + 1] - b[i])) * PPQ);
  }

  /// Un MIDI (formato 0): tempo che segue i battiti veri, metro, tonalità nel nome, marcatori delle parti.
  function tempoMidi(p) {
    const ev = [];                                         // [tick, ordine, byte]
    const tempo = (t, secPerBeat) => {
      const us = Math.max(200000, Math.min(3000000, Math.round(secPerBeat * 1e6)));
      ev.push([t, 0, [0xff, 0x51, 0x03, (us >> 16) & 255, (us >> 8) & 255, us & 255]]);
    };
    const name = text([p.title, head(p, " · ")].filter(Boolean).join(" · "));
    ev.push([0, -2, [0xff, 0x03, ...vlq(name.length), ...name]]);
    ev.push([0, -1, [0xff, 0x58, 0x04, p.beatsPerBar, 2, 24, 8]]);
    tempo(0, 60 / p.bpm);
    const b = p.beats;
    if (b.length >= 2) {
      const lead = Math.round((b[0] * p.bpm * PPQ) / 60);
      for (let i = 0; i < b.length - 1; i++) tempo(lead + i * PPQ, b[i + 1] - b[i]);
    }
    for (const s of p.sections) {
      const t = text(s.label);
      ev.push([tickAt(p, s.start), 1, [0xff, 0x06, ...vlq(t.length), ...t]]);
    }
    ev.sort((a, c) => a[0] - c[0] || a[1] - c[1]);
    const track = [];
    let last = 0;
    for (const [t, , bytes] of ev) { track.push(...vlq(t - last), ...bytes); last = t; }
    track.push(0x00, 0xff, 0x2f, 0x00);
    return new Uint8Array([...text("MThd"), ...be32(6), 0, 0, 0, 1, PPQ >> 8, PPQ & 255, ...text("MTrk"), ...be32(track.length), ...track]);
  }

  // ── DJ: foglio CUE e testo ──
  const cueTime = (sec) => {
    const f = Math.round(sec * 75), m = Math.floor(f / 4500), s = Math.floor((f % 4500) / 75), fr = f % 75;
    return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}:${String(fr).padStart(2, "0")}`;
  };
  function cueSheet(p, file) {
    const parts = p.sections.length ? p.sections : [{ start: 0, label: p.title }];
    const lines = [`TITLE "${p.title.replace(/"/g, "'")}"`];
    if (p.measured !== false) lines.push(`REM BPM ${num(p.bpm)}`);
    if (p.key) lines.push(`REM KEY "${p.key}"`);
    lines.push(`FILE "${file.replace(/"/g, "'")}" ${/\.wav$/i.test(file) ? "WAVE" : "MP3"}`);
    parts.forEach((s, i) => lines.push(`  TRACK ${String(i + 1).padStart(2, "0")} AUDIO`, `    TITLE "${s.label.replace(/"/g, "'")}"`, `    INDEX 01 ${cueTime(s.start)}`));
    return lines.join("\r\n") + "\r\n";
  }
  const clock = (sec) => `${Math.floor(sec / 60)}:${String(Math.floor(sec % 60)).padStart(2, "0")}.${String(Math.floor((sec % 1) * 10))}`;
  function partsText(p) {
    return [[p.title, head(p, " · ")].filter(Boolean).join(" · "), "", ...p.sections.map((s) => `${clock(s.start)}  ${s.label}`)].join("\r\n") + "\r\n";
  }

  /// Un nome che va bene come nome di file su Windows e sul Mac.
  const safe = (s) => String(s).replace(/[\\/:*?"<>|]/g, "-").replace(/\s+$/, "");

  /// Il nome della cartella: «Titolo – Ableton Project», «Titolo – REAPER», «Titolo – Tracce per DAW (120 BPM, La minore)».
  function folderName(p, kind) {
    const tail = head(p, ", ");
    if (kind === "ableton") return safe(`${p.title} – Ableton Project`);
    if (kind === "reaper") return safe(`${p.title} – REAPER`);
    return safe(`${p.title} – Tracce per DAW${tail ? ` (${tail})` : ""}`);
  }

  /// Dove vanno le tracce dentro la cartella del progetto: «Samples/Imported/01 Voce.wav» per Live, «Media/…» per REAPER.
  function trackFile(kind, index, name) {
    const dir = kind === "ableton" ? "Samples/Imported/" : kind === "reaper" ? "Media/" : "";
    return `${dir}${String(index + 1).padStart(2, "0")} ${safe(name)}.wav`;
  }

  function readme(p) {
    return [
      `${p.title} – tracce separate con IsoLR`,
      (p.measured === false ? `Tempo: non misurato (canzone troppo corta per l'analisi): il progetto usa ${Math.round(p.bpm)} BPM, da cambiare a mano` : `Tempo: ${Math.round(p.bpm)} BPM`) + (p.key ? " · Tonalità: " + p.key : ""),
      "",
      "Tutte le tracce iniziano a 0 e sono lunghe uguali: messe una sotto l'altra dall'inizio, sono allineate.",
      "«Tempo e marcatori.mid» contiene il tempo che segue i battiti veri della canzone e le parti (Intro, Strofa…). Trascinalo per primo.",
      "",
      "LOGIC PRO: trascina «Tempo e marcatori.mid» nella finestra principale e, se lo chiede, importa il tempo. Poi seleziona tutti i .wav e trascinali sotto, all'inizio (battuta 1).",
      "GARAGEBAND: imposta il tempo del progetto a " + Math.round(p.bpm) + " BPM, disattiva «Regola tempo» per le regioni audio, poi trascina i .wav all'inizio, uno per traccia.",
      "FL STUDIO: File › Import › MIDI file per «Tempo e marcatori.mid» (spunta «Import tempo»); poi trascina i .wav nella Playlist a battuta 1.",
      "CUBASE: File › Importa › File MIDI (tempo e marcatori), poi File › Importa › File audio, «Posiziona ogni file su una traccia diversa», dall'inizio del progetto.",
      "STUDIO ONE: trascina il .mid nella traccia tempo/marcatori e i .wav all'inizio della canzone.",
      "",
      "Le parti sono anche in «Parti.cue» (foglio CUE, per programmi da DJ e lettori) e in «Parti.txt».",
    ].join("\r\n") + "\r\n";
  }

  const api = { COLORS, project, downbeats, warpMarkers, beatAt, abletonXml, als, gzip, gunzip, reaper, tempoMidi, tickAt, cueSheet, partsText, folderName, trackFile, safe, readme, PPQ };
  NS.Daw = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : globalThis);
