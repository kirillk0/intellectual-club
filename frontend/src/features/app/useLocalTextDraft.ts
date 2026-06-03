import { watch, type ComputedRef, type Ref } from 'vue';

const LOCAL_TEXT_DRAFT_VERSION = 1;

type LocalTextDraftPayload = {
  version: number;
  revision: string;
  text: string;
  savedAt: string;
};

type LocalTextDraftOptions = {
  storageKey: ComputedRef<string | null>;
  revision: ComputedRef<string | null>;
  value: Ref<string>;
  enabled: ComputedRef<boolean>;
  isDraft: ComputedRef<boolean>;
  clearValueOnInvalidation?: boolean;
};

function readStorageItem(key: string) {
  try {
    return window.localStorage.getItem(key);
  } catch {
    return null;
  }
}

function writeStorageItem(key: string, payload: LocalTextDraftPayload) {
  try {
    window.localStorage.setItem(key, JSON.stringify(payload));
  } catch {
    // Ignore storage failures in private mode or when quota is exhausted.
  }
}

function removeStorageItem(key: string | null | undefined) {
  if (!key) return;

  try {
    window.localStorage.removeItem(key);
  } catch {
    // Ignore storage failures in private mode or when quota is exhausted.
  }
}

function parseDraftPayload(raw: string): LocalTextDraftPayload | null {
  try {
    const parsed = JSON.parse(raw) as Partial<LocalTextDraftPayload>;
    if (parsed.version !== LOCAL_TEXT_DRAFT_VERSION) return null;
    if (typeof parsed.revision !== 'string') return null;
    if (typeof parsed.text !== 'string') return null;
    if (typeof parsed.savedAt !== 'string') return null;

    return {
      version: LOCAL_TEXT_DRAFT_VERSION,
      revision: parsed.revision,
      text: parsed.text,
      savedAt: parsed.savedAt,
    };
  } catch {
    return null;
  }
}

function currentKey(options: LocalTextDraftOptions) {
  const key = options.storageKey.value;
  return typeof key === 'string' && key.trim() !== '' ? key : null;
}

function currentRevision(options: LocalTextDraftOptions) {
  const revision = options.revision.value;
  return typeof revision === 'string' && revision.trim() !== '' ? revision : null;
}

export function useLocalTextDraft(options: LocalTextDraftOptions) {
  let applyingStoredValue = false;
  let loadedKey: string | null = null;
  let loadedRevision: string | null = null;

  const clear = (key = currentKey(options)) => {
    removeStorageItem(key);
  };

  const load = () => {
    if (typeof window === 'undefined') return;
    if (!options.enabled.value) return;

    const key = currentKey(options);
    const revision = currentRevision(options);
    if (!key || !revision) return;
    if (loadedKey === key && loadedRevision === revision) return;

    loadedKey = key;
    loadedRevision = revision;

    const raw = readStorageItem(key);
    if (!raw) return;

    const payload = parseDraftPayload(raw);
    if (!payload) {
      removeStorageItem(key);
      return;
    }

    if (payload.revision !== revision) {
      removeStorageItem(key);
      if (options.clearValueOnInvalidation) {
        applyingStoredValue = true;
        options.value.value = '';
        applyingStoredValue = false;
      }
      return;
    }

    if (payload.text === options.value.value) return;

    applyingStoredValue = true;
    options.value.value = payload.text;
    applyingStoredValue = false;
  };

  const persist = () => {
    if (typeof window === 'undefined') return;
    if (applyingStoredValue) return;
    if (!options.enabled.value) return;

    const key = currentKey(options);
    const revision = currentRevision(options);
    if (!key || !revision) return;

    if (!options.isDraft.value) {
      removeStorageItem(key);
      return;
    }

    writeStorageItem(key, {
      version: LOCAL_TEXT_DRAFT_VERSION,
      revision,
      text: options.value.value,
      savedAt: new Date().toISOString(),
    });
  };

  watch(
    () => [options.storageKey.value, options.revision.value, options.enabled.value] as const,
    load,
    { immediate: true }
  );

  watch(
    () => [
      options.value.value,
      options.isDraft.value,
      options.storageKey.value,
      options.revision.value,
      options.enabled.value,
    ] as const,
    persist,
    { flush: 'post' }
  );

  return {
    clear,
  };
}
