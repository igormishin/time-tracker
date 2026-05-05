// Time Tracker — service worker
// Кеширует HTML/JS/иконки чтобы PWA запускалось без сети.
// API запросы (Supabase) НЕ перехватываем — они идут напрямую.

const CACHE = 'tracker-v4';
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
  e.notification.close();
  const action = e.action; // '' | 'stop'
  e.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    if (action === 'stop') {
      if (all.length > 0) {
        all.forEach(c => c.postMessage({ type: 'stop-active' }));
        all[0].focus().catch(() => {});
      } else {
        // Нет открытого клиента — открываем PWA с маркером
        await self.clients.openWindow('./?stop=1');
      }
    } else {
      if (all.length > 0) all[0].focus().catch(() => {});
      else await self.clients.openWindow('./');
    }
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
