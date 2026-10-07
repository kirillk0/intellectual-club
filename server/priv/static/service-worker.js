const INVALID_PRECACHE_MANIFEST_MESSAGE = 'PWA precache manifest is missing or invalid.';
const APP_SHELL_URL = '/pwa/app-shell';
const FORBIDDEN_PRECACHE_PATHS = new Set([
  '/assets/code-version.json',
  '/assets/pwa-bundle-descriptor.json',
  '/assets/pwa-precache-manifest.js',
]);
const ALLOWED_PRECACHE_PATHS = [
  /^\/assets\/(?:assets|css|js)\//u,
  /^\/images\/pwa\//u,
  /^\/pwa\/app-shell$/u,
  /^\/pwa\/offline\.html$/u,
  /^\/(?:apple-touch-icon|favicon)\.png$/u,
  /^\/manifest\.webmanifest$/u,
];

const validPrecacheUrl = (value) => {
  if (typeof value !== 'string' || !value.startsWith('/')) return false;

  let url;
  try {
    url = new URL(value, self.location.origin);
  } catch (_error) {
    return false;
  }

  const queryAllowed =
    url.search === '' ||
    /^\/assets\/(?:css\/(?:app|spa)[^/]*\.css|js\/spa[^/]*\.js)$/u.test(url.pathname);

  return (
    url.origin === self.location.origin &&
    url.username === '' &&
    url.password === '' &&
    url.hash === '' &&
    queryAllowed &&
    !FORBIDDEN_PRECACHE_PATHS.has(url.pathname) &&
    !url.pathname.endsWith('.map') &&
    !url.pathname.endsWith('.gz') &&
    ALLOWED_PRECACHE_PATHS.some((pattern) => pattern.test(url.pathname))
  );
};

const precacheManifestIsValid = (candidate) => {
  if (!candidate || !Array.isArray(candidate.assets)) return false;

  const uniqueAssets = new Set(candidate.assets).size === candidate.assets.length;

  return (
    typeof candidate.buildId === 'string' &&
    typeof candidate.revision === 'string' &&
    candidate.revision.length > 0 &&
    candidate.revision.length <= 128 &&
    candidate.assets.length > 0 &&
    candidate.assets.length <= 500 &&
    uniqueAssets &&
    candidate.assets.includes(candidate.buildId) &&
    candidate.assets.includes(APP_SHELL_URL) &&
    candidate.offlineUrl === '/pwa/offline.html' &&
    candidate.assets.includes(candidate.offlineUrl) &&
    candidate.assets.every(validPrecacheUrl)
  );
};

// A script evaluation error would also break push handling, and Safari revokes
// push subscriptions after a few pushes without a notification. A missing or
// invalid manifest therefore only fails installation and disables caching.
const loadPrecacheManifest = () => {
  try {
    importScripts('/assets/pwa-precache-manifest.js');
  } catch (_error) {
    return null;
  }

  const candidate = self.__PWA_PRECACHE_MANIFEST__;
  return precacheManifestIsValid(candidate) ? candidate : null;
};

const manifest = loadPrecacheManifest();

const CACHE_PREFIX = 'intellectual-club:pwa:';
const META_CACHE = `${CACHE_PREFIX}meta`;
const META_KEY = '/__pwa_cache_metadata__';
const COMPLETE_KEY = '/__pwa_cache_complete__';
const CURRENT_CACHE = manifest ? `${CACHE_PREFIX}assets:${manifest.revision}` : null;
const OFFLINE_URL = manifest?.offlineUrl || '/pwa/offline.html';
const ASSET_ATTEMPT_TIMEOUT_MS = 10_000;
const PRECACHE_CONCURRENCY = 6;
const PRECACHE_RETRY_DELAYS_MS = [0, 500, 1_500];
const RUNTIME_RETRY_DELAYS_MS = [500, 1_500, 3_000, 5_000, 10_000];
const NETWORK_ONLY_PATHS = new Set([
  ...FORBIDDEN_PRECACHE_PATHS,
  '/assets/pwa-precache-manifest.js',
  '/service-worker.js',
]);
const SPA_ROUTE_PATTERNS = [
  /^\/$/u,
  /^\/login\/?$/u,
  /^\/bookmarks\/?$/u,
  /^\/settings(?:\/|$)/u,
  /^\/administration(?:\/|$)/u,
  /^\/chats(?:\/|$)/u,
  /^\/catalogs(?:\/|$)/u,
  /^\/outlets(?:\/|$)/u,
];

const delay = (milliseconds) =>
  new Promise((resolve) => {
    setTimeout(resolve, milliseconds);
  });

const broadcast = async (message) => {
  const clients = await self.clients.matchAll({
    type: 'window',
    includeUncontrolled: true,
  });

  for (const client of clients) {
    client.postMessage(message);
  }
};

const readCacheMetadata = async () => {
  const cache = await caches.open(META_CACHE);
  const response = await cache.match(META_KEY);
  if (!response) return { current: null, previous: null };

  try {
    const value = await response.json();
    return {
      current: typeof value.current === 'string' ? value.current : null,
      previous: typeof value.previous === 'string' ? value.previous : null,
    };
  } catch (_error) {
    return { current: null, previous: null };
  }
};

const writeCacheMetadata = async (metadata) => {
  const cache = await caches.open(META_CACHE);
  await cache.put(
    META_KEY,
    new Response(JSON.stringify(metadata), {
      headers: { 'content-type': 'application/json' },
    })
  );
};

const cacheNameForRevision = (revision) => `${CACHE_PREFIX}assets:${revision}`;

const activeCacheNames = async () => {
  const metadata = await readCacheMetadata();
  const revisions = [manifest.revision, metadata.previous].filter(
    (value, index, values) => value && values.indexOf(value) === index
  );
  return revisions.map(cacheNameForRevision);
};

const matchActiveCaches = async (request, options = {}) => {
  const cacheNames = await activeCacheNames();

  for (const cacheName of cacheNames) {
    const response = await caches.match(request, { cacheName, ...options });
    if (response) return response;
  }

  return null;
};

const appShellMatchesManifest = async (response) => {
  if (
    !response ||
    !response.ok ||
    !response.headers.get('content-type')?.toLowerCase().includes('text/html')
  ) {
    return false;
  }

  const source = await response.clone().text();
  const buildId = source.match(
    /<meta\b[^>]*\bname=["']ic-build-id["'][^>]*\bcontent=["']([^"']+)["'][^>]*>/iu
  )?.[1];

  return (
    buildId === manifest.buildId &&
    /\bdata-session-bootstrap=["']required["']/iu.test(source)
  );
};

const fetchPrecacheAsset = async (url) => {
  let lastError = null;

  for (let attempt = 0; attempt < PRECACHE_RETRY_DELAYS_MS.length; attempt += 1) {
    const retryDelay = PRECACHE_RETRY_DELAYS_MS[attempt];
    if (retryDelay > 0) {
      await broadcast({
        type: 'ASSET_RETRY',
        context: 'precache',
        url,
        attempt: attempt + 1,
      });
      await delay(retryDelay);
    }

    try {
      const response = await fetchWithTimeout(
        new Request(new URL(url, self.location.origin), {
          cache: 'reload',
          credentials: 'same-origin',
        }),
        ASSET_ATTEMPT_TIMEOUT_MS
      );

      if (!response.ok) {
        throw new Error(`Precache request failed with status ${response.status}: ${url}`);
      }
      if (url === APP_SHELL_URL && !(await appShellMatchesManifest(response))) {
        throw new Error('Precached app shell does not match the active build.');
      }

      return response;
    } catch (error) {
      lastError = error;
    }
  }

  throw lastError || new Error(`Precache request failed: ${url}`);
};

const cacheContainsAllAssets = async (cache) => {
  for (const url of manifest.assets) {
    const response = await cache.match(url);
    if (!response) return false;
    if (url === APP_SHELL_URL && !(await appShellMatchesManifest(response))) return false;
  }

  return true;
};

const cacheIsComplete = async (cache) => {
  const marker = await cache.match(COMPLETE_KEY);
  const containsAllAssets = await cacheContainsAllAssets(cache);

  if (
    marker &&
    (await marker.text()) === manifest.revision &&
    containsAllAssets
  ) {
    return true;
  }
  if (!containsAllAssets) return false;

  await cache.put(COMPLETE_KEY, new Response(manifest.revision));
  return true;
};

const markCacheComplete = (cache) =>
  cache.put(COMPLETE_KEY, new Response(manifest.revision));

const reusablePrecacheUrl = (value) => {
  const url = new URL(value, self.location.origin);

  if (
    url.pathname.startsWith('/assets/js/chunks/') &&
    url.pathname.endsWith('.js')
  ) {
    return true;
  }

  const versionedEntry =
    /^\/assets\/(?:css\/(?:app|spa)[^/]*\.css|js\/spa[^/]*\.js)$/u.test(
      url.pathname
    );

  return (
    versionedEntry &&
    (
      url.searchParams.get('vsn') === 'd' ||
      url.searchParams.has('v')
    )
  );
};

const reusablePrecacheCacheNames = (metadata) =>
  [metadata.current, metadata.previous]
    .filter(
      (revision, index, revisions) =>
        revision &&
        revision !== manifest.revision &&
        revisions.indexOf(revision) === index
    )
    .map(cacheNameForRevision);

const matchReusablePrecacheAsset = async (url, metadata) => {
  if (!reusablePrecacheUrl(url)) return null;

  for (const cacheName of reusablePrecacheCacheNames(metadata)) {
    const response = await caches.match(url, { cacheName });
    if (response?.ok) return response;
  }

  return null;
};

const populatePrecacheAsset = async (cache, url, metadata) => {
  const cached = await cache.match(url);
  const cachedIsUsable =
    cached && (url !== APP_SHELL_URL || (await appShellMatchesManifest(cached)));

  if (cachedIsUsable) return;

  const reusable = await matchReusablePrecacheAsset(url, metadata);
  if (reusable) {
    await cache.put(url, reusable);
    return;
  }

  const response = await fetchPrecacheAsset(url);
  await cache.put(url, response);
};

const populatePrecacheAssets = async (cache, metadata) => {
  let nextIndex = 0;
  let completed = 0;
  let failed = false;
  let firstError = null;
  let progressPromise = Promise.resolve();

  const reportProgress = () => {
    const completedCount = completed + 1;
    completed = completedCount;
    progressPromise = progressPromise.then(() =>
      broadcast({
        type: 'CACHE_PROGRESS',
        context: 'precache',
        completed: completedCount,
        total: manifest.assets.length,
      })
    );
  };

  const runWorker = async () => {
    while (!failed) {
      const index = nextIndex;
      nextIndex += 1;
      if (index >= manifest.assets.length) return;

      try {
        await populatePrecacheAsset(cache, manifest.assets[index], metadata);
        reportProgress();
      } catch (error) {
        if (!failed) {
          failed = true;
          firstError = error;
        }
      }
    }
  };

  const workers = Array.from(
    { length: Math.min(PRECACHE_CONCURRENCY, manifest.assets.length) },
    () => runWorker()
  );

  await Promise.all(workers);
  await progressPromise;

  if (failed) throw firstError;
};

const populateCurrentCache = async () => {
  let cache = await caches.open(CURRENT_CACHE);
  if (await cacheIsComplete(cache)) return;

  const metadata = await readCacheMetadata();
  const updatesActiveCache = metadata.current === manifest.revision;

  if (!updatesActiveCache) {
    await caches.delete(CURRENT_CACHE);
    cache = await caches.open(CURRENT_CACHE);
  }

  try {
    await populatePrecacheAssets(cache, metadata);
    await markCacheComplete(cache);
  } catch (error) {
    if (!updatesActiveCache) {
      await caches.delete(CURRENT_CACHE);
    }
    throw error;
  }
};

const activateCurrentCache = async () => {
  const previousMetadata = await readCacheMetadata();
  const previousBuild =
    previousMetadata.current && previousMetadata.current !== manifest.revision
      ? previousMetadata.current
      : previousMetadata.previous;
  const nextMetadata = {
    current: manifest.revision,
    previous: previousBuild && previousBuild !== manifest.revision ? previousBuild : null,
  };

  await writeCacheMetadata(nextMetadata);

  const retainedCaches = new Set([
    META_CACHE,
    CURRENT_CACHE,
    nextMetadata.previous ? cacheNameForRevision(nextMetadata.previous) : null,
  ].filter(Boolean));
  const cacheNames = await caches.keys();

  await Promise.all(
    cacheNames
      .filter((cacheName) => cacheName.startsWith(CACHE_PREFIX))
      .filter((cacheName) => !retainedCaches.has(cacheName))
      .map((cacheName) => caches.delete(cacheName))
  );

  await self.clients.claim();
};

const fetchWithTimeout = async (request, timeoutMs, sourceSignal = null) => {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const forwardAbort = () => controller.abort(sourceSignal?.reason);

  if (sourceSignal?.aborted) {
    forwardAbort();
  } else {
    sourceSignal?.addEventListener('abort', forwardAbort, { once: true });
  }

  try {
    return await fetch(request, {
      cache: 'no-store',
      signal: controller.signal,
    });
  } finally {
    clearTimeout(timer);
    sourceSignal?.removeEventListener('abort', forwardAbort);
  }
};

const isSpaNavigation = (request) => {
  if (request.method !== 'GET' || request.mode !== 'navigate') return false;

  const url = new URL(request.url);
  return (
    url.origin === self.location.origin &&
    SPA_ROUTE_PATTERNS.some((pattern) => pattern.test(url.pathname))
  );
};

const fetchNavigation = async (request) => {
  const response = await fetch(request, { cache: 'no-store' });

  if (response.status >= 500) {
    throw new Error(`Navigation failed with status ${response.status}.`);
  }

  await broadcast({ type: 'NAVIGATION_READY', url: request.url });
  return response;
};

const handleNavigation = async (request, networkResponse) => {
  try {
    return await networkResponse;
  } catch (_error) {
    const appShell = await matchActiveCaches(APP_SHELL_URL);
    if (appShell) return appShell;

    const fallback = await matchActiveCaches(OFFLINE_URL);
    if (fallback) return fallback;

    return new Response('The application is temporarily unavailable.', {
      status: 503,
      headers: { 'content-type': 'text/plain; charset=utf-8' },
    });
  }
};

const isRuntimeCacheableChunk = (request, response) => {
  if (request.method !== 'GET' || !response.ok || response.type === 'opaque') return false;

  const url = new URL(request.url);
  return (
    url.origin === self.location.origin &&
    url.pathname.startsWith('/assets/js/chunks/') &&
    url.pathname.endsWith('.js')
  );
};

const retryableAssetStatus = (status) =>
  status === 408 ||
  status === 425 ||
  status === 429 ||
  (status >= 500 && status <= 599);

const retryAfterDelay = (response) => {
  const value = response.headers.get('retry-after');
  if (!value) return 0;

  const seconds = Number(value);
  if (Number.isFinite(seconds)) {
    return Math.min(10_000, Math.max(0, seconds * 1_000));
  }

  const date = Date.parse(value);
  return Number.isNaN(date) ? 0 : Math.min(10_000, Math.max(0, date - Date.now()));
};

const runtimeRetryDelay = (attempt, response) => {
  const scheduled =
    RUNTIME_RETRY_DELAYS_MS[
      Math.min(attempt - 1, RUNTIME_RETRY_DELAYS_MS.length - 1)
    ];
  return Math.max(scheduled, response ? retryAfterDelay(response) : 0);
};

const delayForRuntimeRetry = (milliseconds, signal) =>
  new Promise((resolve, reject) => {
    if (signal.aborted) {
      reject(signal.reason || new DOMException('Request aborted.', 'AbortError'));
      return;
    }

    let timer = null;
    const onAbort = () => {
      if (timer !== null) clearTimeout(timer);
      reject(signal.reason || new DOMException('Request aborted.', 'AbortError'));
    };
    signal.addEventListener('abort', onAbort, { once: true });
    timer = setTimeout(() => {
      signal.removeEventListener('abort', onAbort);
      resolve();
    }, milliseconds);
  });

const fetchAssetWithRecovery = async (request, startingAttempt = 0) => {
  let attempt = startingAttempt;
  let retryResponse = null;

  while (true) {
    if (attempt > 0) {
      await broadcast({
        type: 'ASSET_RETRY',
        context: 'runtime',
        url: request.url,
        attempt: attempt + 1,
      });
      await delayForRuntimeRetry(runtimeRetryDelay(attempt, retryResponse), request.signal);
    }

    try {
      const response = await fetchWithTimeout(
        request.clone(),
        ASSET_ATTEMPT_TIMEOUT_MS,
        request.signal
      );

      if (response.status === 404 || response.status === 410) {
        await broadcast({
          type: 'VERSION_MISMATCH',
          context: 'runtime',
          url: request.url,
        });
        return response;
      }

      if (!retryableAssetStatus(response.status)) return response;
      retryResponse = response;
      await response.body?.cancel().catch(() => undefined);
    } catch (error) {
      if (request.signal.aborted) throw error;
      retryResponse = null;
    }

    attempt += 1;
  }
};

const cacheRuntimeChunk = async (request, response) => {
  if (!isRuntimeCacheableChunk(request, response)) return;

  const cache = await caches.open(CURRENT_CACHE);
  await cache.put(request, response.clone());
};

const isDevelopmentEntry = (url) =>
  manifest.mode === 'dev' &&
  (
    url.pathname === '/assets/js/spa.js' ||
    url.pathname === '/assets/css/spa.css' ||
    url.pathname === '/assets/css/app.css'
  );

const handleAsset = async (request) => {
  const url = new URL(request.url);

  if (isDevelopmentEntry(url)) {
    const cached = await matchActiveCaches(request);
    if (cached) return cached;

    try {
      const response = await fetchWithTimeout(
        request.clone(),
        ASSET_ATTEMPT_TIMEOUT_MS,
        request.signal
      );

      if (response.status === 404 || response.status === 410) {
        await broadcast({
          type: 'VERSION_MISMATCH',
          context: 'runtime',
          url: request.url,
        });
        const cached = await matchActiveCaches(request, { ignoreSearch: true });
        return cached || response;
      }

      if (retryableAssetStatus(response.status)) {
        const cached = await matchActiveCaches(request, { ignoreSearch: true });
        if (cached) return cached;
        return fetchAssetWithRecovery(request, 1);
      }

      if (response.ok) {
        const cache = await caches.open(CURRENT_CACHE);
        await cache.put(request, response.clone());
      }
      return response;
    } catch (_error) {
      if (request.signal.aborted) throw _error;
      const cached = await matchActiveCaches(request, { ignoreSearch: true });
      if (cached) return cached;
      return fetchAssetWithRecovery(request, 1);
    }
  }

  const cached = await matchActiveCaches(request);
  if (cached) return cached;

  const response = await fetchAssetWithRecovery(request);
  await cacheRuntimeChunk(request, response);
  return response;
};

const isStaticAssetRequest = (request) => {
  if (request.method !== 'GET') return false;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return false;
  if (request.headers.has('x-ic-recovery-probe')) return false;
  if (NETWORK_ONLY_PATHS.has(url.pathname)) return false;

  return (
    url.pathname.startsWith('/assets/') ||
    url.pathname.startsWith('/images/') ||
    url.pathname === '/favicon.png' ||
    url.pathname === '/apple-touch-icon.png' ||
    url.pathname === '/manifest.webmanifest'
  );
};

self.addEventListener('install', (event) => {
  event.waitUntil(
    manifest
      ? populateCurrentCache()
      : Promise.reject(new Error(INVALID_PRECACHE_MANIFEST_MESSAGE))
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(manifest ? activateCurrentCache() : self.clients.claim());
});

self.addEventListener('fetch', (event) => {
  // Without a usable manifest the worker leaves every request to the network.
  if (!manifest) return;

  if (isSpaNavigation(event.request)) {
    const networkResponse = fetchNavigation(event.request);
    event.waitUntil(networkResponse.catch(() => undefined));
    event.respondWith(handleNavigation(event.request, networkResponse));
    return;
  }

  if (isStaticAssetRequest(event.request)) {
    event.respondWith(handleAsset(event.request));
  }
});

const DECLARATIVE_WEB_PUSH_VERSION = 8030;
const NOTIFICATION_FALLBACK_TITLE = 'Intellectual Club';
const NOTIFICATION_ICON_URL = '/images/pwa/icon-192.png';
// Shared with the page (frontend/src/features/push/webPush.ts); kept outside
// CACHE_PREFIX so activation cleanup leaves it alone.
const SHOWN_NOTIFICATIONS_CACHE = 'intellectual-club:web-push:shown';
const SHOWN_NOTIFICATIONS_KEY = '/__web_push_shown_notifications__';
const SHOWN_NOTIFICATIONS_LIMIT = 20;

const plainObject = (value) =>
  value !== null && typeof value === 'object' && !Array.isArray(value) ? value : null;

const nonEmptyString = (value) =>
  typeof value === 'string' && value.trim() !== '' ? value : null;

// WebKit dispatches declarative pushes with `data === null` and exposes the parsed
// message as the proposed `event.notification` instead.
const proposedNotification = (event) => {
  try {
    return plainObject(event.notification);
  } catch (_error) {
    return null;
  }
};

const proposedNotificationPayload = (proposed) => {
  try {
    return {
      web_push: DECLARATIVE_WEB_PUSH_VERSION,
      notification: {
        title: proposed.title,
        body: proposed.body,
        tag: proposed.tag,
        navigate: proposed.navigate,
        data: proposed.data,
      },
    };
  } catch (_error) {
    return null;
  }
};

const readPushPayload = (event, proposed) => {
  try {
    const payload = plainObject(event.data ? event.data.json() : null);
    if (payload) return payload;
  } catch (_error) {
    // Fall back to the proposed declarative notification below.
  }

  return (proposed && proposedNotificationPayload(proposed)) || {};
};

// Notification clicks route inside the app, so only same-origin targets are kept.
const sameOriginNotificationPath = (value) => {
  if (typeof value !== 'string' || value === '') return null;

  try {
    const url = new URL(value, self.location.origin);
    if (url.origin !== self.location.origin) return null;
    return `${url.pathname}${url.search}${url.hash}`;
  } catch (_error) {
    return null;
  }
};

const notificationOptions = ({ body = '', tag, data }) => ({
  body,
  icon: NOTIFICATION_ICON_URL,
  badge: NOTIFICATION_ICON_URL,
  tag: tag || undefined,
  // WebKit only lets a declarative push be replaced by a notification with an absolute `navigate` URL.
  navigate: new URL(data.url, self.location.origin).href,
  data,
});

// Payloads use the Declarative Web Push format, with legacy flat fields kept for
// workers installed before it; browsers without declarative support land here too.
const notificationFromPushPayload = (payload) => {
  const declarative =
    payload.web_push === DECLARATIVE_WEB_PUSH_VERSION ? plainObject(payload.notification) : null;
  const source = declarative || payload;
  const data = plainObject(declarative?.data) || payload;
  const url =
    sameOriginNotificationPath(data.url) ||
    sameOriginNotificationPath(declarative?.navigate) ||
    sameOriginNotificationPath(payload.url) ||
    '/';

  return {
    title: nonEmptyString(source.title) || NOTIFICATION_FALLBACK_TITLE,
    options: notificationOptions({
      body: typeof source.body === 'string' ? source.body : '',
      tag: nonEmptyString(source.tag) || nonEmptyString(payload.tag),
      data: {
        url,
        chat_id: data.chat_id || null,
        message_id: data.message_id || null,
        status: data.status || null,
      },
    }),
  };
};

// iOS restores a backgrounded Home Screen app without applying the tapped
// notification's `navigate` URL and fires no `notificationclick` (WebKit bug
// 268797), so the page infers taps from shown notifications that left
// Notification Center while it was hidden.
const recordShownNotification = async (options) => {
  const tag = nonEmptyString(options?.tag);
  const url = nonEmptyString(options?.data?.url);
  if (!tag || !url) return;

  try {
    const cache = await caches.open(SHOWN_NOTIFICATIONS_CACHE);
    let entries = [];

    try {
      const stored = await (await cache.match(SHOWN_NOTIFICATIONS_KEY))?.json();
      if (Array.isArray(stored)) entries = stored.filter((entry) => plainObject(entry));
    } catch (_error) {
      entries = [];
    }

    entries = [...entries.filter((entry) => entry.tag !== tag), { tag, url, shownAt: Date.now() }];

    await cache.put(
      SHOWN_NOTIFICATIONS_KEY,
      new Response(JSON.stringify(entries.slice(-SHOWN_NOTIFICATIONS_LIMIT)), {
        headers: { 'Content-Type': 'application/json' },
      })
    );
  } catch (_error) {
    // Tap recovery is best effort and must not affect the push lifetime.
  }
};

// The push lifetime promise never rejects: a push that ends without a notification
// counts as a silent push, and Safari drops the subscription after a few of them.
const showPushNotification = async (event) => {
  const proposed = proposedNotification(event);
  let notification = null;

  try {
    notification = notificationFromPushPayload(readPushPayload(event, proposed));
    await self.registration.showNotification(notification.title, notification.options);
  } catch (_error) {
    // The browser shows the proposed declarative notification when no replacement
    // succeeds, so a generic fallback would only hide its content.
    if (!proposed) {
      await showFallbackNotification();
      return;
    }
  }

  if (notification) await recordShownNotification(notification.options);
};

const showFallbackNotification = async () => {
  try {
    await self.registration.showNotification(
      NOTIFICATION_FALLBACK_TITLE,
      notificationOptions({
        data: { url: '/', chat_id: null, message_id: null, status: null },
      })
    );
  } catch (_fallbackError) {
    // Nothing else can be shown from this worker.
  }
};

self.addEventListener('push', (event) => {
  event.waitUntil(showPushNotification(event));
});

self.addEventListener('message', (event) => {
  const data = event.data || {};

  if (data.type === 'ACTIVATE_UPDATE') {
    event.waitUntil(self.skipWaiting());
    return;
  }

  if (data.type !== 'web_push_close_chat_notifications') return;

  event.waitUntil((async () => {
    const chatId = Number(data.chat_id);
    const tag = typeof data.tag === 'string' && data.tag
      ? data.tag
      : Number.isInteger(chatId) && chatId > 0
        ? `chat:${chatId}`
        : '';

    if (!tag || typeof self.registration.getNotifications !== 'function') return;

    const notifications = await self.registration.getNotifications({ tag });
    for (const notification of notifications) {
      notification.close();
    }
  })());
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();

  event.waitUntil((async () => {
    const target = new URL(event.notification.data?.url || '/', self.location.origin);
    const targetUrl = target.href;
    const windowClients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    let sameOriginClient = null;

    for (const client of windowClients) {
      const clientUrl = new URL(client.url);
      if (clientUrl.origin !== target.origin || !('focus' in client)) continue;

      if (clientUrl.pathname === target.pathname) {
        if ('navigate' in client && clientUrl.href !== targetUrl) await client.navigate(targetUrl);
        if ('postMessage' in client) client.postMessage({ type: 'web_push_notification_click', url: targetUrl });
        await client.focus();
        return;
      }

      if (!sameOriginClient) sameOriginClient = client;
    }

    if (sameOriginClient) {
      if ('navigate' in sameOriginClient) await sameOriginClient.navigate(targetUrl);
      if ('postMessage' in sameOriginClient) sameOriginClient.postMessage({ type: 'web_push_notification_click', url: targetUrl });
      await sameOriginClient.focus();
      return;
    }

    if (self.clients.openWindow) {
      const openedClient = await self.clients.openWindow(targetUrl);
      if (openedClient && 'postMessage' in openedClient) {
        openedClient.postMessage({ type: 'web_push_notification_click', url: targetUrl });
      }
    }
  })());
});
