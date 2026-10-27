// Transpose, come Sources/Transpose.swift sul Mac: la canzone in un'altra tonalità senza cambiare la velocità.
// Nell'ascolto lo fa il mixer (Signalsmith, player.semitones); nei file scaricati qui, fuori tempo reale.
// Più la tonalità nuova a parole, il capotasto per la chitarra e «Porta alla mia voce».
/* global SignalsmithStretch, IsoLR */
(function () {
  "use strict";
  const RATE = 44100;
  const RANGE = [-7, 7];
  const IT = ["Do", "Do♯", "Re", "Mi♭", "Mi", "Fa", "Fa♯", "Sol", "La♭", "La", "Si♭", "Si"];
  const EN = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"];
  const mod = (x) => ((x % 12) + 12) % 12;

  /** La traccia spostata di `semitones`, lunga uguale e allineata all'originale. */
  async function apply(ch, semitones) {
    if (!semitones) return ch;
    const n = ch[0].length;
    const off = new OfflineAudioContext(2, n + RATE, RATE);
    const node = await SignalsmithStretch(off);
    node.connect(off.destination);
    await node.addBuffers([ch[0], ch[1] || ch[0]]);
    node.schedule({ active: true, input: 0, output: 0, rate: 1, semitones });
    const r = await off.startRendering();
    // Signalsmith compensa da solo il suo ritardo: si tiene la lunghezza originale
    return [r.getChannelData(0).slice(0, n), r.getChannelData(1).slice(0, n)];
  }

  const label = (s) => (s > 0 ? `+${s}` : s < 0 ? `−${-s}` : "0");
  const suffix = (s) => (s ? ` (${label(s)})` : "");
  const keyName = (root, minor, shift) => IT[mod(root + shift)] + (minor ? " minore" : " maggiore");
  const keyShort = (root, minor, shift) => EN[mod(root + shift)] + (minor ? "m" : "");
  const noteName = (m) => IT[mod(m)] + (Math.floor(m / 12) - 1);

  // Le forme aperte facili della chitarra: C D E G A Dm Em Am
  const EASY = new Set(["0", "2", "4", "7", "9", "2m", "4m", "9m"]);
  /** Il capotasto che fa suonare più accordi con forme facili; null se non serve. */
  function capo(chords, shift) {
    const played = (chords || []).filter((c) => c.root != null);
    if (!played.length) return null;
    const score = (k) => played.reduce((s, c) => s + (EASY.has(`${mod(c.root + shift - k)}${c.minor ? "m" : ""}`) ? c.end - c.start : 0), 0);
    const total = played.reduce((s, c) => s + c.end - c.start, 0);
    let best = 0;
    for (let k = 1; k <= 7; k++) if (score(k) > score(best)) best = k;
    if (best === 0 || score(best) <= score(0) + 0.25 * total) return null;
    const shapes = [];
    for (const c of played) { const s = EN[mod(c.root + shift - best)] + (c.minor ? "m" : ""); if (!shapes.includes(s)) shapes.push(s); if (shapes.length === 4) break; }
    return { capo: best, shapes };
  }

  /** Le note più basse e più alte della voce (MIDI, 10° e 95° percentile). */
  function vocalRange(voice) {
    const C = IsoLR.Compare, x = C.decimate(voice), sr = C.rate / C.down;
    const frames = Math.floor((x.length - C.frame) / C.hop);
    if (frames <= 100) return null;
    let loud = 0;
    for (let t = 0; t < frames; t++) loud = Math.max(loud, C.rms(x, t * C.hop));
    const notes = [];
    for (let t = 0; t < frames; t += 5) {
      if (C.rms(x, t * C.hop) <= loud * 0.05) continue;
      const hz = C.yin(x, t * C.hop, sr, 70, 1100);
      if (hz) notes.push(C.midi(hz));
    }
    if (notes.length < 40) return null;
    notes.sort((a, b) => a - b);
    return { low: notes[Math.floor(notes.length / 10)], high: notes[Math.min(notes.length - 1, Math.floor((notes.length * 95) / 100))] };
  }
  const suggest = (songHigh, myHigh) => Math.max(RANGE[0], Math.min(RANGE[1], Math.round(myHigh - songHigh)));

  window.Transpose = { RANGE, apply, label, suffix, keyName, keyShort, noteName, capo, vocalRange, suggest };
  if (typeof module !== "undefined") module.exports = window.Transpose;
})();
