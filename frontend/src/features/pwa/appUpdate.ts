import { readonly, ref } from 'vue';
import { getServiceWorkerRegistration } from '@/features/pwa/serviceWorker';

const CODE_VERSION_PATH = '/assets/code-version.json';
const CHECK_INTERVAL_MS = 5 * 60 * 1000;
const UPDATE_TIMEOUT_MS = 10_000;
const ACTIVATION_TIMEOUT_MS = 60_000;
const RELOAD_CANCELLATION_GRACE_MS = 1_000;

export type AppCodeVersion = {
  commit_timestamp: string;
  commit_sha: string;
  dirty: boolean;
  label: string;
};

const available = ref(false);
const latestVersion = ref<AppCodeVersion | null>(null);
const checking = ref(false);
const reloading = ref(false);

let checkTimer: number | null = null;
let started = false;
let checkPromise: Promise<void> | null = null;
let reloadPromise: Promise<void> | null = null;

const normalizeCodeVersion = (value: unknown): AppCodeVersion | null => {
  if (!value || typeof value !== 'object') return null;

  const raw = value as Record<string, unknown>;
  if (
    typeof raw.commit_timestamp !== 'string' ||
    typeof raw.commit_sha !== 'string' ||
    typeof raw.dirty !== 'boolean' ||
    typeof raw.label !== 'string' ||
    raw.label.trim() === ''
  ) {
    return null;
  }

  return {
    commit_timestamp: raw.commit_timestamp,
    commit_sha: raw.commit_sha,
    dirty: raw.dirty,
    label: raw.label,
  };
};

const currentVersion = normalizeCodeVersion(__CODE_VERSION__) ?? {
  commit_timestamp: '',
  commit_sha: '',
  dirty: false,
  label: '',
};

const versionKey = (version: AppCodeVersion) =>
  JSON.stringify([
    version.commit_timestamp,
    version.commit_sha,
    version.dirty,
    version.label,
  ]);

const currentVersionKey = versionKey(currentVersion);

const latestVersionUrl = () => {
  const url = new URL(CODE_VERSION_PATH, window.location.origin);
  url.searchParams.set('_', String(Date.now()));
  return url.href;
};

const withTimeout = <T>(promise: Promise<T>, timeoutMs: number, message: string) =>
  new Promise<T>((resolve, reject) => {
    const timer = window.setTimeout(() => reject(new Error(message)), timeoutMs);

    promise.then(
      (value) => {
        window.clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        window.clearTimeout(timer);
        reject(error);
      }
    );
  });

const updateServiceWorkerRegistration = async () => {
  if (!('serviceWorker' in navigator)) return null;

  const registration = await getServiceWorkerRegistration();
  if (!registration) return null;

  await withTimeout(
    registration.update(),
    UPDATE_TIMEOUT_MS,
    'Service worker update timed out.'
  ).catch(() => undefined);
  return registration;
};

const fetchLatestVersion = async () => {
  const controller = new AbortController();
  const timer = window.setTimeout(() => controller.abort(), UPDATE_TIMEOUT_MS);

  let response: Response;

  try {
    response = await fetch(latestVersionUrl(), {
      cache: 'no-store',
      credentials: 'same-origin',
      headers: {
        Accept: 'application/json',
      },
      signal: controller.signal,
    });
  } finally {
    window.clearTimeout(timer);
  }

  if (!response.ok) return null;

  return normalizeCodeVersion(await response.json());
};

const runCheck = async () => {
  try {
    await updateServiceWorkerRegistration();
  } catch {
    // Version metadata remains authoritative when the worker check fails.
  }

  let remoteVersion: AppCodeVersion | null = null;
  let remoteVersionChecked = false;
  try {
    remoteVersion = await fetchLatestVersion();
    remoteVersionChecked = remoteVersion !== null;
  } catch {
    remoteVersionChecked = false;
  }
  const remoteAvailable =
    remoteVersion !== null && versionKey(remoteVersion) !== currentVersionKey;

  if (!remoteVersionChecked) return;

  available.value = remoteAvailable;
  latestVersion.value = remoteAvailable ? remoteVersion : null;
};

const documentVisible = () =>
  typeof document === 'undefined' || document.visibilityState !== 'hidden';

export const checkNow = () => {
  if (checkPromise) return checkPromise;

  checking.value = true;
  checkPromise = runCheck()
    .catch(() => undefined)
    .finally(() => {
      checking.value = false;
      checkPromise = null;
    });

  return checkPromise;
};

const checkIfVisible = () => {
  if (!documentVisible()) return;
  void checkNow();
};

export const start = () => {
  if (started) return;
  started = true;

  void checkNow();
  checkTimer = window.setInterval(checkIfVisible, CHECK_INTERVAL_MS);

  document.addEventListener('visibilitychange', checkIfVisible);
  window.addEventListener('focus', checkIfVisible);
  window.addEventListener('pageshow', checkIfVisible);
  window.addEventListener('online', checkIfVisible);
};

export const stop = () => {
  if (!started) return;
  started = false;

  if (checkTimer !== null) {
    window.clearInterval(checkTimer);
    checkTimer = null;
  }

  document.removeEventListener('visibilitychange', checkIfVisible);
  window.removeEventListener('focus', checkIfVisible);
  window.removeEventListener('pageshow', checkIfVisible);
  window.removeEventListener('online', checkIfVisible);
};

const waitForWorkerActivation = (worker: ServiceWorker) =>
  new Promise<void>((resolve, reject) => {
    let settled = false;
    let timer: number | null = null;

    const cleanup = () => {
      navigator.serviceWorker.removeEventListener('controllerchange', handleControllerChange);
      worker.removeEventListener?.('statechange', handleStateChange);
      if (timer !== null) window.clearTimeout(timer);
    };
    const finish = (error?: Error) => {
      if (settled) return;
      settled = true;
      cleanup();
      if (error) reject(error);
      else resolve();
    };
    const handleStateChange = () => {
      if (worker.state === 'activated') finish();
      if (worker.state === 'redundant') {
        finish(new Error('Service worker update became redundant.'));
      }
    };
    const handleControllerChange = () => handleStateChange();

    navigator.serviceWorker.addEventListener('controllerchange', handleControllerChange);
    worker.addEventListener?.('statechange', handleStateChange);
    timer = window.setTimeout(
      () => finish(new Error('Service worker activation timed out.')),
      ACTIVATION_TIMEOUT_MS
    );
    handleStateChange();
  });

const reloadDocument = () =>
  new Promise<void>((resolve) => {
    let recoveryTimer: number | null = null;

    const cleanup = () => {
      window.removeEventListener('pagehide', handlePageHide);
      window.removeEventListener('beforeunload', handleBeforeUnload);
      if (recoveryTimer !== null) window.clearTimeout(recoveryTimer);
    };
    const handlePageHide = () => cleanup();
    const handleBeforeUnload = (event: BeforeUnloadEvent) => {
      if (!event.defaultPrevented) return;

      recoveryTimer = window.setTimeout(() => {
        cleanup();
        resolve();
      }, RELOAD_CANCELLATION_GRACE_MS);
    };

    window.addEventListener('pagehide', handlePageHide, { once: true });
    window.addEventListener('beforeunload', handleBeforeUnload, { once: true });
    try {
      window.location.reload();
    } catch (error) {
      cleanup();
      throw error;
    }
  });

const performReload = async () => {
  if ('serviceWorker' in navigator) {
    try {
      const registration = await withTimeout(
        getServiceWorkerRegistration(),
        UPDATE_TIMEOUT_MS,
        'Service worker registration timed out.'
      );
      const worker = registration?.installing ?? registration?.waiting;

      if (worker) {
        const activation = waitForWorkerActivation(worker);
        worker.postMessage({ type: 'ACTIVATE_UPDATE' });
        await activation;
      }
    } catch (error) {
      console.warn('Service worker update activation failed.', error);
    }
  }

  await reloadDocument();
};

export const reload = () => {
  if (reloadPromise) return reloadPromise;

  reloading.value = true;
  reloadPromise = performReload().finally(() => {
    reloading.value = false;
    reloadPromise = null;
  });

  return reloadPromise;
};

export const useAppUpdateMonitor = () => ({
  available: readonly(available),
  latestVersion: readonly(latestVersion),
  checking: readonly(checking),
  reloading: readonly(reloading),
  currentVersion,
  checkNow,
  reload,
  start,
  stop,
});
