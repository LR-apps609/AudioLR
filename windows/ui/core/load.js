// ════════════════════════════════════════════════════════════════════
//  Le ricette e il carico sul computer, come Quality e Prefs sul Mac.
//  Studio è la stessa ovunque: voce = media(Revive, voce di SW sulla canzone),
//  strumenti = media(SW sulla base, SW sulla canzone). Sulle 50 canzoni intere
//  di MUSDB uguale o meglio della ricetta di prima con sette passaggi.
//  Sui computer deboli (senza WebGPU, solo processore, dopo il ripiego sul
//  processore o con 4 GB o meno) i modelli si aprono uno alla volta: cambia
//  solo la memoria usata, non il risultato.
// ════════════════════════════════════════════════════════════════════
(function (root) {
  "use strict";

  const NS = (root.IsoLR = root.IsoLR || {});

  /// Pezzi sovrapposti dei RoFormer: 2 su tutti i computer, come nel banco di prova.
  const OVERLAP = 2;

  /// Un modello alla volta in memoria: sui computer deboli. Non cambia il risultato.
  function oneAtATime({ webgpu = true, forceCpu = false, fellBack = false, memoryGB } = {}) {
    return !webgpu || forceCpu || fellBack || (!!memoryGB && memoryGB <= 4);
  }

  /// I modelli di una qualità (Rapida usa HTDemucs, che è dentro l'installer).
  function models(quality) {
    if (quality === "fast") return [];
    if (quality === "best") return ["StrumentiSW"];
    return ["VoceRevive", "StrumentiSW"];
  }

  /// Secondi di lavoro per minuto di canzone, per le schede della qualità (Studio: tre passaggi RoFormer).
  const perMinute = (quality) => ({ fast: 8, best: 40, studio: 120 })[quality];

  const zeros = (n) => [new Float32Array(n), new Float32Array(n)];
  function mean(list, n) {
    const out = zeros(n);
    for (const t of list) for (let c = 0; c < 2; c++) { const a = out[c], b = t[c]; for (let k = 0; k < n; k++) a[k] += b[k]; }
    for (let c = 0; c < 2; c++) { const a = out[c]; for (let k = 0; k < n; k++) a[k] /= list.length; }
    return out;
  }

  /// La voce di Studio: media di Revive e della voce di SW sulla canzone.
  const voice = (revive, onMix, n) => mean([revive, onMix.vocals], n);

  /// Gli strumenti di Studio: medie di SW sulla base e sulla canzone (anche per «altro»: è lo stesso che
  /// prendere il resto medio meno chitarra e piano medi).
  function instruments(onMix, onBase, n) {
    return { drums: mean([onBase.drums, onMix.drums], n), bass: mean([onBase.bass, onMix.bass], n),
      guitar: mean([onBase.guitar, onMix.guitar], n), piano: mean([onBase.piano, onMix.piano], n), other: mean([onBase.other, onMix.other], n) };
  }

  const api = { OVERLAP, oneAtATime, models, perMinute, voice, instruments };
  NS.Load = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : globalThis);
