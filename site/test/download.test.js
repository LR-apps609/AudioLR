// Il download dei pezzi del modello (site/app/worker.js), senza browser: tre cadute brevi di fila non lo fanno
// fallire (prima i tentativi si contavano in tutto per pezzo) e, quando i dati tornano, il messaggio «riprendo…»
// lascia il posto ai MB scaricati.   node site/test/download.test.js
const fs = require("fs"), path = require("path"), vm = require("vm"), assert = require("assert");

const src = fs.readFileSync(path.join(__dirname, "../app/worker.js"), "utf8");
const PART = 1000;
let calls = 0;
// Un server finto: ogni risposta manda 150 byte e poi la connessione cade, finché il pezzo non è finito
function fakeFetch(url, opts = {}) {
  calls++;
  const range = opts.headers && opts.headers.Range;
  const from = range ? +/bytes=(\d+)-/.exec(range)[1] : 0;
  const end = Math.min(PART, from + 150);
  let sent = false;
  return Promise.resolve({
    ok: true, status: range ? 206 : 200,
    body: { getReader: () => ({ read: async () => {
      if (!sent) { sent = true; return { done: false, value: new Uint8Array(end - from) }; }
      if (end >= PART) return { done: true };
      throw new Error("network error");
    } }) },
  });
}
const ctx = { self: { location: new URL("http://x/app/worker.js"), postMessage() {} }, navigator: { hardwareConcurrency: 2 }, importScripts() {}, ort: { env: { wasm: {} } },
              fetch: fakeFetch, setTimeout: (f) => setTimeout(f, 1), clearTimeout, AbortController, URL, Uint8Array, Error, Math, Promise, performance };
vm.createContext(ctx);
vm.runInContext(src, ctx);

(async () => {
  const retries = [];
  const chunks = await ctx.download("http://x/models/p", (n, attempt) => retries.push([n, attempt]));
  const got = chunks.reduce((a, c) => a + c.length, 0);
  assert.strictEqual(got, PART, "il pezzo arriva intero");
  assert.ok(calls >= 7, "ci sono state più cadute dei 5 tentativi");
  // Ogni volta che arrivano byte il tentativo segnalato è 1: niente «riprendo… (tentativo N)» mentre scarica
  assert.ok(retries.filter(([n]) => n > 0).every(([, a]) => a === 1), "con i dati che arrivano niente messaggio di ripresa");
  console.log(`OK: pezzo intero dopo ${calls - 1} cadute brevi, messaggio di ripresa solo mentre si aspetta`);
})().catch((e) => { console.error(e); process.exit(1); });
