/* Service worker: app offline + avisos (push) */
const V = 'v4';
const SHELL = 'shell-' + V, RUNTIME = 'rt-' + V, MEDIA = 'media-v1';
const SHELL_URLS = ['/index.html', '/manifest.webmanifest', '/icon-192.png', '/icon-512.png'];

self.addEventListener('install', e => {
  e.waitUntil((async () => {
    const c = await caches.open(SHELL);
    await Promise.all(SHELL_URLS.map(u => c.add(u).catch(() => {})));
    await self.skipWaiting();
  })());
});
self.addEventListener('activate', e => {
  e.waitUntil((async () => {
    const keep = [SHELL, RUNTIME, MEDIA];
    for (const k of await caches.keys()) if (!keep.includes(k)) await caches.delete(k);
    await self.clients.claim();
  })());
});

const timeout = ms => new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), ms));

async function navHandler(req) {
  const cache = await caches.open(SHELL);
  try {
    const r = await Promise.race([fetch(req), timeout(4000)]);
    if (r && r.ok && /html/i.test(r.headers.get('content-type') || '')) { cache.put('/index.html', r.clone()); return r; }
    if (r && r.ok) return r;
  } catch (_) {}
  const c = await cache.match('/index.html');
  return c || fetch(req);
}

async function swr(req, cacheName) {
  const cache = await caches.open(cacheName);
  const hit = await cache.match(req);
  const net = fetch(req).then(r => { if (r && (r.ok || r.type === 'opaque')) cache.put(req, r.clone()); return r; }).catch(() => null);
  return hit || (await net) || Response.error();
}

async function trimMedia(cache, max) {
  const ks = await cache.keys();
  for (let i = 0; i < ks.length - max; i++) await cache.delete(ks[i]);
}

async function rangeResp(full, range) {
  const blob = await full.blob();
  const size = blob.size, type = full.headers.get('content-type') || 'video/mp4';
  if (!range) return new Response(blob, { status: 200, headers: { 'Content-Type': type, 'Content-Length': String(size), 'Accept-Ranges': 'bytes' } });
  const m = /bytes=(\d*)-(\d*)/.exec(range);
  if (!m) return new Response(blob, { status: 200, headers: { 'Content-Type': type } });
  let s, e;
  if (m[1] === '') { s = Math.max(0, size - parseInt(m[2], 10)); e = size - 1; }
  else { s = parseInt(m[1], 10); e = m[2] === '' ? size - 1 : Math.min(parseInt(m[2], 10), size - 1); }
  if (isNaN(s) || isNaN(e) || s >= size) return new Response(null, { status: 416, headers: { 'Content-Range': 'bytes */' + size } });
  return new Response(blob.slice(s, e + 1), { status: 206, headers: { 'Content-Type': type, 'Content-Range': `bytes ${s}-${e}/${size}`, 'Content-Length': String(e - s + 1), 'Accept-Ranges': 'bytes' } });
}

const inflight = new Set();
async function cacheMedia(url, isVideo) {
  const cache = await caches.open(MEDIA);
  if (await cache.match(url)) return;
  if (inflight.has(url)) return; inflight.add(url);
  try {
    const r = await fetch(url, { mode: 'cors' });
    if (!r.ok || r.status !== 200) return;
    const len = parseInt(r.headers.get('content-length') || '0', 10);
    if (isVideo && len > 30 * 1024 * 1024) return;
    await cache.put(url, r.clone());
    await trimMedia(cache, 400);
  } catch (_) {} finally { inflight.delete(url); }
}

async function mediaHandler(req) {
  const cache = await caches.open(MEDIA);
  const hit = await cache.match(req.url);
  const isVideo = req.destination === 'video' || /\.(mp4|webm|mov|m4v)(\?|$)/i.test(req.url);
  if (hit) return isVideo ? rangeResp(hit, req.headers.get('range')) : hit;
  if (isVideo) return fetch(req);
  try {
    const r = await fetch(req.url, { mode: 'cors' });
    if (r.ok) { cache.put(req.url, r.clone()); trimMedia(cache, 400); }
    return r;
  } catch (_) {
    try { return await fetch(req); } catch (e) { return Response.error(); }
  }
}

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const u = new URL(req.url);
  if (req.mode === 'navigate') { e.respondWith(navHandler(req)); return; }
  if (req.headers.has('range') && u.origin === location.origin) return;
  if (u.origin === location.origin) {
    if (u.pathname === '/sw.js') return;
    e.respondWith(swr(req, RUNTIME)); return;
  }
  if (/supabase\.co$/.test(u.hostname) && u.pathname.startsWith('/storage/v1/object/public/')) { e.respondWith(mediaHandler(req)); return; }
  if (u.hostname === 'cdnjs.cloudflare.com' || u.hostname === 'fonts.googleapis.com' || u.hostname === 'fonts.gstatic.com') { e.respondWith(swr(req, RUNTIME)); return; }
});

self.addEventListener('message', e => {
  const d = e.data || {};
  if (d.type === 'prefetch') {
    e.waitUntil((async () => {
      const imgs = [...new Set(d.images || [])], vids = [...new Set(d.videos || [])];
      for (const u of imgs) await cacheMedia(u, false);
      for (const u of vids) await cacheMedia(u, true);
    })());
  }
});

self.addEventListener('push', e => {
  let d = {}; try { d = e.data ? e.data.json() : {}; } catch (_) { d = { title: 'Novidade no painel', body: 'Toque para abrir' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Novidade no painel', {
    body: d.body || '', tag: d.tag || 'staff', renotify: true, requireInteraction: true,
    icon: '/icon-192.png', badge: '/icon-192.png', vibrate: [300, 120, 300, 120, 300], data: { url: d.url || '/' }
  }));
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
    for (const c of list) { if ('focus' in c) return c.focus(); }
    return self.clients.openWindow((e.notification.data && e.notification.data.url) || '/');
  }));
});
