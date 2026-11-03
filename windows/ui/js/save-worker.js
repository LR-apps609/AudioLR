// I file delle tracce (misure, livello comune e codifica WAV/FLAC/AAC) fuori dalla finestra: su una canzone
// lunga sono secondi di calcoli che prima bloccavano l'interfaccia alla fine della separazione.
// Il codice è lo stesso di prima (encode.js, stems.js): i file escono identici.
/* global Stems, Encode */
self.window = self;                              // encode.js si appoggia a «window»
importScripts("stems.js", "encode.js");

self.onmessage = async (e) => {
  const { tracks, order, format } = e.data;
  try {
    // Se anche una sola traccia supera il massimo, tutte si abbassano dello stesso tanto (Stem.safeGain)
    let top = 0;
    const m = {};
    for (const k of Object.keys(tracks)) { m[k] = Stems.measure(tracks[k]); top = Math.max(top, m[k].peak); }
    const gain = top > 0.98 ? 0.98 / top : 1;
    self.postMessage({ type: "info", gain, m });
    // Una traccia alla volta: la finestra la scrive mentre qui si prepara la successiva
    for (const k of order) {
      const bytes = await Encode.encode(tracks[k], format, gain);
      const work = format !== "wav24" ? Encode.wav(tracks[k], 24, gain) : null;
      tracks[k] = null;
      self.postMessage({ type: "stem", k, bytes, work }, work ? [bytes.buffer, work.buffer] : [bytes.buffer]);
    }
  } catch (err) {
    self.postMessage({ type: "error", message: String((err && err.message) || err) });
  }
};
