// Confronta le tracce salvate dal sito prima e dopo una modifica: SDR di «dopo» rispetto a «prima»
// (identiche = ∞; sopra 60 dB la differenza è sotto il rumore dei 24 bit). Esce con errore se una traccia
// manca o scende sotto 60 dB.
//   node site/test/confronta-wav.js <cartella-prima> <cartella-dopo> [uscita.json]
const fs = require("fs"), path = require("path");

function read24(file) {
  const b = fs.readFileSync(file);
  let o = 12, fmt = null, data = null;
  while (o + 8 <= b.length) {
    const id = b.toString("ascii", o, o + 4), size = b.readUInt32LE(o + 4);
    if (id === "fmt ") fmt = { ch: b.readUInt16LE(o + 10), bits: b.readUInt16LE(o + 22) };
    if (id === "data") data = b.subarray(o + 8, o + 8 + size);
    o += 8 + size + (size & 1);
  }
  const bps = fmt.bits / 8, n = data.length / bps, out = new Float64Array(n);
  for (let i = 0; i < n; i++) out[i] = bps === 3 ? data.readIntLE(i * 3, 3) / 8388608 : data.readInt16LE(i * 2) / 32768;
  return out;
}

const [A, B, OUT] = process.argv.slice(2);
const res = {};
let ok = true;
for (const f of fs.readdirSync(A).filter((x) => x.endsWith(".wav")).sort()) {
  if (!fs.existsSync(path.join(B, f))) { res[f] = "manca"; ok = false; continue; }
  const a = read24(path.join(A, f)), b = read24(path.join(B, f));
  if (a.length !== b.length) { res[f] = `lunghezza diversa (${a.length} / ${b.length})`; ok = false; continue; }
  let num = 0, den = 0;
  for (let i = 0; i < a.length; i++) { num += a[i] * a[i]; den += (a[i] - b[i]) ** 2; }
  const sdr = den === 0 ? Infinity : 10 * Math.log10((num + 1e-12) / den);
  res[f] = sdr === Infinity ? "identica" : `${sdr.toFixed(1)} dB`;
  if (sdr < 60) ok = false;
}
console.log(JSON.stringify(res, null, 1));
if (OUT) fs.writeFileSync(OUT, JSON.stringify({ tracce: res, esito: ok ? "uguali" : "DIVERSE" }, null, 1));
if (!Object.keys(res).length) { console.error("nessuna traccia da confrontare"); process.exit(1); }
process.exit(ok ? 0 : 1);
