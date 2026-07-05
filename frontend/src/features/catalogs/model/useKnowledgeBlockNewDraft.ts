import { onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { useRoute, type LocationQueryRaw } from 'vue-router';
import {
  createRecordset,
  CRUD_RECORDSET_APPENDED_EVENT,
  CRUD_RECORDSET_REMOVED_EVENT,
  getRecordset,
  type CrudRecordsetChangedDetail,
} from './recordsets';
import { useStackNavigation } from '@/features/stack/useStackNavigation';

type MaybePromise<T> = T | Promise<T>;

type PendingNewBlockContext = {
  contextKey: string | null;
  recordsetKey: string;
  initialIds: number[];
};

type Params = {
  contextKey?: () => unknown;
  linkedBlockIds: () => number[];
  onBlocksCreated: (blockIds: number[]) => MaybePromise<void>;
  onBlocksRemoved?: (blockIds: number[]) => MaybePromise<void>;
  resetOn?: () => unknown;
};

const pendingNewBlockContexts = new Map<string, PendingNewBlockContext>();
const PENDING_RECORDSET_QUERY_KEY = 'pendingNewBlockRecordsetKey';
const PENDING_INITIAL_IDS_QUERY_KEY = 'pendingNewBlockInitialIds';
const PENDING_CONTEXT_QUERY_KEY = 'pendingNewBlockContextKey';
const PENDING_STORAGE_KEY = 'ic_v2_pending_new_block_contexts_v1';
const MAX_STORED_PENDING_CONTEXTS = 20;

type StoredPendingNewBlockContext = PendingNewBlockContext & {
  createdAt: number;
};

function safeParseJson(value: string | null) {
  if (!value) return null;
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

function pickQueryString(raw: unknown): string | null {
  if (Array.isArray(raw)) {
    const value = raw.find((item) => typeof item === 'string');
    return value || null;
  }
  return typeof raw === 'string' && raw.trim() ? raw : null;
}

function parseInitialIds(raw: unknown) {
  const value = pickQueryString(raw);
  if (!value) return [];

  return value
    .split(',')
    .map((item) => Number(item))
    .filter((id) => Number.isFinite(id) && id > 0);
}

function normalizeIds(ids: number[]) {
  return Array.from(new Set((ids || []).filter((id): id is number => typeof id === 'number' && id > 0)));
}

function pendingContextStorageKey(context: PendingNewBlockContext) {
  return context.contextKey || context.recordsetKey;
}

function decodeStoredPendingContexts() {
  if (typeof sessionStorage === 'undefined') return new Map<string, StoredPendingNewBlockContext>();
  const parsed = safeParseJson(sessionStorage.getItem(PENDING_STORAGE_KEY));
  if (!Array.isArray(parsed)) return new Map<string, StoredPendingNewBlockContext>();

  const out = new Map<string, StoredPendingNewBlockContext>();
  for (const item of parsed) {
    if (!Array.isArray(item) || item.length !== 2) continue;
    const [key, value] = item as [unknown, unknown];
    if (typeof key !== 'string' || !value || typeof value !== 'object') continue;

    const raw = value as Partial<StoredPendingNewBlockContext>;
    if (typeof raw.recordsetKey !== 'string' || !raw.recordsetKey.trim()) continue;

    out.set(key, {
      contextKey: typeof raw.contextKey === 'string' && raw.contextKey.trim() ? raw.contextKey : null,
      recordsetKey: raw.recordsetKey,
      initialIds: normalizeIds(Array.isArray(raw.initialIds) ? raw.initialIds.map((id) => Number(id)) : []),
      createdAt: typeof raw.createdAt === 'number' ? raw.createdAt : Date.now(),
    });
  }

  return out;
}

function persistStoredPendingContexts(contexts: Map<string, StoredPendingNewBlockContext>) {
  if (typeof sessionStorage === 'undefined') return;
  const entries = Array.from(contexts.entries())
    .sort((a, b) => b[1].createdAt - a[1].createdAt)
    .slice(0, MAX_STORED_PENDING_CONTEXTS);

  sessionStorage.setItem(PENDING_STORAGE_KEY, JSON.stringify(entries));
}

function storePendingContext(context: PendingNewBlockContext) {
  const contexts = decodeStoredPendingContexts();
  contexts.set(pendingContextStorageKey(context), { ...context, createdAt: Date.now() });
  persistStoredPendingContexts(contexts);
}

function removeStoredPendingContext(context: PendingNewBlockContext, extraKeys: Array<string | null | undefined> = []) {
  const contexts = decodeStoredPendingContexts();
  contexts.delete(pendingContextStorageKey(context));
  contexts.delete(context.recordsetKey);
  for (const key of extraKeys) {
    if (key) contexts.delete(key);
  }
  persistStoredPendingContexts(contexts);
}

function findStoredPendingContext(keys: Array<string | null | undefined>) {
  const contexts = decodeStoredPendingContexts();
  for (const key of keys) {
    if (!key) continue;
    const pending = contexts.get(key);
    if (pending) return pending;
  }
  return null;
}

export function useKnowledgeBlockNewDraft(params: Params) {
  const stackNav = useStackNavigation();
  const route = useRoute();
  const pendingNewBlockContext = ref<PendingNewBlockContext | null>(null);
  const rememberedContextKey = ref<string | null>(null);
  const handledCreatedIds = new Set<number>();
  let pendingSyncTimer: number | null = null;

  const currentContextKey = () => {
    const value = params.contextKey?.();
    if (value === null || value === undefined || value === '') return null;
    return String(value);
  };

  function stopPendingSync() {
    if (pendingSyncTimer === null) return;
    window.clearInterval(pendingSyncTimer);
    pendingSyncTimer = null;
  }

  const rememberPendingContext = (context: PendingNewBlockContext) => {
    pendingNewBlockContext.value = context;

    const key = context.contextKey;
    rememberedContextKey.value = key;
    if (key) pendingNewBlockContexts.set(key, context);
    storePendingContext(context);
  };

  const routePendingContext = (): PendingNewBlockContext | null => {
    const recordsetKey = pickQueryString(route.query[PENDING_RECORDSET_QUERY_KEY]);
    if (!recordsetKey) return null;

    return {
      contextKey: pickQueryString(route.query[PENDING_CONTEXT_QUERY_KEY]),
      recordsetKey,
      initialIds: normalizeIds(parseInitialIds(route.query[PENDING_INITIAL_IDS_QUERY_KEY])),
    };
  };

  const peekPendingContext = () => {
    const key = currentContextKey();
    const rememberedKey = rememberedContextKey.value;
    let pending: PendingNewBlockContext | null = null;

    if (pendingNewBlockContext.value) {
      pending = pendingNewBlockContext.value;
    }

    if (!pending && key) {
      pending = pendingNewBlockContexts.get(key) ?? null;
    }

    if (!pending && rememberedKey && (!key || key === rememberedKey)) {
      pending = pendingNewBlockContexts.get(rememberedKey) ?? null;
    }

    if (!pending) {
      pending = findStoredPendingContext([key, rememberedKey]);
    }

    if (!pending) {
      const routePending = routePendingContext();
      if (routePending && (!key || !routePending.contextKey || key === routePending.contextKey)) {
        pending = routePending;
      }
    }

    if (!pending) {
      const routePending = routePendingContext();
      pending = findStoredPendingContext([routePending?.contextKey, routePending?.recordsetKey]);
    }

    if (!pending) return null;

    return pending;
  };

  const takePendingContext = () => {
    const pending = peekPendingContext();
    if (!pending) return null;

    const key = currentContextKey();
    const rememberedKey = rememberedContextKey.value;
    pendingNewBlockContext.value = null;
    rememberedContextKey.value = null;
    if (key) pendingNewBlockContexts.delete(key);
    if (rememberedKey && rememberedKey !== key) pendingNewBlockContexts.delete(rememberedKey);
    if (pending.contextKey) pendingNewBlockContexts.delete(pending.contextKey);
    removeStoredPendingContext(pending, [key, rememberedKey, pending.contextKey]);

    return pending;
  };

  if (params.resetOn) {
    watch(
      () => params.resetOn?.(),
      () => {
        if (currentContextKey()) return;
        const rememberedKey = rememberedContextKey.value;
        pendingNewBlockContext.value = null;
        rememberedContextKey.value = null;
        stopPendingSync();
        const key = currentContextKey();
        if (key) pendingNewBlockContexts.delete(key);
        if (rememberedKey && rememberedKey !== key) pendingNewBlockContexts.delete(rememberedKey);
      }
    );
  }

  const parentPendingQuery = (context: PendingNewBlockContext): LocationQueryRaw => ({
    ...route.query,
    [PENDING_RECORDSET_QUERY_KEY]: context.recordsetKey,
    [PENDING_INITIAL_IDS_QUERY_KEY]: context.initialIds.join(','),
    ...(context.contextKey ? { [PENDING_CONTEXT_QUERY_KEY]: context.contextKey } : {}),
  });

  const clearRoutePendingContext = async (context: PendingNewBlockContext) => {
    const recordsetKey = pickQueryString(route.query[PENDING_RECORDSET_QUERY_KEY]);
    if (recordsetKey !== context.recordsetKey) return;

    const query: LocationQueryRaw = { ...route.query };
    delete query[PENDING_RECORDSET_QUERY_KEY];
    delete query[PENDING_INITIAL_IDS_QUERY_KEY];
    delete query[PENDING_CONTEXT_QUERY_KEY];
    await stackNav.replace({ path: route.path, query, hash: route.hash });
  };

  const openNewBlock = async () => {
    const ids = normalizeIds(params.linkedBlockIds());
    const recordsetKey = createRecordset(ids);
    const context = {
      contextKey: currentContextKey(),
      recordsetKey,
      initialIds: [...ids],
    };
    rememberPendingContext(context);
    startPendingSync(context);
    await stackNav.replace({ path: route.path, query: parentPendingQuery(context), hash: route.hash });
    await stackNav.open({
      path: '/catalogs/knowledge-blocks/new',
      query: { recordsetKey },
    });
  };

  const handleCreatedIds = async (pending: PendingNewBlockContext, candidateIds: number[]) => {
    const baseline = new Set(pending.initialIds);
    const createdIds = normalizeIds(candidateIds).filter((id) => !baseline.has(id) && !handledCreatedIds.has(id));
    if (!createdIds.length) return false;

    for (const id of createdIds) handledCreatedIds.add(id);
    await params.onBlocksCreated(createdIds);
    return true;
  };

  const handleRemovedIds = async (candidateIds: number[]) => {
    const removedIds = normalizeIds(candidateIds).filter((id) => handledCreatedIds.has(id));
    if (!removedIds.length) return false;

    for (const id of removedIds) handledCreatedIds.delete(id);
    await params.onBlocksRemoved?.(removedIds);
    return true;
  };

  const syncPendingRecordset = async (pending: PendingNewBlockContext) => {
    const recordset = getRecordset(pending.recordsetKey);
    if (!recordset) return;

    await handleCreatedIds(pending, recordset.ids);

    const currentIds = new Set(normalizeIds(recordset.ids));
    const removedIds = Array.from(handledCreatedIds).filter((id) => !currentIds.has(id));
    await handleRemovedIds(removedIds);
  };

  function startPendingSync(context: PendingNewBlockContext) {
    stopPendingSync();
    void syncPendingRecordset(context).catch((error) => {
      console.warn('Failed to sync pending knowledge block recordset.', error);
    });

    pendingSyncTimer = window.setInterval(() => {
      const pending = peekPendingContext();
      if (!pending || pending.recordsetKey !== context.recordsetKey) {
        stopPendingSync();
        return;
      }

      void syncPendingRecordset(pending).catch((error) => {
        console.warn('Failed to sync pending knowledge block recordset.', error);
      });
    }, 250);
  }

  const handleRecordsetAppended = (event: Event) => {
    const detail = (event as CustomEvent<CrudRecordsetChangedDetail>).detail;
    if (!detail || typeof detail.key !== 'string' || typeof detail.id !== 'number') return;

    const pending = peekPendingContext();
    if (!pending || pending.recordsetKey !== detail.key) return;

    void handleCreatedIds(pending, [detail.id]).catch((error) => {
      console.warn('Failed to handle created knowledge block.', error);
    });
  };

  const handleRecordsetRemoved = (event: Event) => {
    const detail = (event as CustomEvent<CrudRecordsetChangedDetail>).detail;
    if (!detail || typeof detail.key !== 'string' || typeof detail.id !== 'number') return;

    const pending = peekPendingContext();
    if (!pending || pending.recordsetKey !== detail.key) return;

    void handleRemovedIds([detail.id]).catch((error) => {
      console.warn('Failed to handle removed knowledge block.', error);
    });
  };

  onMounted(() => {
    window.addEventListener(CRUD_RECORDSET_APPENDED_EVENT, handleRecordsetAppended);
    window.addEventListener(CRUD_RECORDSET_REMOVED_EVENT, handleRecordsetRemoved);
  });

  onBeforeUnmount(() => {
    stopPendingSync();
    window.removeEventListener(CRUD_RECORDSET_APPENDED_EVENT, handleRecordsetAppended);
    window.removeEventListener(CRUD_RECORDSET_REMOVED_EVENT, handleRecordsetRemoved);
  });

  const consumePendingNewBlockContext = async (): Promise<boolean> => {
    const pending = takePendingContext();
    if (!pending) return false;
    stopPendingSync();

    await clearRoutePendingContext(pending);
    const recordset = getRecordset(pending.recordsetKey);
    if (!recordset) return true;

    await handleCreatedIds(pending, recordset.ids);
    return true;
  };

  return {
    openNewBlock,
    consumePendingNewBlockContext,
  };
}
