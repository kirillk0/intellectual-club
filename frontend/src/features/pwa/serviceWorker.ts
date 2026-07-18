const SERVICE_WORKER_PATH = '/service-worker.js';
export const SERVICE_WORKER_SCOPE = '/';

const currentBuildId = () => {
  const version = __CODE_VERSION__;
  return [
    version.commit_timestamp,
    version.commit_sha,
    version.dirty ? 'dirty' : 'clean',
    version.label,
  ].join(':');
};

export type PwaServiceWorkerMessage =
  | { type: 'CACHE_PROGRESS'; context: 'precache'; completed: number; total: number }
  | {
      type: 'ASSET_RETRY';
      context: 'runtime' | 'precache';
      url: string;
      attempt: number;
    }
  | { type: 'NAVIGATION_READY'; url: string }
  | { type: 'VERSION_MISMATCH'; context: 'runtime'; url: string }
  | { type: 'ACTIVATE_UPDATE' }
  | { type: 'web_push_close_chat_notifications'; chat_id: number; tag: string };

let registrationPromise: Promise<ServiceWorkerRegistration> | null = null;

const inlineRegistration = () => window.__IC_SERVICE_WORKER_REGISTRATION__;

const trackedBuildId = () =>
  document.querySelector<HTMLMetaElement>('meta[name="ic-build-id"]')?.content ||
  currentBuildId();

export const serviceWorkerScriptUrl = () => {
  const url = new URL(SERVICE_WORKER_PATH, window.location.origin);
  url.searchParams.set('build', trackedBuildId());
  return `${url.pathname}${url.search}`;
};

export const registerServiceWorker = () => {
  if (!('serviceWorker' in navigator)) {
    return Promise.resolve<ServiceWorkerRegistration | null>(null);
  }

  if (!registrationPromise) {
    const registerDirectly = () =>
      navigator.serviceWorker.register(serviceWorkerScriptUrl(), {
        scope: SERVICE_WORKER_SCOPE,
        updateViaCache: 'none',
      });
    const earlyRegistration = inlineRegistration();

    registrationPromise = (earlyRegistration
      ? earlyRegistration.then((registration) => registration ?? registerDirectly())
      : registerDirectly())
      .catch((error) => {
        registrationPromise = null;
        throw error;
      });
  }

  return registrationPromise;
};

export const getServiceWorkerRegistration = async () => {
  if (!('serviceWorker' in navigator)) return null;

  const existing = await navigator.serviceWorker.getRegistration(SERVICE_WORKER_SCOPE);
  return existing ?? registerServiceWorker();
};

export const postServiceWorkerMessage = async (message: PwaServiceWorkerMessage) => {
  const registration = await getServiceWorkerRegistration();
  const worker =
    message.type === 'ACTIVATE_UPDATE'
      ? registration?.waiting
      : navigator.serviceWorker.controller || registration?.active;

  worker?.postMessage(message);
};
