// Time Tracker — service worker
// Кеширует HTML/JS/иконки чтобы PWA запускалось без сети.
// API запросы (Supabase) НЕ перехватываем — они идут напрямую.

const CACHE = 'tracker-v10';
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

// Кнопки шторки. Страница подтверждает действие, чтобы повторный pull не переключил таймер дважды.
let shadePending = null;
let shadeSeq = 0;

self.addEventListener('notificationclick', (event) => {
  const action = event.action || '';
  event.waitUntil(shadeClick(action));
});

self.addEventListener('notificationclose', (event) => {
  if (!event.notification || event.notification.tag !== 'tracker-shade') return;
  event.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const payload = event.notification.data || {};
    all.forEach(client => client.postMessage({
      type: 'shade-closed',
      gen: payload.gen,
      mode: payload.mode,
    }));
  })());
});

self.addEventListener('message', (event) => {
  const data = event.data || {};
  if (data.type === 'shade-ack' && shadePending && data.id === shadePending.id) {
    shadePending = null;
    return;
  }
  if (data.type === 'shade-pull' && shadePending && event.source) {
    event.source.postMessage({
      type: 'shade-action',
      action: shadePending.action,
      id: shadePending.id,
    });
  }
});

async function shadeClick(action) {
  const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
  const client = all.find(c => c.visibilityState === 'visible') || all[0];
  if (client) {
    if (action === 'start' || action === 'stop') {
      shadePending = { action: action, id: ++shadeSeq };
      client.postMessage({ type: 'shade-action', action: shadePending.action, id: shadePending.id });
    } else {
      try { await client.focus(); } catch (e) {}
    }
    return;
  }
  const url = new URL('./', self.registration.scope);
  if (action === 'start' || action === 'stop') url.searchParams.set('shade', action);
  try { await self.clients.openWindow(url.href); } catch (e) {}
}

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
