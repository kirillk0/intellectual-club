import { onBeforeUnmount, type Ref } from 'vue';

import { toIntId, type JsonApiResource } from '@/api/jsonApi';

export type EntityKind =
  | 'chat'
  | 'bot'
  | 'knowledge-block'
  | 'llm-configuration'
  | 'llm-provider'
  | 'tool-instance'
  | 'admin-user'
  | 'admin-user-group';

export type EntityChangeOperation = 'upsert' | 'delete' | 'touch';

export type EntityChange = {
  kind: EntityKind;
  operation: EntityChangeOperation;
  id: number;
  resource?: JsonApiResource | null;
  row?: unknown;
  patch?: Record<string, unknown>;
  meta?: Record<string, unknown>;
  timestamp: number;
};

type EntityChangeInput = Omit<EntityChange, 'timestamp'>;
type EntityChangeHandler = (change: EntityChange) => void;

const listeners = new Set<EntityChangeHandler>();

const JSON_API_TYPE_TO_ENTITY_KIND: Record<string, EntityKind> = {
  bots: 'bot',
  'knowledge-blocks': 'knowledge-block',
  'llm-configurations': 'llm-configuration',
  'llm-providers': 'llm-provider',
  'tool-instances': 'tool-instance',
};

export function entityKindForJsonApiType(type: string | null | undefined): EntityKind | null {
  return JSON_API_TYPE_TO_ENTITY_KIND[String(type || '').trim()] ?? null;
}

export function publishEntityChange(change: EntityChangeInput) {
  if (!Number.isInteger(change.id) || change.id <= 0) return;

  const payload: EntityChange = {
    ...change,
    timestamp: Date.now(),
  };

  for (const listener of Array.from(listeners)) {
    listener(payload);
  }
}

export function publishJsonApiEntityChange(
  operation: EntityChangeOperation,
  resource: JsonApiResource | null | undefined
) {
  const kind = entityKindForJsonApiType(resource?.type);
  const id = toIntId(resource?.id);
  if (!kind || !id) return;

  publishEntityChange({
    kind,
    operation,
    id,
    resource,
  });
}

export function subscribeEntityChanges(handler: EntityChangeHandler) {
  listeners.add(handler);
  return () => {
    listeners.delete(handler);
  };
}

export function useEntityChanges(handler: EntityChangeHandler) {
  const unsubscribe = subscribeEntityChanges(handler);
  onBeforeUnmount(unsubscribe);
  return unsubscribe;
}

export function useLiveEntityRows<T>(rows: Ref<T[]>, options: {
  kind: EntityKind;
  getId: (row: T) => number;
  resolveRow?: (change: EntityChange, current: T | null) => T | null | undefined | Promise<T | null | undefined>;
  include?: (row: T, change: EntityChange, current: T | null) => boolean;
  merge?: (current: T | null, incoming: T, change: EntityChange) => T;
  compare?: (left: T, right: T) => number;
}) {
  const tokensById = new Map<number, number>();

  const removeRow = (id: number) => {
    rows.value = rows.value.filter((row) => options.getId(row) !== id);
  };

  const sortRows = (items: T[]) => {
    return options.compare ? [...items].sort(options.compare) : items;
  };

  const applyUpsert = async (change: EntityChange) => {
    const id = change.id;
    const current = rows.value.find((row) => options.getId(row) === id) ?? null;
    const token = (tokensById.get(id) ?? 0) + 1;
    tokensById.set(id, token);

    const resolved = await options.resolveRow?.(change, current);
    if (tokensById.get(id) !== token) return;
    if (!resolved) return;

    if (options.include && !options.include(resolved, change, current)) {
      removeRow(id);
      return;
    }

    const incoming = options.merge
      ? options.merge(current, resolved, change)
      : ({ ...(current ? (current as object) : {}), ...(resolved as object) } as T);
    const index = rows.value.findIndex((row) => options.getId(row) === id);

    if (index === -1) {
      rows.value = sortRows([...rows.value, incoming]);
      return;
    }

    const next = [...rows.value];
    next[index] = incoming;
    rows.value = sortRows(next);
  };

  return useEntityChanges((change) => {
    if (change.kind !== options.kind) return;

    if (change.operation === 'delete') {
      removeRow(change.id);
      return;
    }

    void applyUpsert(change);
  });
}
