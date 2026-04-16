import { effectScope, ref, watch } from 'vue';

export type BotSortMode = 'name' | 'recent_activity';

type BotSortRecord = {
  id?: number | '' | null;
  name?: string | null;
  sort_activity_at?: string | null;
  updated_at?: string | null;
  created_at?: string | null;
};

const BOT_SORT_STORAGE_KEY = 'ic.bots.sort_mode.v1';
const DEFAULT_BOT_SORT_MODE: BotSortMode = 'name';
const persistenceScope = effectScope(true);

const mode = ref<BotSortMode>(DEFAULT_BOT_SORT_MODE);
let initialized = false;

const isBrowser = () => typeof window !== 'undefined';

const normalizeSortMode = (value: unknown): BotSortMode => {
  return value === 'recent_activity' ? 'recent_activity' : 'name';
};

const restoreSortMode = (): BotSortMode => {
  if (!isBrowser()) return DEFAULT_BOT_SORT_MODE;

  try {
    const raw = window.localStorage.getItem(BOT_SORT_STORAGE_KEY);
    return normalizeSortMode(raw);
  } catch {
    return DEFAULT_BOT_SORT_MODE;
  }
};

const persistSortMode = (next: BotSortMode) => {
  if (!isBrowser()) return;

  try {
    window.localStorage.setItem(BOT_SORT_STORAGE_KEY, next);
  } catch {
    // Ignore storage failures for private mode/quota limits.
  }
};

const parseTimestamp = (value: string | null | undefined): number => {
  if (!value) return 0;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : 0;
};

export const botSortTimestamp = (record: BotSortRecord): number => {
  return (
    parseTimestamp(record.sort_activity_at) ||
    parseTimestamp(record.updated_at) ||
    parseTimestamp(record.created_at)
  );
};

const botSortName = (record: BotSortRecord): string => String(record.name || '').trim();
const isNoBotRecord = (record: BotSortRecord): boolean => record.id === '';

export const compareBotsForSortMode = (
  left: BotSortRecord,
  right: BotSortRecord,
  mode: BotSortMode
): number => {
  if (mode === 'recent_activity') {
    const byActivity = botSortTimestamp(right) - botSortTimestamp(left);
    if (byActivity !== 0) return byActivity;
  }

  const byName = botSortName(left).localeCompare(botSortName(right), undefined, {
    sensitivity: 'base',
  });
  if (byName !== 0) return byName;

  return botSortTimestamp(right) - botSortTimestamp(left);
};

export const sortBotsByPreference = <T extends BotSortRecord>(list: T[], mode: BotSortMode): T[] => {
  const records = [...(list || [])];

  if (mode !== 'name') {
    return records.sort((left, right) => compareBotsForSortMode(left, right, mode));
  }

  const noBotOptions = records.filter((record) => isNoBotRecord(record));
  const regularOptions = records
    .filter((record) => !isNoBotRecord(record))
    .sort((left, right) => compareBotsForSortMode(left, right, mode));

  return [...noBotOptions, ...regularOptions];
};

const ensureInitialized = () => {
  if (initialized) return;
  initialized = true;

  mode.value = restoreSortMode();

  persistenceScope.run(() => {
    watch(mode, (next) => {
      persistSortMode(next);
    });
  });

  if (isBrowser()) {
    window.addEventListener('storage', (event) => {
      if (event.key !== BOT_SORT_STORAGE_KEY) return;
      mode.value = normalizeSortMode(event.newValue);
    });
  }
};

export const useBotSortPreference = () => {
  ensureInitialized();
  return mode;
};
