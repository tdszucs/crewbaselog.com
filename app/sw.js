// CrewBase Log service worker: lets the app open offline and be installed on the Home Screen.
// The logbook itself is in the browser's storage, not here; this only caches the app's files.
const VERSION = "cbl-v1";
const SHELL = ["./", "./index.html", "./manifest.webmanifest", "./airports.json", "./icons/icon-192.png", "./icons/icon-512.png", "./icons/apple-touch-icon.png"];
// libraries and fonts loaded from CDNs (versioned URLs, so a cached copy stays valid)
const CDN = ["cdnjs.cloudflare.com", "cdn.jsdelivr.net", "fonts.googleapis.com", "fonts.gstatic.com"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(VERSION).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k.startsWith("cbl-v") && k !== VERSION).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener("fetch", e => {
  const req = e.request, url = new URL(req.url);
  if (req.method !== "GET") return;
  // the app itself: newest version from the network, the cached one when offline
  if (url.origin === location.origin && url.pathname.startsWith("/app/")) {
    e.respondWith(fetch(req).then(r => { if (r.ok) { const copy = r.clone(); caches.open(VERSION).then(c => c.put(req, copy)); } return r; })
      .catch(() => caches.match(req, { ignoreSearch: true }).then(r => r || caches.match("./"))));
    return;
  }
  // libraries and fonts: cached after first use
  if (CDN.includes(url.hostname)) {
    e.respondWith(caches.match(req).then(hit => hit || fetch(req).then(r => { if (r.ok || r.type === "opaque") { const copy = r.clone(); caches.open(VERSION).then(c => c.put(req, copy)); } return r; })));
  }
  // everything else (sign-in, sharing, feedback) goes straight to the network
});
