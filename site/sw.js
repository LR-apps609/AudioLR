// Il sito anche senza internet, dopo il primo uso: prima si chiede sempre alla rete (così un aggiornamento del
// sito arriva subito) e solo se la rete non c'è si usa la copia salvata. I pezzi del modello non passano di qui:
// li tiene il lavoratore nella sua cache («audiolr-modelli-v1»).
const SHELL = "isolr-sito-v1";
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));
self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== location.origin || /\/models\//.test(url.pathname)) return;
  e.respondWith((async () => {
    try {
      const res = await fetch(e.request);
      if (res.ok && res.type === "basic") { const c = await caches.open(SHELL); c.put(e.request, res.clone()).catch(() => {}); }
      return res;
    } catch (err) {
      const hit = await caches.match(e.request, { ignoreSearch: true });
      if (hit) return hit;
      throw err;
    }
  })());
});
