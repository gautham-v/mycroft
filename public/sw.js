/* Openfeed service worker — hand-written, no workbox. */
const VERSION = "v1";
const STATIC = `openfeed-static-${VERSION}`;
const RUNTIME = `openfeed-runtime-${VERSION}`;
const SHELL = ["/", "/manifest.webmanifest", "/icons/icon-192.png", "/icons/icon-512.png", "/icons/apple-touch-icon-180.png"];
const API_CACHED = ["/api/items", "/api/sources", "/api/stats"];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches
      .open(STATIC)
      .then((c) => c.addAll(SHELL))
      .catch(() => {})
      .then(() => self.skipWaiting()),
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== STATIC && k !== RUNTIME).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

async function cacheFirst(req) {
  const hit = await caches.match(req);
  if (hit) return hit;
  const res = await fetch(req);
  if (res.ok) (await caches.open(STATIC)).put(req, res.clone());
  return res;
}

async function networkFirst(req, fallbackUrl) {
  const cache = await caches.open(RUNTIME);
  try {
    const res = await fetch(req);
    if (res.ok) cache.put(fallbackUrl || req, res.clone());
    return res;
  } catch (err) {
    const hit = (await cache.match(req)) || (fallbackUrl && (await caches.match(fallbackUrl)));
    if (hit) return hit;
    throw err;
  }
}

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;

  if (url.pathname.startsWith("/_next/static/") || url.pathname.startsWith("/icons/")) {
    event.respondWith(cacheFirst(req));
    return;
  }
  if (API_CACHED.some((p) => url.pathname === p)) {
    event.respondWith(networkFirst(req));
    return;
  }
  if (req.mode === "navigate") {
    // All navigations render the same SPA shell; cache it under "/".
    event.respondWith(networkFirst(req, "/"));
  }
});
