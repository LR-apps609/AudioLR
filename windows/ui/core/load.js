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

  /// Pezzi sovrapposti dei RoFormer: 2 in Massima e nelle voci speciali, 1 in Studio, dove i tre passaggi si
  /// fanno già la media (banco severo del 04/11, 50 canzoni: al massimo −0,07 dB). Uguale su tutti i computer.
  const OVERLAP = 2;
  const overlapFor = (quality) => (quality === "studio" ? 1 : OVERLAP);

  /// Un modello alla volta in memoria: sui computer deboli (fino a 9 GB). Non cambia il risultato.
  function oneAtATime({ webgpu = true, forceCpu = false, fellBack = false, memoryGB } = {}) {
    // Fino a 9 GB come sul Mac (Prefs.lowMemory): con 8 GB e Studio due modelli aperti insieme sono troppi (b-6)
    return !webgpu || forceCpu || fellBack || (!!memoryGB && memoryGB <= 9);
  }

  /// I modelli di una qualità (Rapida usa HTDemucs, che è dentro l'installer).
  function models(quality) {
    if (quality === "fast") return [];
    if (quality === "best") return ["StrumentiSW"];
    return ["VoceRevive", "StrumentiSW"];
  }

  /// Secondi di lavoro per minuto di canzone, per le schede della qualità (Studio: tre passaggi RoFormer senza doppio passaggio).
  const perMinute = (quality) => ({ fast: 8, best: 40, studio: 65 })[quality];

  /// Rapida senza WebGPU lavora sul processore: misurato circa 25 volte più lenta (106 s per 30 s di canzone su 4 core).
  const perMinuteCpuFast = 200;

  /// Il tempo della scheda di una qualità per una canzone di 4 minuti. Se questo PC ha già separazioni con questa
  /// qualità, dalla sua velocità vera (mediana delle ultime 5); altrimenti dalla tabella, e Rapida senza WebGPU
  /// non promette più «circa 30 secondi» (bug b-7). Come le schede del Mac.
  function estimate(quality, { library = [], webgpu = true, seconds = 240 } = {}) {
    const rates = library.map((e) => e && e.meta).filter((m) => m && m.quality === quality && m.duration >= 20 && m.took > 0)
      .slice(0, 5).map((m) => m.took / m.duration).sort((a, b) => a - b);
    let s, here = "";
    if (rates.length) { s = rates[rates.length >> 1] * seconds; here = " su questo PC"; }
    else s = ((quality === "fast" && !webgpu ? perMinuteCpuFast : perMinute(quality)) * seconds) / 60;
    if (s < 50) return "circa 30 secondi" + here;
    if (s < 90) return `circa ${Math.round(s / 10) * 10} secondi${here}`;
    const m = Math.max(1, Math.round(s / 60));
    return `circa ${m} ${m === 1 ? "minuto" : "minuti"}${here}`;
  }

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

  const api = { OVERLAP, overlapFor, oneAtATime, models, perMinute, estimate, voice, instruments };
  NS.Load = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : globalThis);
