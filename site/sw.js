const V = 'finanze-v2', CORE = ['./', 'index.html', 'manifest.webmanifest', 'icon-180.png', 'icon-192.png', 'icon-512.png'];
const VELOCI = ['prezzi.json', 'mercati.json', 'analisi.json'];          // piccoli e che cambiano spesso: prima la rete (massimo 4 secondi), poi l'ultima copia
const LENTI = ['storico-prezzi.csv', 'aziende.json', 'catalogo.json', 'grandi-soldi.json', 'classifiche.json', 'storico-mercato.json', 'arena.json'];          // grandi: si aprono subito dalla copia e si aggiornano in sottofondo
self.addEventListener('install', e => e.waitUntil(caches.open(V).then(c => c.addAll(CORE).then(() => Promise.all(VELOCI.concat(LENTI).map(f => c.add(f).catch(() => {}))))).then(() => self.skipWaiting())));
self.addEventListener('activate', e => e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== V).map(k => caches.delete(k)))).then(() => self.clients.claim())));
self.addEventListener('fetch', e => {
  const u = new URL(e.request.url);
  if (e.request.method !== 'GET' || u.origin !== location.origin || u.searchParams.has('nc')) return;        // solo file di questo sito; con ?nc= (controllo versione) sempre dalla rete
  const nome = u.pathname.split('/').pop(), pagina = e.request.mode === 'navigate' || nome === '' || nome === 'index.html', chiave = pagina ? 'index.html' : e.request;
  const rete = () => fetch(e.request, { cache: 'no-store' }).then(r => { if (r.ok) { const cp = r.clone(); caches.open(V).then(c => c.put(chiave, cp)); } return r; });
  const copia = () => caches.match(chiave).then(m => m || (pagina ? caches.match('index.html') : null));
  if (VELOCI.includes(nome)) { e.respondWith(Promise.race([rete(), new Promise((_, no) => setTimeout(no, 4000))]).catch(() => copia().then(m => m || rete().catch(() => Response.error())))); return; }
  e.respondWith(copia().then(m => { if (m) { e.waitUntil(rete().catch(() => {})); return m; } return rete().catch(() => Response.error()); }));        // pagina e dati grandi: subito dalla copia, aggiornata in sottofondo (la versione nuova si vede alla riapertura, o con "Aggiorna adesso")
});