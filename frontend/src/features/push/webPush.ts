import { api } from '@/api/client';
import { isStandalonePwa } from '@/pwa';

const SERVICE_WORKER_PATH = '/service-worker.js';
const SERVICE_WORKER_SCOPE = '/';
const LOCAL_KEY_REVISION = 'intellectual-club:web-push:key-revision';
const SESSION_CLIENT_ID = 'intellectual-club:web-push:client-id';
const ACTIVE_CHAT_HEARTBEAT_MS = 20_000;

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

type ServiceWorkerMessage = {
  type: string;
  [key: string]: unknown;
};

let activeWebPushChatId: number | null = null;
let activeWebPushHeartbeatTimer: number | null = null;
let activeWebPushListenersReady = false;
let activeWebPushClientId: string | null = null;
let reportedVisibleWebPushChatId: number | null = null;
let activeWebPushClientStateQueue: Promise<void> = Promise.resolve();

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

export const loadWebPushConfig = () =>
  api.get<WebPushClientConfig>('/api/bff/web-push/config', { showErrorBanner: false });

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

export const getWebPushRegistration = async () => {
  if (!('serviceWorker' in navigator)) return null;

  const existing = await navigator.serviceWorker.getRegistration(SERVICE_WORKER_SCOPE);
  if (existing) return existing;

  return navigator.serviceWorker.register(SERVICE_WORKER_PATH, { scope: SERVICE_WORKER_SCOPE });
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

  return {
    endpoint,
    keys: { p256dh, auth },
    expirationTime: json.expirationTime ?? null,
    key_revision: keyRevision,
  };
};

const saveSubscription = async (subscription: PushSubscription, config: WebPushClientConfig) => {
  await api.post('/api/bff/web-push/subscriptions', subscriptionPayload(subscription, config.key_revision), {
    showErrorBanner: false,
  });
  setStoredKeyRevision(config.key_revision);
};

const deleteSubscriptionOnServer = async (endpoint: string) => {
  const query = new URLSearchParams({ endpoint });
  await api.del(`/api/bff/web-push/subscriptions?${query.toString()}`, { showErrorBanner: false });
};

const postServiceWorkerMessage = async (message: ServiceWorkerMessage) => {
  if (!('serviceWorker' in navigator)) return;

  const registration = await getWebPushRegistration().catch(() => null);
  const worker = navigator.serviceWorker.controller || registration?.active || null;
  worker?.postMessage(message);
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
    await subscription.unsubscribe().catch(() => false);
    subscription = null;
    clearStoredKeyRevision();
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
  const subscription = await currentWebPushSubscription();
  if (!subscription) return;

  await deleteSubscriptionOnServer(subscription.endpoint).catch((error) => {
    console.warn('Failed to delete Web Push subscription during logout.', error);
  });

  await subscription.unsubscribe().catch(() => false);
  clearStoredKeyRevision();
};

export const syncExistingWebPushSubscription = async () => {
  const support = webPushSupportState();
  if (!support.supported || support.permission !== 'granted') return;

  const config = await loadWebPushConfig().catch(() => null);
  if (!config?.enabled || !config.vapid_public_key) return;

  const subscription = await currentWebPushSubscription();
  if (!subscription) return;

  if (!subscriptionUsesPublicKey(subscription, config.vapid_public_key, config.key_revision)) {
    await subscription.unsubscribe().catch(() => false);
    clearStoredKeyRevision();
    return;
  }

  await saveSubscription(subscription, config).catch((error) => {
    console.warn('Failed to sync Web Push subscription.', error);
  });
};
