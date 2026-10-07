import { beforeEach, describe, expect, it, vi } from 'vitest';

const apiMock = vi.hoisted(() => ({
  get: vi.fn(),
  post: vi.fn(),
  del: vi.fn(),
}));

const registrationMock = vi.hoisted(() => ({
  getNotifications: vi.fn(),
  pushManager: {
    getSubscription: vi.fn(),
    subscribe: vi.fn(),
  },
}));

vi.mock('@/api/client', () => ({ api: apiMock }));
vi.mock('@/features/pwa/serviceWorker', () => ({
  getServiceWorkerRegistration: vi.fn(async () => registrationMock),
  postServiceWorkerMessage: vi.fn(async () => undefined),
}));
vi.mock('@/pwa', () => ({ isStandalonePwa: () => false }));

import {
  disableWebPush,
  dismissWebPushDeviceNotice,
  syncExistingWebPushSubscription,
  takeTappedWebPushNotificationUrl,
  webPushDeviceNotice,
} from '@/features/push/webPush';

const ENABLED_KEY = 'intellectual-club:web-push:enabled';
const DEVICE_ID_KEY = 'intellectual-club:web-push:device-id';
const PUBLIC_KEY = 'AQID';

const config = {
  enabled: true,
  public_origin: 'https://club.test',
  vapid_public_key: PUBLIC_KEY,
  key_revision: 1,
};

const browserSubscription = (endpoint: string, keyBytes = [1, 2, 3]) => ({
  endpoint,
  options: { applicationServerKey: new Uint8Array(keyBytes).buffer },
  toJSON: () => ({ endpoint, keys: { p256dh: 'p256dh-key', auth: 'auth-key' } }),
  unsubscribe: vi.fn().mockResolvedValue(true),
});

const setPermission = (permission: NotificationPermission) => {
  vi.stubGlobal('Notification', { permission, requestPermission: vi.fn() });
};

describe('web push device subscription sync', () => {
  beforeEach(() => {
    window.localStorage.clear();
    webPushDeviceNotice.value = null;
    vi.clearAllMocks();
    Object.defineProperty(window.navigator, 'serviceWorker', { configurable: true, value: {} });
    vi.stubGlobal('PushManager', class {});
    setPermission('granted');
    apiMock.get.mockResolvedValue(config);
    apiMock.post.mockResolvedValue({ status: 'ok' });
    apiMock.del.mockResolvedValue({ status: 'ok' });
    registrationMock.pushManager.getSubscription.mockResolvedValue(null);
  });

  it('reports a lost subscription that was enabled on this device', async () => {
    window.localStorage.setItem(ENABLED_KEY, '1');

    await expect(syncExistingWebPushSubscription()).resolves.toBe('lost');
    expect(webPushDeviceNotice.value).toBe('lost');
    expect(apiMock.post).not.toHaveBeenCalled();
  });

  it('stays quiet when notifications were never enabled on this device', async () => {
    await expect(syncExistingWebPushSubscription()).resolves.toBe('inactive');
    expect(webPushDeviceNotice.value).toBeNull();
  });

  it('reports blocked permission for a device that had notifications enabled', async () => {
    window.localStorage.setItem(ENABLED_KEY, '1');
    setPermission('denied');

    await expect(syncExistingWebPushSubscription()).resolves.toBe('blocked');
    expect(webPushDeviceNotice.value).toBe('blocked');
  });

  it('treats a reset permission prompt as a lost subscription', async () => {
    window.localStorage.setItem(ENABLED_KEY, '1');
    setPermission('default');

    await expect(syncExistingWebPushSubscription()).resolves.toBe('lost');
  });

  it('ignores devices when the administrator disabled notifications', async () => {
    window.localStorage.setItem(ENABLED_KEY, '1');
    apiMock.get.mockResolvedValue({ ...config, enabled: false });

    await expect(syncExistingWebPushSubscription()).resolves.toBe('unavailable');
    expect(webPushDeviceNotice.value).toBeNull();
  });

  it('syncs an existing subscription with a persistent device id and remembers the device', async () => {
    registrationMock.pushManager.getSubscription.mockResolvedValue(
      browserSubscription('https://push.example/current')
    );

    await expect(syncExistingWebPushSubscription()).resolves.toBe('subscribed');
    await expect(syncExistingWebPushSubscription()).resolves.toBe('subscribed');

    const deviceId = window.localStorage.getItem(DEVICE_ID_KEY);
    expect(deviceId).toMatch(/^[A-Za-z0-9_-]{8,64}$/u);
    expect(window.localStorage.getItem(ENABLED_KEY)).toBe('1');
    expect(apiMock.post).toHaveBeenCalledTimes(2);

    for (const [url, payload] of apiMock.post.mock.calls) {
      expect(url).toBe('/api/bff/web-push/subscriptions');
      expect(payload).toMatchObject({
        endpoint: 'https://push.example/current',
        key_revision: 1,
        device_id: deviceId,
      });
    }
  });

  it('removes a subscription made with rotated keys on the server as well', async () => {
    window.localStorage.setItem(ENABLED_KEY, '1');
    const stale = browserSubscription('https://push.example/stale', [9, 9, 9]);
    registrationMock.pushManager.getSubscription.mockResolvedValue(stale);

    await expect(syncExistingWebPushSubscription()).resolves.toBe('lost');

    expect(apiMock.del).toHaveBeenCalledWith(
      `/api/bff/web-push/subscriptions?${new URLSearchParams({ endpoint: stale.endpoint })}`,
      { showErrorBanner: false }
    );
    expect(stale.unsubscribe).toHaveBeenCalled();
    expect(apiMock.post).not.toHaveBeenCalled();
  });

  it('stops reminding once the notice is dismissed', async () => {
    window.localStorage.setItem(ENABLED_KEY, '1');
    await syncExistingWebPushSubscription();

    dismissWebPushDeviceNotice();

    expect(webPushDeviceNotice.value).toBeNull();
    await expect(syncExistingWebPushSubscription()).resolves.toBe('inactive');
  });

  it('forgets the device after notifications are disabled', async () => {
    window.localStorage.setItem(ENABLED_KEY, '1');
    const current = browserSubscription('https://push.example/current');
    registrationMock.pushManager.getSubscription.mockResolvedValue(current);

    await disableWebPush();

    expect(window.localStorage.getItem(ENABLED_KEY)).toBeNull();
    expect(current.unsubscribe).toHaveBeenCalled();

    registrationMock.pushManager.getSubscription.mockResolvedValue(null);
    await expect(syncExistingWebPushSubscription()).resolves.toBe('inactive');
  });
});

describe('web push tap recovery', () => {
  const stubShownNotifications = (entries: unknown) => {
    const cacheStorage = {
      match: vi.fn(async () => new Response(JSON.stringify(entries))),
      delete: vi.fn(async () => true),
    };
    vi.stubGlobal('caches', cacheStorage);
    return cacheStorage;
  };

  const presentNotifications = (...tags: string[]) =>
    registrationMock.getNotifications.mockResolvedValue(tags.map((tag) => ({ tag })));

  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('returns the latest notification shown while hidden that left Notification Center', async () => {
    const cacheStorage = stubShownNotifications([
      { tag: 'chat:11', url: '/chats/11?focusMessage=1', shownAt: 900 },
      { tag: 'chat:12', url: '/chats/12?focusMessage=2', shownAt: 1_100 },
      { tag: 'chat:13', url: '/chats/13?focusMessage=3', shownAt: 1_200 },
      { tag: 'chat:14', url: '/chats/14?focusMessage=4', shownAt: 1_300 },
    ]);
    presentNotifications('chat:14');

    await expect(takeTappedWebPushNotificationUrl(1_000)).resolves.toBe('/chats/13?focusMessage=3');
    expect(cacheStorage.delete).toHaveBeenCalledWith('intellectual-club:web-push:shown');
  });

  it('ignores notifications still in Notification Center or shown before the app was hidden', async () => {
    stubShownNotifications([
      { tag: 'chat:11', url: '/chats/11?focusMessage=1', shownAt: 900 },
      { tag: 'chat:12', url: '/chats/12?focusMessage=2', shownAt: 1_100 },
    ]);
    presentNotifications('chat:12');

    await expect(takeTappedWebPushNotificationUrl(1_000)).resolves.toBeNull();
  });

  it('drops malformed and cross-origin entries', async () => {
    stubShownNotifications([
      { tag: 'chat:12', url: '//evil.example/phish', shownAt: 1_100 },
      { tag: '', url: '/chats/13', shownAt: 1_200 },
      'garbage',
    ]);
    presentNotifications();

    await expect(takeTappedWebPushNotificationUrl(1_000)).resolves.toBeNull();
  });
});
