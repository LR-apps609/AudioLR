// La canzone finta delle prove dell'interfaccia (tracce sintetiche, battiti, parti, accordi), nei file in memoria del ponte.
async function fakeSong(page) {
  await page.evaluate(async () => {
    const n = 44100 * 8, keys = ["vocals", "drums", "bass", "guitar", "piano", "other", "instrumental"];
    const shares = [0.28, 0.22, 0.16, 0.12, 0.09, 0.13, null];
    const folder = "C:/Users/prova/Music/IsoLR/TENDER_WIP_2 versione lunga del titolo";
    const stems = [];
    for (let i = 0; i < keys.length; i++) {
      const ch = [new Float32Array(n), new Float32Array(n)], f = 110 * (i + 1), w = 0.7 + i * 0.3;
      for (let j = 0; j < n; j++) { const t = j / 44100, v = 0.3 * Math.sin(2 * Math.PI * f * t) * (0.5 + 0.5 * Math.sin(2 * Math.PI * w * t)); ch[0][j] = v; ch[1][j] = v; }
      const file = `TENDER – ${Separation.NAMES[keys[i]]}.wav`;
      await Bridge.writeFile(`${folder}/${file}`, Encode.wav(ch, 24));
      stems.push({ key: keys[i], name: Separation.NAMES[keys[i]], file, export: file, share: shares[i], peakDB: -3, peaks: Separation.measure(ch).peaks });
    }
    const beats = []; for (let t = 0; t < 8; t += 0.25) beats.push(t);
    const meta = { version: 1, title: "TENDER_WIP_2 versione lunga del titolo", created: new Date().toISOString(), quality: "studio", duration: 280, took: 480,
      engine: "Scheda grafica (WebGPU)", gainDB: 0, source: "TENDER_WIP_2.mp3", stems,
      analysis: { bpm: 115, keyRoot: 0, minor: false, keyConfidence: 0.8,
        structure: { beats, firstDownbeat: 0, beatsPerBar: 4, sections: [
          { start: 0, end: 0.8, label: "Intro", group: 0 }, { start: 0.8, end: 2.4, label: "Strofa", group: 1 }, { start: 2.4, end: 3.7, label: "Ritornello", group: 2 },
          { start: 3.7, end: 5.3, label: "Strofa", group: 1 }, { start: 5.3, end: 7.2, label: "Ritornello", group: 2 }, { start: 7.2, end: 8, label: "Finale", group: 3 }] },
        chords: [{ start: 0, end: 2, root: 9, minor: true }, { start: 2, end: 4, root: 5, minor: false }, { start: 4, end: 6, root: 0, minor: false }, { start: 6, end: 8, root: 7, minor: false }] } };
    await Bridge.writeText(`${folder}/isolr.json`, JSON.stringify(meta));
    await IsoApp.refreshLibrary();
  });
}
module.exports = { fakeSong };
