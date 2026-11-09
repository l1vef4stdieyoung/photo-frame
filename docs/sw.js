/* Photo frame service worker: always asks the server first (revalidating, so updates arrive right away),
   and falls back to the last saved copy when the tablet is offline.
   The same file serves the normal frame (/photo-frame/) and the beta copy (/photo-frame/beta/); each keeps its own cache. */
const SCOPE = new URL(self.registration.scope).pathname;
const CACHE = 'photo-frame-v3:' + SCOPE;
const CORE = ['./', './index.html', './manifest.webmanifest', './icon-192.png', './icon-512.png'];
self.addEventListener('install', e => { e.waitUntil(caches.open(CACHE).then(c => c.addAll(CORE)).then(() => self.skipWaiting())); });
self.addEventListener('activate', e => {
  /* removes this frame's older caches (and the pre-v3 one) but never the other channel's */
  e.waitUntil(caches.keys().then(k => Promise.all(k.filter(x => x !== CACHE && (x === 'photo-frame-v2' || x.endsWith(':' + SCOPE))).map(x => caches.delete(x)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const r = e.request, u = new URL(r.url);
  if(r.method !== 'GET' || u.origin !== location.origin || u.pathname.endsWith('version.json')) return;
  /* the beta copy has its own service worker */
  if(u.pathname.startsWith(SCOPE + 'beta/')) return;
  /* pages are revalidated with the server every time (a cheap 304 when unchanged) instead of trusting the 10-minute HTTP cache */
  const net = r.mode === 'navigate' ? fetch(r.url, { cache: 'no-cache', credentials: 'same-origin' }) : fetch(r);
  e.respondWith(net.then(res => { if(res.ok){ const c = res.clone(); caches.open(CACHE).then(x => x.put(r.mode === 'navigate' ? './index.html' : r, c)); } return res; })
    .catch(() => caches.open(CACHE).then(c => c.match(r, { ignoreSearch: true }).then(m => m || c.match('./index.html')))));
});
