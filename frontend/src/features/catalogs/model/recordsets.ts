import { reactive } from 'vue';

export type CrudRecordset = {
  ids: number[];
  createdAt: number;
};

export type CrudRecordsetChangedDetail = {
  key: string;
  id: number;
};

const STORAGE_KEY = 'ic_v2_crud_recordsets_v1';
export const CRUD_RECORDSET_APPENDED_EVENT = 'ic:crud-recordset-appended';
export const CRUD_RECORDSET_REMOVED_EVENT = 'ic:crud-recordset-removed';
const MAX_RECORDSETS = 50;

const recordsets = reactive(new Map<string, CrudRecordset>());

function safeParseJson(value: string | null): unknown {
  if (!value) return null;
  try {
    return JSON.parse(value) as unknown;
  } catch {
    return null;
  }
}

function randomKey(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID();
  }
  return `rs_${Math.random().toString(16).slice(2)}_${Date.now()}`;
}

function decodeRecordsets(value: string | null): Array<[string, CrudRecordset]> {
  const parsed = safeParseJson(value);
  if (!Array.isArray(parsed)) return [];

  const out: Array<[string, CrudRecordset]> = [];
  for (const item of parsed) {
    if (!Array.isArray(item) || item.length !== 2) continue;
    const [key, value] = item as [unknown, unknown];
    if (typeof key !== 'string') continue;
    if (!value || typeof value !== 'object') continue;
    const v = value as Partial<CrudRecordset>;
    const ids = Array.isArray(v.ids) ? v.ids.map((n) => Number(n)).filter(Number.isFinite) : [];
    out.push([
      key,
      {
        ids,
        createdAt: typeof v.createdAt === 'number' ? v.createdAt : Date.now(),
      },
    ]);
  }

  return out;
}

function pruneRecordsets() {
  if (recordsets.size <= MAX_RECORDSETS) return;
  const entries = Array.from(recordsets.entries());
  entries.sort((a, b) => (a[1].createdAt || 0) - (b[1].createdAt || 0));
  const toDelete = Math.max(0, entries.length - MAX_RECORDSETS);
  for (let i = 0; i < toDelete; i += 1) {
    recordsets.delete(entries[i][0]);
  }
}

function persistRecordsets() {
  try {
    const encoded = JSON.stringify(
      Array.from(recordsets.entries()).map(([key, value]) => [key, value])
    );
    sessionStorage.setItem(STORAGE_KEY, encoded);
  } catch {
    // ignore storage failures
  }
}

function restoreRecordsets() {
  for (const [key, value] of decodeRecordsets(sessionStorage.getItem(STORAGE_KEY))) {
    recordsets.set(key, value);
  }

  pruneRecordsets();
}

restoreRecordsets();

function notifyRecordsetChanged(eventName: string, key: string, id: number) {
  if (typeof window === 'undefined' || typeof window.dispatchEvent !== 'function') return;
  window.dispatchEvent(
    new CustomEvent<CrudRecordsetChangedDetail>(eventName, {
      detail: { key, id },
    })
  );
}

export function createRecordset(ids: number[]): string {
  const key = randomKey();
  recordsets.set(key, { ids: Array.from(ids), createdAt: Date.now() });
  pruneRecordsets();
  persistRecordsets();
  return key;
}

export function getRecordset(key: string | null | undefined): CrudRecordset | null {
  if (!key) return null;
  const existing = recordsets.get(key);
  if (existing) return existing;

  const restored = decodeRecordsets(sessionStorage.getItem(STORAGE_KEY)).find(([storedKey]) => storedKey === key);
  if (!restored) return null;

  recordsets.set(restored[0], restored[1]);
  return restored[1];
}

export function appendRecordsetId(key: string, id: number) {
  const rs = getRecordset(key);
  if (!rs) return;
  if (rs.ids.includes(id)) return;
  rs.ids = [...rs.ids, id];
  recordsets.set(key, { ...rs });
  persistRecordsets();
  notifyRecordsetChanged(CRUD_RECORDSET_APPENDED_EVENT, key, id);
}

export function removeRecordsetId(key: string, id: number) {
  const rs = getRecordset(key);
  if (!rs) return;
  if (!rs.ids.includes(id)) return;
  const next = rs.ids.filter((x) => x !== id);
  rs.ids = next;
  recordsets.set(key, { ...rs });
  persistRecordsets();
  notifyRecordsetChanged(CRUD_RECORDSET_REMOVED_EVENT, key, id);
}
