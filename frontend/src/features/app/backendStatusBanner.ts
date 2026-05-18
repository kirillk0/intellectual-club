import { readonly, ref } from 'vue';

export type BackendStatusBannerState = {
  title: string;
  message: string;
};

const banner = ref<BackendStatusBannerState | null>(null);

let lastDismissedFingerprint = '';
let lastDismissedAt = 0;

const RESHOW_AFTER_DISMISS_MS = 10_000;

const fingerprint = (value: BackendStatusBannerState) => `${value.title}\n${value.message}`;

export function showBackendStatusBanner(next: BackendStatusBannerState) {
  const nextFingerprint = fingerprint(next);
  const now = Date.now();

  if (banner.value && fingerprint(banner.value) === nextFingerprint) return;

  if (
    lastDismissedFingerprint === nextFingerprint &&
    now - lastDismissedAt < RESHOW_AFTER_DISMISS_MS
  ) {
    return;
  }

  banner.value = next;
}

function dismissBackendStatusBanner() {
  if (banner.value) {
    lastDismissedFingerprint = fingerprint(banner.value);
    lastDismissedAt = Date.now();
  }

  banner.value = null;
}

export function clearBackendStatusBanner() {
  banner.value = null;
}

export function useBackendStatusBanner() {
  return {
    banner: readonly(banner),
    dismissBackendStatusBanner,
  };
}
