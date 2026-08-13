/*! coi-serviceworker - scoped & loop-safe */

if (typeof window !== 'undefined') {
  (() => {
    if (window.crossOriginIsolated) {
      // Already cross-origin isolated by HTTP headers (e.g. serve.json)
      return;
    }

    let hasReloaded = false;
    try {
      hasReloaded = !!sessionStorage.getItem('coi_reload_done');
    } catch (_) {}

    if (hasReloaded) {
      console.warn('[coi] Cross-Origin Isolation reload attempted once; will not loop.');
      return;
    }

    if (!window.isSecureContext) return;

    if (navigator.serviceWorker) {
      navigator.serviceWorker
        .register('coi-serviceworker.js')
        .then((registration) => {
          if (registration.active && !navigator.serviceWorker.controller) {
            try {
              sessionStorage.setItem('coi_reload_done', 'true');
            } catch (_) {}
            window.location.reload();
          }
        })
        .catch((err) => {
          console.warn('[coi] Service Worker registration skipped:', err);
        });
    }
  })();
} else if (
  typeof ServiceWorkerGlobalScope !== 'undefined' &&
  self instanceof ServiceWorkerGlobalScope
) {
  self.addEventListener('install', () => self.skipWaiting());
  self.addEventListener('activate', (event) =>
    event.waitUntil(self.clients.claim())
  );

  self.addEventListener('fetch', (event) => {
    const r = event.request;
    if (r.cache === 'only-if-cached' && r.mode !== 'same-origin') return;

    event.respondWith(
      fetch(r)
        .then((response) => {
          if (response.status === 0) return response;
          const newHeaders = new Headers(response.headers);
          newHeaders.set('Cross-Origin-Embedder-Policy', 'require-corp');
          newHeaders.set('Cross-Origin-Resource-Policy', 'cross-origin');
          newHeaders.set('Cross-Origin-Opener-Policy', 'same-origin');
          return new Response(response.body, {
            status: response.status,
            statusText: response.statusText,
            headers: newHeaders,
          });
        })
        .catch(() => fetch(r))
    );
  });
}
