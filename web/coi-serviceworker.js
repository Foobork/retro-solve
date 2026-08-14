/*! coi-serviceworker v0.1.7 - Guido Zuidhof and contributors, MIT licensed (with safe single reload guard) */
let coepCredentialless = false;

if (typeof window === 'undefined') {
  self.addEventListener('install', () => self.skipWaiting());
  self.addEventListener('activate', (event) =>
    event.waitUntil(self.clients.claim())
  );

  self.addEventListener('message', (ev) => {
    if (!ev.data) return;
    if (ev.data.type === 'deregister') {
      self.registration.unregister().then(() => {
        return self.clients.matchAll();
      }).then((clients) => {
        clients.forEach((client) => client.navigate(client.url));
      });
    } else if (ev.data.type === 'coepCredentialless') {
      coepCredentialless = ev.data.value;
    }
  });

  self.addEventListener('fetch', (event) => {
    const r = event.request;
    if (r.cache === 'only-if-cached' && r.mode !== 'same-origin') return;

    const request = (coepCredentialless && r.mode === 'no-cors')
      ? new Request(r, { credentials: 'omit' })
      : r;

    event.respondWith(
      fetch(request)
        .then((response) => {
          if (response.status === 0) return response;

          const newHeaders = new Headers(response.headers);
          newHeaders.set(
            'Cross-Origin-Embedder-Policy',
            coepCredentialless ? 'credentialless' : 'require-corp'
          );
          if (!coepCredentialless) {
            newHeaders.set('Cross-Origin-Resource-Policy', 'cross-origin');
          }
          newHeaders.set('Cross-Origin-Opener-Policy', 'same-origin');

          return new Response(response.body, {
            status: response.status,
            statusText: response.statusText,
            headers: newHeaders,
          });
        })
        .catch((e) => console.error('[coi-sw] fetch error:', e))
    );
  });
} else {
  (() => {
    // If already cross-origin isolated, clear flag and continue
    if (window.crossOriginIsolated) {
      try {
        sessionStorage.removeItem('coi_reload_count');
      } catch (_) {}
      return;
    }

    // Safety guard: Limit reloads to maximum 1 attempt per session
    let reloadCount = 0;
    try {
      reloadCount = parseInt(sessionStorage.getItem('coi_reload_count') || '0', 10);
    } catch (_) {}

    if (reloadCount >= 1) {
      console.warn('[coi] Cross-Origin Isolation reload attempted once. Stopping to prevent reload loops.');
      return;
    }

    if (!window.isSecureContext) {
      console.warn('[coi] Secure context required for Cross-Origin Isolation.');
      return;
    }

    const doSafeReload = () => {
      try {
        sessionStorage.setItem('coi_reload_count', String(reloadCount + 1));
      } catch (_) {}
      window.location.reload();
    };

    if (navigator.serviceWorker) {
      const scriptUrl =
        document.currentScript && document.currentScript.src
          ? document.currentScript.src
          : new URL('coi-serviceworker.js', window.location.href).href;

      navigator.serviceWorker.addEventListener('controllerchange', () => {
        if (!window.crossOriginIsolated) {
          doSafeReload();
        }
      });

      navigator.serviceWorker
        .register(scriptUrl)
        .then((reg) => {
          reg.addEventListener('updatefound', () => {
            doSafeReload();
          });
          if (reg.active && !navigator.serviceWorker.controller) {
            doSafeReload();
          }
        })
        .catch((err) => {
          console.warn('[coi] Service Worker registration failed:', err);
        });
    }
  })();
}
