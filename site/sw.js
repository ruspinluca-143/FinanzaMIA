const V = 'finanze-v1', CORE = ['./', 'index.html', 'manifest.webmanifest', 'icon-180.png', 'icon-192.png', 'icon-512.png'];
const DATI = ['prezzi.json', 'mercati.json', 'storico-prezzi.csv', 'aziende.json'];        // ultimi dati noti: se uno manca non blocca l'installazione
self.addEventListener('install', e => e.waitUntil(caches.open(V).then(c => c.addAll(CORE).then(() => Promise.all(DATI.map(f => c.add(f).catch(() => {}))))).then(() => self.skipWaiting())));
self.addEventListener('activate', e => e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== V).map(k => caches.delete(k)))).then(() => self.clients.claim())));
self.addEventListener('fetch', e => {
  const u = new URL(e.request.url);
  if (e.request.method !== 'GET' || u.origin !== location.origin) return;        // solo file di questo sito: nessun altro indirizzo
  e.respondWith(fetch(e.request).then(r => { if (r.ok) { const cp = r.clone(); caches.open(V).then(c => c.put(e.request, cp)); } return r; })
    .catch(() => caches.match(e.request).then(m => m || (e.request.mode === 'navigate' ? caches.match('index.html') : Response.error()))));
});