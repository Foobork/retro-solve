/*! coi-serviceworker v0.1.7 - Guido Zuidhof and contributors, MIT licensed */

if (typeof window === 'undefined') {
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
} else {
  (() => {
    // If already cross-origin isolated, nothing more to do
    if (window.crossOriginIsolated) {
      console.log('[coi] Environment is Cross-Origin Isolated.');
      return;
    }

    if (!window.isSecureContext) {
      console.warn('[coi] Secure context required for Cross-Origin Isolation.');
      return;
    }

    if (navigator.serviceWorker) {
      const scriptUrl =
        document.currentScript && document.currentScript.src
          ? document.currentScript.src
          : new URL('coi-serviceworker.js', window.location.href).href;

      // Reload ONLY when controllerchange fires (meaning the ServiceWorker has claimed clients)
      navigator.serviceWorker.addEventListener('controllerchange', () => {
        if (!window.crossOriginIsolated) {
          console.log('[coi] Service Worker activated and claimed client. Reloading for Cross-Origin Isolation...');
          window.location.reload();
        }
      });

      navigator.serviceWorker
        .register(scriptUrl)
        .then((reg) => {
          // If active service worker is already controlling and we are not yet isolated, reload once
          if (reg.active && navigator.serviceWorker.controller && !window.crossOriginIsolated) {
            console.log('[coi] Active Service Worker detected. Reloading for Cross-Origin Isolation...');
            window.location.reload();
          }
        })
        .catch((err) => {
          console.warn('[coi] Service Worker registration failed:', err);
        });
    }
  })();
}
