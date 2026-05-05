// Time Tracker — service worker
// Кеширует HTML/JS/иконки чтобы PWA запускалось без сети.
// API запросы (Supabase) НЕ перехватываем — они идут напрямую.

const CACHE = 'tracker-v6';
const ASSETS = [
  './',
  './index.html',
  './manifest.webmanifest',
  './icons/app-icon-v3-180.png',
  './icons/app-icon-v3-192.png',
  './icons/app-icon-v3-512.png',
];

self.addEventListener('install', (e) => {
  e.waitUntil(
    caches.open(CACHE)
      .then(c => c.addAll(ASSETS).catch(err => console.warn('precache:', err)))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

// Клик по уведомлению (включая action "Стоп") — пробрасываем в открытое окно
self.addEventListener('notificationclick', (e) => {
  const action = e.action; // '' | 'stop'
  if (action === 'stop') e.notification.close();
  e.waitUntil((async () => {
    const scope = self.registration.scope;
    const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    // Берём только наши клиенты (в нашем scope)
    const ours = all.filter(c => c.url.startsWith(scope));
    if (action === 'stop') {
      if (ours.length > 0) {
        ours.forEach(c => c.postMessage({ type: 'stop-active' }));
        try { await ours[0].focus(); }
        catch { await self.clients.openWindow(scope + '?stop=1'); }
      } else {
        await self.clients.openWindow(scope + '?stop=1');
      }
      return;
    }
    // Body tap — открываем/фокусируем PWA
    if (ours.length > 0) {
      try { await ours[0].focus(); return; }
      catch {}
    }
    try { await self.clients.openWindow(scope); }
    catch (err) { console.warn('openWindow failed:', err); }
  })());
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  const url = new URL(req.url);

  // Не трогаем Supabase API / Realtime
  if (url.hostname.endsWith('supabase.co') || url.hostname.endsWith('supabase.in')) return;

  // Только GET кешируем
  if (req.method !== 'GET') return;

  // HTML / навигация — network-first с фоллбеком на кэш
  if (req.mode === 'navigate' || (req.headers.get('accept') || '').includes('text/html')) {
    e.respondWith(
      fetch(req)
        .then(r => {
          const copy = r.clone();
          caches.open(CACHE).then(c => c.put(req, copy)).catch(() => {});
          return r;
        })
        .catch(() => caches.match(req).then(r => r || caches.match('./')))
    );
    return;
  }

  // Всё остальное (статика, шрифты, CDN-скрипты) — cache-first
  e.respondWith(
    caches.match(req).then(cached => {
      if (cached) {
        // Фоновое обновление кэша
        fetch(req).then(r => {
          if (r && r.ok) caches.open(CACHE).then(c => c.put(req, r.clone())).catch(() => {});
        }).catch(() => {});
        return cached;
      }
      return fetch(req).then(r => {
        if (r && r.ok) {
          const copy = r.clone();
          caches.open(CACHE).then(c => c.put(req, copy)).catch(() => {});
        }
        return r;
      });
    })
  );
});
