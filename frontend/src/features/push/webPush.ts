import { ref } from 'vue';
import { api, type ApiRequestOptions } from '@/api/client';
import {
  getServiceWorkerRegistration,
  postServiceWorkerMessage as postPwaServiceWorkerMessage,
  type PwaServiceWorkerMessage,
} from '@/features/pwa/serviceWorker';
import { isStandalonePwa } from '@/pwa';

const LOCAL_KEY_REVISION = 'intellectual-club:web-push:key-revision';
const LOCAL_DEVICE_ID = 'intellectual-club:web-push:device-id';
const LOCAL_DEVICE_ENABLED = 'intellectual-club:web-push:enabled';
const SESSION_CLIENT_ID = 'intellectual-club:web-push:client-id';
const ACTIVE_CHAT_HEARTBEAT_MS = 20_000;
const DEVICE_ID_PATTERN = /^[A-Za-z0-9_-]{8,64}$/u;

export type WebPushClientConfig = {
  enabled: boolean;
  public_origin: string | null;
  vapid_public_key: string | null;
  key_revision: number;
};

export type WebPushSupportState = {
  supported: boolean;
  reason: string | null;
  permission: NotificationPermission | 'unsupported';
  standalone: boolean;
  ios: boolean;
};

type PushSubscriptionJson = {
  endpoint?: string;
  keys?: {
    p256dh?: string;
    auth?: string;
  };
  expirationTime?: number | null;
};

/**
 * Result of checking this device's subscription on startup:
 * - `lost`: the user enabled notifications here, but the browser no longer has a
 *   subscription (Safari drops it after repeated silent pushes, keys may rotate);
 * - `blocked`: the same, but notification permission is now denied.
 */
export type WebPushDeviceStatus = 'unavailable' | 'inactive' | 'subscribed' | 'lost' | 'blocked';
export type WebPushDeviceNotice = Extract<WebPushDeviceStatus, 'lost' | 'blocked'>;

export const webPushDeviceNotice = ref<WebPushDeviceNotice | null>(null);

let activeWebPushChatId: number | null = null;
let activeWebPushHeartbeatTimer: number | null = null;
let activeWebPushListenersReady = false;
let activeWebPushClientId: string | null = null;
let reportedVisibleWebPushChatId: number | null = null;
let activeWebPushClientStateQueue: Promise<void> = Promise.resolve();
const reportedSeenGenerations = new Set<string>();

const isIosLike = () => {
  const platform = navigator.platform || '';
  const userAgent = navigator.userAgent || '';
  return (
    /iPad|iPhone|iPod/u.test(platform) ||
    (platform === 'MacIntel' && navigator.maxTouchPoints > 1) ||
    /iPad|iPhone|iPod/u.test(userAgent)
  );
};

export const webPushSupportState = (): WebPushSupportState => {
  const permission =
    typeof Notification === 'undefined' ? 'unsupported' : Notification.permission;
  const ios = isIosLike();
  const standalone = isStandalonePwa();

  if (!('serviceWorker' in navigator)) {
    return { supported: false, reason: 'Service workers are not supported in this browser.', permission, standalone, ios };
  }

  if (!('PushManager' in window) || typeof Notification === 'undefined') {
    return { supported: false, reason: 'Push notifications are not supported in this browser.', permission, standalone, ios };
  }

  if (ios && !standalone) {
    return { supported: false, reason: 'On iOS, install this app to the Home Screen to enable notifications.', permission, standalone, ios };
  }

  return { supported: true, reason: null, permission, standalone, ios };
};

export const loadWebPushConfig = (options: ApiRequestOptions = {}) =>
  api.get<WebPushClientConfig>('/api/bff/web-push/config', {
    ...options,
    retry: options.retry ?? false,
    showErrorBanner: false,
  });

const readLocalValue = (key: string) => {
  try {
    return window.localStorage.getItem(key);
  } catch {
    return null;
  }
};

const writeLocalValue = (key: string, value: string) => {
  try {
    window.localStorage.setItem(key, value);
    return true;
  } catch {
    return false;
  }
};

const removeLocalValue = (key: string) => {
  try {
    window.localStorage.removeItem(key);
  } catch {
    // Ignore private mode storage failures.
  }
};

const webPushEnabledOnDevice = () => readLocalValue(LOCAL_DEVICE_ENABLED) === '1';

const markWebPushEnabledOnDevice = () => {
  writeLocalValue(LOCAL_DEVICE_ENABLED, '1');
  webPushDeviceNotice.value = null;
};

const clearWebPushEnabledOnDevice = () => {
  removeLocalValue(LOCAL_DEVICE_ENABLED);
  webPushDeviceNotice.value = null;
};

const getStoredKeyRevision = () => {
  try {
    const value = window.localStorage.getItem(LOCAL_KEY_REVISION);
    const parsed = Number(value);
    return Number.isInteger(parsed) && parsed > 0 ? parsed : null;
  } catch {
    return null;
  }
};

const setStoredKeyRevision = (revision: number) => {
  try {
    window.localStorage.setItem(LOCAL_KEY_REVISION, String(revision));
  } catch {
    // Ignore private mode storage failures.
  }
};

const clearStoredKeyRevision = () => {
  try {
    window.localStorage.removeItem(LOCAL_KEY_REVISION);
  } catch {
    // Ignore private mode storage failures.
  }
};

const base64UrlToUint8Array = (base64Url: string) => {
  const padding = '='.repeat((4 - (base64Url.length % 4)) % 4);
  const base64 = `${base64Url}${padding}`.replace(/-/gu, '+').replace(/_/gu, '/');
  const raw = window.atob(base64);
  const output = new Uint8Array(raw.length);

  for (let i = 0; i < raw.length; i += 1) {
    output[i] = raw.charCodeAt(i);
  }

  return output;
};

const arrayBufferToBase64Url = (value: ArrayBuffer | ArrayBufferView) => {
  const bytes = value instanceof ArrayBuffer
    ? new Uint8Array(value)
    : new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  let raw = '';

  for (const byte of bytes) {
    raw += String.fromCharCode(byte);
  }

  return window.btoa(raw).replace(/\+/gu, '-').replace(/\//gu, '_').replace(/=+$/u, '');
};

const subscriptionUsesPublicKey = (subscription: PushSubscription, publicKey: string, keyRevision: number) => {
  const applicationServerKey = subscription.options?.applicationServerKey;

  if (applicationServerKey) {
    return arrayBufferToBase64Url(applicationServerKey) === publicKey;
  }

  return getStoredKeyRevision() === keyRevision;
};

const normalizeChatId = (chatId: number | null | undefined) =>
  typeof chatId === 'number' && Number.isInteger(chatId) && chatId > 0 ? chatId : null;

const createWebPushClientId = () => {
  if (typeof window.crypto?.randomUUID === 'function') return window.crypto.randomUUID();
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
};

/**
 * Stable id of this browser profile, letting the server replace the endpoint the
 * device used before it re-subscribed. Without persistent storage none is sent.
 */
export const getWebPushDeviceId = () => {
  const stored = readLocalValue(LOCAL_DEVICE_ID);
  if (stored && DEVICE_ID_PATTERN.test(stored)) return stored;

  const generated = createWebPushClientId();
  return writeLocalValue(LOCAL_DEVICE_ID, generated) ? generated : null;
};

const getWebPushClientId = () => {
  if (activeWebPushClientId) return activeWebPushClientId;

  try {
    const stored = window.sessionStorage.getItem(SESSION_CLIENT_ID);
    if (stored) {
      activeWebPushClientId = stored;
      return activeWebPushClientId;
    }

    activeWebPushClientId = createWebPushClientId();
    window.sessionStorage.setItem(SESSION_CLIENT_ID, activeWebPushClientId);
    return activeWebPushClientId;
  } catch {
    activeWebPushClientId = createWebPushClientId();
    return activeWebPushClientId;
  }
};

const webPushChatNotificationTag = (chatId: number) => `chat:${chatId}`;

const normalizeGenerationStatus = (status: string | null | undefined) =>
  status === 'done' || status === 'error' || status === 'canceled' ? status : null;

export const getWebPushRegistration = async () => {
  return getServiceWorkerRegistration();
};

export const currentWebPushSubscription = async () => {
  const registration = await getWebPushRegistration();
  if (!registration || !registration.pushManager) return null;
  return registration.pushManager.getSubscription();
};

const subscriptionPayload = (subscription: PushSubscription, keyRevision: number) => {
  const json = subscription.toJSON() as PushSubscriptionJson;
  const endpoint = json.endpoint || subscription.endpoint;
  const p256dh = json.keys?.p256dh;
  const auth = json.keys?.auth;

  if (!endpoint || !p256dh || !auth) {
    throw new Error('Browser returned an incomplete push subscription.');
  }

  const deviceId = getWebPushDeviceId();

  return {
    endpoint,
    keys: { p256dh, auth },
    expirationTime: json.expirationTime ?? null,
    key_revision: keyRevision,
    ...(deviceId ? { device_id: deviceId } : {}),
  };
};

const saveSubscription = async (subscription: PushSubscription, config: WebPushClientConfig) => {
  await api.post('/api/bff/web-push/subscriptions', subscriptionPayload(subscription, config.key_revision), {
    showErrorBanner: false,
  });
  setStoredKeyRevision(config.key_revision);
  markWebPushEnabledOnDevice();
};

const deleteSubscriptionOnServer = async (endpoint: string) => {
  const query = new URLSearchParams({ endpoint });
  await api.del(`/api/bff/web-push/subscriptions?${query.toString()}`, { showErrorBanner: false });
};

// A subscription made with rotated VAPID keys can no longer receive pushes, so the
// server copy is removed too instead of being sent to forever.
const discardSubscription = async (subscription: PushSubscription) => {
  await deleteSubscriptionOnServer(subscription.endpoint).catch((error) => {
    console.warn('Failed to delete a stale Web Push subscription on the server.', error);
  });
  await subscription.unsubscribe().catch(() => false);
  clearStoredKeyRevision();
};

const postServiceWorkerMessage = async (message: PwaServiceWorkerMessage) => {
  if (!('serviceWorker' in navigator)) return;

  await postPwaServiceWorkerMessage(message).catch(() => undefined);
};

const sendWebPushClientState = async (chatId: number, visible: boolean) => {
  const subscription = await currentWebPushSubscription().catch(() => null);
  if (!subscription) return;

  await api.post(
    '/api/bff/web-push/client-state',
    {
      endpoint: subscription.endpoint,
      client_id: getWebPushClientId(),
      chat_id: chatId,
      visible,
    },
    { showErrorBanner: false }
  ).catch(() => {
    // This is a best-effort hint; stale entries expire quickly on the server.
  });
};

const enqueueWebPushClientState = (chatId: number, visible: boolean) => {
  activeWebPushClientStateQueue = activeWebPushClientStateQueue
    .catch(() => undefined)
    .then(() => sendWebPushClientState(chatId, visible));
};

const syncActiveWebPushClientState = () => {
  const visibleChatId =
    activeWebPushChatId !== null && document.visibilityState === 'visible'
      ? activeWebPushChatId
      : null;

  if (visibleChatId !== null) {
    reportedVisibleWebPushChatId = visibleChatId;
    enqueueWebPushClientState(visibleChatId, true);
    return;
  }

  if (reportedVisibleWebPushChatId !== null) {
    const hiddenChatId = reportedVisibleWebPushChatId;
    reportedVisibleWebPushChatId = null;
    enqueueWebPushClientState(hiddenChatId, false);
  }
};

const startActiveWebPushHeartbeat = () => {
  if (activeWebPushHeartbeatTimer !== null) return;
  activeWebPushHeartbeatTimer = window.setInterval(
    syncActiveWebPushClientState,
    ACTIVE_CHAT_HEARTBEAT_MS
  );
};

const stopActiveWebPushHeartbeat = () => {
  if (activeWebPushHeartbeatTimer === null) return;
  window.clearInterval(activeWebPushHeartbeatTimer);
  activeWebPushHeartbeatTimer = null;
};

const handleActiveWebPushClientWake = () => {
  if (activeWebPushChatId !== null) startActiveWebPushHeartbeat();
  syncActiveWebPushClientState();
};

const ensureActiveWebPushClientListeners = () => {
  if (activeWebPushListenersReady) return;
  activeWebPushListenersReady = true;
  document.addEventListener('visibilitychange', handleActiveWebPushClientWake);
  window.addEventListener('pageshow', handleActiveWebPushClientWake);
  window.addEventListener('focus', handleActiveWebPushClientWake);
};

export const setActiveWebPushChat = (chatId: number | null | undefined) => {
  activeWebPushChatId = normalizeChatId(chatId);
  ensureActiveWebPushClientListeners();

  if (activeWebPushChatId !== null) {
    startActiveWebPushHeartbeat();
  } else {
    stopActiveWebPushHeartbeat();
  }

  syncActiveWebPushClientState();
};

export const clearActiveWebPushChat = () => {
  activeWebPushChatId = null;
  stopActiveWebPushHeartbeat();
  syncActiveWebPushClientState();
};

export const closeWebPushNotificationsForChat = (chatId: number | null | undefined) => {
  const normalizedChatId = normalizeChatId(chatId);
  if (normalizedChatId === null) return;

  void postServiceWorkerMessage({
    type: 'web_push_close_chat_notifications',
    chat_id: normalizedChatId,
    tag: webPushChatNotificationTag(normalizedChatId),
  });
};

// Shared with server/priv/static/service-worker.js, which records each shown notification.
const SHOWN_NOTIFICATIONS_CACHE = 'intellectual-club:web-push:shown';
const SHOWN_NOTIFICATIONS_KEY = '/__web_push_shown_notifications__';
// Lets Notification Center drop the tapped notification before it is inspected.
const TAPPED_NOTIFICATION_SETTLE_MS = 300;

type ShownWebPushNotification = { tag: string; url: string; shownAt: number };

const shownNotificationEntry = (value: unknown): ShownWebPushNotification | null => {
  if (!value || typeof value !== 'object') return null;

  const { tag, url, shownAt } = value as Record<string, unknown>;
  if (typeof tag !== 'string' || tag === '') return null;
  if (typeof url !== 'string' || !url.startsWith('/') || url.startsWith('//')) return null;
  if (typeof shownAt !== 'number' || !Number.isFinite(shownAt)) return null;

  return { tag, url, shownAt };
};

const takeShownWebPushNotifications = async (): Promise<ShownWebPushNotification[]> => {
  if (typeof caches === 'undefined') return [];

  try {
    const response = await caches.match(SHOWN_NOTIFICATIONS_KEY, {
      cacheName: SHOWN_NOTIFICATIONS_CACHE,
    });
    const stored: unknown = response ? await response.json() : [];
    await caches.delete(SHOWN_NOTIFICATIONS_CACHE);

    return Array.isArray(stored)
      ? stored.map(shownNotificationEntry).filter((entry) => entry !== null)
      : [];
  } catch {
    return [];
  }
};

/**
 * Returns the in-app URL of the notification the user most likely tapped to bring
 * the app back after `hiddenAt`: shown since then and no longer in Notification
 * Center. A notification swiped away while hidden is indistinguishable from a tap.
 */
export const takeTappedWebPushNotificationUrl = async (hiddenAt: number): Promise<string | null> => {
  const shown = (await takeShownWebPushNotifications()).filter((entry) => entry.shownAt >= hiddenAt);
  if (shown.length === 0) return null;

  const registration = await getWebPushRegistration().catch(() => null);
  if (!registration || typeof registration.getNotifications !== 'function') return null;

  const presentTags = new Set(
    (await registration.getNotifications().catch(() => [])).map((notification) => notification.tag)
  );
  const tapped = shown
    .filter((entry) => !presentTags.has(entry.tag))
    .sort((left, right) => right.shownAt - left.shownAt)[0];

  return tapped?.url ?? null;
};

/**
 * iOS restores a backgrounded Home Screen app without applying the tapped
 * notification's `navigate` URL and dispatches no `notificationclick` (WebKit bug
 * 268797), so taps are recovered when the app becomes visible again. Other
 * platforms route through `notificationclick` and are left alone.
 */
export const startWebPushTapRecovery = (navigate: (url: string) => void): (() => void) => {
  if (!isIosLike() || !isStandalonePwa() || typeof caches === 'undefined') return () => undefined;

  let hiddenAt: number | null = null;
  let settleTimer: number | null = null;

  // A cold start already lands on the notification URL; earlier entries are stale.
  void takeShownWebPushNotifications();

  const handleVisibilityChange = () => {
    if (document.visibilityState === 'hidden') {
      hiddenAt = Date.now();
      return;
    }

    if (hiddenAt === null) return;

    const since = hiddenAt;
    hiddenAt = null;
    if (settleTimer !== null) window.clearTimeout(settleTimer);

    settleTimer = window.setTimeout(() => {
      settleTimer = null;
      void takeTappedWebPushNotificationUrl(since).then((url) => {
        if (url) navigate(url);
      });
    }, TAPPED_NOTIFICATION_SETTLE_MS);
  };

  document.addEventListener('visibilitychange', handleVisibilityChange);

  return () => {
    document.removeEventListener('visibilitychange', handleVisibilityChange);
    if (settleTimer !== null) window.clearTimeout(settleTimer);
  };
};

export const markWebPushGenerationSeen = (
  chatId: number | null | undefined,
  messageId: number | null | undefined,
  status: string | null | undefined
) => {
  const normalizedChatId = normalizeChatId(chatId);
  const normalizedMessageId = normalizeChatId(messageId);
  const normalizedStatus = normalizeGenerationStatus(status);

  if (
    normalizedChatId === null ||
    normalizedMessageId === null ||
    normalizedStatus === null ||
    document.visibilityState !== 'visible'
  ) {
    return;
  }

  const key = `${normalizedChatId}:${normalizedMessageId}:${normalizedStatus}`;
  if (reportedSeenGenerations.has(key)) return;
  reportedSeenGenerations.add(key);

  void api.post(
    '/api/bff/web-push/message-seen',
    {
      chat_id: normalizedChatId,
      message_id: normalizedMessageId,
      status: normalizedStatus,
    },
    { showErrorBanner: false }
  ).catch(() => {
    reportedSeenGenerations.delete(key);
  });
};

export const enableWebPush = async () => {
  const support = webPushSupportState();
  if (!support.supported) throw new Error(support.reason || 'Push notifications are not supported in this browser.');

  const config = await loadWebPushConfig();
  if (!config.enabled || !config.vapid_public_key) throw new Error('Web Push is disabled.');

  const permission = await Notification.requestPermission();
  if (permission !== 'granted') throw new Error('Notification permission was not granted.');

  const registration = await getWebPushRegistration();
  if (!registration) throw new Error('Service worker registration is unavailable.');

  let subscription = await registration.pushManager.getSubscription();

  if (subscription && !subscriptionUsesPublicKey(subscription, config.vapid_public_key, config.key_revision)) {
    await discardSubscription(subscription);
    subscription = null;
  }

  if (!subscription) {
    subscription = await registration.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: base64UrlToUint8Array(config.vapid_public_key),
    });
  }

  await saveSubscription(subscription, config);
  return subscription;
};

export const disableWebPush = async () => {
  clearWebPushEnabledOnDevice();
  const subscription = await currentWebPushSubscription();

  if (subscription) {
    await deleteSubscriptionOnServer(subscription.endpoint).catch((error) => {
      console.warn('Failed to delete Web Push subscription on the server.', error);
    });
    await subscription.unsubscribe().catch(() => false);
  }

  clearStoredKeyRevision();
};

export const cleanupWebPushForLogout = async () => {
  clearWebPushEnabledOnDevice();
  const subscription = await currentWebPushSubscription();
  if (!subscription) return;

  await deleteSubscriptionOnServer(subscription.endpoint).catch((error) => {
    console.warn('Failed to delete Web Push subscription during logout.', error);
  });

  await subscription.unsubscribe().catch(() => false);
  clearStoredKeyRevision();
};

/** Stops reminding about a lost subscription until notifications are enabled again. */
export const dismissWebPushDeviceNotice = () => {
  clearWebPushEnabledOnDevice();
};

const resolveWebPushDeviceStatus = async (): Promise<WebPushDeviceStatus> => {
  const support = webPushSupportState();
  if (!support.supported) return 'unavailable';

  const config = await loadWebPushConfig().catch(() => null);
  if (!config?.enabled || !config.vapid_public_key) return 'unavailable';

  const expected = webPushEnabledOnDevice();
  if (support.permission === 'denied') return expected ? 'blocked' : 'inactive';
  if (support.permission !== 'granted') return expected ? 'lost' : 'inactive';

  let subscription: PushSubscription | null;
  try {
    subscription = await currentWebPushSubscription();
  } catch (error) {
    console.warn('Failed to read Web Push subscription.', error);
    return 'unavailable';
  }

  if (!subscription) return expected ? 'lost' : 'inactive';

  if (!subscriptionUsesPublicKey(subscription, config.vapid_public_key, config.key_revision)) {
    await discardSubscription(subscription);
    return expected ? 'lost' : 'inactive';
  }

  await saveSubscription(subscription, config).catch((error) => {
    console.warn('Failed to sync Web Push subscription.', error);
  });
  return 'subscribed';
};

/**
 * Re-registers this device's subscription and reports whether a subscription the
 * user enabled here has disappeared, which drives the re-enable banner.
 */
export const syncExistingWebPushSubscription = async (): Promise<WebPushDeviceStatus> => {
  const status = await resolveWebPushDeviceStatus();
  webPushDeviceNotice.value = status === 'lost' || status === 'blocked' ? status : null;
  return status;
};
