// Duel Arena moved to /duel-arena/ (2026-11-09). This stub clears the old
// /godot/ caches and unregisters itself, so the redirect always loads fresh.
self.addEventListener('install', function (e) { self.skipWaiting(); });
self.addEventListener('activate', function (e) {
  e.waitUntil(
    caches.keys()
      .then(function (keys) { return Promise.all(keys.map(function (k) { return caches.delete(k); })); })
      .then(function () { return self.registration.unregister(); })
  );
});
self.addEventListener('fetch', function (e) {});
