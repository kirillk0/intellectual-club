import { readonly, ref } from 'vue';

const CODE_VERSION_PATH = '/assets/code-version.json';
const CHECK_INTERVAL_MS = 5 * 60 * 1000;

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

const updateServiceWorkerRegistration = async () => {
  if (!('serviceWorker' in navigator)) return;

  const registration = await navigator.serviceWorker.getRegistration('/');
  await registration?.update();
};

const fetchLatestVersion = async () => {
  const response = await fetch(latestVersionUrl(), {
    cache: 'no-store',
    credentials: 'same-origin',
    headers: {
      Accept: 'application/json',
    },
  });

  if (!response.ok) return null;

  return normalizeCodeVersion(await response.json());
};

const runCheck = async () => {
  await updateServiceWorkerRegistration().catch(() => undefined);

  const remoteVersion = await fetchLatestVersion().catch(() => null);
  if (!remoteVersion) return;

  const remoteVersionKey = versionKey(remoteVersion);
  const remoteAvailable = remoteVersionKey !== currentVersionKey;

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

export const reload = () => {
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
