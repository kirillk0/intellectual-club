function normalizeForStableJson(value: unknown): unknown {
  if (value === undefined) return null;
  if (value === null) return null;
  if (typeof value !== 'object') return value;
  if (value instanceof Date) return value.toISOString();
  if (Array.isArray(value)) return value.map(normalizeForStableJson);

  const record = value as Record<string, unknown>;
  const out: Record<string, unknown> = {};
  for (const key of Object.keys(record).sort()) {
    out[key] = normalizeForStableJson(record[key]);
  }
  return out;
}

export function stableStringify(value: unknown): string {
  return JSON.stringify(normalizeForStableJson(value));
}

