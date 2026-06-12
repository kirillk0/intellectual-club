self.addEventListener('install', () => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('push', (event) => {
  event.waitUntil((async () => {
    let payload = {};

    try {
      payload = event.data ? event.data.json() : {};
    } catch (_error) {
      payload = {};
    }

    const title = payload.title || 'Intellectual Club';
    const options = {
      body: payload.body || '',
      icon: '/images/pwa/icon-192.png',
      badge: '/images/pwa/icon-192.png',
      tag: payload.tag || undefined,
      data: {
        url: payload.url || '/',
        chat_id: payload.chat_id || null,
        message_id: payload.message_id || null,
        status: payload.status || null,
      },
    };

    await self.registration.showNotification(title, options);
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
