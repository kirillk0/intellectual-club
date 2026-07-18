import { readonly, ref } from 'vue';

export type BackendStatusBannerState = {
  title: string;
  message: string;
};

const banner = ref<BackendStatusBannerState | null>(null);
type BannerEntry = {
  state: BackendStatusBannerState;
  order: number;
};

const entries = new Map<string, BannerEntry>();
let entryOrder = 0;
let visibleSourceKey: string | null = null;

let lastDismissedFingerprint = '';
let lastDismissedAt = 0;

const RESHOW_AFTER_DISMISS_MS = 10_000;

const fingerprint = (value: BackendStatusBannerState) => `${value.title}\n${value.message}`;

function refreshVisibleBanner() {
  const nextEntry = [...entries.entries()].sort((left, right) => right[1].order - left[1].order)[0];
  visibleSourceKey = nextEntry?.[0] ?? null;
  banner.value = nextEntry?.[1].state ?? null;
}

export function showBackendStatusBanner(next: BackendStatusBannerState, sourceKey = 'global') {
  const nextFingerprint = fingerprint(next);
  const now = Date.now();

  const currentEntry = entries.get(sourceKey);
  if (currentEntry && fingerprint(currentEntry.state) === nextFingerprint) return;

  if (
    lastDismissedFingerprint === nextFingerprint &&
    now - lastDismissedAt < RESHOW_AFTER_DISMISS_MS
  ) {
    return;
  }

  entries.set(sourceKey, { state: next, order: ++entryOrder });
  refreshVisibleBanner();
}

function dismissBackendStatusBanner() {
  if (banner.value) {
    lastDismissedFingerprint = fingerprint(banner.value);
    lastDismissedAt = Date.now();
  }

  if (visibleSourceKey) entries.delete(visibleSourceKey);
  refreshVisibleBanner();
}

export function clearBackendStatusBanner(sourceKey = 'global') {
  if (!entries.delete(sourceKey)) return;
  refreshVisibleBanner();
}

export function useBackendStatusBanner() {
  return {
    banner: readonly(banner),
    dismissBackendStatusBanner,
  };
}
