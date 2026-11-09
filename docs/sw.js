/* photo-frame is discontinued. This service worker replaces the old one: it deletes the saved offline copy,
   removes itself and reloads open pages, so they show the "discontinued" notice. */
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => {
  e.waitUntil((async () => {
    for(const k of await caches.keys()) await caches.delete(k);
    await self.registration.unregister();
    for(const c of await self.clients.matchAll({ type: 'window' })) { try { c.navigate(c.url); } catch {} }
  })());
});
