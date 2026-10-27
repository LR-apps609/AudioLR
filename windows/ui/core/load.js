// ════════════════════════════════════════════════════════════════════
//  Carico sul computer, come Prefs.light e Quality sul Mac: in leggero
//  (computer lenti) meno passaggi, pezzi meno sovrapposti e un modello in
//  memoria alla volta. Automatico = leggero senza WebGPU, con «Usa solo il
//  processore», dopo il ripiego sul processore o con 4 GB di memoria o meno.
//  Studio leggera, ricetta A: voce = media(Revive, voce di SW sulla canzone),
//  strumenti = media(SW sulla base, SW sulla canzone); B: strumenti solo da
//  SW sulla canzone. Si sceglie con il banco di prova («Leggera A» e «B»).
// ════════════════════════════════════════════════════════════════════
(function (root) {
  "use strict";

  const NS = (root.IsoLR = root.IsoLR || {});

  /// La ricetta di Studio leggera: "a" o "b" (come Quality.lightStudioRecipe sul Mac).
  const LIGHT_STUDIO = "a";
  /// Pezzi sovrapposti dei RoFormer: 2 di serie, 1,5 in leggero (come «Rapida» sul Mac).
  const overlap = (light) => (light ? 1.5 : 2);

  /// Il perché della modalità leggera (null = completa).
  function reason({ mode = "auto", webgpu = true, forceCpu = false, fellBack = false, memoryGB } = {}) {
    if (mode === "full") return null;
    if (mode === "light") return "scelta nelle Impostazioni";
    if (!webgpu) return "automatica: niente scheda grafica adatta";
    if (forceCpu) return "automatica: solo il processore";
    if (fellBack) return "automatica: la scheda grafica non riesce";
    if (memoryGB && memoryGB <= 4) return "automatica: poca memoria";
    return null;
  }
  const isLight = (o) => reason(o) !== null;
  const text = (o) => { const r = reason(o); return r ? `leggera (${r})` : null; };

  /// I modelli di una qualità: in leggero Studio ne usa due (niente Kim né Demucs).
  function models(quality, light) {
    if (quality === "fast") return [];
    if (quality === "best") return ["StrumentiSW"];
    return light ? ["VoceRevive", "StrumentiSW"] : ["VoceRevive", "VoceRoFormer9", "StrumentiSW", "HTDemucsFT-1"];
  }

  /// Quante volte la durata della canzone (secondi di lavoro per minuto di canzone), per le schede della qualità.
  function perMinute(quality, light) {
    const full = { fast: 8, best: 40, studio: 200 }[quality];
    if (!light || quality === "fast") return full;
    // Massima: pezzi meno sovrapposti (circa un quarto in meno); Studio: due o tre passaggi invece di sette
    return quality === "best" ? 30 : LIGHT_STUDIO === "a" ? 90 : 60;
  }

  const zeros = (n) => [new Float32Array(n), new Float32Array(n)];
  function mean(list, n) {
    const out = zeros(n);
    for (const t of list) for (let c = 0; c < 2; c++) { const a = out[c], b = t[c]; for (let k = 0; k < n; k++) a[k] += b[k]; }
    for (let c = 0; c < 2; c++) { const a = out[c]; for (let k = 0; k < n; k++) a[k] /= list.length; }
    return out;
  }

  /// La voce di Studio leggera: media di Revive e della voce di SW sulla canzone.
  const voice = (revive, onMix, n) => mean([revive, onMix.vocals], n);

  /// Gli strumenti di Studio leggera. A: medie di SW sulla base e sulla canzone; B (onBase null): SW sulla canzone.
  /// «Altro» resta quello che avanza (resto meno chitarra e piano), come in Studio.
  function instruments(onMix, onBase, n) {
    if (!onBase) return { drums: onMix.drums, bass: onMix.bass, guitar: onMix.guitar, piano: onMix.piano, other: onMix.other };
    return { drums: mean([onBase.drums, onMix.drums], n), bass: mean([onBase.bass, onMix.bass], n),
      guitar: mean([onBase.guitar, onMix.guitar], n), piano: mean([onBase.piano, onMix.piano], n), other: mean([onBase.other, onMix.other], n) };
  }

  const api = { LIGHT_STUDIO, overlap, reason, isLight, text, models, perMinute, voice, instruments };
  NS.Load = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : globalThis);
