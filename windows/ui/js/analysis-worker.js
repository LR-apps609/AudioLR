// Tempo, tonalità, battiti, parti e accordi (core/*.js, copia di Analysis.swift, Rhythm.swift, Chords.swift),
// fuori dalla finestra: su una canzone lunga sono alcuni secondi di calcoli.
/* global IsoLR */
importScripts("../core/stft.js", "../core/rhythm.js", "../core/chords.js", "../core/analysis.js");
self.onmessage = (e) => {
  const { keys, channels } = e.data;
  try {
    const stems = {};
    keys.forEach((k, i) => { stems[k] = [channels[2 * i], channels[2 * i + 1]]; });
    const a = IsoLR.Analysis.analyze(stems);
    self.postMessage({ analysis: a ? JSON.parse(JSON.stringify(a)) : null });
  } catch (err) {
    self.postMessage({ analysis: null, error: String((err && err.message) || err) });
  }
};
