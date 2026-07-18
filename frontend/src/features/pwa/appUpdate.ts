import { readonly, ref } from 'vue';
import {
  getServiceWorkerRegistration,
  postServiceWorkerMessage,
} from '@/features/pwa/serviceWorker';

const CODE_VERSION_PATH = '/assets/code-version.json';
const CHECK_INTERVAL_MS = 5 * 60 * 1000;
const UPDATE_TIMEOUT_MS = 10_000;
const ACTIVATION_TIMEOUT_MS = 12_000;

export type AppCodeVersion = {
  commit_timestamp: string;
  commit_sha: string;
  dirty: boolean;
  label: string;
};

const available = ref(false);
const latestVersion = ref<AppCodeVersion | null>(null);
const checking = ref(false);

let checkTimer: number | null = null;
let started = false;
let checkPromise: Promise<void> | null = null;

const normalizeCodeVersion = (value: unknown): AppCodeVersion | null => {
  if (!value || typeof value !== 'object') return null;

  const raw = value as Record<string, unknown>;
  const commitTimestamp = typeof raw.commit_timestamp === 'string' ? raw.commit_timestamp : '';
  const commitSha = typeof raw.commit_sha === 'string' ? raw.commit_sha : '';
  const label = typeof raw.label === 'string' ? raw.label : '';

  return {
    commit_timestamp: commitTimestamp,
    commit_sha: commitSha,
    dirty: raw.dirty === true,
    label,
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
  let registration: ServiceWorkerRegistration | null = null;
  let registrationChecked = false;
  try {
    registration = await updateServiceWorkerRegistration();
    registrationChecked = true;
  } catch {
    registrationChecked = false;
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
  const workerAvailable = Boolean(registration?.waiting);

  if (remoteAvailable || workerAvailable) {
    available.value = true;
    if (remoteAvailable) {
      latestVersion.value = remoteVersion;
    } else if (remoteVersionChecked) {
      latestVersion.value = null;
    }
    return;
  }

  if (registrationChecked && remoteVersionChecked) {
    available.value = false;
    latestVersion.value = null;
  }
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

const waitForControllerChange = () =>
  withTimeout(
    new Promise<void>((resolve) => {
      navigator.serviceWorker.addEventListener('controllerchange', () => resolve(), {
        once: true,
      });
    }),
    ACTIVATION_TIMEOUT_MS,
    'Service worker activation timed out.'
  );

export const reload = async () => {
  if (!('serviceWorker' in navigator)) {
    window.location.reload();
    return;
  }

  const registration =
    (await updateServiceWorkerRegistration().catch(() => null)) ??
    (await getServiceWorkerRegistration().catch(() => null));
  const waiting = registration?.waiting;

  if (!waiting) {
    window.location.reload();
    return;
  }

  const controllerChange = waitForControllerChange();
  await postServiceWorkerMessage({ type: 'ACTIVATE_UPDATE' });
  await controllerChange.catch(() => undefined);
  window.location.reload();
};

export const useAppUpdateMonitor = () => ({
  available: readonly(available),
  latestVersion: readonly(latestVersion),
  checking: readonly(checking),
  currentVersion,
  checkNow,
  reload,
  start,
  stop,
});
