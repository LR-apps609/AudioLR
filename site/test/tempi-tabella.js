// La tabella prima/dopo del banco dei tempi del sito, in Markdown (per il riepilogo di GitHub).
//   node site/test/tempi-tabella.js prima.json dopo.json [confronto.json]
const fs = require("fs");
const [P, D, C] = process.argv.slice(2).map((f) => f && JSON.parse(fs.readFileSync(f, "utf8")));
const kb = (b) => b == null ? "–" : b > 1048576 ? `${(b / 1048576).toFixed(1)} MB` : `${Math.round(b / 1024)} KB`;
const s = (x) => x == null ? "–" : `${x} s`;
const rows = [
  ["Pagina, prima visita: byte", (r) => kb(r.visita_fredda.byte_pagina)],
  ["Pagina, prima visita: primo disegno", (r) => `${r.visita_fredda.primo_disegno_ms} ms`],
  ["Pagina, seconda visita: byte", (r) => kb(r.visita_calda.byte_pagina)],
  ["Pagina, seconda visita: primo disegno", (r) => `${r.visita_calda.primo_disegno_ms} ms`],
  ["Modello a freddo (scarica + apre)", (r) => s(r.separazione_fredda.modello_pronto_s)],
  ["Modello a freddo: byte dalla rete", (r) => kb(r.separazione_fredda.byte_rete)],
  ["Modello a caldo (dalla cache)", (r) => s(r.separazione_calda.modello_pronto_s)],
  ["Modello a caldo: byte dalla rete", (r) => kb(r.separazione_calda.byte_rete)],
  [`Separazione (${P.secondi_canzone} s di canzone), a freddo`, (r) => s(r.separazione_fredda.separazione_s)],
  ["Separazione, a caldo", (r) => s(r.separazione_calda.separazione_s)],
  ["Aggiornamenti della barra (fredda)", (r) => String(r.separazione_fredda.aggiornamenti_barra)],
  ["Blocchi della pagina > 50 ms durante la separazione", (r) => `${r.separazione_fredda.longtask.numero} (max ${r.separazione_fredda.longtask.massimo_ms} ms)`],
  ["Memoria massima del browser", (r) => `${r.separazione_fredda.memoria_max_mb} MB`],
  ["Rete caduta a 30 MB del modello", (r) => r.interruzione.ripreso ? `riprende (${s(r.interruzione.modello_pronto_s)})` : `si ferma: ${String(r.interruzione.errore).slice(0, 60)}`],
];
let md = `| Misura | Prima | Dopo |\n|---|---|---|\n`;
for (const [name, f] of rows) {
  let a = "–", b = "–";
  try { a = f(P); } catch {}
  try { b = f(D); } catch {}
  md += `| ${name} | ${a} | ${b} |\n`;
}
md += `\nMacchina: ${D.macchina}, Chromium senza schermo (senza scheda grafica: calcolo sul processore).\n`;
if (C) md += `\nQualità, tracce dopo contro prima: **${C.esito}** · ${Object.entries(C.tracce).map(([k, v]) => `${k.replace(".wav", "")} ${v}`).join(" · ")}\n`;
console.log(md);
